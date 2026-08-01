#!/usr/bin/env bash

set -Eeuo pipefail

AUTH_NAMESPACE="${AUTH_NAMESPACE:-auth-service}"
AUTH_DEPLOYMENT="${AUTH_DEPLOYMENT:-auth-service}"
AUTH_CONFIGMAP="${AUTH_CONFIGMAP:-auth-service-config}"

RUNBOOK_NAMESPACE="${RUNBOOK_NAMESPACE:-monitoring}"
RUNBOOK_DEPLOYMENT="${RUNBOOK_DEPLOYMENT:-self-healing-runbook}"

SELF_HEALING_ANNOTATION="togglemaster.io/self-healed-at"
LOG_LOOKBACK="${LOG_LOOKBACK:-20m}"

ERRORS=0

success() {
  echo "✅ $1"
}

failure() {
  echo "❌ $1" >&2
  ERRORS=$((ERRORS + 1))
}

echo
echo "=================================================="
echo " COMPROVAÇÃO DO SELF-HEALING"
echo "=================================================="

echo
echo "===== 1. ANOTAÇÃO DO SELF-HEALING ====="

SELF_HEALED_AT="$(
  kubectl get deployment \
    -n "$AUTH_NAMESPACE" \
    "$AUTH_DEPLOYMENT" \
    -o json |
  jq -r \
    --arg key "$SELF_HEALING_ANNOTATION" \
    '.spec.template.metadata.annotations[$key] // ""'
)"

if [[ -n "$SELF_HEALED_AT" ]]; then
  echo "self-healed-at: $SELF_HEALED_AT"
  success "O runbook registrou a solicitação de recuperação."
else
  failure "A anotação $SELF_HEALING_ANNOTATION não foi encontrada."
fi

echo
echo "===== 2. ESTADO DO DEPLOYMENT ====="

kubectl get deployment \
  -n "$AUTH_NAMESPACE" \
  "$AUTH_DEPLOYMENT" \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas'

DEPLOYMENT_STATUS="$(
  kubectl get deployment \
    -n "$AUTH_NAMESPACE" \
    "$AUTH_DEPLOYMENT" \
    -o json
)"

DESIRED="$(
  printf '%s' "$DEPLOYMENT_STATUS" |
  jq -r '.spec.replicas // 0'
)"

READY="$(
  printf '%s' "$DEPLOYMENT_STATUS" |
  jq -r '.status.readyReplicas // 0'
)"

UPDATED="$(
  printf '%s' "$DEPLOYMENT_STATUS" |
  jq -r '.status.updatedReplicas // 0'
)"

AVAILABLE="$(
  printf '%s' "$DEPLOYMENT_STATUS" |
  jq -r '.status.availableReplicas // 0'
)"

if [[
  "$READY" -eq "$DESIRED" &&
  "$UPDATED" -eq "$DESIRED" &&
  "$AVAILABLE" -eq "$DESIRED"
]]; then
  success "Deployment totalmente disponível."
else
  failure \
    "Deployment inconsistente: desired=$DESIRED ready=$READY updated=$UPDATED available=$AVAILABLE."
fi

echo
echo "===== 3. POD MAIS RECENTE ====="

LATEST_POD_JSON="$(
  kubectl get pods \
    -n "$AUTH_NAMESPACE" \
    -l app="$AUTH_DEPLOYMENT" \
    -o json |
  jq -c '
    .items
    | sort_by(.metadata.creationTimestamp)
    | last
  '
)"

LATEST_POD_NAME="$(
  printf '%s' "$LATEST_POD_JSON" |
  jq -r '.metadata.name // ""'
)"

LATEST_POD_PHASE="$(
  printf '%s' "$LATEST_POD_JSON" |
  jq -r '.status.phase // ""'
)"

LATEST_POD_READY="$(
  printf '%s' "$LATEST_POD_JSON" |
  jq -r '
    [
      .status.containerStatuses[]?
      | select(.ready == true)
    ]
    | length
  '
)"

LATEST_POD_CONTAINERS="$(
  printf '%s' "$LATEST_POD_JSON" |
  jq -r '(.status.containerStatuses // []) | length'
)"

LATEST_POD_CREATED="$(
  printf '%s' "$LATEST_POD_JSON" |
  jq -r '.metadata.creationTimestamp // ""'
)"

echo "Nome:      $LATEST_POD_NAME"
echo "Status:    $LATEST_POD_PHASE"
echo "Ready:     $LATEST_POD_READY/$LATEST_POD_CONTAINERS"
echo "Criado em: $LATEST_POD_CREATED"

if [[
  "$LATEST_POD_PHASE" == "Running" &&
  "$LATEST_POD_CONTAINERS" -gt 0 &&
  "$LATEST_POD_READY" -eq "$LATEST_POD_CONTAINERS"
]]; then
  success "O Pod mais recente está Running e Ready."
else
  failure "O Pod mais recente ainda não está completamente saudável."
fi

echo
echo "===== 4. CONFIGURAÇÃO DA FALHA ====="

FAILURE_INJECTION="$(
  kubectl get configmap \
    -n "$AUTH_NAMESPACE" \
    "$AUTH_CONFIGMAP" \
    -o jsonpath='{.data.ENABLE_FAILURE_INJECTION}'
)"

echo "ENABLE_FAILURE_INJECTION=$FAILURE_INJECTION"

if [[ "$FAILURE_INJECTION" == "false" ]]; then
  success "A injeção de falha foi desabilitada."
else
  failure "A injeção de falha ainda está habilitada."
fi

echo
echo "===== 5. EVENTO DO RUNBOOK ====="

RUNBOOK_EVENT="$(
  kubectl logs \
    -n "$RUNBOOK_NAMESPACE" \
    deployment/"$RUNBOOK_DEPLOYMENT" \
    --since="$LOG_LOOKBACK" \
    --tail=1000 2>/dev/null |
  grep '"event":"deployment_restart_requested"' |
  tail -1 || true
)"

if [[ -n "$RUNBOOK_EVENT" ]]; then
  printf '%s\n' "$RUNBOOK_EVENT" | jq . 2>/dev/null || \
    printf '%s\n' "$RUNBOOK_EVENT"

  success "O evento deployment_restart_requested foi encontrado."
else
  failure \
    "Nenhum deployment_restart_requested foi encontrado nos últimos $LOG_LOOKBACK."
fi

echo
echo "===== 6. RESULTADO FINAL ====="

if [[ "$ERRORS" -eq 0 ]]; then
  echo "✅ SELF-HEALING VALIDADO DE PONTA A PONTA."
  echo
  echo "Evidências confirmadas:"
  echo "- alerta provocou a execução do runbook;"
  echo "- o runbook solicitou um novo rollout;"
  echo "- o Deployment ficou totalmente disponível;"
  echo "- o Pod novo está Running e Ready;"
  echo "- a injeção de falha foi desabilitada."
  exit 0
fi

echo "❌ SELF-HEALING NÃO FOI COMPLETAMENTE VALIDADO."
echo "Total de verificações com falha: $ERRORS"
exit 1
