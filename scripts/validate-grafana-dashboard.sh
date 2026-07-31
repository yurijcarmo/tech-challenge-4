#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
DASHBOARD_FILE="observability/gitops/togglemaster-dashboard-configmap.yaml"
MONITORING_FILE="observability/gitops/monitoring-application.yaml"

for file in "$DASHBOARD_FILE" "$MONITORING_FILE"; do
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
import json
import yaml

configmap_path = Path("observability/gitops/togglemaster-dashboard-configmap.yaml")
monitoring_path = Path("observability/gitops/monitoring-application.yaml")

configmap = yaml.safe_load(configmap_path.read_text(encoding="utf-8"))
assert configmap["kind"] == "ConfigMap", "Dashboard deve ser entregue em um ConfigMap"
assert configmap["metadata"]["namespace"] == "monitoring", "ConfigMap deve estar no namespace monitoring"
assert configmap["metadata"]["labels"].get("grafana_dashboard") == "1", "Label grafana_dashboard=1 ausente"

entries = configmap.get("data", {})
assert len(entries) == 1, "ConfigMap deve conter exatamente um dashboard"
filename, raw_dashboard = next(iter(entries.items()))
assert filename.endswith(".json"), "Dashboard deve ser armazenado como JSON"
dashboard = json.loads(raw_dashboard)

assert dashboard.get("uid") == "togglemaster-ecosystem-health", "UID estável do dashboard ausente"
assert dashboard.get("title") == "ToggleMaster - Ecosystem Health", "Título do dashboard inesperado"
assert dashboard.get("refresh") in {"5s", "10s", "30s"}, "Dashboard deve atualizar em tempo quase real"

panels = dashboard.get("panels", [])
assert len(panels) >= 6, "Dashboard deve possuir pelo menos seis painéis"
panel_titles = {panel.get("title") for panel in panels}
required_titles = {
    "Cluster CPU Usage",
    "Cluster Memory Usage",
    "HTTP Request Rate by Service",
    "Application Logs in Real Time",
}
missing = required_titles - panel_titles
assert not missing, f"Painéis obrigatórios ausentes: {sorted(missing)}"

prom_queries = []
loki_queries = []
for panel in panels:
    datasource = panel.get("datasource", {})
    for target in panel.get("targets", []):
        expression = target.get("expr", "")
        if datasource.get("uid") == "prometheus":
            prom_queries.append(expression)
        if datasource.get("uid") == "loki":
            loki_queries.append(expression)

assert any("node_cpu_seconds_total" in query for query in prom_queries), "Consulta de CPU do cluster ausente"
assert any("node_memory_MemAvailable_bytes" in query for query in prom_queries), "Consulta de memória do cluster ausente"
assert any("togglemaster_http_server_requests" in query for query in prom_queries), "Consulta de taxa HTTP ausente"
assert any("k8s_namespace_name" in query for query in loki_queries), "Consulta de logs dos namespaces ausente"

monitoring = yaml.safe_load(monitoring_path.read_text(encoding="utf-8"))
grafana = monitoring["spec"]["source"]["helm"]["valuesObject"]["grafana"]
dashboards_sidecar = grafana["sidecar"]["dashboards"]
assert dashboards_sidecar.get("enabled") is True, "Sidecar de dashboards do Grafana deve estar habilitado"
assert dashboards_sidecar.get("label") == "grafana_dashboard", "Label do sidecar deve ser grafana_dashboard"
assert str(dashboards_sidecar.get("labelValue")) == "1", "Valor da label do sidecar deve ser 1"

data_sources = grafana.get("additionalDataSources", [])
assert any(source.get("uid") == "loki" for source in data_sources), "Datasource Loki com UID loki ausente"

print("✅ Dashboard customizado, consultas Prometheus/Loki e sidecar do Grafana validados")
PY

printf 'Dashboard customizado do Grafana validado estaticamente.\n'
