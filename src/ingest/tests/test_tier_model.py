"""Reactive tier model: settings, current status, expected usage, alert views.

Scenario as of 2026-11-20 (day 20 of a 30-day month), October fully covered.
Prices are the list prices from V001 ($20/$40/$100/$200, $0.04 per credit).
"""
from collections import defaultdict
from datetime import date
from decimal import Decimal

import psycopg
import pytest

from kiro_ingest.core import RunConfig, run
from kiro_ingest.store import apply_settings

from conftest import report_csv, report_key
from test_integration import MemorySource

MODELS = ["auto_messages", "claude_opus_4.7_messages", "claude_opus_5.5_messages"]
TODAY = date(2026, 11, 21)

# user, day, tier, credits, models
ROWS = [
    ("u-inactive", "2026-10-01", "PRO_MAX", 10, {"auto_messages": 1}),  # also: October coverage
    ("u-inactive", "2026-10-10", "PRO_MAX", 2990, {"auto_messages": 10}),
    ("u-stay", "2026-10-15", "PRO_PLUS", 3800, {"auto_messages": 10}),
    ("u-stay", "2026-11-03", "PRO_PLUS", 900, {"auto_messages": 10}),
    ("u-overage", "2026-11-05", "PRO", 1310, {"auto_messages": 10}),
    ("u-new", "2026-11-11", "PRO", 200, {"auto_messages": 10}),
    ("u-atreset", "2026-11-19", "PRO_MAX", 4000, {"auto_messages": 10}),
    ("u-opus", "2026-11-19", "PRO_PLUS", 450, {"claude_opus_4.7_messages": 500}),
    ("u-opus", "2026-11-20", "PRO_PLUS", 450, {"claude_opus_4.7_messages": 500}),
    ("u-raise", "2026-11-20", "PRO", 6100, {"auto_messages": 90, "claude_opus_5.5_messages": 10}),
    ("u-max", "2026-11-20", "POWER", 11200, {"auto_messages": 10}),
    ("u-mixed", "2026-11-20", "PRO_MAX", 1000, {"auto_messages": 21, "claude_opus_5.5_messages": 79}),
    ("u-low", "2026-11-20", "PRO", 749, {"claude_opus_5.5_messages": 100}),
    ("u-edge", "2026-11-20", "PRO", Decimal("937.5"), {"auto_messages": 20, "claude_opus_5.5_messages": 80}),
]

LIMITS = {"PRO": 1000, "PRO_PLUS": 2000, "PRO_MAX": 5000, "POWER": 10000}


def scenario_files(rows=ROWS):
    by_day = defaultdict(list)
    for user, day, tier, credits, models in rows:
        by_day[day].append({"date": day, "user": user, "email": f"{user}@example.com",
                            "tier": tier, "limit": LIMITS[tier], "credits": credits, "models": models})
    return {report_key(day): report_csv(r, MODELS) for day, r in by_day.items()}


def rows_by_user(conn, sql_text):
    cur = conn.execute(sql_text)
    names = [c.name for c in cur.description]
    return {r[0].split("@")[0]: dict(zip(names, r)) for r in cur.fetchall()}


@pytest.fixture
def db(fresh_db):
    result = run(fresh_db, MemorySource(scenario_files()), RunConfig(today=TODAY))
    assert result["status"] == "ok" and result["reconcile_mismatches"] == 0
    return fresh_db


@pytest.mark.usefixtures("pg_available")
class TestSettings:
    def test_defaults(self, db):
        s = db.execute("SELECT reset_tier, billing_discount_pct, net_factor, opus_min_credits FROM v_settings").fetchone()
        assert (s[0], float(s[1]), float(s[2]), float(s[3])) == ("PRO", 0.0, 1.0, 750.0)

    def test_run_applies_settings(self, fresh_db):
        cfg = RunConfig(today=TODAY, settings={"billing_discount_pct": 21, "opus_min_credits": 500,
                                               "safe_to_lower_margin": None})
        result = run(fresh_db, MemorySource(scenario_files()), cfg)
        assert result["settings_applied"] is True
        s = fresh_db.execute(
            "SELECT billing_discount_pct, opus_min_credits, safe_to_lower_margin FROM settings").fetchone()
        assert (float(s[0]), float(s[1]), float(s[2])) == (21.0, 500.0, 0.8)

    def test_unknown_key_rejected(self, db):
        with pytest.raises(ValueError, match="unknown tier-model settings: discount"):
            apply_settings(db, {"discount": 21})

    def test_invalid_values_rejected_by_database(self, db):
        with pytest.raises(psycopg.errors.ForeignKeyViolation):
            apply_settings(db, {"reset_tier": "GOLD"})
        with pytest.raises(psycopg.errors.CheckViolation):
            apply_settings(db, {"billing_discount_pct": 120})


@pytest.mark.usefixtures("pg_available")
class TestCurrentStatus:
    def test_actions(self, db):
        rows = rows_by_user(db, "SELECT user_label, action, raise_to FROM v_current_status")
        actions = {u: (r["action"], r["raise_to"]) for u, r in rows.items()}
        assert actions == {
            "u-raise": ("raise", "PRO_MAX"),      # skips PRO_PLUS: PRO_MAX is cheapest at 6,100
            "u-overage": ("overage (ok)", None),  # 1,310 on PRO: $32.40 < $40 on PRO_PLUS
            "u-max": ("at max", None),
            "u-stay": ("stay", None),
            "u-atreset": ("stay", None),
            "u-inactive": ("inactive", None),
            "u-new": ("stay", None),
            "u-opus": ("stay", None),
            "u-mixed": ("stay", None),
            "u-low": ("stay", None),
            "u-edge": ("stay", None),
        }

    def test_numbers(self, db):
        rows = rows_by_user(db, """SELECT user_label, plan_pct, over_plan, raise_at_credits, cost_now_net,
                                          saving_this_month_net, saving_this_month_list, last_active, reset_to
                                   FROM v_current_status""")
        raise_ = rows["u-raise"]
        assert float(raise_["saving_this_month_net"]) == 80.0          # $224 on PRO vs $144 on PRO_MAX
        # First use Nov 20: seat for 11 of 30 days ($7.33) + 5,100 overage credits ($204).
        assert float(raise_["cost_now_net"]) == pytest.approx(211.33, abs=0.005)
        assert raise_["raise_at_credits"] == 1500
        over = rows["u-overage"]  # first use Nov 5: seat for 26 of 30 days + 310 credits
        assert (float(over["plan_pct"]), float(over["over_plan"])) == (131.0, 310.0)
        assert float(over["cost_now_net"]) == pytest.approx(29.73, abs=0.005)
        assert over["saving_this_month_net"] is None
        assert float(rows["u-stay"]["cost_now_net"]) == 40.0  # seen since October: full seat
        assert rows["u-max"]["raise_at_credits"] is None
        assert rows["u-inactive"]["last_active"] == date(2026, 10, 10)
        # First use on Nov 11: seat billed for 20 of 30 days.
        assert float(rows["u-new"]["cost_now_net"]) == pytest.approx(13.33, abs=0.005)
        assert {r["reset_to"] for r in rows.values()} == {"PRO"}

    def test_discount_applies_to_dollars_only(self, db):
        apply_settings(db, {"billing_discount_pct": 21})
        rows = rows_by_user(db, """SELECT user_label, action, raise_to, cost_now_net,
                                          saving_this_month_net, saving_this_month_list FROM v_current_status""")
        assert (rows["u-raise"]["action"], rows["u-raise"]["raise_to"]) == ("raise", "PRO_MAX")
        assert float(rows["u-raise"]["saving_this_month_net"]) == 63.2
        assert float(rows["u-raise"]["saving_this_month_list"]) == 80.0
        assert float(rows["u-overage"]["cost_now_net"]) == pytest.approx(29.73 * 0.79, abs=0.005)
        assert float(rows["u-stay"]["cost_now_net"]) == pytest.approx(31.60, abs=0.005)


@pytest.mark.usefixtures("pg_available")
class TestExpectedUsage:
    def test_projection_and_raise_expected(self, db):
        rows = rows_by_user(db, """SELECT user_label, projected_month_end, needed_by_month_end,
                                          raise_expected, raise_straight_to FROM v_expected_usage""")
        r = rows["u-raise"]  # 6,100 + 6,100/7 x 10 remaining days
        assert float(r["projected_month_end"]) == pytest.approx(14814.3, abs=0.05)
        assert (r["needed_by_month_end"], r["raise_expected"], r["raise_straight_to"]) == (
            "POWER", "raise straight to POWER", "POWER")
        assert rows["u-atreset"]["raise_expected"] == "next batch"
        assert rows["u-overage"]["raise_expected"] == "no"
        assert {u for u, x in rows.items() if x["raise_expected"] == "next batch"} == {
            "u-atreset", "u-edge", "u-low"}

    def test_trend(self, db):
        rows = rows_by_user(db, "SELECT user_label, trend, trend_pct, credits_prev_month FROM v_expected_usage")
        assert (rows["u-stay"]["trend"], int(rows["u-stay"]["trend_pct"])) == ("quiet", -76)
        assert rows["u-inactive"]["trend"] == "quiet"
        assert rows["u-raise"]["trend"] == "busy"  # previous month complete, no usage then
        assert float(rows["u-stay"]["credits_prev_month"]) == 3800.0

    def test_lower(self, db):
        rows = rows_by_user(db, "SELECT user_label, lower FROM v_expected_usage")
        lower = {u: r["lower"] for u, r in rows.items()}
        assert {u for u, v in lower.items() if v == "safe now"} == {
            "u-max", "u-stay", "u-inactive", "u-opus", "u-mixed"}
        assert lower["u-atreset"] == "at reset"   # projection 9,714 >= 0.8 x 7,500
        assert lower["u-overage"] == "-"          # already on the reset tier

    def test_lower_waits_for_mid_month(self, fresh_db):
        rows = [("u-early", "2026-10-01", "PRO", 10, {"auto_messages": 1}),
                ("u-early", "2026-11-10", "PRO_PLUS", 100, {"auto_messages": 1})]
        run(fresh_db, MemorySource(scenario_files(rows)), RunConfig(today=date(2026, 11, 11)))
        assert fresh_db.execute("SELECT lower FROM v_expected_usage").fetchone()[0] == "at reset"
        apply_settings(fresh_db, {"safe_to_lower_from_day": 10})
        assert fresh_db.execute("SELECT lower FROM v_expected_usage").fetchone()[0] == "safe now"


@pytest.mark.usefixtures("pg_available")
class TestAlertViews:
    def test_glance(self, db):
        g = db.execute("""SELECT users_to_raise, saving_if_raised_net, expected_raises,
                                 users_to_lower, users_safe_to_lower FROM v_month_glance""").fetchone()
        assert (g[0], float(g[1]), g[2], g[3], g[4]) == (1, 80.0, 3, 6, 5)

    def test_raise(self, db):
        rows = db.execute("""SELECT section, split_part(user_label, '@', 1), target_tier, saving_net, value
                             FROM v_alert_raise ORDER BY section, user_label""").fetchall()
        assert rows[0] == ("1 raise now", "u-raise", "POWER", "80.00", Decimal("80.00"))
        assert {r[1] for r in rows[1:]} == {"u-atreset", "u-edge", "u-low"}
        assert all(r[0] == "2 likely by month end" and r[4] > 0 for r in rows[1:])

    def test_lower_lists(self, db):
        safe = {r[0].split("@")[0] for r in db.execute("SELECT user_label FROM v_alert_safe_to_lower")}
        reset = {r[0].split("@")[0] for r in db.execute("SELECT user_label FROM v_alert_reset")}
        assert safe == {"u-max", "u-stay", "u-inactive", "u-opus", "u-mixed"}
        assert reset == safe | {"u-atreset"}

    def test_heavy_opus(self, db):
        rows = rows_by_user(db, """SELECT user_label, model, newest_opus, superseded, opus_share,
                                          messages, credits_est, window_days, value
                                   FROM v_alert_heavy_opus""")
        # u-mixed: 790 credits but 79% share; u-low: 100% share but 749 credits.
        assert set(rows) == {"u-opus", "u-edge"}
        opus = rows["u-opus"]
        assert (opus["model"], opus["newest_opus"], opus["superseded"]) == (
            "claude_opus_4.7", "claude_opus_5.5", "yes")
        assert (opus["opus_share"], opus["messages"], opus["credits_est"]) == ("100%", "1,000", "900")
        assert opus["window_days"] == "Nov 19 - Nov 20"
        edge = rows["u-edge"]  # exactly 750 credits at exactly 80%
        assert (edge["superseded"], float(edge["value"])) == ("no", 750.0)

    def test_heavy_opus_threshold_is_configurable(self, db):
        apply_settings(db, {"opus_min_credits": 1000})
        assert db.execute("SELECT count(*) FROM v_alert_heavy_opus").fetchone()[0] == 0
        apply_settings(db, {"opus_min_credits": 500, "opus_min_share": 0.75})
        users = {r[0].split("@")[0] for r in db.execute("SELECT user_label FROM v_alert_heavy_opus")}
        # u-raise stays out: 610 Opus credits, but only 10% of its messages.
        assert users == {"u-opus", "u-edge", "u-mixed", "u-low"}
