-- V002: settings for the reactive tier model.
--
-- One row, written by the ingest run from the deployment configuration
-- (TIER_MODEL_JSON), so views, panels and alert rules share the same values.
-- The defaults suit any deployment: no discount, everyone resets to PRO.
--
-- Versioned migration: applied exactly once, never edited afterwards.

CREATE TABLE settings (
    id                     boolean       PRIMARY KEY DEFAULT true CHECK (id),
    -- Tier every user returns to for the next month.
    reset_tier             text          NOT NULL DEFAULT 'PRO' REFERENCES plans (tier),
    -- Discount on the whole Kiro bill (e.g. an AWS Enterprise Discount
    -- Program). Applied to dollar figures only; break-even points use list
    -- prices because the same discount applies to every price.
    billing_discount_pct   numeric(5, 2) NOT NULL DEFAULT 0
                           CHECK (billing_discount_pct >= 0 AND billing_discount_pct < 100),
    -- "Safe to lower now": from this day of the month, when the projection
    -- stays below margin x the tier's raise point.
    safe_to_lower_from_day integer       NOT NULL DEFAULT 15
                           CHECK (safe_to_lower_from_day BETWEEN 1 AND 28),
    safe_to_lower_margin   numeric(4, 3) NOT NULL DEFAULT 0.8
                           CHECK (safe_to_lower_margin > 0 AND safe_to_lower_margin <= 1),
    -- Trend: projection / previous month below quiet or above busy.
    quiet_ratio            numeric(4, 3) NOT NULL DEFAULT 0.7
                           CHECK (quiet_ratio > 0 AND quiet_ratio < 1),
    busy_ratio             numeric(4, 3) NOT NULL DEFAULT 1.3
                           CHECK (busy_ratio > 1),
    -- Heavy Opus use: estimated Opus credits and share of messages over the
    -- last N reported days.
    opus_window_days       integer       NOT NULL DEFAULT 2
                           CHECK (opus_window_days BETWEEN 1 AND 14),
    opus_min_credits       numeric(12, 2) NOT NULL DEFAULT 750
                           CHECK (opus_min_credits > 0),
    opus_min_share         numeric(4, 3) NOT NULL DEFAULT 0.8
                           CHECK (opus_min_share > 0 AND opus_min_share <= 1),
    updated_at             timestamptz   NOT NULL DEFAULT now()
);

INSERT INTO settings DEFAULT VALUES;
