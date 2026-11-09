# Each rule's query returns one row per user (or account). Grafana turns the
# string columns into labels, so every row becomes its own alert instance,
# and the single numeric `value` column is compared against the threshold.
#
# Reactive tier model: everyone starts the month low and is raised when actual
# usage makes a higher tier cheaper. Usage alerts are digests (one mail per
# rule listing everyone), delivered only inside their windows; pipeline alerts
# go out whenever they happen.

locals {
  rules = {
    raise = {
      uid         = "kiro-raise"
      title       = "Kiro - raise before month end"
      threshold   = 0
      sql         = <<-SQL
        SELECT section, user_label, account_id, tier, target_tier, expected_tier,
               credits_mtd, projected, saving_net, value
        FROM v_alert_raise
        ORDER BY section, value DESC
      SQL
      labels      = { severity = "warning", team = "finops", digest = "raise", alert_type = "tier_raise" }
      summary     = <<-EOT
        {{ if eq $labels.section "1 raise now" }}{{ $labels.user_label }}: {{ $labels.tier }} -> {{ $labels.target_tier }}, {{ $labels.credits_mtd }} credits this month, saving $${{ $labels.saving_net }}{{ if ne $labels.expected_tier $labels.target_tier }} (expected {{ $labels.expected_tier }} by month end){{ end }}{{ else }}{{ $labels.user_label }}: {{ $labels.tier }}, {{ $labels.credits_mtd }} credits, projected {{ $labels.projected }} -> {{ $labels.target_tier }}{{ end }}
      EOT
      description = "Actual usage this month makes a higher tier cheaper for these users. An upgrade recalculates the whole month under the new tier, so any time before the reset works; batch them, and do not miss the reset."
    }

    lower = {
      uid         = "kiro-safe-to-lower"
      title       = "Kiro - safe to lower now"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, tier, reset_to, credits_mtd, projected, value
        FROM v_alert_safe_to_lower
      SQL
      labels      = { severity = "info", team = "finops", digest = "lower", alert_type = "tier_lower_early" }
      summary     = "{{ $labels.user_label }}: {{ $labels.tier }} -> {{ $labels.reset_to }} ({{ $labels.credits_mtd }} credits so far, projected {{ $labels.projected }})"
      description = "These users' projection stays well below their tier's raise point, so the downgrade to the reset tier can be requested now. Downgrades apply from next month; the user keeps the current tier until then."
    }

    reset = {
      uid         = "kiro-lower-before-reset"
      title       = "Kiro - lower before reset"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, tier, reset_to, lower, credits_mtd, credits_prev_month, value
        FROM v_alert_reset
      SQL
      labels      = { severity = "info", team = "finops", digest = "reset", alert_type = "tier_reset" }
      summary     = "{{ $labels.user_label }}: {{ $labels.tier }} -> {{ $labels.reset_to }} (this month {{ $labels.credits_mtd }}, last month {{ $labels.credits_prev_month }}{{ if eq $labels.lower \"safe now\" }}, may already be requested{{ end }})"
      description = "Everyone above the reset tier for next month. Request these now so the identity provider sync completes before the reset; users lowered earlier this month are listed too, because the data cannot tell."
    }

    opus = {
      uid         = "kiro-heavy-opus"
      title       = "Kiro - heavy Opus use"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, model, newest_opus, superseded, opus_share,
               messages, credits_est, window_days, value
        FROM v_alert_heavy_opus
      SQL
      labels      = { severity = "info", team = "finops", digest = "opus", alert_type = "heavy_opus" }
      summary     = "{{ $labels.user_label }}: {{ $labels.model }}, {{ $labels.opus_share }} of messages, {{ $labels.messages }} messages, ~{{ $labels.credits_est }} credits ({{ $labels.window_days }}){{ if eq $labels.superseded \"yes\" }}; superseded, {{ $labels.newest_opus }} is available{{ end }}"
      description = "Opus is allowed; sustained use can also be a model left selected by mistake. Worth a quick check with the user. Credits per model are estimates (split by message share); usage under auto is not broken down by Kiro."
    }

    freshness = {
      uid         = "kiro-data-freshness"
      title       = "Kiro - usage data is stale"
      threshold   = var.freshness_max_days_behind
      sql         = <<-SQL
        SELECT account_id, days_behind AS value
        FROM v_data_freshness
      SQL
      labels      = { severity = "warning", team = "ops", alert_type = "data_freshness" }
      summary     = "Kiro usage data for account {{ $labels.account_id }} is {{ printf \"%.0f\" $values.B.Value }} days behind."
      description = "Kiro writes each day's report at 02:00 UTC the next day, so 1 day behind is normal. Check the ingest function log and the source bucket."
    }
  }

  delivery_times = [{ start = var.delivery_window.start, end = var.delivery_window.end }]
}

resource "grafana_rule_group" "kiro" {
  name             = "kiro-credit-alerts"
  folder_uid       = grafana_folder.kiro.uid
  interval_seconds = var.evaluation_interval_seconds

  dynamic "rule" {
    for_each = local.rules
    content {
      uid            = rule.value.uid
      name           = rule.value.title
      condition      = "C"
      for            = "0s"
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels         = rule.value.labels
      annotations = {
        summary     = trimspace(rule.value.summary)
        description = rule.value.description
      }

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.kiro.uid
        # Must be non-zero although the views scope themselves to the month.
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({
          refId         = "A"
          datasource    = { type = local.datasource_type, uid = grafana_data_source.kiro.uid }
          format        = "table"
          rawQuery      = true
          editorMode    = "code"
          rawSql        = rule.value.sql
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "B"
          type       = "reduce"
          expression = "A"
          reducer    = "last"
          datasource = { type = "__expr__", uid = "__expr__" }
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "B"
          datasource = { type = "__expr__", uid = "__expr__" }
          conditions = [{ evaluator = { type = "gt", params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

# --- Delivery --------------------------------------------------------------

# Digest mails: the rule's description as the intro, then one line per user
# from the summary annotation. The raise digest prints its two sections.
resource "grafana_message_template" "kiro" {
  name     = "kiro"
  template = <<-EOT
    {{ define "kiro.subject" -}}
    {{ .CommonLabels.alertname }}{{ if .CommonLabels.user_label }}: {{ .CommonLabels.user_label }}{{ else }}: {{ len .Alerts.Firing }} users{{ end }}
    {{- end }}

    {{ define "kiro.message" -}}
    {{ if .Alerts.Firing -}}
    {{ with index .Alerts.Firing 0 }}{{ .Annotations.description }}{{ end }}

    {{ if eq .CommonLabels.digest "raise" -}}
    Raise now:
    {{ range .Alerts.Firing }}{{ if eq .Labels.section "1 raise now" }}  {{ .Annotations.summary }}
    {{ end }}{{ end }}
    Likely to need a raise by month end (projection, for the next batch):
    {{ range .Alerts.Firing }}{{ if eq .Labels.section "2 likely by month end" }}  {{ .Annotations.summary }}
    {{ end }}{{ end }}
    {{- else -}}
    {{ range .Alerts.Firing }}  {{ .Annotations.summary }}
    {{ end }}
    {{- end }}
    {{- end }}
    {{- end }}
  EOT
}

resource "grafana_contact_point" "finops" {
  name = "kiro-finops"
  sns {
    topic = var.alerts_topic_arn
    # Grafana 13's SNS integration reads `topic_arn`; provider 4.49 only
    # sends `topic`, which Grafana 13 rejects. With no sigv4 block, Grafana
    # signs with the workspace IAM role. The message goes into the settings
    # map for the same reason (the provider's `body` is not Grafana's
    # `message`); the subject maps cleanly, and the provider reads it back as
    # `subject`, so it must be set there to avoid a change on every plan.
    subject = "{{ template \"kiro.subject\" . }}"
    settings = {
      topic_arn = var.alerts_topic_arn
      message   = "{{ template \"kiro.message\" . }}"
    }
    # Usage digests: no mail when an item clears (e.g. after a raise).
    disable_resolve_message = true
  }

  depends_on = [grafana_message_template.kiro]
}

resource "grafana_contact_point" "ops" {
  name = "kiro-ops"
  sns {
    topic    = var.ops_topic_arn
    settings = { topic_arn = var.ops_topic_arn }
  }
}

# Rules are evaluated on an interval, not on a clock schedule, so usage
# alerts are held back and only delivered inside these windows (UTC by
# default). Evaluation runs every 10 minutes, so results computed after the
# 06:30 import are what gets delivered at 07:00.

# Raise digest: weekly, and daily from month_end_daily_from_day to the end of
# the month so nobody is left on the wrong tier at the reset.
resource "grafana_mute_timing" "raise" {
  name = "kiro-raise-windows"
  intervals {
    location = var.delivery_timezone
    weekdays = [var.weekly_digest_weekday]
    dynamic "times" {
      for_each = local.delivery_times
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
  intervals {
    location      = var.delivery_timezone
    days_of_month = ["${var.month_end_daily_from_day}:31"]
    dynamic "times" {
      for_each = local.delivery_times
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
}

# Safe to lower: the weekly digest day, from mid-month.
resource "grafana_mute_timing" "lower" {
  name = "kiro-lower-windows"
  intervals {
    location      = var.delivery_timezone
    weekdays      = [var.weekly_digest_weekday]
    days_of_month = ["${var.safe_to_lower_from_day}:31"]
    dynamic "times" {
      for_each = local.delivery_times
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
}

# Lower before reset: once a month, with lead time for the identity sync.
resource "grafana_mute_timing" "reset" {
  name = "kiro-reset-window"
  intervals {
    location      = var.delivery_timezone
    days_of_month = [tostring(var.reset_list_day)]
    dynamic "times" {
      for_each = local.delivery_times
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
}

# Heavy Opus use: any day, as soon as a case is seen.
resource "grafana_mute_timing" "daily" {
  name = "kiro-daily-window"
  intervals {
    location = var.delivery_timezone
    dynamic "times" {
      for_each = local.delivery_times
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
}

# Replaces the workspace's root notification policy. Time intervals are not
# inherited, so every child repeats its active_timings.
resource "grafana_notification_policy" "root" {
  contact_point = grafana_contact_point.finops.name
  group_by      = ["alertname", "user_label"]

  # One mail per rule, listing everyone. Repeat intervals are shorter than
  # the gap between two windows, so every window resends the current list.
  dynamic "policy" {
    for_each = {
      raise = { timing = grafana_mute_timing.raise.name, repeat = var.raise_repeat_interval }
      lower = { timing = grafana_mute_timing.lower.name, repeat = var.lower_repeat_interval }
      reset = { timing = grafana_mute_timing.reset.name, repeat = var.reset_repeat_interval }
    }
    content {
      contact_point = grafana_contact_point.finops.name
      group_by      = ["alertname"]
      matcher {
        label = "team"
        match = "="
        value = "finops"
      }
      matcher {
        label = "digest"
        match = "="
        value = policy.key
      }
      active_timings  = [policy.value.timing]
      group_wait      = "1m"
      group_interval  = "5m" # shorter than the window, so a flush always lands inside it
      repeat_interval = policy.value.repeat
    }
  }

  # Heavy Opus use: one mail per user when a case starts; a reminder after
  # opus_repeat_interval while it continues; a new mail if it starts again.
  policy {
    contact_point = grafana_contact_point.finops.name
    group_by      = ["alertname", "user_label"]
    matcher {
      label = "team"
      match = "="
      value = "finops"
    }
    matcher {
      label = "digest"
      match = "="
      value = "opus"
    }
    active_timings  = [grafana_mute_timing.daily.name]
    group_wait      = "1m"
    group_interval  = "5m"
    repeat_interval = var.opus_repeat_interval
  }

  # Pipeline alerts: whenever they happen.
  policy {
    contact_point = grafana_contact_point.ops.name
    matcher {
      label = "team"
      match = "="
      value = "ops"
    }
    group_by        = ["alertname", "account_id"]
    repeat_interval = "12h"
  }
}
