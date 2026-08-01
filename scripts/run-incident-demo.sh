#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-auth-service}"
DEPLOYMENT="${DEPLOYMENT:-auth-service}"
SERVICE="${SERVICE:-auth-service}"
CONFIG_MAP="${CONFIG_MAP:-auth-service-config}"

ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
ARGO_APPLICATION="${ARGO_APPLICATION:-auth-service}"

LOCAL_PORT="${LOCAL_PORT:-18001}"
SERVICE_PORT="${SERVICE_PORT:-8001}"

REQUEST_INTERVAL_SECONDS="${REQUEST_INTERVAL_SECONDS:-1}"
DEMO_TIMEOUT_SECONDS="${DEMO_TIMEOUT_SECONDS:-420}"
SELF_HEALING_COOLDOWN_SECONDS="${SELF_HEALING_COOLDOWN_SECONDS:-300}"

FAILURE_PATH="/internal/demo/failure"
FAILURE_HEADER="X-ToggleMaster-Failure-Test: phase-4-demo"

ARGO_SKIP_ANNOTATION="argocd.argoproj.io/skip-reconcile"
ACTIVATION_ANNOTATION="togglemaster.io/failure-demo-at"
SELF_HEALING_ANNOTATION="togglemaster.io/self-healed-at"

PORT_FORWARD_PID=""
TRAFFIC_PID=""
ARGO_PREVIOUS_SKIP=""
ARGO_PAUSED=0

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Comando obrigatório não encontrado: $1" >&2
    exit 1
  fi
}

get_deployment_annotation() {
  local annotation_key="$1"

  kubectl get deployment "$DEPLOYMENT" \
    --namespace "$NAMESPACE" \
    --output json |
  jq -r \
    --arg key "$annotation_key" \
    '.spec.template.metadata.annotations[$key] // ""'
}

cleanup() {
  set +e

  if [[ -n "${TRAFFIC_PID:-}" ]]; then
    kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
    wait "$TRAFFIC_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi

  kubectl patch configmap "$CONFIG_MAP" \
    --namespace "$NAMESPACE" \
    --type merge \
    --patch '{"data":{"ENABLE_FAILURE_INJECTION":"false"}}' \
    >/dev/null 2>&1 || true

  if [[ "$ARGO_PAUSED" -eq 1 ]]; then
    if [[ "$ARGO_PREVIOUS_SKIP" == "true" ]]; then
      kubectl annotate application \
        --namespace "$ARGO_NAMESPACE" \
        "$ARGO_APPLICATION" \
        "$ARGO_SKIP_ANNOTATION=true" \
        --overwrite >/dev/null 2>&1 || true

    elif [[ -n "$ARGO_PREVIOUS_SKIP" ]]; then
      kubectl annotate application \
        --namespace "$ARGO_NAMESPACE" \
        "$ARGO_APPLICATION" \
        "$ARGO_SKIP_ANNOTATION=$ARGO_PREVIOUS_SKIP" \
        --overwrite >/dev/null 2>&1 || true

    else
      kubectl annotate application \
        --namespace "$ARGO_NAMESPACE" \
        "$ARGO_APPLICATION" \
        "$ARGO_SKIP_ANNOTATION-" \
        >/dev/null 2>&1 || true
    fi

    kubectl annotate application \
      --namespace "$ARGO_NAMESPACE" \
      "$ARGO_APPLICATION" \
      argocd.argoproj.io/refresh=hard \
      --overwrite >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

require_command kubectl
require_command curl
require_command jq
require_command python3

kubectl cluster-info >/dev/null

kubectl get deployment "$DEPLOYMENT" \
  --namespace "$NAMESPACE" >/dev/null

kubectl get service "$SERVICE" \
  --namespace "$NAMESPACE" >/dev/null

kubectl get configmap "$CONFIG_MAP" \
  --namespace "$NAMESPACE" >/dev/null

kubectl get application "$ARGO_APPLICATION" \
  --namespace "$ARGO_NAMESPACE" >/dev/null

kubectl get deployment self-healing-runbook \
  --namespace monitoring >/dev/null

baseline_self_healing="$(
  get_deployment_annotation "$SELF_HEALING_ANNOTATION"
)"

if [[ -n "$baseline_self_healing" ]]; then
  remaining_cooldown="$(
    python3 - \
      "$baseline_self_healing" \
      "$SELF_HEALING_COOLDOWN_SECONDS" \
      <<'PY'
import sys
from datetime import datetime, timezone

value = sys.argv[1]
cooldown = int(sys.argv[2])

try:
    previous = datetime.fromisoformat(
        value.replace("Z", "+00:00")
    )
except ValueError:
    print(0)
    raise SystemExit

elapsed = (
    datetime.now(timezone.utc) - previous
).total_seconds()

print(max(0, int(cooldown - elapsed) + 1))
PY
  )"

  if (( remaining_cooldown > 0 )); then
    echo "❌ O runbook ainda está no período de cooldown." >&2
    echo \
      "Aguarde aproximadamente ${remaining_cooldown}s " \
      "e execute novamente." >&2
    exit 1
  fi
fi

echo
echo "== 1. Pausando temporariamente o auth-service no Argo CD =="

ARGO_PREVIOUS_SKIP="$(
  kubectl get application "$ARGO_APPLICATION" \
    --namespace "$ARGO_NAMESPACE" \
    --output json |
  jq -r \
    --arg key "$ARGO_SKIP_ANNOTATION" \
    '.metadata.annotations[$key] // ""'
)"

kubectl annotate application \
  --namespace "$ARGO_NAMESPACE" \
  "$ARGO_APPLICATION" \
  "$ARGO_SKIP_ANNOTATION=true" \
  --overwrite

ARGO_PAUSED=1

echo
echo "== 2. Habilitando a falha para o próximo Pod =="

kubectl patch configmap "$CONFIG_MAP" \
  --namespace "$NAMESPACE" \
  --type merge \
  --patch '{"data":{"ENABLE_FAILURE_INJECTION":"true"}}'

failure_flag="$(
  kubectl get configmap "$CONFIG_MAP" \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.data.ENABLE_FAILURE_INJECTION}'
)"

if [[ "$failure_flag" != "true" ]]; then
  echo "❌ Não foi possível habilitar a falha no ConfigMap." >&2
  exit 1
fi

echo
echo "== 3. Criando o Pod com a falha controlada =="

activation_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

activation_patch="$(
  jq -nc \
    --arg key "$ACTIVATION_ANNOTATION" \
    --arg value "$activation_time" \
    '{
      spec: {
        template: {
          metadata: {
            annotations: {
              ($key): $value
            }
          }
        }
      }
    }'
)"

kubectl patch deployment "$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --type merge \
  --patch "$activation_patch"

kubectl rollout status "deployment/$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --timeout=180s

echo
echo "== 4. Abrindo acesso temporário ao auth-service =="

kubectl port-forward \
  --namespace "$NAMESPACE" \
  "service/$SERVICE" \
  "$LOCAL_PORT:$SERVICE_PORT" \
  >/tmp/togglemaster-auth-port-forward.log 2>&1 &

PORT_FORWARD_PID=$!
service_ready=0

for attempt in $(seq 1 30)
do
  if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
    cat /tmp/togglemaster-auth-port-forward.log >&2 || true
    echo "❌ O port-forward foi encerrado antes do teste." >&2
    exit 1
  fi

  if curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 2 \
    --max-time 5 \
    "http://127.0.0.1:${LOCAL_PORT}/health" \
    >/dev/null 2>&1
  then
    service_ready=1
    break
  fi

  echo "Aguardando auth-service... tentativa $attempt/30"
  sleep 1
done

if [[ "$service_ready" -ne 1 ]]; then
  echo "❌ O auth-service não ficou acessível." >&2
  exit 1
fi

echo
echo "== 5. Confirmando que a falha retorna HTTP 500 =="

initial_failure_status="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout 2 \
    --max-time 5 \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header "$FAILURE_HEADER" \
    "http://127.0.0.1:${LOCAL_PORT}${FAILURE_PATH}" \
    || true
)"

if [[ "$initial_failure_status" != "500" ]]; then
  echo \
    "❌ A falha não foi ativada. Status recebido: " \
    "${initial_failure_status:-sem_resposta}." >&2

  echo "ConfigMap atual:" >&2

  kubectl get configmap "$CONFIG_MAP" \
    --namespace "$NAMESPACE" \
    --output jsonpath='{
      .data.ENABLE_FAILURE_INJECTION
    }{"\n"}' >&2 || true

  exit 1
fi

echo "✅ Endpoint de demonstração retornou HTTP 500."

echo
echo "== 6. Restaurando o ConfigMap para o próximo Pod =="

kubectl patch configmap "$CONFIG_MAP" \
  --namespace "$NAMESPACE" \
  --type merge \
  --patch '{"data":{"ENABLE_FAILURE_INJECTION":"false"}}'

echo
echo "== 7. Gerando erros HTTP 500 até o alerta disparar =="

(
  request_number=0

  while true
  do
    request_number=$((request_number + 1))

    status_code="$(
      curl \
        --silent \
        --show-error \
        --connect-timeout 2 \
        --max-time 5 \
        --output /dev/null \
        --write-out '%{http_code}' \
        --header "$FAILURE_HEADER" \
        "http://127.0.0.1:${LOCAL_PORT}${FAILURE_PATH}" \
        || true
    )"

    printf \
      'request=%s status=%s\n' \
      "$request_number" \
      "${status_code:-connection_error}"

    sleep "$REQUEST_INTERVAL_SECONDS"
  done
) &

TRAFFIC_PID=$!

echo
echo "== 8. Aguardando o rollout de self-healing =="
echo \
  "A regra exige taxa de 5xx acima de 5%, " \
  "20 requisições e persistência por 2 minutos."

started_at="$(date +%s)"
self_healing_restart=""

while (( $(date +%s) - started_at < DEMO_TIMEOUT_SECONDS ))
do
  current_restart="$(
    get_deployment_annotation "$SELF_HEALING_ANNOTATION"
  )"

  if [[
    -n "$current_restart"
    && "$current_restart" != "$baseline_self_healing"
  ]]
  then
    self_healing_restart="$current_restart"
    break
  fi

  sleep 10
done

if [[ -z "$self_healing_restart" ]]; then
  echo \
    "❌ O Self-Healing não foi detectado em " \
    "${DEMO_TIMEOUT_SECONDS}s." >&2

  echo \
    "Confira Prometheus, Alertmanager e os logs " \
    "do self-healing-runbook." >&2

  exit 1
fi

kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
wait "$TRAFFIC_PID" >/dev/null 2>&1 || true
TRAFFIC_PID=""

echo "✅ Runbook solicitou o rollout em: $self_healing_restart"

kubectl rollout status "deployment/$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --timeout=180s

sleep 5

recovered_status="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout 2 \
    --max-time 5 \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header "$FAILURE_HEADER" \
    "http://127.0.0.1:${LOCAL_PORT}${FAILURE_PATH}" \
    || true
)"

if [[ "$recovered_status" == "500" ]]; then
  echo "❌ O novo Pod ainda iniciou com a falha habilitada." >&2
  exit 1
fi

echo \
  "✅ Novo Pod saudável. " \
  "Endpoint de falha retornou: $recovered_status"

echo
echo "Demonstração concluída:"
echo "- falha controlada confirmou HTTP 500;"
echo "- Prometheus e Alertmanager detectaram o incidente;"
echo "- o runbook solicitou um novo rollout;"
echo "- o Pod novo iniciou com a falha desabilitada."
