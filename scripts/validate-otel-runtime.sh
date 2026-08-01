#!/usr/bin/env bash

set -Eeuo pipefail

OTEL_NAMESPACE="${OTEL_NAMESPACE:-monitoring}"
OTEL_DAEMONSET="${OTEL_DAEMONSET:-otel-collector-agent}"
EXPECTED_PRIORITY_CLASS="${OTEL_PRIORITY_CLASS:-togglemaster-observability-critical}"
STRICT_NODE_CAPACITY="${STRICT_NODE_CAPACITY:-false}"

fail() {
  echo "❌ $1" >&2
  exit 1
}

warn() {
  echo "⚠️  $1"
}

command -v kubectl >/dev/null 2>&1 ||
  fail "kubectl não está instalado."

command -v jq >/dev/null 2>&1 ||
  fail "jq não está instalado."

kubectl -n "$OTEL_NAMESPACE" get daemonset "$OTEL_DAEMONSET" \
  >/dev/null 2>&1 ||
  fail "DaemonSet ${OTEL_NAMESPACE}/${OTEL_DAEMONSET} não encontrado."

read -r desired ready available priority_class < <(
  kubectl -n "$OTEL_NAMESPACE" get daemonset "$OTEL_DAEMONSET" -o json |
    jq -r '[
      (.status.desiredNumberScheduled // 0),
      (.status.numberReady // 0),
      (.status.numberAvailable // 0),
      (.spec.template.spec.priorityClassName // "")
    ] | @tsv'
)

echo "===== OPENTELEMETRY COLLECTOR ====="
echo "Desired:   $desired"
echo "Ready:     $ready"
echo "Available: $available"
echo "Priority:  ${priority_class:-não configurada}"

[[ "$desired" -gt 0 ]] ||
  fail "O DaemonSet não possui nós desejados."

[[ "$ready" -eq "$desired" ]] ||
  fail "Collector incompleto: Ready=${ready}, Desired=${desired}."

[[ "$available" -eq "$desired" ]] ||
  fail "Collector indisponível: Available=${available}, Desired=${desired}."

[[ "$priority_class" == "$EXPECTED_PRIORITY_CLASS" ]] ||
  fail "PriorityClass incorreta: '${priority_class:-nenhuma}'. Esperada: '$EXPECTED_PRIORITY_CLASS'."

echo
echo "===== CAPACIDADE DE PODS POR NÓ ====="

nodes=0
nodes_without_headroom=0
total_free=0

while IFS=$'\t' read -r node limit; do
  [[ -n "$node" ]] || continue

  nodes=$((nodes + 1))

  used="$(
    kubectl get pods -A \
      --field-selector "spec.nodeName=${node}" \
      -o json |
      jq '
        [
          .items[]
          | select(
              .status.phase != "Succeeded"
              and .status.phase != "Failed"
            )
        ]
        | length
      '
  )"

  free=$((limit - used))

  if [[ "$free" -lt 0 ]]; then
    free=0
  fi

  total_free=$((total_free + free))

  echo "${node}: usados=${used} limite=${limit} livres=${free}"

  if [[ "$free" -eq 0 ]]; then
    nodes_without_headroom=$((nodes_without_headroom + 1))
    warn "Nó sem capacidade adicional: ${node}"
  fi
done < <(
  kubectl get nodes -o json |
    jq -r '
      .items[]
      | [
          .metadata.name,
          (.status.allocatable.pods | tonumber)
        ]
      | @tsv
    '
)

[[ "$nodes" -gt 0 ]] ||
  fail "Nenhum nó foi encontrado no cluster."

echo
echo "Capacidade livre total no cluster: ${total_free} Pod(s)"

if [[ "$nodes_without_headroom" -gt 0 ]]; then
  warn "${nodes_without_headroom} nó(s) estão sem vaga adicional."

  if [[ "$STRICT_NODE_CAPACITY" == "true" || "$STRICT_NODE_CAPACITY" == "1" ]]; then
    fail "Validação estrita de capacidade habilitada."
  fi
fi

echo
echo "✅ Collector disponível em todos os nós."
echo "✅ PriorityClass validada."
echo "✅ Validação concluída."

if [[ "$nodes_without_headroom" -gt 0 ]]; then
  echo "⚠️  Capacidade apertada aceita como aviso neste ambiente."
fi
