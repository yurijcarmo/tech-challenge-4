#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

errors=0

pass() {
  printf '✅ %s\n' "$1"
}

fail() {
  printf '❌ %s\n' "$1" >&2
  errors=$((errors + 1))
}

required_files=(
  auth-service/telemetry.go
  auth-service/main.go
  auth-service/go.mod
  auth-service/k8s/configmap.yaml
  evaluation-service/telemetry.go
  evaluation-service/main.go
  evaluation-service/handlers.go
  evaluation-service/sqs.go
  evaluation-service/go.mod
  evaluation-service/k8s/configmap.yaml
  observability/gitops/otel-collector-application.yaml
)

for file in "${required_files[@]}"; do
  if [[ -f "$file" ]]; then
    pass "Arquivo encontrado: $file"
  else
    fail "Arquivo ausente: $file"
  fi
done

for service in auth-service evaluation-service; do
  if grep -q 'go.opentelemetry.io/otel' "$service/go.mod" && \
     grep -q 'go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp' "$service/go.mod"; then
    pass "Dependências OpenTelemetry encontradas: $service"
  else
    fail "Dependências OpenTelemetry ausentes: $service"
  fi

  if grep -q 'setupTelemetry' "$service/main.go" && \
     grep -q 'telemetry.HTTPHandler' "$service/main.go"; then
    pass "Servidor HTTP instrumentado: $service"
  else
    fail "Instrumentação HTTP incompleta: $service"
  fi

  if grep -q 'togglemaster_http_server_requests' "$service/telemetry.go" && \
     grep -q 'togglemaster_http_server_request_duration' "$service/telemetry.go"; then
    pass "Métricas HTTP customizadas encontradas: $service"
  else
    fail "Métricas HTTP customizadas ausentes: $service"
  fi

  if grep -q 'OTEL_SERVICE_NAME' "$service/k8s/configmap.yaml" && \
     grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT' "$service/k8s/configmap.yaml"; then
    pass "Variáveis OTLP configuradas: $service"
  else
    fail "Variáveis OTLP ausentes: $service"
  fi
done

if grep -q 'otelhttp.NewTransport' evaluation-service/main.go; then
  pass "Cliente HTTP do evaluation-service instrumentado"
else
  fail "Cliente HTTP do evaluation-service não instrumentado"
fi

if grep -q 'MessageAttributes' evaluation-service/sqs.go && \
   grep -q 'GetTextMapPropagator().Inject' evaluation-service/sqs.go && \
   grep -q 'SpanKindProducer' evaluation-service/sqs.go; then
  pass "Contexto de trace propagado para a SQS"
else
  fail "Propagação de trace para a SQS incompleta"
fi

if grep -q 'context.WithoutCancel' evaluation-service/handlers.go && \
   grep -q 'context.WithTimeout' evaluation-service/handlers.go; then
  pass "Contexto assíncrono preserva o trace e possui timeout"
else
  fail "Contexto assíncrono da SQS está incompleto"
fi

if grep -q 'fullnameOverride: otel-collector' observability/gitops/otel-collector-application.yaml; then
  pass "Nome estável do Service do Collector configurado"
else
  fail "fullnameOverride do Collector ausente"
fi

formatted_output="$(gofmt -d \
  auth-service/main.go \
  auth-service/telemetry.go \
  evaluation-service/main.go \
  evaluation-service/handlers.go \
  evaluation-service/sqs.go \
  evaluation-service/telemetry.go)"

if [[ -z "$formatted_output" ]]; then
  pass "Arquivos Go estão formatados"
else
  printf '%s\n' "$formatted_output" >&2
  fail "Arquivos Go precisam de gofmt"
fi

if (( errors > 0 )); then
  printf '\nValidação da instrumentação Go concluída com %d erro(s).\n' "$errors" >&2
  exit 1
fi

printf '\nInstrumentação OpenTelemetry dos serviços Go validada.\n'
