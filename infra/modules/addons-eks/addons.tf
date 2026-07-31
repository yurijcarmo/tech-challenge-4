resource "helm_release" "metrics_server" {
  name         = "metrics-server"
  repository   = "https://kubernetes-sigs.github.io/metrics-server/"
  chart        = "metrics-server"
  version      = "3.12.2"
  namespace    = "kube-system"
  force_update = true # AWS ACADEMY: evita erro "cannot re-use a name that is still in use"
}

locals {
  oidc = split("/", var.oidc)[4]
}
resource "kubernetes_namespace_v1" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  name            = "ingress-nginx"
  repository      = "https://kubernetes.github.io/ingress-nginx"
  chart           = "ingress-nginx"
  version         = "4.10.1"
  namespace       = "ingress-nginx"
  force_update    = false # atualiza recursos sem tentar substituí-los
  replace         = false # preserva o Service e seu loadBalancerClass
  cleanup_on_fail = true  # AWS ACADEMY: limpa recursos em caso de falha no upgrade
  wait            = false # AWS ACADEMY: NLB demora para provisionar, não bloquear o apply
  timeout         = 600

  set = [
    {
      name  = "controller.service.type"
      value = "LoadBalancer"
    },
    {
      name  = "controller.service.externalTrafficPolicy"
      value = "Cluster"
    },
    {
      name  = "controller.ingressClassResource.name"
      value = "nginx"
    },
    {
      name  = "controller.ingressClass"
      value = "nginx"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
      value = "nlb"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
      value = "ip"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
      value = "internet-facing"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-attributes"
      value = "load_balancing.cross_zone.enabled=true"
    },
    {
      name  = "controller.service.ports.http"
      value = "80"
    },
    {
      name  = "controller.service.ports.https"
      value = "443"
    }
    ,
    {
      name  = "controller.service.targetPorts.http"
      value = "http"
    },
    {
      name  = "controller.service.targetPorts.https"
      value = "http"
    }
  ]

  depends_on = [
    kubernetes_namespace_v1.ingress_nginx,
  ]
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.project}-external-secrets"
  description = "Policy for External Secrets Operator to read AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# CONTA PESSOAL - código original (comentado para referência)
# IRSA para External Secrets Operator com trust policy OIDC federada
# ============================================================
# resource "aws_iam_role" "external_secrets" {
#   name               = "${var.project}-external-secrets"
#   description        = "IAM role for External Secrets Operator"
#   assume_role_policy = <<EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Principal": {
#         "Federated": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${data.aws_region.current.region}.amazonaws.com/id/${local.oidc}"
#       },
#       "Action": "sts:AssumeRoleWithWebIdentity",
#       "Condition": {
#         "StringEquals": {
#           "oidc.eks.${data.aws_region.current.region}.amazonaws.com/id/${local.oidc}:aud": "sts.amazonaws.com",
#           "oidc.eks.${data.aws_region.current.region}.amazonaws.com/id/${local.oidc}:sub": "system:serviceaccount:external-secrets:external-secrets"
#         }
#       }
#     }
#   ]
# }
# EOF
#
#   tags = merge(var.tags, {
#     Name = "${var.project}-external-secrets"
#   })
# }
#
# resource "aws_iam_role_policy_attachment" "external_secrets" {
#   role       = aws_iam_role.external_secrets.name
#   policy_arn = aws_iam_policy.external_secrets.arn
# }

resource "kubernetes_service_account_v1" "external_secrets" {
  metadata {
    name      = "external-secrets"
    namespace = "external-secrets"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.aws_iam_role.lab_role.arn
    }
  }
}

resource "helm_release" "external_secrets" {
  name         = "external-secrets"
  chart        = "oci://ghcr.io/external-secrets/charts/external-secrets"
  version      = "0.10.4"
  namespace    = "external-secrets"
  replace      = true # AWS ACADEMY: substitui release em estado failed
  wait         = true
  timeout      = 600
  force_update = true # AWS ACADEMY: evita erro "cannot re-use a name that is still in use"

  set = [
    {
      name  = "installCRDs"
      value = "true"
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.external_secrets.metadata[0].name
    }
  ]

  depends_on = [
    kubernetes_namespace_v1.external_secrets,
    kubernetes_service_account_v1.external_secrets
  ]
}

resource "helm_release" "keda" {
  name         = "keda"
  repository   = "https://kedacore.github.io/charts"
  chart        = "keda"
  version      = "2.15.0"
  namespace    = "keda"
  force_update = true  # AWS ACADEMY: evita erro "cannot re-use a name that is still in use"
  replace      = true  # AWS ACADEMY: substitui release em estado failed
  wait         = false # AWS ACADEMY: CRDs podem não estar prontos no timeout — evita "scaledobjects.keda.sh not found"
  timeout      = 600

  set = [
    {
      name  = "crds.install"
      value = "true"
    }
  ]

  depends_on = [
    kubernetes_namespace_v1.keda
  ]
}

resource "kubernetes_namespace_v1" "keda" {
  metadata {
    name = "keda"
  }
}

resource "kubernetes_manifest" "external_secrets_cluster_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secrets-manager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = data.aws_region.current.id
          # AWS ACADEMY: sem IRSA — usa secretRef com credenciais temporárias da sessão
          auth = {
            secretRef = {
              accessKeyIDSecretRef = {
                name      = "aws-credentials"
                namespace = "external-secrets"
                key       = "access-key"
              }
              secretAccessKeySecretRef = {
                name      = "aws-credentials"
                namespace = "external-secrets"
                key       = "secret-access-key"
              }
              sessionTokenSecretRef = {
                name      = "aws-credentials"
                namespace = "external-secrets"
                key       = "session-token"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.external_secrets
  ]
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "random_password" "argocd_server_secretkey" {
  length  = 32
  special = false
}

resource "helm_release" "argocd" {
  name         = "argocd"
  repository   = "https://argoproj.github.io/argo-helm"
  chart        = "argo-cd"
  version      = "9.0.0"
  namespace    = "argocd"
  force_update = true
  wait         = false
  timeout      = 600

  values = [
    yamlencode({
      configs = {
        secret = {
          createSecret          = true
          argocdServerSecretkey = random_password.argocd_server_secretkey.result
        }
        cm = {
          "accounts.terraform" = "apiKey, login"
        }
        params = {
          "server.insecure" = "true"
        }
        rbac = {
          "policy.csv" = "g, terraform, role:admin"
        }
      }
    })
  ]

  set = [
    {
      name  = "server.service.type"
      value = "LoadBalancer"
    },
    {
      name  = "server.insecure"
      value = "true"
    }
  ]

  # AWS ACADEMY: sem dominio - ArgoCD exposto via LoadBalancer HTTP
  # Apos apply: kubectl get svc argocd-server -n argocd -o wide

  depends_on = [
    kubernetes_namespace_v1.argocd
  ]
}
