# Configuration shared by the bootstrap, platform and grafana stacks.
# Each stack links this file (variables.tf -> ../variables.tf), and all values
# come from one file per deployment: config/<environment>.tfvars.
# See config/example.tfvars.

variable "environment" {
  description = "Short name of this deployment, e.g. \"team-a\". Used for local file names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.environment))
    error_message = "Use lowercase letters, digits and dashes."
  }
}

# --- AWS ---------------------------------------------------------------------

variable "aws_profile" {
  description = "AWS CLI profile to use. null = default credential chain (environment variables, SSO, instance role)."
  type        = string
  default     = null
}

variable "aws_account_id" {
  description = "Account to deploy into. OpenTofu refuses to run against any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "An AWS account ID has 12 digits."
  }
}

variable "aws_region" {
  type = string
}

variable "name_prefix" {
  description = "Prefix for all resource names, the state bucket and the state encryption keys."
  type        = string
  default     = "kiro-usage"
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}

variable "ignore_tag_prefixes" {
  description = "Tag key prefixes managed outside OpenTofu (e.g. by an organization backup automation). OpenTofu leaves them alone."
  type        = list(string)
  default     = []
}

# --- Network -----------------------------------------------------------------

variable "vpc_id" {
  description = "VPC for the database, the ingest Lambda and the Grafana VPC connection."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private subnets in at least two Availability Zones."
  type        = list(string)
  default     = []
}

variable "interface_endpoint_services" {
  description = "VPC interface endpoints to create. Needed without a NAT gateway; set to [] if the VPC already has them."
  type        = list(string)
  default     = ["secretsmanager", "sns"]
}

# --- Kiro reports ------------------------------------------------------------

variable "source_bucket" {
  description = "S3 bucket Kiro writes its user activity reports to."
  type        = string
  default     = null
}

variable "user_report_paths" {
  description = <<-EOT
    Path(s) to the user_report folder inside source_bucket, as shown in the
    S3 console, e.g. "kiro/AWSLogs/123456789012/KiroLogs/user_report/".
    List more than one if Kiro wrote reports under several prefixes. Nothing
    outside these paths is read; the ingest role has no access to it.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for p in var.user_report_paths : can(regex("^(.*/)?AWSLogs/[0-9]{12}/KiroLogs/user_report/$", p))
    ])
    error_message = "Each path must look like \"<prefix>/AWSLogs/<account-id>/KiroLogs/user_report/\" (with trailing slash)."
  }

  validation {
    condition = length(distinct([
      for p in var.user_report_paths : try(regex("AWSLogs/([0-9]{12})/", p)[0], "")
    ])) <= 1
    error_message = "All user_report paths must belong to the same account."
  }
}

# --- People ------------------------------------------------------------------
# E-mail addresses as registered in IAM Identity Center. Grafana roles are
# resolved to Identity Center user IDs at plan time.

variable "grafana_admin_emails" {
  description = "Grafana Admin: everything, including data source and user management."
  type        = list(string)
  default     = []
}

variable "grafana_editor_emails" {
  description = "Grafana Editor: dashboards, alert rule view and silences."
  type        = list(string)
  default     = []
}

variable "grafana_viewer_emails" {
  description = "Grafana Viewer: dashboards and alert states, read-only."
  type        = list(string)
  default     = []
}

variable "alert_emails" {
  description = "Receive usage alerts (raise, lower, heavy Opus use). Each address must confirm the SNS subscription."
  type        = list(string)
  default     = []
}

variable "ops_emails" {
  description = "Receive pipeline alerts (ingest errors, schedule not running, stale data)."
  type        = list(string)
  default     = []
}

# --- Reactive tier model ------------------------------------------------------
# Everyone starts the month on reset_tier and is raised when actual usage
# makes a higher tier cheaper. Written to the database by every ingest run, so
# dashboard panels and alert rules use the same values.

variable "tier_model" {
  description = "Reactive tier model settings. The defaults suit any deployment (list prices, reset to PRO)."
  type = object({
    reset_tier             = optional(string, "PRO") # tier every user returns to for the next month
    billing_discount_pct   = optional(number, 0)     # discount on the whole Kiro bill, e.g. an AWS EDP; 0 = list prices
    safe_to_lower_from_day = optional(number, 15)    # "safe to lower now" from this day of the month
    safe_to_lower_margin   = optional(number, 0.8)   # ... when the projection stays below margin x the tier's raise point
    quiet_ratio            = optional(number, 0.7)   # projection / last month below this: quiet month
    busy_ratio             = optional(number, 1.3)   # above this: busy month
    opus_window_days       = optional(number, 2)     # heavy Opus use: last N report days ...
    opus_min_credits       = optional(number, 750)   # ... at least this many estimated Opus credits ...
    opus_min_share         = optional(number, 0.8)   # ... and at least this share of the user's messages
  })
  default = {}

  validation {
    condition     = contains(["PRO", "PRO_PLUS", "PRO_MAX", "POWER"], var.tier_model.reset_tier)
    error_message = "reset_tier must be PRO, PRO_PLUS, PRO_MAX or POWER."
  }
  validation {
    condition     = var.tier_model.billing_discount_pct >= 0 && var.tier_model.billing_discount_pct < 100
    error_message = "billing_discount_pct is a percentage between 0 and 100."
  }
  validation {
    condition     = var.tier_model.safe_to_lower_from_day >= 1 && var.tier_model.safe_to_lower_from_day <= 28
    error_message = "safe_to_lower_from_day must be between 1 and 28."
  }
  validation {
    condition = (
      var.tier_model.safe_to_lower_margin > 0 && var.tier_model.safe_to_lower_margin <= 1 &&
      var.tier_model.quiet_ratio > 0 && var.tier_model.quiet_ratio < 1 && var.tier_model.busy_ratio > 1 &&
      var.tier_model.opus_min_share > 0 && var.tier_model.opus_min_share <= 1 &&
      var.tier_model.opus_min_credits > 0 &&
      var.tier_model.opus_window_days >= 1 && var.tier_model.opus_window_days <= 14
    )
    error_message = "Margins and shares are fractions (0-1], quiet_ratio < 1 < busy_ratio, opus_window_days 1-14."
  }
}
