resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.ingest_function_name}"
  retention_in_days = var.log_retention_days
}

# --- Role ------------------------------------------------------------------

data "aws_iam_policy_document" "ingest_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.name_prefix}-ingest"
  assume_role_policy = data.aws_iam_policy_document.ingest_assume.json
}

# Network interfaces in the VPC and log delivery.
resource "aws_iam_role_policy_attachment" "ingest_vpc" {
  role       = aws_iam_role.ingest.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "ingest" {
  # Listing is limited to the user_report prefixes, reading to the objects
  # below them. Prompt and completion logs in the same bucket are out of reach.
  statement {
    sid       = "ListUserReports"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.source_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for p in local.user_report_prefixes : "${p}*"]
    }
  }

  statement {
    sid       = "ReadUserReports"
    actions   = ["s3:GetObject"]
    resources = [for p in local.user_report_prefixes : "arn:${local.partition}:s3:::${var.source_bucket}/${p}*"]
  }

  statement {
    sid     = "ReadDatabaseSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_db_instance.this.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.reader.arn,
    ]
  }

  statement {
    sid       = "DecryptDatabaseSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  dynamic "statement" {
    for_each = var.source_kms_key_arn == null ? [] : [var.source_kms_key_arn]
    content {
      sid       = "DecryptSourceBucket"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${local.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

# --- Function --------------------------------------------------------------

resource "aws_lambda_function" "ingest" {
  function_name = local.ingest_function_name
  description   = "Imports Kiro user_report CSVs into PostgreSQL"
  role          = aws_iam_role.ingest.arn

  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "kiro_ingest.handler.lambda_handler"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  memory_size = 256
  timeout     = 300
  # Runs never overlap; the code also takes a database advisory lock.
  reserved_concurrent_executions = 1

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.ingest.id]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.ingest.name
  }

  environment {
    variables = {
      DB_HOST           = aws_db_instance.this.address
      DB_PORT           = tostring(aws_db_instance.this.port)
      DB_NAME           = var.db_name
      DB_SECRET_ARN     = aws_db_instance.this.master_user_secret[0].secret_arn
      DB_SSLMODE        = "verify-full"
      READER_SECRET_ARN = aws_secretsmanager_secret.reader.arn
      READER_ROLE       = var.reader_role_name
      SOURCE_BUCKET     = var.source_bucket
      SOURCE_PREFIXES   = join(",", var.source_prefixes)
      SOURCE_ACCOUNT_ID = local.source_account_id
      SOURCE_REGIONS    = join(",", local.source_regions)
      LOOKBACK_MONTHS   = tostring(var.lookback_months)
      TIER_MODEL_JSON   = jsonencode(var.tier_model)
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ingest_vpc,
    aws_iam_role_policy.ingest,
    aws_secretsmanager_secret_version.reader,
  ]
}

# --- Schedules -------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.ingest.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-ingest"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "ingest" {
  for_each = var.ingest_schedules

  name                         = "${var.name_prefix}-ingest-${each.key}"
  schedule_expression          = each.value
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.ingest.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({})

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# --- Alarms ----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ingest_errors" {
  alarm_name          = "${local.ingest_function_name}-errors"
  alarm_description   = "The Kiro ingest failed. Check the function log; data in Grafana is not updated."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.ingest.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.this["ops"].arn]
  ok_actions          = [aws_sns_topic.this["ops"].arn]
}

resource "aws_cloudwatch_metric_alarm" "ingest_not_running" {
  alarm_name          = "${local.ingest_function_name}-not-running"
  alarm_description   = "The Kiro ingest has not been invoked for a day. Check the EventBridge schedules."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.ingest.function_name }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.this["ops"].arn]
  ok_actions          = [aws_sns_topic.this["ops"].arn]
}
