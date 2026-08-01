#!/usr/bin/env bash

set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
UPDATE_GITHUB_SECRETS="${UPDATE_GITHUB_SECRETS:-true}"

fail() {
  echo "❌ $1" >&2
  exit 1
}

warn() {
  echo "⚠️  $1"
}

success() {
  echo "✅ $1"
}

for command in aws kubectl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Comando obrigatório não encontrado: $command"
done

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID não definida}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY não definida}"
: "${AWS_SESSION_TOKEN:?AWS_SESSION_TOKEN não definida}"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "===== 1. VALIDANDO A NOVA SESSÃO AWS ====="

AWS_IDENTITY="$(
  aws sts get-caller-identity \
    --query '[Account,Arn]' \
    --output text
)"

echo "Identidade: $AWS_IDENTITY"

aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id eks/newrelic \
  --query 'ARN' \
  --output text >/dev/null

success "Sessão AWS válida e com acesso ao Secrets Manager."

apply_aws_secret() {
  local namespace="$1"
  local secret_name="$2"

  echo "Atualizando ${namespace}/${secret_name}..."

  kubectl -n "$namespace" create secret generic "$secret_name" \
    --from-literal=access-key="$AWS_ACCESS_KEY_ID" \
    --from-literal=secret-access-key="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=session-token="$AWS_SESSION_TOKEN" \
    --dry-run=client \
    -o yaml |
  kubectl apply -f - >/dev/null

  keys="$(
    kubectl -n "$namespace" get secret "$secret_name" -o json |
      jq -r '.data | keys | sort | join(", ")'
  )"

  echo "Chaves aplicadas: $keys"
}

echo
echo "===== 2. ATUALIZANDO CREDENCIAIS NO EKS ====="

apply_aws_secret external-secrets aws-credentials
apply_aws_secret analytics-service aws-credentials

success "Credenciais Kubernetes atualizadas."

echo
echo "===== 3. ATUALIZANDO GITHUB ACTIONS SECRETS ====="

if [[ "$UPDATE_GITHUB_SECRETS" == "true" || "$UPDATE_GITHUB_SECRETS" == "1" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    REPOSITORY="$(
      gh repo view \
        --json nameWithOwner \
        --jq '.nameWithOwner' \
        2>/dev/null || true
    )"

    if [[ -n "$REPOSITORY" ]]; then
      gh secret set AWS_ACCESS_KEY_ID \
        --repo "$REPOSITORY" \
        --body "$AWS_ACCESS_KEY_ID"

      gh secret set AWS_SECRET_ACCESS_KEY \
        --repo "$REPOSITORY" \
        --body "$AWS_SECRET_ACCESS_KEY"

      gh secret set AWS_SESSION_TOKEN \
        --repo "$REPOSITORY" \
        --body "$AWS_SESSION_TOKEN"

      success "GitHub Actions Secrets atualizados em $REPOSITORY."
    else
      warn "Não foi possível identificar o repositório pelo GitHub CLI."
    fi
  else
    warn "GitHub CLI ausente ou não autenticado. Secrets do GitHub não foram atualizados."
  fi
else
  warn "Atualização dos Secrets do GitHub desabilitada."
fi

echo
echo "===== 4. RECONCILIANDO EXTERNAL SECRETS ====="

SYNC_TIMESTAMP="$(date +%s)"

kubectl get externalsecrets.external-secrets.io -A -o json |
  jq -r '
    .items[]
    | [.metadata.namespace, .metadata.name]
    | @tsv
  ' |
  while IFS=$'\t' read -r namespace name; do
    echo "Solicitando sincronização de ${namespace}/${name}..."

    kubectl -n "$namespace" annotate externalsecret "$name" \
      force-sync="$SYNC_TIMESTAMP" \
      --overwrite >/dev/null
  done

kubectl -n external-secrets rollout restart \
  deployment/external-secrets >/dev/null

kubectl -n external-secrets rollout status \
  deployment/external-secrets \
  --timeout=3m

echo
echo "===== 5. RECONCILIANDO KEDA ====="

kubectl -n analytics-service annotate \
  triggerauthentication analytics-service-aws-auth \
  force-sync="$SYNC_TIMESTAMP" \
  --overwrite >/dev/null

kubectl -n analytics-service annotate \
  scaledobject analytics-service \
  force-sync="$SYNC_TIMESTAMP" \
  --overwrite >/dev/null

kubectl -n keda rollout restart \
  deployment/keda-operator >/dev/null

kubectl -n keda rollout status \
  deployment/keda-operator \
  --timeout=3m

echo
echo "===== 6. AGUARDANDO RECURSOS ====="

kubectl wait \
  --for=condition=Ready \
  externalsecret \
  --all \
  --all-namespaces \
  --timeout=3m

kubectl wait \
  -n analytics-service \
  --for=condition=Ready \
  scaledobject/analytics-service \
  --timeout=3m

echo
echo "===== 7. ATUALIZANDO SAÚDE NO ARGO CD ====="

for application in observability analytics-service; do
  kubectl -n argocd annotate application "$application" \
    argocd.argoproj.io/refresh=hard \
    --overwrite >/dev/null
done

sleep 10

echo
echo "===== 8. RESULTADO FINAL ====="

echo "--- ExternalSecrets ---"

kubectl get externalsecrets.external-secrets.io -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[-1].status,REASON:.status.conditions[-1].reason'

echo
echo "--- KEDA ---"

kubectl -n analytics-service get scaledobject analytics-service \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ACTIVE:.status.conditions[?(@.type=="Active")].status,HPA:.status.hpaName'

echo
kubectl -n analytics-service get hpa -o wide

echo
echo "--- Argo CD ---"

kubectl -n argocd get applications \
  observability analytics-service \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase'

echo
success "Credenciais temporárias propagadas com sucesso."
