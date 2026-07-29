locals {
  apps_by_name = { for app in var.apps : app.name => app }
}

resource "kubernetes_namespace_v1" "apps" {
  for_each = local.apps_by_name

  metadata {
    name = each.value.namespace
  }
}

resource "kubernetes_manifest" "apps" {
  for_each = local.apps_by_name

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = each.value.name
      namespace = "argocd"
    }
    spec = {
      project = var.argocd_project
      source = {
        repoURL        = var.argocd_repo_url
        path           = each.value.path
        targetRevision = var.target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = each.value.namespace
      }
      ignoreDifferences = [
        {
          group     = "apps"
          kind      = "Deployment"
          name      = each.value.name
          namespace = each.value.namespace
          jsonPointers = [
            "/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"
          ]
        }
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "RespectIgnoreDifferences=true"
        ]
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.apps
  ]
}

resource "null_resource" "apps_ingress" {
  for_each = local.apps_by_name

  triggers = {
    app_name    = each.value.name
    apps_domain = var.apps_domain
    path_prefix = each.value.path_prefix
    port        = each.value.port
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${var.eks_cluster_name} --region ${var.aws_region}
      kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${each.value.name}-ingress
  namespace: ${each.value.namespace}
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
    external-dns.alpha.kubernetes.io/hostname: ${var.apps_domain}
spec:
  ingressClassName: ${var.ingress_class_name}
  rules:
  - host: ${var.apps_domain}
    http:
      paths:
      - path: ${each.value.path_prefix}(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: ${each.value.name}
            port:
              number: ${each.value.port}
EOF
    EOT
  }

  depends_on = [
    kubernetes_namespace_v1.apps
  ]
}
