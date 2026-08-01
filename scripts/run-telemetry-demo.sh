#!/usr/bin/env bash

set -Eeuo pipefail

ACTION="${1:-demo}"

NAMESPACE="${NAMESPACE:-monitoring}"
OTLP_ENDPOINT="${OTLP_ENDPOINT:-otel-collector.monitoring.svc.cluster.local:4317}"
TELEMETRYGEN_IMAGE="${TELEMETRYGEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.156.0}"

DURATION="${DURATION:-5s}"
APP_ITERATIONS="${APP_ITERATIONS:-3}"

RUN_ID="$(date +%s)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Comando obrigatório não encontrado: $1" >&2
    exit 1
  fi
}

generate_signal() {
  local signal="$1"
  local pod_name="telemetry-demo-${signal}-${RUN_ID}"

  echo
  echo "=================================================="
  echo "Gerando sinal: $signal"
  echo "Collector:     $OTLP_ENDPOINT"
  echo "Duração:       $DURATION"
  echo "=================================================="

  kubectl run "$pod_name" \
    --namespace "$NAMESPACE" \
    --restart=Never \
    --attach \
    --rm \
    --image="$TELEMETRYGEN_IMAGE" \
    -- \
    "$signal" \
    --otlp-endpoint "$OTLP_ENDPOINT" \
    --otlp-insecure \
    --duration "$DURATION"

  echo "✅ $signal enviado ao OpenTelemetry Collector."
}

generate_synthetic_telemetry() {
  generate_signal traces
  generate_signal metrics
  generate_signal logs

  echo
  echo "✅ Telemetria sintética concluída."
  echo
  echo "Consultas sugeridas:"
  echo 'Loki:       {service_name="telemetrygen"}'
  echo 'Prometheus: otelcol_receiver_accepted_spans'
  echo 'New Relic:  procurar pelo serviço telemetrygen'
}

generate_application_telemetry() {
  if [[ ! -f "test-flow-eks.sh" ]]; then
    echo "❌ test-flow-eks.sh não encontrado." >&2
    exit 1
  fi

  for ((attempt = 1; attempt <= APP_ITERATIONS; attempt++))
  do
    echo
    echo "=================================================="
    echo "Fluxo real da aplicação $attempt/$APP_ITERATIONS"
    echo "=================================================="

    env -u MASTER_KEY bash test-flow-eks.sh
    sleep 2
  done

  echo
  echo "✅ Tráfego real dos microsserviços gerado."
}

show_help() {
  cat <<'HELP'
Uso:
  scripts/run-telemetry-demo.sh synthetic
  scripts/run-telemetry-demo.sh application
  scripts/run-telemetry-demo.sh demo

Ações:
  synthetic    Gera traces, métricas e logs com telemetrygen.
  application  Executa o fluxo real do ToggleMaster.
  demo         Executa os dois testes.
HELP
}

require_command kubectl

case "$ACTION" in
  synthetic)
    generate_synthetic_telemetry
    ;;

  application)
    generate_application_telemetry
    ;;

  demo)
    generate_application_telemetry
    generate_synthetic_telemetry
    ;;

  help | --help | -h)
    show_help
    ;;

  *)
    echo "❌ Ação inválida: $ACTION" >&2
    show_help
    exit 1
    ;;
esac
