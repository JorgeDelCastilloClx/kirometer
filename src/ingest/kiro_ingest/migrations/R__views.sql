-- R__views: every view and function, rebuilt as a unit.
--
-- Repeatable migration: re-applied whenever the checksum of this file changes.
-- Everything is dropped and recreated, so column changes never hit the
-- CREATE OR REPLACE VIEW restrictions. Grants on the views are re-applied by
-- the ingest code after every run, because DROP VIEW removes them.
--
-- Views that were removed stay in the DROP list, so existing databases lose
-- them too (otherwise they would survive and keep their reader grant).

DROP VIEW IF EXISTS
    -- removed with the reactive tier model
    v_alert_tier_downgrade,
    v_tier_recommendation,
    v_alert_overage_forecast,
    v_alert_tier_upgrade,
    -- current
    v_alert_heavy_opus,
    v_alert_reset,
    v_alert_safe_to_lower,
    v_alert_raise,
    v_month_glance,
    v_expected_usage,
    v_current_status,
    v_month_base,
    v_settings,
    v_plans,
    v_data_freshness,
    v_usage_monthly,
    v_usage_model_daily,
    v_usage_daily
CASCADE;

-- SECURITY DEFINER: functions run with the caller's privileges by default,
-- even inside a view. These run as their owner, so readers of the views do
-- not need access to the plans table. search_path is pinned so the functions
-- cannot be redirected to objects a caller creates.
CREATE OR REPLACE FUNCTION plan_cost(p_tier text, p_credits numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.monthly_price_usd
         + greatest(0::numeric, p_credits - p.included_credits) * p.addon_rate_usd
    FROM public.plans p WHERE p.tier = p_tier
$$;

-- Cheapest tier for a month's credits at list prices. A discount applies to
-- every price alike, so it never changes the answer. On a tie the lower tier
-- wins.
CREATE OR REPLACE FUNCTION cheapest_tier(p_credits numeric)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.tier FROM public.plans p
    ORDER BY public.plan_cost(p.tier, p_credits), p.sort_order
    LIMIT 1
$$;

-- ---------------------------------------------------------------------------
-- Dashboard views. user_label falls back to a short id prefix when the report
-- carries no email.
-- ---------------------------------------------------------------------------
CREATE VIEW v_usage_daily AS
SELECT d.usage_date,
       d.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(d.user_id, 8)) AS user_label,
       d.client_type,
       d.subscription_tier,
       d.credits_used,
       d.total_messages,
       d.chat_conversations,
       d.overage_enabled,
       d.overage_cap,
       d.overage_credits_used,
       d.usage_limit,
       d.account_id
FROM usage_daily d
JOIN users u USING (user_id);

CREATE VIEW v_usage_model_daily AS
SELECT m.usage_date,
       m.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(m.user_id, 8)) AS user_label,
       m.client_type,
       d.subscription_tier,
       m.model,
       m.messages,
       -- Credits are reported per user/day/client, never per model. Split them
       -- by message share so model cost is comparable (an estimate).
       CASE WHEN d.total_messages > 0
            THEN d.credits_used * m.messages / d.total_messages
            ELSE 0
       END AS credits_attributed,
       m.account_id
FROM usage_model_daily m
JOIN usage_daily d USING (account_id, usage_date, user_id, client_type)
JOIN users u USING (user_id);

-- ---------------------------------------------------------------------------
-- Calendar-month rollup per user. Credits reset per calendar month, so every
-- utilisation metric is scoped to the month.
-- ---------------------------------------------------------------------------
CREATE VIEW v_usage_monthly AS
WITH per_user AS (
    SELECT d.account_id,
           date_trunc('month', d.usage_date)::date                         AS month,
           d.user_id,
           COALESCE(NULLIF(u.email, ''), 'unknown-' || left(d.user_id, 8)) AS user_label,
           -- A mid-month plan change leaves several tiers in a month; the
           -- newest one is the current subscription.
           (array_agg(d.subscription_tier ORDER BY d.usage_date DESC))[1]  AS subscription_tier,
           sum(d.credits_used)                                             AS credits_mtd,
           sum(d.total_messages)                                           AS messages_mtd,
           sum(d.overage_credits_used)                                     AS overage_credits_mtd,
           max(d.overage_cap)                                              AS overage_cap,
           max(d.usage_date)                                               AS last_usage_date,
           count(DISTINCT d.usage_date)                                    AS active_days
    FROM usage_daily d
    JOIN users u USING (user_id)
    GROUP BY 1, 2, 3, 4
)
SELECT pu.*,
       p.included_credits,
       p.monthly_price_usd,
       p.next_tier,
       round(pu.credits_mtd / NULLIF(p.included_credits, 0) * 100, 1) AS utilization_pct,
       plan_cost(pu.subscription_tier, pu.credits_mtd)                AS cost_current_tier,
       CASE WHEN p.next_tier IS NOT NULL
            THEN plan_cost(p.next_tier, pu.credits_mtd) END           AS cost_next_tier
FROM per_user pu
LEFT JOIN plans p ON p.tier = pu.subscription_tier;

-- ---------------------------------------------------------------------------
-- Plan catalogue and settings, readable by panels (the base tables are not).
-- raise_at_credits: credits at which the next tier becomes cheaper than
-- staying and paying add-on credits; no value for the top tier.
-- ---------------------------------------------------------------------------
CREATE VIEW v_plans AS
SELECT p.tier,
       p.monthly_price_usd                                       AS price_usd,
       p.included_credits,
       p.addon_rate_usd,
       p.next_tier,
       p.sort_order,
       CASE WHEN p.next_tier IS NOT NULL
            THEN p.included_credits + p.overshoot_threshold_credits END AS raise_at_credits
FROM plans p;

CREATE VIEW v_settings AS
SELECT s.reset_tier,
       s.billing_discount_pct,
       1 - s.billing_discount_pct / 100 AS net_factor,
       s.safe_to_lower_from_day,
       s.safe_to_lower_margin,
       s.quiet_ratio,
       s.busy_ratio,
       s.opus_window_days,
       s.opus_min_credits,
       s.opus_min_share,
       s.updated_at
FROM settings s;

-- ---------------------------------------------------------------------------
-- Per-user basis for the current calendar month (the month of the newest
-- report). Everyone seen this month or last month is included: Kiro only
-- reports active users, so people without usage this month come from last
-- month.
-- ---------------------------------------------------------------------------
CREATE VIEW v_month_base AS
WITH bounds AS (
    SELECT max(usage_date)                                                           AS as_of,
           date_trunc('month', max(usage_date))::date                                AS month,
           (date_trunc('month', max(usage_date)) - interval '1 month')::date         AS prev_month,
           (date_trunc('month', max(usage_date)) + interval '1 month - 1 day')::date AS month_end
    FROM usage_daily
),
-- Only subscriptions that are still reporting; retired accounts are ignored.
active_accounts AS (
    SELECT DISTINCT d.account_id
    FROM usage_daily d CROSS JOIN bounds b
    WHERE d.usage_date >= b.month
),
-- The previous month only counts if the account reported for all of it.
coverage AS (
    SELECT account_id, min(usage_date) AS first_report
    FROM usage_daily
    GROUP BY 1
),
population AS (
    SELECT d.account_id,
           d.user_id,
           -- Newest report wins; several clients on the same day take the
           -- highest tier (only the highest applies when assigned twice).
           (array_agg(d.subscription_tier ORDER BY d.usage_date DESC, tp.sort_order DESC NULLS LAST))[1]
                                                                                     AS tier,
           COALESCE(sum(d.credits_used) FILTER (WHERE d.usage_date >= b.month), 0) AS credits_mtd,
           COALESCE(sum(d.credits_used) FILTER (
               WHERE d.usage_date >= b.prev_month AND d.usage_date < b.month), 0)    AS credits_prev_month,
           -- Divided by the window length, not by active days, so idle days
           -- pull the average down.
           COALESCE(sum(d.credits_used) FILTER (
               WHERE d.usage_date > b.as_of - 7), 0) / 7.0                           AS avg_daily_7d,
           max(d.usage_date)                                                         AS last_active,
           bool_or(d.usage_date >= b.month)                                          AS active_this_month
    FROM usage_daily d
    CROSS JOIN bounds b
    JOIN active_accounts a USING (account_id)
    LEFT JOIN plans tp ON tp.tier = d.subscription_tier
    WHERE d.usage_date >= b.prev_month
    GROUP BY 1, 2
)
SELECT p.account_id,
       p.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(p.user_id, 8)) AS user_label,
       p.tier,
       cp.sort_order                                                    AS tier_rank,
       cp.included_credits,
       cp.monthly_price_usd                                             AS price_usd,
       cp.addon_rate_usd,
       cp.next_tier IS NOT NULL                                         AS has_next_tier,
       CASE WHEN cp.next_tier IS NOT NULL
            THEN cp.included_credits + cp.overshoot_threshold_credits END AS raise_at_credits,
       b.as_of,
       b.month,
       b.month_end,
       extract(day FROM b.month_end)::int                               AS days_in_month,
       p.credits_mtd,
       CASE WHEN cv.first_report <= b.prev_month THEN p.credits_prev_month END
                                                                        AS credits_prev_month,
       p.avg_daily_7d,
       p.credits_mtd + p.avg_daily_7d * (b.month_end - b.as_of)         AS projected_month_end,
       p.last_active,
       p.active_this_month,
       u.first_seen,
       -- Seats are billed per day from first use (pending users are not
       -- billed before). Users whose first use is in this month pay for the
       -- remaining days only.
       CASE WHEN u.first_seen >= b.month
            THEN (extract(day FROM b.month_end) - extract(day FROM u.first_seen) + 1)
                 / extract(day FROM b.month_end)
            ELSE 1 END                                                  AS seat_fraction,
       1 - s.billing_discount_pct / 100                                 AS net_factor,
       s.reset_tier,
       rp.sort_order                                                    AS reset_rank,
       s.safe_to_lower_from_day,
       s.safe_to_lower_margin,
       s.quiet_ratio,
       s.busy_ratio
FROM population p
CROSS JOIN bounds b
CROSS JOIN settings s
JOIN users u USING (user_id)
JOIN coverage cv USING (account_id)
JOIN plans cp ON cp.tier = p.tier
JOIN plans rp ON rp.tier = s.reset_tier;

-- ---------------------------------------------------------------------------
-- Current status: actual month-to-date usage, no projection. The action is
-- what to do now under the reactive model (start low, raise on need):
--   inactive      no usage this month (tier shown may be stale)
--   raise         a higher tier is already cheaper at the credits used
--   at max        on the top tier and past its included credits
--   overage (ok)  past the included credits, but staying is still cheaper
--   stay          within the included credits
-- Lowering is not a mid-month action (it applies next month); see reset_to
-- and v_expected_usage.lower.
-- ---------------------------------------------------------------------------
CREATE VIEW v_current_status AS
WITH c AS (
    SELECT b.*,
           cheapest_tier(b.credits_mtd) AS cheapest
    FROM v_month_base b
),
r AS (
    SELECT c.*,
           ct.sort_order AS cheapest_rank
    FROM c JOIN plans ct ON ct.tier = c.cheapest
)
SELECT r.account_id,
       r.user_id,
       r.user_label,
       r.tier,
       r.tier_rank,
       round(r.credits_mtd, 1)                                            AS credits_mtd,
       r.included_credits,
       round(100 * r.credits_mtd / NULLIF(r.included_credits, 0), 1)      AS plan_pct,
       round(greatest(r.credits_mtd - r.included_credits, 0), 1)          AS over_plan,
       r.raise_at_credits,
       round((r.price_usd * r.seat_fraction
              + greatest(r.credits_mtd - r.included_credits, 0) * r.addon_rate_usd)
             * r.net_factor, 2)                                           AS cost_now_net,
       CASE WHEN NOT r.active_this_month                            THEN 'inactive'
            WHEN r.cheapest_rank > r.tier_rank                      THEN 'raise'
            WHEN NOT r.has_next_tier AND r.credits_mtd > r.included_credits THEN 'at max'
            WHEN r.credits_mtd > r.included_credits                 THEN 'overage (ok)'
            ELSE 'stay' END                                               AS action,
       CASE WHEN r.active_this_month AND r.cheapest_rank > r.tier_rank
            THEN r.cheapest END                                           AS raise_to,
       CASE WHEN r.active_this_month AND r.cheapest_rank > r.tier_rank
            THEN round((plan_cost(r.tier, r.credits_mtd) - plan_cost(r.cheapest, r.credits_mtd))
                       * r.net_factor, 2) END                             AS saving_this_month_net,
       CASE WHEN r.active_this_month AND r.cheapest_rank > r.tier_rank
            THEN round(plan_cost(r.tier, r.credits_mtd) - plan_cost(r.cheapest, r.credits_mtd), 2)
            END                                                           AS saving_this_month_list,
       r.last_active,
       r.active_this_month,
       r.reset_tier                                                       AS reset_to,
       r.as_of
FROM r;

-- ---------------------------------------------------------------------------
-- Expected usage: where each user is heading this month (projection = credits
-- so far + 7-day daily average over the remaining days). Planning view: who
-- will need a raise later, quiet and busy months, and who is safe to lower
-- for next month already.
-- ---------------------------------------------------------------------------
CREATE VIEW v_expected_usage AS
WITH e AS (
    SELECT b.*,
           cheapest_tier(b.credits_mtd)         AS cheapest_now,
           cheapest_tier(b.projected_month_end) AS needed
    FROM v_month_base b
),
r AS (
    SELECT e.*,
           cn.sort_order AS cheapest_now_rank,
           nd.sort_order AS needed_rank
    FROM e
    JOIN plans cn ON cn.tier = e.cheapest_now
    JOIN plans nd ON nd.tier = e.needed
)
SELECT r.account_id,
       r.user_id,
       r.user_label,
       r.tier,
       r.tier_rank,
       round(r.credits_mtd, 1)          AS credits_mtd,
       round(r.avg_daily_7d, 1)         AS avg_daily_7d,
       round(r.projected_month_end, 1)  AS projected_month_end,
       round(r.credits_prev_month, 1)   AS credits_prev_month,
       CASE WHEN r.credits_prev_month IS NULL OR r.credits_prev_month = 0 THEN NULL
            ELSE round(100 * (r.projected_month_end / r.credits_prev_month - 1)) END AS trend_pct,
       CASE WHEN r.credits_prev_month IS NULL THEN NULL
            WHEN r.credits_prev_month = 0
                 THEN CASE WHEN r.projected_month_end > 0 THEN 'busy' ELSE 'normal' END
            WHEN r.projected_month_end / r.credits_prev_month < r.quiet_ratio THEN 'quiet'
            WHEN r.projected_month_end / r.credits_prev_month > r.busy_ratio  THEN 'busy'
            ELSE 'normal' END                                                       AS trend,
       r.needed                                                                     AS needed_by_month_end,
       CASE WHEN r.cheapest_now_rank > r.tier_rank AND r.needed_rank > r.cheapest_now_rank
                 THEN 'raise straight to ' || r.needed
            WHEN r.cheapest_now_rank > r.tier_rank THEN 'in raise list'
            WHEN r.needed_rank > r.tier_rank       THEN 'next batch'
            ELSE 'no' END                                                           AS raise_expected,
       CASE WHEN r.cheapest_now_rank > r.tier_rank AND r.needed_rank > r.cheapest_now_rank
            THEN r.needed END                                                       AS raise_straight_to,
       CASE WHEN r.tier_rank <= r.reset_rank THEN '-'
            WHEN extract(day FROM r.as_of) >= r.safe_to_lower_from_day
                 AND (NOT r.has_next_tier
                      OR r.projected_month_end < r.safe_to_lower_margin * r.raise_at_credits)
                 THEN 'safe now'
            ELSE 'at reset' END                                                     AS lower,
       r.reset_tier                                                                 AS reset_to,
       r.last_active,
       r.active_this_month,
       r.as_of
FROM r;

-- ---------------------------------------------------------------------------
-- This month at a glance, per account. Dollar figures are estimates at list
-- prices with the configured discount; the actual bill is in Cost Explorer.
-- ---------------------------------------------------------------------------
CREATE VIEW v_month_glance AS
SELECT c.account_id,
       max(c.as_of)                                                 AS as_of,
       round(sum(c.cost_now_net), 2)                                AS bill_estimate_net,
       count(*) FILTER (WHERE c.action = 'raise')                   AS users_to_raise,
       COALESCE(round(sum(c.saving_this_month_net), 2), 0)          AS saving_if_raised_net,
       count(*) FILTER (WHERE e.raise_expected = 'next batch')      AS expected_raises,
       count(*) FILTER (WHERE e.lower IN ('safe now', 'at reset'))  AS users_to_lower,
       count(*) FILTER (WHERE e.lower = 'safe now')                 AS users_safe_to_lower
FROM v_current_status c
JOIN v_expected_usage e USING (account_id, user_id)
GROUP BY c.account_id;

-- ---------------------------------------------------------------------------
-- Alert inputs. Grafana turns every string column into a label and compares
-- the single numeric column `value` with 0, so display numbers are text.
-- ---------------------------------------------------------------------------

-- Raise before month end: everyone a higher tier is already cheaper for, plus
-- (second section) everyone the projection says will need one.
CREATE VIEW v_alert_raise AS
SELECT '1 raise now'                                         AS section,
       c.user_label,
       c.account_id,
       c.tier,
       COALESCE(e.raise_straight_to, c.raise_to)             AS target_tier,
       e.needed_by_month_end                                 AS expected_tier,
       to_char(c.credits_mtd, 'FM999G999G990')               AS credits_mtd,
       to_char(e.projected_month_end, 'FM999G999G990')       AS projected,
       to_char(c.saving_this_month_net, 'FM999G999G990D00')  AS saving_net,
       c.saving_this_month_list                              AS value
FROM v_current_status c
JOIN v_expected_usage e USING (account_id, user_id)
WHERE c.action = 'raise'
UNION ALL
SELECT '2 likely by month end',
       e.user_label,
       e.account_id,
       e.tier,
       e.needed_by_month_end,
       e.needed_by_month_end,
       to_char(e.credits_mtd, 'FM999G999G990'),
       to_char(e.projected_month_end, 'FM999G999G990'),
       '',
       e.projected_month_end
FROM v_expected_usage e
WHERE e.raise_expected = 'next batch';

-- Safe to lower now (from mid-month): the projection stays well below the
-- tier's raise point, so requesting the downgrade early cannot clash with a
-- raise. The downgrade applies from next month.
CREATE VIEW v_alert_safe_to_lower AS
SELECT e.user_label,
       e.account_id,
       e.tier,
       e.reset_to,
       to_char(e.credits_mtd, 'FM999G999G990')         AS credits_mtd,
       to_char(e.projected_month_end, 'FM999G999G990') AS projected,
       1                                               AS value
FROM v_expected_usage e
WHERE e.lower = 'safe now';

-- Lower before the reset: everyone above the reset tier (including users
-- already requested early; the data cannot tell).
CREATE VIEW v_alert_reset AS
SELECT e.user_label,
       e.account_id,
       e.tier,
       e.reset_to,
       e.lower,
       to_char(e.credits_mtd, 'FM999G999G990')                     AS credits_mtd,
       COALESCE(to_char(e.credits_prev_month, 'FM999G999G990'), '-') AS credits_prev_month,
       1                                                           AS value
FROM v_expected_usage e
WHERE e.lower IN ('safe now', 'at reset');

-- Heavy Opus use over the last N report days: a prompt to check whether it
-- is intended (Opus is allowed). Credits per model are estimates split by
-- message share; usage under `auto` is not broken down by Kiro and is not
-- counted. The newest Opus version is taken from what anyone used in the
-- last 30 days, so there is no list to maintain.
CREATE VIEW v_alert_heavy_opus AS
WITH bounds AS (
    SELECT max(m.usage_date) AS as_of, s.opus_window_days, s.opus_min_credits, s.opus_min_share
    FROM usage_model_daily m CROSS JOIN settings s
    GROUP BY s.opus_window_days, s.opus_min_credits, s.opus_min_share
),
versions AS (
    SELECT m.model,
           string_to_array((regexp_match(m.model, '^claude_opus_(\d+(?:\.\d+)*)$'))[1], '.')::int[] AS version
    FROM (SELECT DISTINCT model FROM usage_model_daily
          WHERE model LIKE 'claude\_opus\_%'
            AND usage_date > (SELECT as_of FROM bounds) - 30) m
),
newest AS (
    SELECT model AS newest_opus, version AS newest_version
    FROM versions WHERE version IS NOT NULL
    ORDER BY version DESC LIMIT 1
),
win AS (
    SELECT v.account_id, v.user_id, v.user_label, v.model, v.messages, v.credits_attributed
    FROM v_usage_model_daily v CROSS JOIN bounds b
    WHERE v.usage_date > b.as_of - b.opus_window_days AND v.usage_date <= b.as_of
),
per_user AS (
    SELECT w.account_id,
           w.user_id,
           w.user_label,
           sum(w.messages)                                                       AS messages_all,
           COALESCE(sum(w.messages) FILTER (WHERE w.model LIKE 'claude\_opus\_%'), 0) AS messages_opus,
           COALESCE(sum(w.credits_attributed) FILTER (WHERE w.model LIKE 'claude\_opus\_%'), 0) AS credits_opus
    FROM win w
    GROUP BY 1, 2, 3
),
top_model AS (
    SELECT DISTINCT ON (w.account_id, w.user_id)
           w.account_id, w.user_id, w.model
    FROM (SELECT account_id, user_id, model, sum(messages) AS msgs
          FROM win WHERE model LIKE 'claude\_opus\_%'
          GROUP BY 1, 2, 3) w
    ORDER BY w.account_id, w.user_id, w.msgs DESC, w.model
)
SELECT p.user_label,
       p.account_id,
       t.model,
       COALESCE(n.newest_opus, t.model)                                       AS newest_opus,
       CASE WHEN v.version IS NOT NULL AND n.newest_version IS NOT NULL
                 AND v.version < n.newest_version THEN 'yes' ELSE 'no' END     AS superseded,
       to_char(100 * p.messages_opus::numeric / NULLIF(p.messages_all, 0), 'FM990') || '%' AS opus_share,
       to_char(p.messages_opus, 'FM999G999G990')                              AS messages,
       to_char(p.credits_opus, 'FM999G999G990')                               AS credits_est,
       to_char(b.as_of - b.opus_window_days + 1, 'Mon DD') || ' - ' || to_char(b.as_of, 'Mon DD')
                                                                               AS window_days,
       round(p.credits_opus, 1)                                               AS value
FROM per_user p
CROSS JOIN bounds b
JOIN top_model t USING (account_id, user_id)
LEFT JOIN versions v ON v.model = t.model
LEFT JOIN newest n ON true
WHERE p.credits_opus >= b.opus_min_credits
  AND p.messages_opus::numeric / NULLIF(p.messages_all, 0) >= b.opus_min_share;

-- ---------------------------------------------------------------------------
-- Pipeline alert input: how many days the newest imported report is behind
-- today (UTC). Kiro writes each day's report at 02:00 UTC the next day, so 1
-- is the normal value. Based on imported files, not on usage rows, so a day
-- nobody used Kiro does not look like missing data.
-- ---------------------------------------------------------------------------
CREATE VIEW v_data_freshness AS
SELECT account_id,
       max(report_date)                                   AS latest_report_date,
       max(imported_at)                                   AS last_import_at,
       (now() AT TIME ZONE 'UTC')::date - max(report_date) AS days_behind
FROM ingest_files
GROUP BY account_id;
