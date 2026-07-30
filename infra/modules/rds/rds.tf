
resource "aws_db_subnet_group" "default" {
  name       = "${var.prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = "${var.prefix}-db-subnet-group"
    }
  )
}

resource "aws_security_group" "rds" {
  name        = "${var.prefix}-rds-sg"
  description = "Allow Postgres access from VPC"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
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
      Name = "${var.prefix}-rds-sg"
    }
  )
}

resource "aws_db_instance" "default" {
  for_each = { for db in var.dbs_config : db.name => db }

  identifier          = "${each.value.name}-db"
  allocated_storage   = each.value.storage
  db_name             = "${each.value.name}db"
  engine              = each.value.engine
  engine_version      = each.value.version
  instance_class      = each.value.instance_class
  username            = each.value.username
  password            = each.value.password
  skip_final_snapshot = true

  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  tags = merge(
    var.tags,
    {
      Name = "${each.value.name}-db"
    }
  )
}
