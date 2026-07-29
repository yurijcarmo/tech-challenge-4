#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  printf '❌ Ambiente virtual ausente. Execute: make setup-dev\n' >&2
  exit 1
fi

errors=0
pass() { printf '✅ %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1" >&2; errors=$((errors + 1)); }

services=(flag-service targeting-service analytics-service)
required_packages=(
  opentelemetry-api
  opentelemetry-sdk
  opentelemetry-exporter-otlp-proto-grpc
  opentelemetry-instrumentation-flask
)

for service in "${services[@]}"; do
  for file in app.py telemetry.py requirements.txt k8s/configmap.yaml; do
    if [[ -f "$service/$file" ]]; then
      pass "Arquivo encontrado: $service/$file"
    else
      fail "Arquivo ausente: $service/$file"
    fi
  done

  for package in "${required_packages[@]}"; do
    if grep -q "^${package}==" "$service/requirements.txt"; then
      pass "Dependência configurada em $service: $package"
    else
      fail "Dependência ausente em $service: $package"
    fi
  done

  if grep -q 'OTEL_SERVICE_NAME' "$service/k8s/configmap.yaml" \
    && grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT' "$service/k8s/configmap.yaml" \
    && grep -q 'OTEL_EXPORTER_OTLP_INSECURE' "$service/k8s/configmap.yaml"; then
    pass "Configuração OTLP encontrada: $service"
  else
    fail "Configuração OTLP incompleta: $service"
  fi

done

if grep -q 'instrument_requests=True' flag-service/app.py \
  && grep -q 'instrument_psycopg2=True' flag-service/app.py \
  && grep -q '^opentelemetry-instrumentation-requests==' flag-service/requirements.txt \
  && grep -q '^opentelemetry-instrumentation-psycopg2==' flag-service/requirements.txt; then
  pass "Chamadas HTTP e PostgreSQL instrumentados: flag-service"
else
  fail "Instrumentação de requests/PostgreSQL incompleta: flag-service"
fi

if grep -q 'instrument_requests=True' targeting-service/app.py \
  && grep -q 'instrument_psycopg2=True' targeting-service/app.py \
  && grep -q '^opentelemetry-instrumentation-requests==' targeting-service/requirements.txt \
  && grep -q '^opentelemetry-instrumentation-psycopg2==' targeting-service/requirements.txt; then
  pass "Chamadas HTTP e PostgreSQL instrumentados: targeting-service"
else
  fail "Instrumentação de requests/PostgreSQL incompleta: targeting-service"
fi

if grep -q 'instrument_botocore=True' analytics-service/app.py \
  && grep -q '^opentelemetry-instrumentation-botocore==' analytics-service/requirements.txt; then
  pass "Chamadas AWS instrumentadas: analytics-service"
else
  fail "Instrumentação Botocore incompleta: analytics-service"
fi

if grep -q 'MessageAttributeNames=\["All"\]' analytics-service/app.py \
  && grep -q 'propagate.extract' analytics-service/app.py \
  && grep -q 'SpanKind.CONSUMER' analytics-service/app.py; then
  pass "Contexto do trace extraído das mensagens SQS"
else
  fail "Continuação do trace da SQS não configurada"
fi

if grep -q 'threading.Event()' analytics-service/app.py \
  && grep -q 'signal.SIGTERM' analytics-service/app.py \
  && grep -q 'stop_event.set()' analytics-service/app.py \
  && grep -q 'worker_thread.join(timeout=25)' analytics-service/app.py \
  && grep -q 'telemetry.shutdown()' analytics-service/app.py; then
  pass "Encerramento gracioso do worker SQS configurado"
else
  fail "Encerramento gracioso do worker SQS incompleto"
fi

if grep -q 'togglemaster_http_server_requests' flag-service/telemetry.py \
  && grep -q 'togglemaster_http_server_request_duration' flag-service/telemetry.py \
  && grep -q 'TraceContextFilter' flag-service/telemetry.py; then
  pass "Métricas HTTP e correlação de logs configuradas"
else
  fail "Métricas HTTP ou correlação de logs ausentes"
fi

if "$PYTHON_BIN" -m compileall -q \
  flag-service/app.py flag-service/telemetry.py \
  targeting-service/app.py targeting-service/telemetry.py \
  analytics-service/app.py analytics-service/telemetry.py; then
  pass "Arquivos Python compilam sintaticamente"
else
  fail "Erro de sintaxe na instrumentação Python"
fi

if (( errors > 0 )); then
  printf '\nValidação da telemetria Python concluída com %d erro(s).\n' "$errors" >&2
  exit 1
fi

printf '\nInstrumentação OpenTelemetry dos serviços Python validada.\n'
