"""Integration tests against a real PostgreSQL (skipped without PG* env)."""
from datetime import date

import psycopg
import pytest

from kiro_ingest.core import IngestError, RunConfig, run
from kiro_ingest.migrate import Migration, MigrationError, apply_migrations, load_migrations
from kiro_ingest.parse import parse_key
from kiro_ingest.source import SourceObject
from kiro_ingest.store import scram_sha256_verifier

from conftest import ACCOUNT, report_csv, report_key

# Reporting views created by R__views.sql (all granted to the reader role).
VIEW_COUNT = 14


class MemorySource:
    def __init__(self, files: dict[str, str], etags: dict[str, str] | None = None):
        self.files = files
        self.etags = etags or {}
        self.reads = []

    def list(self, months):
        wanted = set(months)
        for key in sorted(self.files):
            rk = parse_key(key)
            if (rk.report_date.year, rk.report_date.month) in wanted:
                yield SourceObject(rk, self.etags.get(key, "v1"))

    def read_text(self, key):
        self.reads.append(key)
        return self.files[key]


def test_load_order_versioned_then_repeatable():
    names = [m.name for m in load_migrations()]
    assert names[0] == "V001__core.sql"
    assert names[-1] == "R__views.sql"


def test_scram_verifier_format_is_deterministic_with_fixed_salt():
    v = scram_sha256_verifier("secret", salt=b"0" * 16)
    assert v.startswith("SCRAM-SHA-256$4096:")
    assert v == scram_sha256_verifier("secret", salt=b"0" * 16)
    assert v != scram_sha256_verifier("secret")


@pytest.mark.usefixtures("pg_available")
class TestMigrations:
    def test_fresh_apply_then_idempotent(self, fresh_db):
        first = apply_migrations(fresh_db)
        assert first == ["V001__core.sql", "V002__tier_model.sql", "R__views.sql"]
        assert apply_migrations(fresh_db) == []
        thresholds = dict(fresh_db.execute(
            "SELECT tier, overshoot_threshold_credits FROM plans").fetchall())
        assert {k: int(v) for k, v in thresholds.items()} == {
            "PRO": 500, "PRO_PLUS": 1500, "PRO_MAX": 2500, "POWER": 5000}

    def test_edited_versioned_migration_is_rejected(self, fresh_db):
        apply_migrations(fresh_db)
        tampered = [Migration("V001__core.sql", "SELECT 1;", repeatable=False)]
        with pytest.raises(MigrationError):
            apply_migrations(fresh_db, tampered)

    def test_repeatable_reapplied_when_changed(self, fresh_db):
        apply_migrations(fresh_db)
        changed = load_migrations()
        views = next(m for m in changed if m.repeatable)
        changed[-1] = Migration(views.name, views.sql + "\n-- tweak\n", repeatable=True)
        assert apply_migrations(fresh_db, changed) == ["R__views.sql"]


def _files():
    models = ["auto_messages", "claude_opus_5_messages"]
    return {
        report_key("2026-09-30"): report_csv([
            {"date": "2026-09-30", "user": "u-1", "credits": 100, "email": "a@example.com",
             "models": {"auto_messages": 2}},
        ], models),
        report_key("2026-10-01"): report_csv([
            {"date": "2026-10-01", "user": "u-1", "credits": 900, "email": "a@example.com",
             "models": {"auto_messages": 5, "claude_opus_5_messages": 1}},
            {"date": "2026-10-01", "user": "u-2", "credits": 10, "tier": "POWER", "limit": 10000,
             "models": {"auto_messages": 1}},
        ], models),
        report_key("2026-10-02", "KIRO_IDE"): report_csv([
            {"date": "2026-10-02", "user": "u-1", "client": "KIRO_IDE", "credits": 700,
             "models": {"claude_opus_5_messages": 3}},
        ], models),
    }


@pytest.mark.usefixtures("pg_available")
class TestRun:
    def test_full_run_then_incremental(self, fresh_db):
        cfg = RunConfig(today=date(2026, 10, 3))
        src = MemorySource(_files())
        first = run(fresh_db, src, cfg)
        assert first["files_imported"] == 3
        assert first["usage_rows"] == 4
        assert first["reconcile_mismatches"] == 0
        assert first["latest_report_date"] == "2026-10-02"

        # Nothing changed: nothing is read again.
        src.reads.clear()
        second = run(fresh_db, src, cfg)
        assert second["files_imported"] == 0 and second["files_unchanged"] == 3
        assert src.reads == []

        # A corrected file (new ETag) is re-imported and replaces the old values.
        key = report_key("2026-10-02", "KIRO_IDE")
        src.files[key] = src.files[key].replace(",700,", ",650,")
        src.etags[key] = "v2"
        third = run(fresh_db, src, cfg)
        assert third["files_imported"] == 1
        total = fresh_db.execute(
            "SELECT sum(credits_used) FROM usage_daily WHERE account_id = %s", (ACCOUNT,)).fetchone()[0]
        assert int(total) == 100 + 900 + 10 + 650

    def test_views_compute_month_rollup_and_projection(self, fresh_db):
        run(fresh_db, MemorySource(_files()), RunConfig(today=date(2026, 10, 3)))
        u1 = fresh_db.execute(
            """SELECT credits_mtd, subscription_tier, included_credits, utilization_pct
               FROM v_usage_monthly WHERE user_id = 'u-1' AND month = '2026-10-01'""").fetchone()
        assert (int(u1[0]), u1[1], u1[2], float(u1[3])) == (1600, "PRO", 1000, 160.0)

        ex = fresh_db.execute(
            """SELECT avg_daily_7d, projected_month_end FROM v_expected_usage
               WHERE user_label = 'a@example.com'""").fetchone()
        # 7-day window ending Oct 2 holds Sep 30 + Oct 1 + Oct 2 = 1700 credits;
        # 29 days remain.
        assert float(ex[0]) == pytest.approx(1700 / 7, abs=0.05)
        assert float(ex[1]) == pytest.approx(1600 + 1700 / 7 * 29, abs=0.1)

        # 1,600 credits on PRO: $44 vs $40 on PRO_PLUS.
        cs = fresh_db.execute(
            "SELECT action, raise_to FROM v_current_status WHERE user_label = 'a@example.com'").fetchone()
        assert cs == ("raise", "PRO_PLUS")

        fresh = fresh_db.execute("SELECT latest_report_date FROM v_data_freshness").fetchone()
        assert fresh[0] == date(2026, 10, 2)

    def test_mismatch_commits_data_then_raises(self, fresh_db):
        files = _files()
        key = report_key("2026-10-01")
        files[key] = files[key].replace(",PRO,6,", ",PRO,9,")
        with pytest.raises(IngestError):
            run(fresh_db, MemorySource(files), RunConfig(today=date(2026, 10, 3)))
        assert fresh_db.execute("SELECT count(*) FROM ingest_files").fetchone()[0] == 3
        # The advisory lock was released.
        assert run(fresh_db, MemorySource(files), RunConfig(today=date(2026, 10, 3)))["status"] == "ok"

    # reader_role first: fixtures tear down in reverse order, so the database
    # (holding the grants) is dropped before the cluster-wide role.
    def test_reader_role_sees_views_only(self, reader_role, fresh_db):
        cfg = RunConfig(today=date(2026, 10, 3), reader_role=reader_role, reader_password="Reader-Pass-123")
        result = run(fresh_db, MemorySource(_files()), cfg)
        assert result["reader_views_granted"] == VIEW_COUNT

        info = fresh_db.info
        with psycopg.connect(host=info.host, port=info.port, dbname=info.dbname,
                             user=reader_role, password="Reader-Pass-123", connect_timeout=3) as ro:
            assert ro.execute("SELECT count(*) FROM v_usage_daily").fetchone()[0] == 4
            # Every view the dashboards and alert rules use must work for the
            # reader, including views that call plan_cost().
            views = [r[0] for r in fresh_db.execute(
                "SELECT table_name FROM information_schema.views "
                "WHERE table_schema = 'public' AND table_name LIKE 'v\\_%'").fetchall()]
            assert len(views) == VIEW_COUNT
            for view in views:
                ro.execute(f"SELECT * FROM {view}").fetchall()
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                ro.execute("SELECT * FROM settings")
            ro.rollback()
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                ro.execute("SELECT count(*) FROM usage_daily")
            ro.rollback()
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                ro.execute("SELECT count(*) FROM plans")
            ro.rollback()
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                ro.execute("DELETE FROM plans")

    def test_reader_password_is_enforced(self, reader_role, fresh_db):
        cfg = RunConfig(today=date(2026, 10, 3), reader_role=reader_role, reader_password="Reader-Pass-123")
        run(fresh_db, MemorySource(_files()), cfg)
        info = fresh_db.info
        conninfo = dict(host=info.host, port=info.port, dbname=info.dbname, user=reader_role, connect_timeout=3)
        try:
            psycopg.connect(password="definitely-wrong", **conninfo).close()
        except psycopg.OperationalError:
            pass
        else:
            pytest.skip("server trusts this client address (e.g. loopback); password not checked")
        psycopg.connect(password="Reader-Pass-123", **conninfo).close()


@pytest.mark.usefixtures("pg_available")
def test_full_run_as_non_superuser_like_rds(rds_like_db):
    """RDS's master user is not a superuser. Regression for: PostgreSQL 16+
    rejecting `ALTER ROLE ... NOSUPERUSER` from non-superusers."""
    conn, reader = rds_like_db
    cfg = RunConfig(today=date(2026, 10, 3), reader_role=reader, reader_password="Reader-Pass-123")
    first = run(conn, MemorySource(_files()), cfg)
    assert first["status"] == "ok" and first["reader_views_granted"] == VIEW_COUNT
    # Second run takes the ALTER ROLE path for the now-existing role.
    second = run(conn, MemorySource(_files()), cfg)
    assert second["status"] == "ok" and second["reader_views_granted"] == VIEW_COUNT
    attrs = conn.execute(
        "SELECT rolsuper, rolcreatedb, rolcreaterole, rolcanlogin FROM pg_roles WHERE rolname = %s",
        (reader,)).fetchone()
    assert attrs == (False, False, False, True)
