import atexit
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

from flask import Flask, g, request
from opentelemetry import metrics, propagate, trace
from opentelemetry.baggage.propagation import W3CBaggagePropagator
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


class TraceContextFilter(logging.Filter):
    """Adds the current trace and span identifiers to application log records."""

    def filter(self, record: logging.LogRecord) -> bool:
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            record.trace_id = format(span_context.trace_id, "032x")
            record.span_id = format(span_context.span_id, "016x")
        else:
            record.trace_id = "0" * 32
            record.span_id = "0" * 16
        return True


@dataclass
class Telemetry:
    tracer_provider: TracerProvider
    meter_provider: MeterProvider
    _shutdown_lock: threading.Lock = field(default_factory=threading.Lock)
    _shutdown_complete: bool = False

    def shutdown(self) -> None:
        """Flushes pending telemetry before the Python worker exits."""
        with self._shutdown_lock:
            if self._shutdown_complete:
                return
            self._shutdown_complete = True

        self.tracer_provider.force_flush(timeout_millis=5_000)
        self.meter_provider.force_flush(timeout_millis=5_000)
        self.tracer_provider.shutdown()
        self.meter_provider.shutdown()


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _configure_log_correlation() -> None:
    trace_filter = TraceContextFilter()
    root_logger = logging.getLogger()
    for handler in root_logger.handlers:
        handler.addFilter(trace_filter)


def _configure_http_metrics(app: Flask, service_name: str, meter_provider: MeterProvider) -> None:
    meter = meter_provider.get_meter("togglemaster.http")
    request_counter = meter.create_counter(
        "togglemaster_http_server_requests",
        unit="1",
        description="Number of HTTP requests handled by the service",
    )
    request_duration = meter.create_histogram(
        "togglemaster_http_server_request_duration",
        unit="s",
        description="Duration of HTTP requests handled by the service",
    )

    @app.before_request
    def _start_http_measurement() -> None:
        g.otel_request_started_at = time.perf_counter()

    @app.after_request
    def _record_http_measurement(response):
        started_at: Optional[float] = getattr(g, "otel_request_started_at", None)
        if started_at is None:
            return response

        route = request.url_rule.rule if request.url_rule else "unmatched"
        attributes = {
            "service.name": service_name,
            "http.request.method": request.method,
            "http.route": route,
            "http.response.status_code": response.status_code,
        }
        request_counter.add(1, attributes)
        request_duration.record(time.perf_counter() - started_at, attributes)
        return response


def setup_telemetry(
    app: Flask,
    service_name: str,
    *,
    instrument_requests: bool = False,
    instrument_psycopg2: bool = False,
    instrument_botocore: bool = False,
) -> Telemetry:
    """Configures traces, metrics and context propagation for a Python service."""
    _configure_log_correlation()

    endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "otel-collector.monitoring.svc.cluster.local:4317",
    )
    insecure = _env_bool("OTEL_EXPORTER_OTLP_INSECURE", True)
    export_interval = int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", "15000"))

    resource = Resource.create({SERVICE_NAME: service_name})

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint=endpoint, insecure=insecure),
        )
    )
    trace.set_tracer_provider(tracer_provider)

    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=endpoint, insecure=insecure),
        export_interval_millis=export_interval,
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    propagate.set_global_textmap(
        CompositePropagator(
            [TraceContextTextMapPropagator(), W3CBaggagePropagator()]
        )
    )

    FlaskInstrumentor().instrument_app(
        app,
        tracer_provider=tracer_provider,
        meter_provider=meter_provider,
    )

    if instrument_requests:
        from opentelemetry.instrumentation.requests import RequestsInstrumentor

        RequestsInstrumentor().instrument(
            tracer_provider=tracer_provider,
            meter_provider=meter_provider,
        )

    if instrument_psycopg2:
        from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

        Psycopg2Instrumentor().instrument(tracer_provider=tracer_provider)

    if instrument_botocore:
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor

        BotocoreInstrumentor().instrument(
            tracer_provider=tracer_provider,
            meter_provider=meter_provider,
        )

    _configure_http_metrics(app, service_name, meter_provider)

    telemetry = Telemetry(tracer_provider, meter_provider)
    atexit.register(telemetry.shutdown)
    return telemetry
