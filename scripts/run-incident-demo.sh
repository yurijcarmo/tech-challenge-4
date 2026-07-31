#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-auth-service}"
DEPLOYMENT="${DEPLOYMENT:-auth-service}"
SERVICE="${SERVICE:-auth-service}"
CONFIG_MAP="${CONFIG_MAP:-auth-service-config}"
LOCAL_PORT="${LOCAL_PORT:-18001}"
SERVICE_PORT="${SERVICE_PORT:-8001}"
REQUEST_INTERVAL_SECONDS="${REQUEST_INTERVAL_SECONDS:-1}"
DEMO_TIMEOUT_SECONDS="${DEMO_TIMEOUT_SECONDS:-420}"
FAILURE_PATH="/internal/demo/failure"
FAILURE_HEADER="X-ToggleMaster-Failure-Test: phase-4-demo"
RESTART_ANNOTATION='kubectl.kubernetes.io/restartedAt'
PORT_FORWARD_PID=""
TRAFFIC_PID=""

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Comando obrigatório não encontrado: $1" >&2
    exit 1
  fi
}

cleanup() {
  set +e
  kubectl patch configmap "$CONFIG_MAP" \
    --namespace "$NAMESPACE" \
    --type merge \
    --patch '{"data":{"ENABLE_FAILURE_INJECTION":"false"}}' \
    >/dev/null 2>&1

  if [[ -n "$TRAFFIC_PID" ]]; then
    kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
    wait "$TRAFFIC_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

require_command kubectl
require_command curl

kubectl cluster-info >/dev/null
kubectl get deployment "$DEPLOYMENT" --namespace "$NAMESPACE" >/dev/null
kubectl get service "$SERVICE" --namespace "$NAMESPACE" >/dev/null
kubectl get configmap "$CONFIG_MAP" --namespace "$NAMESPACE" >/dev/null

echo "== 1. Habilitando a falha somente no próximo Pod =="
kubectl patch configmap "$CONFIG_MAP" \
  --namespace "$NAMESPACE" \
  --type merge \
  --patch '{"data":{"ENABLE_FAILURE_INJECTION":"true"}}'

echo "== 2. Reiniciando o auth-service para carregar a falha controlada =="
kubectl rollout restart "deployment/$DEPLOYMENT" --namespace "$NAMESPACE"
kubectl rollout status "deployment/$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --timeout=180s

activation_restart="$({
  kubectl get deployment "$DEPLOYMENT" \
    --namespace "$NAMESPACE" \
    --output "jsonpath={.spec.template.metadata.annotations.${RESTART_ANNOTATION//./\\.}}"
} 2>/dev/null || true)"

if [[ -z "$activation_restart" ]]; then
  echo "❌ Não foi possível identificar a anotação do rollout inicial." >&2
  exit 1
fi

echo "== 3. Restaurando o ConfigMap para false =="
echo "O Pod atual continua com a falha ativa, mas o próximo Pod iniciará saudável."
kubectl patch configmap "$CONFIG_MAP" \
  --namespace "$NAMESPACE" \
  --type merge \
  --patch '{"data":{"ENABLE_FAILURE_INJECTION":"false"}}'

echo "== 4. Abrindo acesso local temporário ao Service =="
kubectl port-forward \
  --namespace "$NAMESPACE" \
  "service/$SERVICE" \
  "$LOCAL_PORT:$SERVICE_PORT" \
  >/tmp/togglemaster-auth-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!

for _ in $(seq 1 30); do
  if curl --silent --show-error --fail \
    "http://127.0.0.1:${LOCAL_PORT}/health" \
    >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
  cat /tmp/togglemaster-auth-port-forward.log >&2 || true
  echo "❌ O port-forward foi encerrado antes do teste." >&2
  exit 1
fi

echo "== 5. Gerando respostas HTTP 500 =="
(
  request_number=0
  while true; do
    request_number=$((request_number + 1))
    status_code="$(curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --header "$FAILURE_HEADER" \
      "http://127.0.0.1:${LOCAL_PORT}${FAILURE_PATH}" \
      || true)"

    printf 'request=%s status=%s\n' "$request_number" "${status_code:-connection_error}"
    sleep "$REQUEST_INTERVAL_SECONDS"
  done
) &
TRAFFIC_PID=$!

echo "== 6. Aguardando o Self-Healing solicitar um novo rollout =="
echo "O alerta exige tráfego, taxa de 5xx acima de 5% e persistência por 2 minutos."

started_at="$(date +%s)"
self_healing_restart=""
while (( $(date +%s) - started_at < DEMO_TIMEOUT_SECONDS )); do
  current_restart="$({
    kubectl get deployment "$DEPLOYMENT" \
      --namespace "$NAMESPACE" \
      --output "jsonpath={.spec.template.metadata.annotations.${RESTART_ANNOTATION//./\\.}}"
  } 2>/dev/null || true)"

  if [[ -n "$current_restart" && "$current_restart" != "$activation_restart" ]]; then
    self_healing_restart="$current_restart"
    break
  fi

  sleep 10
done

if [[ -z "$self_healing_restart" ]]; then
  echo "❌ O Self-Healing não foi detectado em ${DEMO_TIMEOUT_SECONDS}s." >&2
  echo "Confira Prometheus, Alertmanager e os logs do self-healing-runbook." >&2
  exit 1
fi

echo "✅ Novo rollout solicitado automaticamente em: $self_healing_restart"
kubectl rollout status "deployment/$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --timeout=180s

sleep 5
recovered_status="$(curl \
  --silent \
  --output /dev/null \
  --write-out '%{http_code}' \
  --header "$FAILURE_HEADER" \
  "http://127.0.0.1:${LOCAL_PORT}${FAILURE_PATH}" \
  || true)"

if [[ "$recovered_status" == "500" ]]; then
  echo "❌ O novo Pod ainda está com a falha habilitada." >&2
  exit 1
fi

echo "✅ Falha desabilitada no novo Pod. Status atual do endpoint: $recovered_status"
echo
printf '%s\n' \
  "Demonstração concluída:" \
  "- respostas HTTP 500 foram geradas;" \
  "- o alerta pôde atingir o estado firing;" \
  "- o Self-Healing solicitou um novo rollout;" \
  "- o Pod novo iniciou com a falha desabilitada."
