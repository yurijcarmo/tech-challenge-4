locals {
  apps_by_name = { for app in var.apps : app.name => app }
}

resource "kubernetes_namespace_v1" "apps" {
  for_each = local.apps_by_name

  metadata {
    name = each.value.namespace
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
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
            "/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt",
            "/spec/replicas"
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

resource "kubernetes_ingress_v1" "apps_ingress" {
  for_each = local.apps_by_name

  metadata {
    name      = "${each.key}-ingress"
    namespace = each.value.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/use-regex"          = "true"
      "nginx.ingress.kubernetes.io/rewrite-target"     = "/$2"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "60"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "60"
      "external-dns.alpha.kubernetes.io/hostname"      = var.apps_domain
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.apps_domain

      http {
        path {
          path      = "${each.value.path_prefix}(/|$)(.*)"
          path_type = "ImplementationSpecific"

          backend {
            service {
              name = each.key

              port {
                number = each.value.port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.apps,
  ]
}

