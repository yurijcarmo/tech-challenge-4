#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${OTEL_NAMESPACE:-monitoring}"
DAEMONSET="${OTEL_DAEMONSET:-otel-collector-agent}"

DESIRED="$(
  kubectl get daemonset \
    -n "$NAMESPACE" \
    "$DAEMONSET" \
    -o jsonpath='{.status.desiredNumberScheduled}'
)"

READY="$(
  kubectl get daemonset \
    -n "$NAMESPACE" \
    "$DAEMONSET" \
    -o jsonpath='{.status.numberReady}'
)"

AVAILABLE="$(
  kubectl get daemonset \
    -n "$NAMESPACE" \
    "$DAEMONSET" \
    -o jsonpath='{.status.numberAvailable}'
)"

READY="${READY:-0}"
AVAILABLE="${AVAILABLE:-0}"

echo "===== OPENTELEMETRY COLLECTOR ====="
echo "Desired:   $DESIRED"
echo "Ready:     $READY"
echo "Available: $AVAILABLE"

if [[
  "$READY" -ne "$DESIRED" ||
  "$AVAILABLE" -ne "$DESIRED"
]]; then
  echo
  echo "❌ OTel Collector incompleto."
  echo "Não execute a demonstração até o DaemonSet ficar totalmente disponível."
  echo

  kubectl get pods \
    -n "$NAMESPACE" \
    -l app.kubernetes.io/instance=otel-collector \
    -o wide

  exit 1
fi

echo
echo "===== CAPACIDADE DE PODS POR NÓ ====="

FAILURE=0

while IFS=$'\t' read -r node max_pods
do
  usados="$(
    kubectl get pods -A -o json |
    jq -r \
      --arg node "$node" '
        [
          .items[]
          | select(.spec.nodeName == $node)
          | select(
              .status.phase != "Succeeded"
              and .status.phase != "Failed"
            )
        ]
        | length
      '
  )"

  livres=$((max_pods - usados))

  echo "$node: usados=$usados limite=$max_pods livres=$livres"

  if [[ "$livres" -lt 1 ]]; then
    echo "❌ Nó sem vaga para novos Pods: $node"
    FAILURE=1
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

if [[ "$FAILURE" -ne 0 ]]; then
  exit 1
fi

echo
echo "✅ Collector disponível em todos os nós e capacidade validada."
