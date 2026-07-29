# ============================================================
# Secrets Manager — popula os secrets consumidos pelo ESO
# Cada serviço tem um secret em eks/<service-name> com todos
# os valores que o ExternalSecret busca via dataFrom.extract
# ============================================================

locals {
  sqs_queue_url  = values(module.sqs.queue_urls)[0]
  redis_endpoint = values(module.elasticache.cache_endpoints)[0]
  redis_port     = tostring(values(module.elasticache.cache_ports)[0])
}

# auth-service
resource "aws_secretsmanager_secret" "auth_service" {
  name                    = "eks/auth-service"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "auth_service" {
  secret_id = aws_secretsmanager_secret.auth_service.id
  secret_string = jsonencode({
    DB_HOST     = module.databases.db_endpoints["auth"]
    DB_PORT     = "5432"
    DB_USER     = module.databases.db_usernames["auth"]
    DB_PASSWORD = var.db_password
    DB_NAME     = module.databases.db_names["auth"]
  })
}

# flag-service
resource "aws_secretsmanager_secret" "flag_service" {
  name                    = "eks/flag-service"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "flag_service" {
  secret_id = aws_secretsmanager_secret.flag_service.id
  secret_string = jsonencode({
    DB_HOST     = module.databases.db_endpoints["flag"]
    DB_PORT     = "5432"
    DB_USER     = module.databases.db_usernames["flag"]
    DB_PASSWORD = var.db_password
    DB_NAME     = module.databases.db_names["flag"]
  })
}

# targeting-service
resource "aws_secretsmanager_secret" "targeting_service" {
  name                    = "eks/targeting-service"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "targeting_service" {
  secret_id = aws_secretsmanager_secret.targeting_service.id
  secret_string = jsonencode({
    DB_HOST     = module.databases.db_endpoints["targeting"]
    DB_PORT     = "5432"
    DB_USER     = module.databases.db_usernames["targeting"]
    DB_PASSWORD = var.db_password
    DB_NAME     = module.databases.db_names["targeting"]
  })
}

# evaluation-service
resource "aws_secretsmanager_secret" "evaluation_service" {
  name                    = "eks/evaluation-service"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "evaluation_service" {
  secret_id = aws_secretsmanager_secret.evaluation_service.id
  secret_string = jsonencode({
    REDIS_HOST = local.redis_endpoint
    REDIS_PORT = local.redis_port
  })
}

# analytics-service
resource "aws_secretsmanager_secret" "analytics_service" {
  name                    = "eks/analytics-service"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "analytics_service" {
  secret_id = aws_secretsmanager_secret.analytics_service.id
  secret_string = jsonencode({
    DYNAMODB_TABLE     = "ToggleMasterAnalytics"
    SQS_QUEUE_URL      = local.sqs_queue_url
    AWS_DEFAULT_REGION = "us-east-1"
  })
}

# observability stack
resource "random_password" "grafana_admin_password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "observability" {
  name                    = "eks/observability"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "observability" {
  secret_id = aws_secretsmanager_secret.observability.id
  secret_string = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin_password.result
  })
}

# New Relic OTLP ingest
resource "aws_secretsmanager_secret" "new_relic" {
  name                    = "eks/newrelic"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "new_relic" {
  secret_id = aws_secretsmanager_secret.new_relic.id
  secret_string = jsonencode({
    "license-key" = var.new_relic_license_key
  })
}

# Alertmanager incident management and ChatOps
resource "aws_secretsmanager_secret" "alert_notifications" {
  name                    = "eks/alert-notifications"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "alert_notifications" {
  secret_id = aws_secretsmanager_secret.alert_notifications.id
  secret_string = jsonencode({
    "pagerduty-routing-key" = var.pagerduty_routing_key
    "discord-webhook-url"   = var.discord_webhook_url
  })
}
