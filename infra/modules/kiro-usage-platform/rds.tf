resource "aws_db_subnet_group" "this" {
  name       = var.name_prefix
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name_prefix}-pg${local.pg_major}-"
  family      = "postgres${local.pg_major}"
  description = "Kiro usage PostgreSQL ${local.pg_major}"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "password_encryption"
    value        = "scram-sha-256"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name_prefix
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_master_username
  # RDS generates the master password, stores it in Secrets Manager and
  # rotates it. It never appears in OpenTofu state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.this.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  # Backups and maintenance finish well before the 06:30 UTC ingest.
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "00:00-00:45"
  maintenance_window      = "sun:01:00-sun:01:45"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = false

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-final"

  lifecycle {
    # Retention and window are only initial values. An organisation backup
    # plan with continuous backup (point-in-time restore) sets its own
    # retention and window on the instance; reverting them would conflict
    # with that plan and delete automated backups beyond the shorter period.
    ignore_changes = [backup_retention_period, backup_window]
  }
}
