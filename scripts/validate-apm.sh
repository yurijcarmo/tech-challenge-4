#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
COLLECTOR_FILE="observability/gitops/otel-collector-application.yaml"
EXTERNAL_SECRET_FILE="observability/gitops/newrelic-external-secret.yaml"

required_files=(
  "$COLLECTOR_FILE"
  "$EXTERNAL_SECRET_FILE"
  infra/variables.tf
  infra/secrets.tf
  infra/observability.tf
  infra/terraform.tfvars.example
)

for file in "${required_files[@]}"; do
  if [[ -f "$file" ]]; then
    printf '✅ Arquivo encontrado: %s\n' "$file"
  else
    printf '❌ Arquivo ausente: %s\n' "$file" >&2
    exit 1
  fi
done

if [[ ! -x "$PYTHON_BIN" ]] || ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
  printf '❌ Ambiente de validação ausente. Execute: make setup-dev\n' >&2
  exit 1
fi

"$PYTHON_BIN" - <<'PY'
from pathlib import Path
import yaml

collector_path = Path('observability/gitops/otel-collector-application.yaml')
secret_path = Path('observability/gitops/newrelic-external-secret.yaml')

collector = yaml.safe_load(collector_path.read_text(encoding='utf-8'))
values = collector['spec']['source']['helm']['valuesObject']

extra_envs = {item['name']: item for item in values.get('extraEnvs', [])}
assert 'NEW_RELIC_LICENSE_KEY' in extra_envs, 'variável NEW_RELIC_LICENSE_KEY ausente'
secret_ref = extra_envs['NEW_RELIC_LICENSE_KEY']['valueFrom']['secretKeyRef']
assert secret_ref['name'] == 'newrelic-otlp-credentials', 'Secret da New Relic incorreto'
assert secret_ref['key'] == 'license-key', 'chave license-key ausente'

endpoint = extra_envs.get('NEW_RELIC_OTLP_ENDPOINT', {}).get('value', '')
assert endpoint.startswith('https://otlp.'), 'endpoint OTLP da New Relic inválido'

config = values['alternateConfig']
exporter = config['exporters'].get('otlphttp/newrelic')
assert exporter, 'exporter otlphttp/newrelic ausente'
assert exporter['endpoint'] == '${env:NEW_RELIC_OTLP_ENDPOINT}', 'endpoint do exporter deve vir de variável de ambiente'
assert exporter['headers']['api-key'] == '${env:NEW_RELIC_LICENSE_KEY}', 'api-key deve vir do Secret'

pipelines = config['service']['pipelines']
assert 'otlphttp/newrelic' in pipelines['traces']['exporters'], 'traces devem ser enviados à New Relic'
assert 'otlphttp/loki' in pipelines['logs']['exporters'], 'logs devem continuar no Loki'
assert 'prometheus' in pipelines['metrics']['exporters'], 'métricas devem continuar no Prometheus'

external_secret = yaml.safe_load(secret_path.read_text(encoding='utf-8'))
assert external_secret['kind'] == 'ExternalSecret', 'recurso deve ser ExternalSecret'
assert external_secret['metadata']['namespace'] == 'monitoring', 'namespace deve ser monitoring'
assert external_secret['spec']['target']['name'] == 'newrelic-otlp-credentials', 'nome do Secret Kubernetes inválido'
remote = external_secret['spec']['data'][0]['remoteRef']
assert remote['key'] == 'eks/newrelic', 'Secret remoto deve ser eks/newrelic'
assert remote['property'] == 'license-key', 'propriedade remota license-key ausente'

rendered = collector_path.read_text(encoding='utf-8')
assert 'replace-with-new-relic' not in rendered.lower(), 'não inclua chave de exemplo no Collector'

print('✅ Exportação de traces para New Relic validada')
PY

if grep -q 'variable "new_relic_license_key"' infra/variables.tf \
  && grep -q 'resource "aws_secretsmanager_secret" "new_relic"' infra/secrets.tf \
  && grep -q 'aws_secretsmanager_secret_version.new_relic' infra/observability.tf; then
  printf '✅ Credencial da New Relic integrada ao Terraform e Secrets Manager\n'
else
  printf '❌ Integração Terraform da credencial da New Relic está incompleta\n' >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra fmt -check variables.tf secrets.tf observability.tf
  printf '✅ Arquivos Terraform do APM estão formatados\n'
else
  printf '⚠️  Terraform não instalado; formatação não validada localmente.\n'
fi

printf '\nIntegração APM com New Relic validada estaticamente.\n'
