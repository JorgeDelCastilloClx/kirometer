# Two topics: usage alerts go to whoever manages the subscriptions, pipeline
# alerts (ingest errors, stale data) to whoever runs the platform.

locals {
  topics = {
    alerts = "Kiro usage alerts (raise, lower, model use)"
    ops    = "Kiro pipeline alerts (ingest errors, stale data)"
  }
}

resource "aws_sns_topic" "this" {
  for_each = local.topics

  name              = "${var.name_prefix}-${each.key}"
  display_name      = "Kiro ${each.key}"
  kms_master_key_id = aws_kms_key.this.arn
}

data "aws_iam_policy_document" "topic" {
  for_each = local.topics

  statement {
    sid       = "AccountPrincipals"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic"]
    resources = [aws_sns_topic.this[each.key].arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this[each.key].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this[each.key].arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  for_each = local.topics

  arn    = aws_sns_topic.this[each.key].arn
  policy = data.aws_iam_policy_document.topic[each.key].json
}

resource "aws_sns_topic_subscription" "alerts" {
  for_each = toset(var.alert_email_subscriptions)

  topic_arn = aws_sns_topic.this["alerts"].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "ops" {
  for_each = toset(var.ops_email_subscriptions)

  topic_arn = aws_sns_topic.this["ops"].arn
  protocol  = "email"
  endpoint  = each.value
}
