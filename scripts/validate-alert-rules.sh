#!/usr/bin/env bash
set -euo pipefail

RULE_FILE="observability/gitops/togglemaster-alert-rules.yaml"
MONITORING_FILE="observability/gitops/monitoring-application.yaml"
DASHBOARD_FILE="observability/gitops/togglemaster-dashboard-configmap.yaml"

errors=0

require_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    echo "✅ Arquivo encontrado: $file"
  else
    echo "❌ Arquivo ausente: $file"
    errors=$((errors + 1))
  fi
}

require_file "$RULE_FILE"
require_file "$MONITORING_FILE"
require_file "$DASHBOARD_FILE"

if [[ $errors -ne 0 ]]; then
  exit "$errors"
fi

PYTHON="python3"
if [[ -x .venv/bin/python ]]; then
  PYTHON=".venv/bin/python"
fi

"$PYTHON" - <<'PY'
from pathlib import Path
import json
import sys
import yaml

rule_path = Path("observability/gitops/togglemaster-alert-rules.yaml")
monitoring_path = Path("observability/gitops/monitoring-application.yaml")
dashboard_path = Path("observability/gitops/togglemaster-dashboard-configmap.yaml")

rule_doc = yaml.safe_load(rule_path.read_text())
if rule_doc.get("apiVersion") != "monitoring.coreos.com/v1" or rule_doc.get("kind") != "PrometheusRule":
    raise SystemExit("❌ O recurso de alerta deve ser um PrometheusRule monitoring.coreos.com/v1")

metadata = rule_doc.get("metadata", {})
if metadata.get("namespace") != "monitoring":
    raise SystemExit("❌ O PrometheusRule deve ser criado no namespace monitoring")

rules = [
    rule
    for group in rule_doc.get("spec", {}).get("groups", [])
    for rule in group.get("rules", [])
]
alert = next((rule for rule in rules if rule.get("alert") == "AuthServiceHigh5xxErrorRate"), None)
if not alert:
    raise SystemExit("❌ Alerta AuthServiceHigh5xxErrorRate não encontrado")

expr = str(alert.get("expr", ""))
required_expr_fragments = [
    'service_name="auth-service"',
    'http_response_status_code=~"5.."',
    "> 0.05",
    ">= 20",
    "clamp_min",
    "rate(",
    "increase(",
]
missing = [fragment for fragment in required_expr_fragments if fragment not in expr]
if missing:
    raise SystemExit(f"❌ Expressão do alerta incompleta. Ausentes: {', '.join(missing)}")

if alert.get("for") != "2m":
    raise SystemExit("❌ O alerta deve permanecer acima do limite por 2m antes de disparar")
if alert.get("keep_firing_for") != "2m":
    raise SystemExit("❌ keep_firing_for deve ser 2m para evitar flapping")

labels = alert.get("labels", {})
for key, expected in {
    "severity": "critical",
    "service": "auth-service",
    "self_healing": "true",
}.items():
    if str(labels.get(key)) != expected:
        raise SystemExit(f"❌ Label obrigatória inválida: {key}={expected}")

annotations = alert.get("annotations", {})
for key in ("summary", "description", "impact", "action"):
    if not annotations.get(key):
        raise SystemExit(f"❌ Annotation obrigatória ausente: {key}")

monitoring_doc = yaml.safe_load(monitoring_path.read_text())
prom_spec = (
    monitoring_doc.get("spec", {})
    .get("source", {})
    .get("helm", {})
    .get("valuesObject", {})
    .get("prometheus", {})
    .get("prometheusSpec", {})
)
if prom_spec.get("ruleSelector") != {}:
    raise SystemExit("❌ ruleSelector deve ser {} para selecionar os PrometheusRules")
if prom_spec.get("ruleNamespaceSelector") != {}:
    raise SystemExit("❌ ruleNamespaceSelector deve ser {} para permitir descoberta das regras")

config = yaml.safe_load(dashboard_path.read_text())
raw_dashboard = config.get("data", {}).get("togglemaster-ecosystem-health.json")
if not raw_dashboard:
    raise SystemExit("❌ JSON do dashboard não encontrado no ConfigMap")
dashboard = json.loads(raw_dashboard)
panel = next((panel for panel in dashboard.get("panels", []) if panel.get("id") == 6), None)
if not panel:
    raise SystemExit("❌ Painel HTTP 5xx não encontrado")
query = panel.get("targets", [{}])[0].get("expr", "")
if "100 *" not in query or "clamp_min" not in query or 'http_response_status_code=~"5.."' not in query:
    raise SystemExit("❌ Painel HTTP 5xx deve exibir o percentual de erros")
if panel.get("fieldConfig", {}).get("defaults", {}).get("unit") != "percent":
    raise SystemExit("❌ Painel HTTP 5xx deve utilizar a unidade percent")

print("✅ Regra de alerta, seleção do PrometheusRule e painel percentual validados")
PY

if command -v promtool >/dev/null 2>&1; then
  tmp_rule="$(mktemp)"
  trap 'rm -f "$tmp_rule"' EXIT
  "$PYTHON" - "$RULE_FILE" "$tmp_rule" <<'PY'
from pathlib import Path
import sys
import yaml

source = yaml.safe_load(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_text(yaml.safe_dump({"groups": source["spec"]["groups"]}, sort_keys=False))
PY
  promtool check rules "$tmp_rule"
  echo "✅ Sintaxe PromQL validada com promtool"
else
  echo "⚠️ promtool não encontrado; a validação sintática final ocorrerá no Prometheus Operator"
fi

echo "Alerta inteligente do auth-service validado estaticamente."
