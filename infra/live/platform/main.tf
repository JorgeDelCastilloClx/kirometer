provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge(
      { Project = "kiro-usage-analytics", ManagedBy = "opentofu", Stack = "platform" },
      var.tags,
    )
  }

  ignore_tags {
    key_prefixes = var.ignore_tag_prefixes
  }
}

locals {
  # "<prefix>AWSLogs/<account>/KiroLogs/user_report/" -> prefix and account.
  report_paths = [
    for p in var.user_report_paths : regex("^(.*)AWSLogs/([0-9]{12})/KiroLogs/user_report/$", p)
  ]

  grafana_emails = distinct(concat(var.grafana_admin_emails, var.grafana_editor_emails, var.grafana_viewer_emails))
}

check "required_settings" {
  assert {
    condition = (
      var.vpc_id != null && length(var.subnet_ids) >= 2 &&
      var.source_bucket != null && length(var.user_report_paths) > 0
    )
    error_message = "Set vpc_id, subnet_ids (2+), source_bucket and user_report_paths in config/<environment>.tfvars."
  }
}

# Grafana sign-in uses IAM Identity Center, so roles are assigned to its
# user IDs. Resolve the configured e-mail addresses to those IDs.
data "aws_ssoadmin_instances" "this" {
  count = length(local.grafana_emails) > 0 ? 1 : 0
}

data "aws_identitystore_user" "grafana" {
  for_each = toset(local.grafana_emails)

  identity_store_id = tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "emails.value"
      attribute_value = each.value
    }
  }
}

module "platform" {
  source = "../../modules/kiro-usage-platform"

  name_prefix                 = var.name_prefix
  vpc_id                      = var.vpc_id
  subnet_ids                  = var.subnet_ids
  interface_endpoint_services = var.interface_endpoint_services

  source_bucket     = var.source_bucket
  source_prefixes   = [for m in local.report_paths : m[0]]
  source_account_id = try(local.report_paths[0][1], null)

  lambda_zip_path = "${path.root}/../../../build/kiro-ingest.zip"

  grafana_admin_user_ids  = [for e in var.grafana_admin_emails : data.aws_identitystore_user.grafana[e].user_id]
  grafana_editor_user_ids = [for e in var.grafana_editor_emails : data.aws_identitystore_user.grafana[e].user_id]
  grafana_viewer_user_ids = [for e in var.grafana_viewer_emails : data.aws_identitystore_user.grafana[e].user_id]

  alert_email_subscriptions = var.alert_emails
  ops_email_subscriptions   = var.ops_emails

  tier_model = var.tier_model
}
