resource "aws_elasticache_subnet_group" "default" {
  name       = "redis-cache-subnet"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "${var.prefix}-redis-sg"
  description = "Allow Redis access from VPC"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.prefix}-redis-sg"
    }
  )
}

resource "aws_elasticache_cluster" "default" {
  for_each             = { for cache in var.cache_config : cache.name => cache }
  cluster_id           = "${each.value.name}-cluster"
  engine               = each.value.engine
  node_type            = each.value.node_type
  num_cache_nodes      = each.value.num_cache_nodes
  parameter_group_name = each.value.parameter_group_name
  engine_version       = each.value.engine_version
  port                 = each.value.port

  subnet_group_name  = aws_elasticache_subnet_group.default.name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(
    var.tags,
    {
      Name = "${each.value.name}-cache"
    }
  )
}
