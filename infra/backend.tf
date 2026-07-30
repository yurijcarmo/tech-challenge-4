terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate-yuri-698173141574"
    key          = "eks-cluster/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = false # AWS ACADEMY: s3:PutObject no .tflock é bloqueado pela LabRole
  }
}
