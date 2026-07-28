#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
required_files=(
  observability/gitops/namespace.yaml
  observability/gitops/grafana-external-secret.yaml
  observability/gitops/loki-application.yaml
  observability/gitops/monitoring-application.yaml
  infra/observability.tf
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || {
    printf '❌ Arquivo ausente: %s\n' "$file" >&2
    exit 1
  }
  printf '✅ Arquivo encontrado: %s\n' "$file"
done

if [[ ! -x "$PYTHON_BIN" ]] || ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
  printf '❌ Ambiente de validação ausente. Execute: make setup-dev\n' >&2
  exit 1
fi

"$PYTHON_BIN" - <<'PY'
from pathlib import Path
import yaml

application_files = [
    Path('observability/gitops/loki-application.yaml'),
    Path('observability/gitops/monitoring-application.yaml'),
]

for path in application_files:
    document = yaml.safe_load(path.read_text(encoding='utf-8'))
    assert document['kind'] == 'Application', f'{path}: kind deve ser Application'
    source = document['spec']['source']
    revision = str(source.get('targetRevision', '')).strip()
    assert revision and revision not in {'*', 'latest'}, f'{path}: chart deve possuir versão fixa'
    automated = document['spec']['syncPolicy']['automated']
    assert automated['prune'] is True, f'{path}: prune deve estar habilitado'
    assert automated['selfHeal'] is True, f'{path}: selfHeal deve estar habilitado'

monitoring = yaml.safe_load(application_files[1].read_text(encoding='utf-8'))
values = monitoring['spec']['source']['helm']['valuesObject']
data_sources = values['grafana']['additionalDataSources']
assert any(ds.get('type') == 'loki' for ds in data_sources), 'Datasource Loki ausente no Grafana'

print('✅ Applications do Argo CD e datasource Loki validados')
PY

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra fmt -check \
  modules.tf \
  observability.tf \
  secrets.tf \
  variables.tf
  printf '✅ Formatação Terraform validada\n'
else
  printf '⚠️  Terraform não instalado; formatação não validada localmente.\n'
fi

printf 'Stack de observabilidade validada estaticamente.\n'
