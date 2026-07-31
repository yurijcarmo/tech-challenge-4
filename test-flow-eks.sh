#!/usr/bin/env bash
set -euo pipefail

MASTER_KEY="${MASTER_KEY:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

HTTP_SCHEME="${HTTP_SCHEME:-http}"
LB_HOST="${LB_HOST:-}"

if [ -z "$LB_HOST" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Erro: kubectl nao encontrado no PATH." >&2
    exit 1
  fi

  LB_HOST="$(
    kubectl get service       -n ingress-nginx       ingress-nginx-controller       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  )"
fi

if [ -z "$LB_HOST" ]; then
  echo "Erro: o hostname do Load Balancer do ingress-nginx nao foi encontrado." >&2
  exit 1
fi

BASE_URL="${BASE_URL:-${HTTP_SCHEME}://${LB_HOST}}"

AUTH_URL="${AUTH_URL:-${BASE_URL}/auth}"
FLAG_URL="${FLAG_URL:-${BASE_URL}/flag}"
TARGETING_URL="${TARGETING_URL:-${BASE_URL}/targeting}"
EVAL_URL="${EVAL_URL:-${BASE_URL}/evaluation}"

# Usa a chave informada pelo usuário ou recupera automaticamente
# o valor sincronizado pelo External Secrets no Kubernetes.
if [ -z "${MASTER_KEY:-}" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Erro: kubectl não encontrado e MASTER_KEY não foi informada." >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Erro: python3 não encontrado para decodificar o Secret." >&2
    exit 1
  fi

  MASTER_KEY_B64="$(
    kubectl get secret \
      -n auth-service \
      auth-service-secrets \
      -o jsonpath='{.data.MASTER_KEY}' \
      2>/dev/null || true
  )"

  if [ -z "$MASTER_KEY_B64" ]; then
    echo "Erro: MASTER_KEY não encontrada no Secret auth-service-secrets." >&2
    exit 1
  fi

  MASTER_KEY="$(
    printf '%s' "$MASTER_KEY_B64" |
      python3 -c '
import base64
import sys

encoded = sys.stdin.read().strip()
print(base64.b64decode(encoded).decode(), end="")
'
  )"

  unset MASTER_KEY_B64
fi

if [ -z "${MASTER_KEY:-}" ]; then
  echo "Erro: MASTER_KEY está vazia." >&2
  exit 1
fi

echo "Load Balancer detectado: $LB_HOST"
echo "URL base dos microsservicos: $BASE_URL"

SERVICE_API_KEY="${SERVICE_API_KEY:-}"
RULE_PERCENT="${RULE_PERCENT:-50}"
USER_ID="${USER_ID:-user-$RANDOM}"

wait_for_health() {
  local name="$1"
  local url="$2"

  echo "Aguardando $name em $url..."
  for _ in {1..30}; do
    if curl -fsS --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1; then
      echo "$name OK"
      return 0
    fi
    sleep 2
  done

  echo "Timeout aguardando $name"
  return 1
}

wait_for_health "auth-service" "$AUTH_URL/health"
wait_for_health "flag-service" "$FLAG_URL/health"
wait_for_health "targeting-service" "$TARGETING_URL/health"
wait_for_health "evaluation-service" "$EVAL_URL/health"

if [ -z "$SERVICE_API_KEY" ]; then
  echo "Criando chave de API..."
  CREATE_KEY_BODY=""
  CREATE_KEY_STATUS=""
  for _ in {1..5}; do
    CREATE_KEY_BODY="$(curl -sS -o /tmp/create_key_body.json -w "%{http_code}" -X POST "$AUTH_URL/admin/keys" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $MASTER_KEY" \
      -d '{"name":"test-flow"}' || true)"
    CREATE_KEY_STATUS="$CREATE_KEY_BODY"
    CREATE_KEY_BODY="$(cat /tmp/create_key_body.json 2>/dev/null || true)"
    if [ -n "$CREATE_KEY_BODY" ] && [ "$CREATE_KEY_STATUS" = "201" ]; then
      break
    fi
    sleep 2
  done

  if [ -z "$CREATE_KEY_BODY" ] || [ "$CREATE_KEY_STATUS" != "201" ]; then
    echo "Erro ao criar chave de API (status ${CREATE_KEY_STATUS:-unknown})."
    if [ -n "$CREATE_KEY_BODY" ]; then
      echo "Resposta: $CREATE_KEY_BODY"
    fi
    exit 1
  fi

  SERVICE_API_KEY="$(python3 - <<'PY' "$CREATE_KEY_BODY"
import json, sys
data = json.loads(sys.argv[1])
print(data["key"])
PY
)"

  export SERVICE_API_KEY
  echo "SERVICE_API_KEY definida para esta execucao."
fi

echo "Chave de API criada com sucesso."

RAND_SUFFIX="$(date +%s)-$RANDOM"
FLAG_NAME="enable-new-dashboard-$RAND_SUFFIX"

echo "Criando flag '$FLAG_NAME'..."
FLAG_STATUS="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$FLAG_URL/flags" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SERVICE_API_KEY" \
  -d "{\"name\":\"$FLAG_NAME\",\"description\":\"Flag criada pelo teste\",\"is_enabled\":true}")"
if [ "$FLAG_STATUS" != "201" ]; then
  echo "Erro ao criar flag (status $FLAG_STATUS)."
  exit 1
fi

echo "Criando regra de targeting ($RULE_PERCENT%)..."
RULE_STATUS="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$TARGETING_URL/rules" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SERVICE_API_KEY" \
  -d "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":$RULE_PERCENT}}")"
if [ "$RULE_STATUS" != "201" ]; then
  echo "Erro ao criar regra (status $RULE_STATUS)."
  exit 1
fi

echo "Testando avaliacao (user_id=$USER_ID)..."

if [ -z "${SERVICE_API_KEY:-}" ]; then
  echo "Erro: SERVICE_API_KEY está vazia antes da avaliação."
  exit 1
fi

EVAL_ENDPOINT="${EVAL_URL}/evaluate?user_id=${USER_ID}&flag_name=${FLAG_NAME}"

echo "Endpoint: $EVAL_ENDPOINT"
echo "API key carregada (${#SERVICE_API_KEY} caracteres)."

EVAL_BODY_FILE="$(mktemp)"

EVAL_STATUS="$(
  curl -sS \
    --connect-timeout 5 \
    --max-time 20 \
    --output "$EVAL_BODY_FILE" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer ${SERVICE_API_KEY}" \
    "$EVAL_ENDPOINT" || true
)"

EVAL_BODY="$(cat "$EVAL_BODY_FILE" 2>/dev/null || true)"
rm -f "$EVAL_BODY_FILE"

if [ "$EVAL_STATUS" != "200" ]; then
  echo "Erro na avaliação (status ${EVAL_STATUS:-unknown})."

  if [ -n "$EVAL_BODY" ]; then
    echo "Resposta: $EVAL_BODY"
  fi

  exit 1
fi

echo "Avaliação concluída com sucesso."
printf '%s\n' "$EVAL_BODY"
