# Example deployment configuration. Copy to config/<environment>.tfvars and
# fill in your values; every config/*.tfvars except this file is git-ignored.
#
#   cp config/example.tfvars config/team-a.tfvars
#   make ENV=team-a bootstrap

environment = "team-a"

# --- AWS ---------------------------------------------------------------------
aws_profile    = "team-a-admin" # AWS CLI profile; remove to use the default credential chain
aws_account_id = "123456789012"
aws_region     = "eu-central-1"
name_prefix    = "kiro-usage"

tags = {
  CostCenter = "1234"
}

# Tag prefixes set by automation outside OpenTofu, e.g. an organization backup
# policy that tags RDS and S3. Leave empty if there is none.
ignore_tag_prefixes = []

# --- Network: private subnets in at least two AZs ----------------------------
vpc_id     = "vpc-0123456789abcdef0"
subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]

# Without a NAT gateway these interface endpoints are required. Set to [] if
# the VPC already has them (private DNS would clash).
interface_endpoint_services = ["secretsmanager", "sns"]

# --- Kiro reports ------------------------------------------------------------
source_bucket = "my-kiro-logs-bucket"
# Copy the path from the S3 console. Nothing outside it is readable.
user_report_paths = [
  "kiro/AWSLogs/123456789012/KiroLogs/user_report/",
]

# --- People (IAM Identity Center e-mail addresses) ---------------------------
grafana_admin_emails  = ["admin@example.com"]
grafana_editor_emails = ["finops@example.com"]
grafana_viewer_emails = ["manager@example.com"]

alert_emails = ["finops@example.com"]
ops_emails   = ["platform-team@example.com"]

# --- Reactive tier model -------------------------------------------------------
# Everyone starts the month on reset_tier and is raised when actual usage makes
# a higher tier cheaper. Every key is optional; these are the defaults.
tier_model = {
  reset_tier             = "PRO"
  billing_discount_pct   = 0 # discount on the whole Kiro bill (e.g. an AWS EDP), if any
  safe_to_lower_from_day = 15
  safe_to_lower_margin   = 0.8
  quiet_ratio            = 0.7
  busy_ratio             = 1.3
  opus_window_days       = 2
  opus_min_credits       = 750
  opus_min_share         = 0.8
}
