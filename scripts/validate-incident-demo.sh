#!/usr/bin/env bash
set -Eeuo pipefail

errors=0

require_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    echo "✅ Arquivo encontrado: $file"
  else
    echo "❌ Arquivo não encontrado: $file"
    errors=$((errors + 1))
  fi
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "✅ $message"
  else
    echo "❌ $message"
    errors=$((errors + 1))
  fi
}

require_file auth-service/failure_injection.go
require_file auth-service/main.go
require_file auth-service/k8s/configmap.yaml
require_file scripts/run-incident-demo.sh

require_pattern 'ENABLE_FAILURE_INJECTION: "false"' \
  auth-service/k8s/configmap.yaml \
  "Falha controlada desabilitada por padrão"
require_pattern '/internal/demo/failure' \
  auth-service/main.go \
  "Rota interna de demonstração registrada"
require_pattern 'http.StatusInternalServerError' \
  auth-service/failure_injection.go \
  "Endpoint controlado retorna HTTP 500"
require_pattern 'X-ToggleMaster-Failure-Test' \
  auth-service/failure_injection.go \
  "Header obrigatório protege a injeção de falha"
require_pattern 'kubectl patch configmap' \
  scripts/run-incident-demo.sh \
  "Script habilita e restaura a falha pelo ConfigMap"
require_pattern 'kubectl rollout restart' \
  scripts/run-incident-demo.sh \
  "Script reinicia o Pod somente para ativar a simulação"
require_pattern 'kubectl port-forward' \
  scripts/run-incident-demo.sh \
  "Script usa acesso local temporário ao Service"
require_pattern 'DEMO_TIMEOUT_SECONDS' \
  scripts/run-incident-demo.sh \
  "Espera do Self-Healing possui limite de tempo"
require_pattern 'self_healing_restart' \
  scripts/run-incident-demo.sh \
  "Script detecta o rollout solicitado pela automação"

if command -v gofmt >/dev/null 2>&1; then
  unformatted="$(gofmt -l auth-service/main.go auth-service/failure_injection.go)"
  if [[ -z "$unformatted" ]]; then
    echo "✅ Arquivos Go estão formatados"
  else
    echo "❌ Arquivos Go fora do padrão: $unformatted"
    errors=$((errors + 1))
  fi
else
  echo "⚠️ gofmt não encontrado; formatação Go não validada"
fi

bash -n scripts/run-incident-demo.sh

echo
if (( errors > 0 )); then
  echo "Validação concluída com $errors erro(s)."
  exit 1
fi

echo "Demonstração controlada de incidente e recuperação validada estaticamente."
