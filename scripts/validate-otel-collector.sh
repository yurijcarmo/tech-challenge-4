#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
APPLICATION_FILE="observability/gitops/otel-collector-application.yaml"

if [[ ! -f "$APPLICATION_FILE" ]]; then
  printf '❌ Arquivo ausente: %s\n' "$APPLICATION_FILE" >&2
  exit 1
fi
printf '✅ Arquivo encontrado: %s\n' "$APPLICATION_FILE"

if [[ ! -x "$PYTHON_BIN" ]] || ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
  printf '❌ Ambiente de validação ausente. Execute: make setup-dev\n' >&2
  exit 1
fi

"$PYTHON_BIN" - <<'PY'
from pathlib import Path
import yaml

path = Path('observability/gitops/otel-collector-application.yaml')
document = yaml.safe_load(path.read_text(encoding='utf-8'))

assert document['kind'] == 'Application', 'kind deve ser Application'
assert document['metadata']['name'] == 'otel-collector', 'nome da Application inválido'

source = document['spec']['source']
assert source['chart'] == 'opentelemetry-collector', 'chart do OTel Collector ausente'
revision = str(source.get('targetRevision', '')).strip()
assert revision and revision not in {'*', 'latest'}, 'chart deve possuir versão fixa'

values = source['helm']['valuesObject']
assert values['mode'] == 'daemonset', 'Collector deve executar como DaemonSet'
assert values['presets']['logsCollection']['enabled'] is True, 'coleta de logs deve estar habilitada'
assert values['presets']['kubernetesAttributes']['enabled'] is True, 'metadados Kubernetes devem estar habilitados'
assert values['service']['enabled'] is True, 'Service do Collector deve estar habilitado'
assert values['ports']['otlp']['enabled'] is True, 'porta OTLP gRPC deve estar habilitada'
assert values['ports']['otlp-http']['enabled'] is True, 'porta OTLP HTTP deve estar habilitada'
assert values['serviceMonitor']['enabled'] is True, 'ServiceMonitor deve estar habilitado'

config = values['alternateConfig']
pipelines = config['service']['pipelines']
assert {'logs', 'metrics', 'traces'} <= set(pipelines), 'pipelines de logs, métricas e traces são obrigatórios'

log_exporters = pipelines['logs']['exporters']
assert 'otlphttp/loki' in log_exporters, 'pipeline de logs deve exportar para Loki'
loki_endpoint = config['exporters']['otlphttp/loki']['endpoint']
assert loki_endpoint.endswith('/otlp'), 'endpoint OTLP do Loki deve terminar em /otlp'

metric_exporters = pipelines['metrics']['exporters']
assert 'prometheus' in metric_exporters, 'pipeline de métricas deve expor dados para Prometheus'

trace_exporters = pipelines['traces']['exporters']
assert trace_exporters, 'pipeline de traces deve possuir ao menos um exporter'

sync_policy = document['spec']['syncPolicy']['automated']
assert sync_policy['prune'] is True, 'prune deve estar habilitado'
assert sync_policy['selfHeal'] is True, 'selfHeal deve estar habilitado'

print('✅ OpenTelemetry Collector validado')
PY
