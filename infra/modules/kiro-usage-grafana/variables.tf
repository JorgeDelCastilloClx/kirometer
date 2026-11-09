variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_user" {
  description = "Read-only reporting role."
  type        = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_ca_cert" {
  description = "PEM bundle used to verify the database certificate (sslmode verify-full)."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for usage alerts."
  type        = string
}

variable "ops_topic_arn" {
  description = "SNS topic for pipeline alerts."
  type        = string
}

variable "folder_title" {
  type    = string
  default = "Kiro"
}

variable "dashboards_dir" {
  description = "Directory with dashboard JSON files. Default: the dashboards shipped with this module."
  type        = string
  default     = null
}

variable "evaluation_interval_seconds" {
  description = "How often alert rules are evaluated. Grafana picks its own offset within the interval, so this must be short enough that rules re-evaluate between the ingest (06:30 UTC) and the delivery window (07:00 UTC)."
  type        = number
  default     = 600
}

variable "delivery_window" {
  description = "Time of day when usage alerts may be sent. Starts after the 06:30 UTC import and a following rule evaluation."
  type = object({
    start = string
    end   = string
  })
  default = { start = "07:00", end = "07:15" }
}

variable "delivery_timezone" {
  type    = string
  default = "UTC"
}

variable "weekly_digest_weekday" {
  description = "Day of the weekly raise digest (and of the safe-to-lower digest from mid-month)."
  type        = string
  default     = "monday"

  validation {
    condition     = contains(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"], var.weekly_digest_weekday)
    error_message = "Use a lowercase English weekday."
  }
}

variable "month_end_daily_from_day" {
  description = "From this day of the month the raise digest is sent daily, so short last weeks are covered."
  type        = number
  default     = 22
}

variable "safe_to_lower_from_day" {
  description = "First day of the month for the safe-to-lower digest. Pass tier_model.safe_to_lower_from_day so mails and views agree."
  type        = number
  default     = 15
}

variable "reset_list_day" {
  description = "Day of the month the lower-before-reset list is sent, with lead time for the identity provider sync."
  type        = number
  default     = 22
}

# Repeat intervals, written the way Grafana stores them, otherwise every plan
# shows a change. Each is shorter than the gap between two of its windows.
variable "raise_repeat_interval" {
  type    = string
  default = "23h"
}

variable "lower_repeat_interval" {
  type    = string
  default = "6d23h"
}

variable "reset_repeat_interval" {
  description = "Shorter than the gap between two reset days (28 days from Feb 22 to Mar 22)."
  type        = string
  default     = "27d"
}

variable "opus_repeat_interval" {
  description = "Reminder while a heavy-Opus case continues (one week; Grafana stores 7d as 1w)."
  type        = string
  default     = "1w"
}

variable "freshness_max_days_behind" {
  description = "Pipeline alert when the newest imported report is older than this many days. 1 is normal."
  type        = number
  default     = 2
}
