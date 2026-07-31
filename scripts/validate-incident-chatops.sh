#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
EXTERNAL_SECRET_FILE="observability/gitops/alertmanager-notification-external-secret.yaml"
ALERTMANAGER_CONFIG_FILE="observability/gitops/togglemaster-alertmanager-config.yaml"
MONITORING_FILE="observability/gitops/monitoring-application.yaml"
ALERT_RULE_FILE="observability/gitops/togglemaster-alert-rules.yaml"

required_files=(
  "$EXTERNAL_SECRET_FILE"
  "$ALERTMANAGER_CONFIG_FILE"
  "$MONITORING_FILE"
  "$ALERT_RULE_FILE"
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

external_secret_path = Path("observability/gitops/alertmanager-notification-external-secret.yaml")
alertmanager_config_path = Path("observability/gitops/togglemaster-alertmanager-config.yaml")
monitoring_path = Path("observability/gitops/monitoring-application.yaml")
alert_rule_path = Path("observability/gitops/togglemaster-alert-rules.yaml")

external_secret = yaml.safe_load(external_secret_path.read_text(encoding="utf-8"))
assert external_secret.get("kind") == "ExternalSecret", "recurso de credenciais deve ser ExternalSecret"
assert external_secret.get("metadata", {}).get("namespace") == "monitoring", "ExternalSecret deve ficar em monitoring"
assert external_secret.get("spec", {}).get("target", {}).get("name") == "alertmanager-notification-credentials", "Secret Kubernetes inválido"
remote_data = {
    item["secretKey"]: item["remoteRef"]
    for item in external_secret.get("spec", {}).get("data", [])
}
for key in ("pagerduty-routing-key", "discord-webhook-url"):
    assert key in remote_data, f"credencial ausente no ExternalSecret: {key}"
    assert remote_data[key].get("key") == "eks/alert-notifications", "Secret remoto incorreto"
    assert remote_data[key].get("property") == key, f"propriedade remota incorreta: {key}"

config = yaml.safe_load(alertmanager_config_path.read_text(encoding="utf-8"))
assert config.get("apiVersion") == "monitoring.coreos.com/v1alpha1", "apiVersion do AlertmanagerConfig inválida"
assert config.get("kind") == "AlertmanagerConfig", "recurso deve ser AlertmanagerConfig"
metadata = config.get("metadata", {})
assert metadata.get("namespace") == "monitoring", "AlertmanagerConfig deve ficar em monitoring"
labels = metadata.get("labels", {})
assert labels.get("app.kubernetes.io/part-of") == "togglemaster", "label part-of ausente"
assert labels.get("role") == "alert-routing", "label role=alert-routing ausente"

spec = config.get("spec", {})
route = spec.get("route", {})
assert route.get("receiver") == "pagerduty-and-discord", "receiver principal inválido"
assert route.get("groupWait") == "10s", "groupWait deve ser 10s"
assert route.get("groupInterval") == "5m", "groupInterval deve ser 5m"
assert route.get("repeatInterval") == "4h", "repeatInterval deve ser 4h"
assert set(route.get("groupBy", [])) == {"alertname", "service", "severity"}, "groupBy incompleto"
matchers = {(m.get("name"), m.get("matchType")): str(m.get("value")) for m in route.get("matchers", [])}
assert matchers.get(("severity", "=")) == "critical", "rota deve selecionar severity=critical"
assert matchers.get(("category", "=")) == "availability", "rota deve selecionar category=availability"

receivers = {receiver.get("name"): receiver for receiver in spec.get("receivers", [])}
receiver = receivers.get("pagerduty-and-discord")
assert receiver, "receiver PagerDuty e Discord ausente"

pagerduty = receiver.get("pagerdutyConfigs", [])
assert len(pagerduty) == 1, "deve existir uma configuração PagerDuty"
pagerduty = pagerduty[0]
assert pagerduty.get("sendResolved") is True, "PagerDuty deve receber resolução"
pd_ref = pagerduty.get("routingKey", {})
assert pd_ref.get("name") == "alertmanager-notification-credentials", "Secret PagerDuty incorreto"
assert pd_ref.get("key") == "pagerduty-routing-key", "chave PagerDuty incorreta"
assert "CommonAnnotations.summary" in pagerduty.get("description", ""), "descrição PagerDuty deve usar summary"

discord = receiver.get("discordConfigs", [])
assert len(discord) == 1, "deve existir uma configuração Discord"
discord = discord[0]
assert discord.get("sendResolved") is True, "Discord deve receber resolução"
discord_ref = discord.get("apiURL", {})
assert discord_ref.get("name") == "alertmanager-notification-credentials", "Secret Discord incorreto"
assert discord_ref.get("key") == "discord-webhook-url", "chave Discord incorreta"
for fragment in ("CommonLabels.service", "CommonAnnotations.summary", "CommonAnnotations.action"):
    assert fragment in discord.get("message", ""), f"mensagem Discord incompleta: {fragment}"

monitoring = yaml.safe_load(monitoring_path.read_text(encoding="utf-8"))
alertmanager_spec = (
    monitoring.get("spec", {})
    .get("source", {})
    .get("helm", {})
    .get("valuesObject", {})
    .get("alertmanager", {})
    .get("alertmanagerSpec", {})
)
selector = alertmanager_spec.get("alertmanagerConfigSelector", {}).get("matchLabels", {})
assert selector.get("app.kubernetes.io/part-of") == "togglemaster", "selector part-of ausente"
assert selector.get("role") == "alert-routing", "selector role ausente"
namespace_selector = alertmanager_spec.get("alertmanagerConfigNamespaceSelector", {}).get("matchLabels", {})
assert namespace_selector.get("kubernetes.io/metadata.name") == "monitoring", "namespace selector inválido"

rule = yaml.safe_load(alert_rule_path.read_text(encoding="utf-8"))
rules = [r for group in rule.get("spec", {}).get("groups", []) for r in group.get("rules", [])]
alert = next((r for r in rules if r.get("alert") == "AuthServiceHigh5xxErrorRate"), None)
assert alert, "alerta AuthServiceHigh5xxErrorRate ausente"
alert_labels = alert.get("labels", {})
assert alert_labels.get("namespace") == "monitoring", "alerta deve conter namespace=monitoring"
assert alert_labels.get("severity") == "critical", "alerta deve ser critical"
assert alert_labels.get("category") == "availability", "alerta deve ser availability"

for path in (external_secret_path, alertmanager_config_path):
    text = path.read_text(encoding="utf-8").lower()
    assert "discord.com/api/webhooks/" not in text, "não inclua URL real do Discord no Git"
    assert "events.pagerduty.com" not in text, "não inclua credencial ou endpoint customizado do PagerDuty no Git"

print("✅ Roteamento para PagerDuty e Discord, secrets e seletores validados")
PY

if grep -q 'variable "pagerduty_routing_key"' infra/variables.tf \
  && grep -q 'variable "discord_webhook_url"' infra/variables.tf \
  && grep -q 'resource "aws_secretsmanager_secret" "alert_notifications"' infra/secrets.tf \
  && grep -q 'aws_secretsmanager_secret_version.alert_notifications' infra/observability.tf; then
  printf '✅ Credenciais de incidentes e ChatOps integradas ao Terraform e Secrets Manager\n'
else
  printf '❌ Integração Terraform das credenciais está incompleta\n' >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra fmt -check variables.tf secrets.tf observability.tf
  printf '✅ Arquivos Terraform de notificações estão formatados\n'
else
  printf '⚠️ Terraform não instalado; formatação não validada localmente.\n'
fi

printf '\nIntegração de incidentes com PagerDuty e ChatOps com Discord validada estaticamente.\n'
