module "network" {
  source     = "./modules/network"
  prefix     = var.prefix
  project    = var.project
  cidr_block = var.cidr_block
  tags       = local.tags
}

module "eks_cluster" {
  source  = "./modules/cluster"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  public_subnet_1a_id = module.network.eks_subnet_public_1a_id
  public_subnet_1b_id = module.network.eks_subnet_public_1b_id

}

module "managed_node_group" {
  source  = "./modules/managed-node-group"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  eks_cluster_name     = module.eks_cluster.eks_cluster_name
  private_subnet_1a_id = module.network.eks_subnet_private_1a_id
  private_subnet_1b_id = module.network.eks_subnet_private_1b_id
}

module "eks_loadbalancer_controller" {
  source           = "./modules/aws-loadbalacer-controller"
  prefix           = var.prefix
  project          = var.project
  tags             = local.tags
  oidc             = module.eks_cluster.oidc
  eks_cluster_name = module.eks_cluster.eks_cluster_name

}

module "ecr_repositories" {
  source  = "./modules/ecr"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  repos = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service"
  ]

}

module "databases" {
  source  = "./modules/rds"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  subnet_ids     = [module.network.eks_subnet_private_1a_id, module.network.eks_subnet_private_1b_id]
  vpc_id         = module.network.vpc_id
  vpc_cidr_block = var.cidr_block
  dbs_config = [
    {
      name           = "auth"
      engine         = "postgres"
      version        = "17.2"
      storage        = 10
      instance_class = "db.t3.micro"
      username       = "appuser"
      password       = var.db_password
    },
    {
      name           = "flag"
      engine         = "postgres"
      version        = "17.2"
      storage        = 20
      instance_class = "db.t3.micro"
      username       = "appuser"
      password       = var.db_password
    },

    {
      name           = "targeting"
      engine         = "postgres"
      version        = "17.2"
      storage        = 20
      instance_class = "db.t3.micro"
      username       = "appuser"
      password       = var.db_password
    }
  ]
}

module "elasticache" {
  source  = "./modules/elasticache"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  subnet_ids     = [module.network.eks_subnet_private_1a_id, module.network.eks_subnet_private_1b_id]
  vpc_id         = module.network.vpc_id
  vpc_cidr_block = var.cidr_block
  cache_config = [
    {
      name                 = "redis-cache"
      engine               = "redis"
      engine_version       = "6.x"
      node_type            = "cache.t3.micro"
      num_cache_nodes      = 1
      parameter_group_name = "default.redis6.x"
      port                 = 6379
    }
  ]
}

module "dynamodb" {
  source  = "./modules/dynamodb"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  dynamodb_table = {
    name           = "ToggleMasterAnalytics"
    billing_mode   = "PROVISIONED"
    read_capacity  = 20
    write_capacity = 20
    attribute_definitions = [
      {
        name = "event_id"
        type = "S"
      }
    ]
  }
}


module "sqs" {
  source  = "./modules/sqs"
  prefix  = var.prefix
  project = var.project
  tags    = local.tags

  queues = [
    {
      name                      = "analytics-queue"
      delay_seconds             = 0
      max_message_size          = 262144
      message_retention_seconds = 345600
    }
  ]

}


module "addons-eks" {
  source  = "./modules/addons-eks"
  project = var.project
  tags    = local.tags

  eks_cluster_name = module.eks_cluster.eks_cluster_name
  oidc             = module.eks_cluster.oidc
  argocd_domain    = var.argocd_domain
  apps_domain      = var.apps_domain
}

module "apps" {
  source = "./modules/apps"

  argocd_repo_url  = var.argocd_repo_url
  target_revision  = var.argocd_target_revision
  apps_domain      = var.apps_domain
  eks_cluster_name = module.eks_cluster.eks_cluster_name
  depends_on       = [module.addons-eks]

  apps = [
    {
      name        = "auth-service"
      namespace   = "auth-service"
      path        = "auth-service/k8s"
      path_prefix = "/auth"
      port        = 8001
    },
    {
      name        = "flag-service"
      namespace   = "flag-service"
      path        = "flag-service/k8s"
      path_prefix = "/flag"
      port        = 8002
    },
    {
      name        = "targeting-service"
      namespace   = "targeting-service"
      path        = "targeting-service/k8s"
      path_prefix = "/targeting"
      port        = 8003
    },
    {
      name        = "evaluation-service"
      namespace   = "evaluation-service"
      path        = "evaluation-service/k8s"
      path_prefix = "/evaluation"
      port        = 8004
    },
    {
      name        = "analytics-service"
      namespace   = "analytics-service"
      path        = "analytics-service/k8s"
      path_prefix = "/analytics"
      port        = 8005
    }
  ]
}
