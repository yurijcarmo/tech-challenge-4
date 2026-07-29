#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
RUNBOOK_FILE="observability/gitops/self-healing-runbook.yaml"
ALERTMANAGER_FILE="observability/gitops/togglemaster-alertmanager-config.yaml"
APPS_MODULE_FILE="infra/modules/apps/main.tf"

required_files=(
  "$RUNBOOK_FILE"
  "$ALERTMANAGER_FILE"
  "$APPS_MODULE_FILE"
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

runbook_path = Path("observability/gitops/self-healing-runbook.yaml")
alertmanager_path = Path("observability/gitops/togglemaster-alertmanager-config.yaml")
apps_module_path = Path("infra/modules/apps/main.tf")

documents = [doc for doc in yaml.safe_load_all(runbook_path.read_text(encoding="utf-8")) if doc]
resources = {
    (
        doc.get("kind"),
        doc.get("metadata", {}).get("namespace"),
        doc.get("metadata", {}).get("name"),
    ): doc
    for doc in documents
}

expected = {
    ("ConfigMap", "monitoring", "self-healing-runbook-script"),
    ("ServiceAccount", "monitoring", "self-healing-runbook"),
    ("Role", "auth-service", "self-healing-auth-service-restarter"),
    ("RoleBinding", "auth-service", "self-healing-auth-service-restarter"),
    ("Deployment", "monitoring", "self-healing-runbook"),
    ("Service", "monitoring", "self-healing-runbook"),
}
missing = expected - set(resources)
assert not missing, f"recursos ausentes no runbook: {sorted(missing)}"

config_map = resources[("ConfigMap", "monitoring", "self-healing-runbook-script")]
script = config_map.get("data", {}).get("runbook.py", "")
assert script, "runbook.py ausente no ConfigMap"
compile(script, "runbook.py", "exec")
for fragment in (
    'RESTART_ANNOTATION = "kubectl.kubernetes.io/restartedAt"',
    'labels.get("self_healing") != "true"',
    'labels.get("service") != TARGET_SERVICE',
    "COOLDOWN_SECONDS",
    'kube_request("PATCH", deployment_path(), patch)',
    "ThreadingHTTPServer",
):
    assert fragment in script, f"lógica obrigatória ausente no runbook: {fragment}"

service_account = resources[("ServiceAccount", "monitoring", "self-healing-runbook")]
assert service_account.get("automountServiceAccountToken") is True

role = resources[("Role", "auth-service", "self-healing-auth-service-restarter")]
rules = role.get("rules", [])
assert len(rules) == 1, "Role deve possuir uma única regra mínima"
rule = rules[0]
assert rule.get("apiGroups") == ["apps"]
assert rule.get("resources") == ["deployments"]
assert rule.get("resourceNames") == ["auth-service"]
assert set(rule.get("verbs", [])) == {"get", "patch"}

binding = resources[("RoleBinding", "auth-service", "self-healing-auth-service-restarter")]
subject = binding.get("subjects", [])[0]
assert subject == {
    "kind": "ServiceAccount",
    "name": "self-healing-runbook",
    "namespace": "monitoring",
}
assert binding.get("roleRef", {}).get("name") == "self-healing-auth-service-restarter"

deployment = resources[("Deployment", "monitoring", "self-healing-runbook")]
pod_spec = deployment.get("spec", {}).get("template", {}).get("spec", {})
assert pod_spec.get("serviceAccountName") == "self-healing-runbook"
containers = pod_spec.get("containers", [])
assert len(containers) == 1
container = containers[0]
env = {item.get("name"): item.get("value") for item in container.get("env", [])}
assert env.get("TARGET_SERVICE") == "auth-service"
assert env.get("TARGET_NAMESPACE") == "auth-service"
assert env.get("TARGET_DEPLOYMENT") == "auth-service"
assert env.get("COOLDOWN_SECONDS") == "300"
security_context = container.get("securityContext", {})
assert security_context.get("allowPrivilegeEscalation") is False
assert security_context.get("readOnlyRootFilesystem") is True

service = resources[("Service", "monitoring", "self-healing-runbook")]
assert service.get("spec", {}).get("type") == "ClusterIP"
ports = service.get("spec", {}).get("ports", [])
assert any(port.get("port") == 8080 for port in ports)

alertmanager = yaml.safe_load(alertmanager_path.read_text(encoding="utf-8"))
receivers = {
    receiver.get("name"): receiver
    for receiver in alertmanager.get("spec", {}).get("receivers", [])
}
receiver = receivers.get("pagerduty-and-discord")
assert receiver, "receiver principal ausente"
webhooks = receiver.get("webhookConfigs", [])
assert len(webhooks) == 1
webhook = webhooks[0]
assert webhook.get("sendResolved") is True
assert webhook.get("url") == (
    "http://self-healing-runbook.monitoring.svc.cluster.local:8080/alerts"
)
assert webhook.get("timeout") == "10s"

apps_module = apps_module_path.read_text(encoding="utf-8")
for fragment in (
    "ignoreDifferences",
    "kubectl.kubernetes.io~1restartedAt",
    "RespectIgnoreDifferences=true",
):
    assert fragment in apps_module, f"proteção GitOps ausente: {fragment}"

runbook_text = runbook_path.read_text(encoding="utf-8")
assert "kind: ClusterRole" not in runbook_text
assert 'verbs:\n      - "*"' not in runbook_text

print("✅ Webhook, runbook, cooldown, rollout restart e RBAC mínimo validados")
PY

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra fmt -check modules/apps/main.tf
  printf '✅ Módulo Terraform do Argo CD está formatado\n'
else
  printf '⚠️ Terraform não instalado; formatação do módulo Argo CD não validada localmente.\n'
fi

printf '\nAutomação de Self-Healing validada estaticamente.\n'
