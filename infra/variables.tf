variable "prefix" {
  description = "Prefix para nomear os recursos"
  type        = string
  default     = "terraform"
}

variable "environment" {
  description = "Ambiente onde os recursos serão criados"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Nome do projeto"
  type        = string
  default     = "eks-setup"
}

variable "aws_region" {
  description = "Região AWS onde os recursos serão criados"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
  default     = "eks-cluster"
}

variable "cidr_block" {
  description = "Bloco CIDR para a VPC"
  type        = string
}

variable "argocd_domain" {
  description = "Dominio completo para o ArgoCD (ex: argocd.exemplo.com)"
  type        = string
}

variable "apps_domain" {
  description = "Dominio completo para as apps (ex: desafio.exemplo.com)"
  type        = string
}

variable "argocd_repo_url" {
  description = "Repositorio Git com os manifests das apps"
  type        = string
}

variable "argocd_target_revision" {
  description = "Branch, tag ou commit sincronizado pelo Argo CD"
  type        = string
  default     = "HEAD"
}

variable "db_password" {
  description = "Senha dos bancos de dados RDS (nao commitar — definir no terraform.tfvars)"
  type        = string
  sensitive   = true
}

variable "new_relic_license_key" {
  description = "New Relic ingest license key usada pelo OpenTelemetry Collector"
  type        = string
  sensitive   = true
}
