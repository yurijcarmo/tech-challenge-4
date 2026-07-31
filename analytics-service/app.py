import json
import logging
import os
import signal
import sys
import threading
import uuid

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from dotenv import load_dotenv
from flask import Flask, jsonify
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind, Status, StatusCode

from telemetry import setup_telemetry


logging.basicConfig(
    level=logging.INFO,
    format=(
        "%(asctime)s - %(levelname)s - trace_id=%(trace_id)s "
        "span_id=%(span_id)s - %(message)s"
    ),
)
log = logging.getLogger(__name__)

load_dotenv()

app = Flask(__name__)
telemetry = setup_telemetry(
    app,
    os.getenv("OTEL_SERVICE_NAME", "analytics-service"),
    instrument_botocore=True,
)
tracer = trace.get_tracer(__name__)
stop_event = threading.Event()
worker_thread: threading.Thread | None = None
shutdown_lock = threading.Lock()
shutdown_started = False

AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")
AWS_SQS_ENDPOINT = os.getenv("AWS_SQS_ENDPOINT")
AWS_DYNAMODB_ENDPOINT = os.getenv("AWS_DYNAMODB_ENDPOINT")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical("Erro: AWS_REGION, AWS_SQS_URL, e AWS_DYNAMODB_TABLE devem ser definidos.")
    sys.exit(1)

try:
    session = boto3.Session(region_name=AWS_REGION)
    sqs_client = session.client("sqs", endpoint_url=AWS_SQS_ENDPOINT)
    dynamodb_client = session.client("dynamodb", endpoint_url=AWS_DYNAMODB_ENDPOINT)
    log.info("Clientes Boto3 inicializados na região %s", AWS_REGION)
except NoCredentialsError:
    log.critical("Credenciais da AWS não encontradas. Verifique seu ambiente.")
    sys.exit(1)
except Exception as exc:
    log.critical("Erro ao inicializar o Boto3: %s", exc)
    sys.exit(1)


def _trace_carrier(message: dict) -> dict[str, str]:
    """Converts SQS string message attributes into an OpenTelemetry carrier."""
    carrier: dict[str, str] = {}
    for key, value in message.get("MessageAttributes", {}).items():
        string_value = value.get("StringValue")
        if string_value:
            carrier[key] = string_value
    return carrier


def process_message(message: dict) -> None:
    """Continues the producer trace and persists one SQS analytics event."""
    parent_context = propagate.extract(carrier=_trace_carrier(message))
    message_id = message.get("MessageId", "unknown")
    queue_name = SQS_QUEUE_URL.rsplit("/", maxsplit=1)[-1]

    with tracer.start_as_current_span(
        "SQS ProcessMessage",
        context=parent_context,
        kind=SpanKind.CONSUMER,
        attributes={
            "messaging.system": "aws_sqs",
            "messaging.destination.name": queue_name,
            "messaging.operation.name": "process",
            "messaging.message.id": message_id,
        },
    ) as span:
        try:
            log.info("Processando mensagem ID: %s", message_id)
            body = json.loads(message["Body"])
            event_id = str(uuid.uuid4())

            item = {
                "event_id": {"S": event_id},
                "user_id": {"S": body["user_id"]},
                "flag_name": {"S": body["flag_name"]},
                "result": {"BOOL": body["result"]},
                "timestamp": {"S": body["timestamp"]},
            }

            dynamodb_client.put_item(
                TableName=DYNAMODB_TABLE_NAME,
                Item=item,
            )
            log.info(
                "Evento %s (Flag: %s) salvo no DynamoDB.",
                event_id,
                body["flag_name"],
            )

            sqs_client.delete_message(
                QueueUrl=SQS_QUEUE_URL,
                ReceiptHandle=message["ReceiptHandle"],
            )
            span.set_attribute("analytics.event.persisted", True)

        except json.JSONDecodeError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, "invalid message JSON"))
            log.error("Erro ao decodificar JSON da mensagem ID: %s", message_id)
        except ClientError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            log.error(
                "Erro do Boto3 (DynamoDB ou SQS) ao processar %s: %s",
                message_id,
                exc,
            )
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            log.error("Erro inesperado ao processar %s: %s", message_id, exc)


def sqs_worker_loop() -> None:
    """Long-polls SQS until the application receives a shutdown signal."""
    log.info("Iniciando o worker SQS...")
    while not stop_event.is_set():
        try:
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                MessageAttributeNames=["All"],
            )

            messages = response.get("Messages", [])
            if not messages:
                continue

            log.info("Recebidas %d mensagens.", len(messages))
            for message in messages:
                process_message(message)

        except ClientError as exc:
            log.error("Erro do Boto3 no loop principal do SQS: %s", exc)
            stop_event.wait(10)
        except Exception as exc:
            log.error("Erro inesperado no loop principal do SQS: %s", exc)
            stop_event.wait(10)

    log.info("Worker SQS encerrado.")


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


def start_worker() -> None:
    global worker_thread
    worker_thread = threading.Thread(
        target=sqs_worker_loop,
        name="sqs-worker",
        daemon=True,
    )
    worker_thread.start()


def shutdown_application(signum=None, _frame=None) -> None:
    """Stops the worker, waits for its current work and flushes telemetry."""
    global shutdown_started
    with shutdown_lock:
        if shutdown_started:
            return
        shutdown_started = True

    if signum is not None:
        log.info("Sinal %s recebido. Encerrando o serviço...", signum)

    stop_event.set()
    if (
        worker_thread is not None
        and worker_thread.is_alive()
        and threading.current_thread() is not worker_thread
    ):
        worker_thread.join(timeout=25)
        if worker_thread.is_alive():
            log.warning("Worker SQS não encerrou dentro do prazo de 25 segundos.")

    telemetry.shutdown()

    if signum is not None:
        raise SystemExit(0)


signal.signal(signal.SIGTERM, shutdown_application)
signal.signal(signal.SIGINT, shutdown_application)
start_worker()

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8005))
    app.run(host="0.0.0.0", port=port, debug=False)
