"""Database writes: batch upsert and the read-only reporting role."""
from __future__ import annotations

import base64
import hashlib
import hmac
import os

from psycopg import sql

from .parse import Batch, ReportKey


def upsert_batch(conn, batch: Batch, files: dict[str, tuple[ReportKey, str]]) -> dict:
    """Write a parsed batch and record its source files, in one transaction.

    files maps s3_key -> (ReportKey, etag) for every file in the batch.
    Per-model rows for each written key are replaced, so a model that
    disappears from a corrected report does not leave a stale count behind.
    """
    model_rows = [
        (k[0], k[1], k[2], k[3], model, count)
        for k, per_model in batch.models.items()
        for model, count in per_model.items()
    ]
    with conn.transaction(), conn.cursor() as cur:
        cur.executemany(
            """INSERT INTO users (user_id, email, first_seen, last_seen)
               VALUES (%(user_id)s, %(email)s, %(first_seen)s, %(last_seen)s)
               ON CONFLICT (user_id) DO UPDATE SET
                   email      = COALESCE(EXCLUDED.email, users.email),
                   first_seen = LEAST(users.first_seen, EXCLUDED.first_seen),
                   last_seen  = GREATEST(users.last_seen, EXCLUDED.last_seen)""",
            [{"user_id": uid, **vals} for uid, vals in batch.users.items()],
        )
        cur.executemany(
            """INSERT INTO usage_daily (
                   account_id, usage_date, user_id, client_type, subscription_tier,
                   credits_used, total_messages, chat_conversations,
                   overage_enabled, overage_cap, overage_credits_used,
                   usage_limit, new_user, profile_id, source_file
               ) VALUES (
                   %(account_id)s, %(usage_date)s, %(user_id)s, %(client_type)s,
                   %(subscription_tier)s, %(credits_used)s, %(total_messages)s,
                   %(chat_conversations)s, %(overage_enabled)s, %(overage_cap)s,
                   %(overage_credits_used)s, %(usage_limit)s, %(new_user)s,
                   %(profile_id)s, %(source_file)s
               )
               ON CONFLICT (account_id, usage_date, user_id, client_type) DO UPDATE SET
                   subscription_tier    = EXCLUDED.subscription_tier,
                   credits_used         = EXCLUDED.credits_used,
                   total_messages       = EXCLUDED.total_messages,
                   chat_conversations   = EXCLUDED.chat_conversations,
                   overage_enabled      = EXCLUDED.overage_enabled,
                   overage_cap          = EXCLUDED.overage_cap,
                   overage_credits_used = EXCLUDED.overage_credits_used,
                   usage_limit          = EXCLUDED.usage_limit,
                   new_user             = EXCLUDED.new_user,
                   profile_id           = EXCLUDED.profile_id,
                   source_file          = EXCLUDED.source_file,
                   imported_at          = now()""",
            list(batch.facts.values()),
        )
        cur.executemany(
            """DELETE FROM usage_model_daily
               WHERE account_id = %s AND usage_date = %s AND user_id = %s AND client_type = %s""",
            list(batch.facts.keys()),
        )
        cur.executemany(
            """INSERT INTO usage_model_daily
                   (account_id, usage_date, user_id, client_type, model, messages)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            model_rows,
        )
        cur.executemany(
            """INSERT INTO ingest_files (s3_key, etag, account_id, report_date, row_count)
               VALUES (%s, %s, %s, %s, %s)
               ON CONFLICT (s3_key) DO UPDATE SET
                   etag = EXCLUDED.etag, account_id = EXCLUDED.account_id,
                   report_date = EXCLUDED.report_date, row_count = EXCLUDED.row_count,
                   imported_at = now()""",
            [
                (key, etag, rk.account_id, rk.report_date, batch.file_rows.get(key, 0))
                for key, (rk, etag) in files.items()
            ],
        )
    return {"usage_rows": len(batch.facts), "model_rows": len(model_rows), "users": len(batch.users)}


def scram_sha256_verifier(password: str, iterations: int = 4096, salt: bytes | None = None) -> str:
    """Postgres SCRAM-SHA-256 verifier for a password.

    Setting the role password to the verifier instead of the clear text means
    the password itself never appears in an SQL statement, so it cannot leak
    into statement logs. Same format psql's \\password produces.
    """
    salt = os.urandom(16) if salt is None else salt
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda raw: base64.b64encode(raw).decode("ascii")  # noqa: E731
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def ensure_reader_role(conn, role: str, password: str) -> int:
    """Create or update the read-only role used by Grafana.

    It can log in and SELECT the reporting views, nothing else: no base
    tables, no write access. Returns the number of views granted.

    Works as a non-superuser with CREATEROLE, like the RDS master user:
    privilege attributes are only set when the role is created (PostgreSQL
    16+ rejects any SUPERUSER clause in ALTER ROLE from non-superusers) and
    are verified afterwards instead.
    """
    ident = sql.Identifier(role)
    verifier = sql.Literal(scram_sha256_verifier(password))
    with conn.transaction():
        exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone()
        if exists:
            conn.execute(sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(ident, verifier))
        else:
            conn.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                        "NOREPLICATION NOBYPASSRLS PASSWORD {}").format(ident, verifier)
            )
        attrs = conn.execute(
            """SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
               FROM pg_roles WHERE rolname = %s""",
            (role,),
        ).fetchone()[0]
        if attrs:
            raise RuntimeError(f"role {role} has elevated attributes; fix it manually before granting access")
        dbname = conn.execute("SELECT current_database()").fetchone()[0]
        conn.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(dbname), ident))
        conn.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(ident))
        conn.execute(sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {}").format(ident))
        views = [
            r[0] for r in conn.execute(
                """SELECT table_name FROM information_schema.views
                   WHERE table_schema = 'public' AND table_name LIKE 'v\\_%'
                   ORDER BY 1"""
            ).fetchall()
        ]
        for view in views:
            conn.execute(sql.SQL("GRANT SELECT ON {} TO {}").format(sql.Identifier(view), ident))
    return len(views)


# Columns of the single settings row and how to convert configured values.
# The database CHECK constraints validate the ranges.
SETTINGS_COLUMNS = {
    "reset_tier": str,
    "billing_discount_pct": float,
    "safe_to_lower_from_day": int,
    "safe_to_lower_margin": float,
    "quiet_ratio": float,
    "busy_ratio": float,
    "opus_window_days": int,
    "opus_min_credits": float,
    "opus_min_share": float,
}


def apply_settings(conn, settings: dict) -> None:
    """Write the tier-model settings row from the deployment configuration.

    Only the keys given are changed; the others keep their current values.
    Unknown keys are rejected so a typo in the configuration fails loudly
    instead of being ignored. Null values are skipped (an optional setting
    that was not configured).
    """
    unknown = sorted(set(settings) - set(SETTINGS_COLUMNS))
    if unknown:
        raise ValueError(f"unknown tier-model settings: {', '.join(unknown)}")
    values = {k: SETTINGS_COLUMNS[k](v) for k, v in settings.items() if v is not None}
    if not values:
        return
    assignments = sql.SQL(", ").join(
        sql.SQL("{} = {}").format(sql.Identifier(k), sql.Placeholder(k)) for k in values
    )
    with conn.transaction():
        conn.execute(
            sql.SQL("UPDATE settings SET {}, updated_at = now() WHERE id").format(assignments),
            values,
        )
