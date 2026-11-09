variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "kiro-usage"
}

# --- Network ---------------------------------------------------------------

variable "vpc_id" {
  description = "VPC for the Lambda, the database and the Grafana VPC connection."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets in at least two Availability Zones (required by RDS and Managed Grafana)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two private subnets in different Availability Zones."
  }
}

variable "interface_endpoint_services" {
  description = <<-EOT
    VPC interface endpoints to create, as AWS service names (e.g. "secretsmanager").
    Needed when the VPC has no NAT gateway: the Lambda reads secrets and the
    VPC-connected Grafana workspace sends alerts to SNS. Set to [] if the VPC
    already has these endpoints or a NAT gateway (private DNS would conflict
    with an existing endpoint). Add "sts" if SNS delivery from Grafana fails
    with credential errors.
  EOT
  type        = list(string)
  default     = ["secretsmanager", "sns"]
}

variable "interface_endpoint_subnet_ids" {
  description = "Subnets for the interface endpoints (one per AZ). Default: the first subnet only, which keeps hourly endpoint cost minimal; endpoints are reachable from all AZs."
  type        = list(string)
  default     = null
}

variable "extra_https_egress_cidrs" {
  description = "Additional CIDRs the Lambda and Grafana may reach on 443, e.g. when existing endpoints or a NAT gateway are used instead of interface_endpoint_services."
  type        = list(string)
  default     = []
}

# --- Source ----------------------------------------------------------------

variable "source_bucket" {
  description = "S3 bucket Kiro writes its user activity reports to."
  type        = string
}

variable "source_prefixes" {
  description = "Prefixes in front of AWSLogs/ in the source bucket. Include duplicated prefixes if Kiro ever wrote reports under them."
  type        = list(string)
  default     = ["kiro/"]

  validation {
    condition     = alltrue([for p in var.source_prefixes : p == "" || endswith(p, "/")])
    error_message = "Each prefix must be empty or end with '/'."
  }
}

variable "source_account_id" {
  description = "Account ID in the report paths. Default: the current account."
  type        = string
  default     = null
}

variable "source_regions" {
  description = "Regions of the Kiro profiles whose reports are imported. Default: the current region."
  type        = list(string)
  default     = null
}

variable "source_kms_key_arn" {
  description = "KMS key of the source bucket, only if it uses SSE-KMS."
  type        = string
  default     = null
}

# --- Ingest ----------------------------------------------------------------

variable "lambda_zip_path" {
  description = "Path to the ingest package built by scripts/build_lambda.py."
  type        = string
}

variable "ingest_schedules" {
  description = "EventBridge Scheduler expressions (UTC). Kiro writes each day's report at 02:00 UTC the next day; 06:30 leaves margin for late reports and finishes before the 07:00 alert delivery."
  type        = map(string)
  default = {
    daily = "cron(30 6 * * ? *)"
  }

  validation {
    condition     = alltrue([for e in values(var.ingest_schedules) : can(regex("^(cron|rate)\\(", e))])
    error_message = "Schedule expressions must be cron(...) or rate(...)."
  }
}

variable "lookback_months" {
  description = "Calendar months re-checked on every run (current month plus previous ones). Unchanged files are skipped."
  type        = number
  default     = 2
}

variable "tier_model" {
  description = "Reactive tier model settings (see infra/live/variables.tf). Passed to the ingest as JSON and written to the settings table; keys not given keep their database defaults."
  type        = any
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the ingest function."
  type        = number
  default     = 90
}

# --- Database --------------------------------------------------------------

variable "db_engine_version" {
  description = "PostgreSQL version. A major version only (e.g. \"18\") takes the default minor and lets RDS apply minor upgrades."
  type        = string
  default     = "18"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 50
}

variable "db_name" {
  type    = string
  default = "kiro_usage"
}

variable "db_master_username" {
  type    = string
  default = "kiro_admin"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_backup_retention_days" {
  description = "Backup retention set when the instance is created. Later changes are ignored, so an organisation backup plan can own retention and window."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "reader_role_name" {
  description = "Read-only database role Grafana uses. Created and kept in sync by the ingest function."
  type        = string
  default     = "kiro_grafana_ro"
}

variable "reader_password_version" {
  description = "Increase by one to generate a new reader password. Afterwards run the ingest once and re-apply the grafana stack."
  type        = number
  default     = 1
}

# --- Grafana ---------------------------------------------------------------

variable "grafana_version" {
  type    = string
  default = "13.2"
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs with the Grafana Admin role."
  type        = list(string)
  default     = []
}

variable "grafana_admin_group_ids" {
  type    = list(string)
  default = []
}

variable "grafana_editor_user_ids" {
  description = "IAM Identity Center user IDs with the Grafana Editor role (can also create silences)."
  type        = list(string)
  default     = []
}

variable "grafana_editor_group_ids" {
  type    = list(string)
  default = []
}

variable "grafana_viewer_user_ids" {
  description = "IAM Identity Center user IDs with the Grafana Viewer role."
  type        = list(string)
  default     = []
}

variable "grafana_viewer_group_ids" {
  type    = list(string)
  default = []
}

# --- Notifications ---------------------------------------------------------

variable "alert_email_subscriptions" {
  description = "E-mail addresses for usage alerts (raise, lower, model use). Each must confirm the SNS subscription."
  type        = list(string)
  default     = []
}

variable "ops_email_subscriptions" {
  description = "E-mail addresses for pipeline alerts (ingest errors, stale data)."
  type        = list(string)
  default     = []
}
