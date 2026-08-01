#!/usr/bin/env bash

set -Eeuo pipefail

ACTION="${1:-demo}"

NAMESPACE="${NAMESPACE:-monitoring}"
ALERTMANAGER_SERVICE="${ALERTMANAGER_SERVICE:-monitoring-kube-prometheus-alertmanager}"
LOCAL_PORT="${LOCAL_PORT:-19093}"

ALERT_NAME="${ALERT_NAME:-}"
SERVICE_LABEL="${SERVICE_LABEL:-notification-test}"

STATE_FILE="${STATE_FILE:-/tmp/togglemaster-notification-alert-name}"
RESOLVE_WAIT_SECONDS="${RESOLVE_WAIT_SECONDS:-20}"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG="/tmp/togglemaster-alertmanager-port-forward.log"
PAYLOAD_FILE=""

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Comando obrigatório não encontrado: $1" >&2
    exit 1
  fi
}

cleanup() {
  set +e

  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "${PAYLOAD_FILE:-}" ]]; then
    rm -f "$PAYLOAD_FILE"
  fi
}

trap cleanup EXIT INT TERM

require_command kubectl
require_command curl
require_command jq
require_command python3

prepare_alert_identity() {
  case "$ACTION" in
    fire | demo)
      if [[ -z "$ALERT_NAME" ]]; then
        ALERT_NAME="ToggleMasterNotificationTest-$(date +%s)"
      fi

      printf '%s' "$ALERT_NAME" > "$STATE_FILE"

      echo "Alerta desta execução: $ALERT_NAME"
      ;;

    resolve | status)
      if [[ -z "$ALERT_NAME" && -s "$STATE_FILE" ]]; then
        ALERT_NAME="$(cat "$STATE_FILE")"
      fi

      if [[ -z "$ALERT_NAME" ]]; then
        echo "❌ Nenhum alerta anterior foi encontrado." >&2
        echo "Execute primeiro: make notification-fire" >&2
        exit 1
      fi

      echo "Alerta selecionado: $ALERT_NAME"
      ;;
  esac
}

prepare_alert_identity

start_port_forward() {
  echo "Abrindo acesso temporário ao Alertmanager..."

  : > "$PORT_FORWARD_LOG"

  kubectl port-forward \
    --namespace "$NAMESPACE" \
    "service/$ALERTMANAGER_SERVICE" \
    "$LOCAL_PORT:9093" \
    >"$PORT_FORWARD_LOG" 2>&1 &

  PORT_FORWARD_PID=$!

  for attempt in $(seq 1 30)
  do
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      echo "❌ O port-forward foi encerrado." >&2
      cat "$PORT_FORWARD_LOG" >&2
      exit 1
    fi

    if curl \
      --silent \
      --show-error \
      --fail \
      --connect-timeout 2 \
      --max-time 3 \
      "http://127.0.0.1:${LOCAL_PORT}/-/ready" \
      >/dev/null 2>&1
    then
      echo "✅ Alertmanager pronto em 127.0.0.1:${LOCAL_PORT}."
      return
    fi

    echo "Aguardando Alertmanager... tentativa $attempt/30"
    sleep 1
  done

  echo "❌ Alertmanager não ficou pronto dentro do prazo." >&2
  cat "$PORT_FORWARD_LOG" >&2
  exit 1
}

create_payload() {
  local state="$1"

  PAYLOAD_FILE="$(mktemp)"

  python3 \
    - "$state" "$ALERT_NAME" "$SERVICE_LABEL" "$PAYLOAD_FILE" \
    <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

state = sys.argv[1]
alert_name = sys.argv[2]
service = sys.argv[3]
output_file = sys.argv[4]

now = datetime.now(timezone.utc)

if state == "firing":
    starts_at = now
    ends_at = now + timedelta(minutes=15)
    description = (
        "Alerta sintético para validar Alertmanager, "
        "Discord e PagerDuty."
    )
    action = "Confirmar o recebimento nos canais de incidente."
else:
    starts_at = now - timedelta(minutes=5)
    ends_at = now
    description = "Teste controlado finalizado com sucesso."
    action = "Nenhuma ação adicional necessária."

payload = [
    {
        "labels": {
            "alertname": alert_name,
            "severity": "critical",
            "category": "availability",
            "service": service,
            "team": "platform",
            "self_healing": "false",
        },
        "annotations": {
            "summary": (
                "Teste controlado de notificações do ToggleMaster"
            ),
            "description": description,
            "impact": "Nenhum impacto real.",
            "action": action,
        },
        "startsAt": starts_at.isoformat().replace("+00:00", "Z"),
        "endsAt": ends_at.isoformat().replace("+00:00", "Z"),
        "generatorURL": (
            "https://github.com/yurijcarmo/tech-challenge-4"
        ),
    }
]

with open(output_file, "w", encoding="utf-8") as file:
    json.dump(payload, file)
PY
}

send_alert() {
  local state="$1"
  local response_file
  local status

  create_payload "$state"

  response_file="$(mktemp)"

  status="$(
    curl \
      --silent \
      --show-error \
      --connect-timeout 5 \
      --max-time 20 \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary "@$PAYLOAD_FILE" \
      "http://127.0.0.1:${LOCAL_PORT}/api/v2/alerts" \
      || true
  )"

  echo "Alertmanager respondeu HTTP ${status:-sem_resposta}."

  if [[ -s "$response_file" ]]; then
    cat "$response_file"
    echo
  fi

  rm -f "$response_file"
  rm -f "$PAYLOAD_FILE"
  PAYLOAD_FILE=""

  if [[ "$status" != "200" && "$status" != "202" ]]; then
    echo "❌ Não foi possível registrar o alerta." >&2
    exit 1
  fi
}

show_alert() {
  curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 5 \
    --max-time 15 \
    "http://127.0.0.1:${LOCAL_PORT}/api/v2/alerts" |
  jq \
    --arg alert_name "$ALERT_NAME" \
    '
      [
        .[]
        | select(.labels.alertname == $alert_name)
        | {
            alertname: .labels.alertname,
            state: .status.state,
            service: .labels.service,
            severity: .labels.severity,
            category: .labels.category,
            startsAt: .startsAt,
            endsAt: .endsAt
          }
      ]
    '
}

fire_alert() {
  echo
  echo "===== DISPARANDO ALERTA SINTÉTICO ====="

  send_alert firing

  echo
  echo "Aguardando o groupWait e o envio das notificações..."
  sleep 15

  echo
  echo "===== ALERTA NO ALERTMANAGER ====="
  show_alert

  echo
  echo "✅ Alerta disparado."
  echo "Confira agora o Discord e o PagerDuty."
}

resolve_alert() {
  echo
  echo "===== RESOLVENDO ALERTA SINTÉTICO ====="

  send_alert resolved

  echo
  echo "✅ Resolução registrada no Alertmanager."
  echo "Aguardando ${RESOLVE_WAIT_SECONDS}s para envio aos canais..."

  sleep "$RESOLVE_WAIT_SECONDS"

  rm -f "$STATE_FILE"

  echo
  echo "✅ Intervalo de notificação concluído."
  echo "Confira o RESOLVED no Discord e no PagerDuty."
}

start_port_forward

case "$ACTION" in
  fire)
    fire_alert
    ;;

  resolve)
    resolve_alert
    ;;

  status)
    show_alert
    ;;

  demo)
    fire_alert

    echo
    read -r -p \
      "Capture as evidências e pressione Enter para resolver o alerta..."

    resolve_alert
    ;;

  *)
    echo "Uso: $0 {fire|resolve|status|demo}" >&2
    exit 1
    ;;
esac
