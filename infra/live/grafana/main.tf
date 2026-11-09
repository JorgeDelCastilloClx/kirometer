provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.aws_account_id]

  ignore_tags {
    key_prefixes = var.ignore_tag_prefixes
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket  = "${var.name_prefix}-tofu-state-${var.aws_account_id}-${var.aws_region}"
    key     = "platform/terraform.tfstate"
    region  = var.aws_region
    profile = var.aws_profile
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs
}

# Authentication comes from the GRAFANA_AUTH environment variable, set by
# scripts/with-grafana-token.sh with a token that expires after one hour.
provider "grafana" {
  url = local.platform.grafana_url
}

data "aws_secretsmanager_secret_version" "reader" {
  secret_id = local.platform.reader_secret_arn
}

module "grafana" {
  source = "../../modules/kiro-usage-grafana"

  db_host     = local.platform.db_host
  db_port     = local.platform.db_port
  db_name     = local.platform.db_name
  db_user     = local.platform.reader_role_name
  db_password = data.aws_secretsmanager_secret_version.reader.secret_string
  db_ca_cert  = file("${path.root}/../../../certs/rds-global-bundle.pem")

  alerts_topic_arn = local.platform.alerts_topic_arn
  ops_topic_arn    = local.platform.ops_topic_arn

  safe_to_lower_from_day = var.tier_model.safe_to_lower_from_day
}

output "dashboard_urls" {
  value = module.grafana.dashboard_urls
}
