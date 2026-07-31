#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
SERVICES=(
  auth-service
  flag-service
  targeting-service
  evaluation-service
  analytics-service
)
PYTHON_SERVICES=(
  flag-service
  targeting-service
  analytics-service
)
GO_SERVICES=(
  auth-service
  evaluation-service
)

errors=0

pass() {
  printf '✅ %s\n' "$1"
}

warn() {
  printf '⚠️  %s\n' "$1"
}

fail() {
  printf '❌ %s\n' "$1" >&2
  errors=$((errors + 1))
}

printf '\n== Ambiente de validação ==\n'
if [[ ! -x "$PYTHON_BIN" ]]; then
  fail "Ambiente virtual ausente. Execute: make setup-dev"
elif ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
  fail "Dependência PyYAML ausente. Execute: make setup-dev"
else
  pass "Ambiente Python de desenvolvimento disponível"
fi

printf '\n== Estrutura dos microsserviços ==\n'
for service in "${SERVICES[@]}"; do
  [[ -d "$service" ]] && pass "Diretório encontrado: $service" || fail "Diretório ausente: $service"
  [[ -f "$service/Dockerfile" ]] && pass "Dockerfile encontrado: $service" || fail "Dockerfile ausente: $service"
  [[ -f "$service/k8s/deployment.yaml" ]] && pass "Deployment Kubernetes encontrado: $service" || fail "Deployment Kubernetes ausente: $service"
done

printf '\n== Infraestrutura e GitOps ==\n'
for required in \
  infra/modules.tf \
  infra/provider.tf \
  infra/modules/apps/main.tf \
  .github/workflows/_ci-go.yml \
  .github/workflows/_ci-python.yml; do
  [[ -f "$required" ]] && pass "Arquivo encontrado: $required" || fail "Arquivo ausente: $required"
done

if [[ -x "$PYTHON_BIN" ]]; then
  printf '\n== Compilação dos serviços Python ==\n'
  PYTHON_CACHE_DIR="$(mktemp -d)"
  trap 'rm -rf "$PYTHON_CACHE_DIR"' EXIT
  if PYTHONPYCACHEPREFIX="$PYTHON_CACHE_DIR" \
    "$PYTHON_BIN" -m compileall -q "${PYTHON_SERVICES[@]}"; then
    pass "Serviços Python compilam para bytecode sem erros de sintaxe"
  else
    fail "Erro de compilação em serviço Python"
  fi

  printf '\n== Sintaxe YAML ==\n'
  if "$PYTHON_BIN" - <<'PY'
from pathlib import Path
import sys
import yaml

failures = []
paths = sorted(Path('.').rglob('*.yaml')) + sorted(Path('.').rglob('*.yml'))

for path in paths:
    if '.git' in path.parts or '.venv' in path.parts:
        continue

    try:
        with path.open(encoding='utf-8') as stream:
            list(yaml.safe_load_all(stream))
    except Exception as exc:
        failures.append((path, exc))

if failures:
    for path, exc in failures:
        print(f'{path}: {exc}', file=sys.stderr)
    raise SystemExit(1)
PY
  then
    pass "Arquivos YAML válidos"
  else
    fail "Erro de sintaxe em arquivo YAML"
  fi
fi

printf '\n== Compilação e testes dos serviços Go ==\n'
if command -v go >/dev/null 2>&1; then
  for service in "${GO_SERVICES[@]}"; do
    if output="$(cd "$service" && GOPROXY=off go test ./... 2>&1)"; then
      [[ -n "$output" ]] && printf '%s\n' "$output"
      pass "Serviço Go compilado e testes executados: $service"
    elif grep -q 'module lookup disabled by GOPROXY=off' <<<"$output"; then
      warn "Dependências Go de $service não estão no cache local; a pipeline CI executará essa validação"
    else
      printf '%s\n' "$output" >&2
      fail "Compilação ou testes Go falharam: $service"
    fi
  done
else
  warn "Go não está instalado; validação dos serviços Go não foi executada"
fi

printf '\n== Resultado ==\n'
if (( errors > 0 )); then
  printf 'Validação concluída com %d erro(s).\n' "$errors" >&2
  exit 1
fi

printf 'Base validada com sucesso.\n'
