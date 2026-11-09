"""One ingest run: lock, migrate, maintain the reader role, import new files."""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date, datetime, timezone

from .migrate import apply_migrations
from .parse import Batch
from .source import Source, months_back
from .store import apply_settings, ensure_reader_role, upsert_batch

log = logging.getLogger("kiro_ingest")

# Arbitrary constant identifying this job's advisory lock.
LOCK_ID = 7_331_001


class IngestError(RuntimeError):
    pass


@dataclass
class RunConfig:
    lookback_months: int = 2
    force: bool = False
    reader_role: str | None = None
    reader_password: str | None = field(default=None, repr=False)
    today: date | None = None
    # Tier-model settings from the deployment configuration; None leaves the
    # stored row unchanged.
    settings: dict | None = None


def run(conn, source: Source, cfg: RunConfig) -> dict:
    """Execute one ingest run on an autocommit psycopg connection.

    Every step that writes (each migration, the reader role, the data upsert)
    is its own transaction. Idempotent: only files whose ETag changed since
    the last import are read, and every write is an upsert. Raises IngestError
    when the reports cannot be trusted (rows whose model counts do not add
    up), after the data is committed, so the Lambda error alarm fires.
    """
    if not conn.autocommit:
        raise ValueError("run() needs an autocommit connection")
    today = cfg.today or datetime.now(timezone.utc).date()
    if not conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_ID,)).fetchone()[0]:
        return {"status": "skipped", "reason": "another run holds the lock"}
    try:
        applied = apply_migrations(conn)

        if cfg.settings is not None:
            apply_settings(conn, cfg.settings)

        views_granted = None
        if cfg.reader_role and cfg.reader_password:
            views_granted = ensure_reader_role(conn, cfg.reader_role, cfg.reader_password)

        months = months_back(today, cfg.lookback_months)
        listed = list(source.list(months))

        # The same report can exist under two prefixes; keep the first copy.
        unique: dict[str, object] = {}
        for obj in listed:
            unique.setdefault(obj.report.filename, obj)
        objects = list(unique.values())

        known = dict(conn.execute(
            "SELECT s3_key, etag FROM ingest_files WHERE s3_key = ANY(%s)",
            ([o.report.key for o in objects],),
        ).fetchall())
        changed = [o for o in objects if cfg.force or known.get(o.report.key) != o.etag]

        batch = Batch()
        files = {}
        for obj in sorted(changed, key=lambda o: (o.report.report_date, o.report.key)):
            batch.add_report(obj.report, source.read_text(obj.report.key))
            files[obj.report.key] = (obj.report, obj.etag)

        written = upsert_batch(conn, batch, files) if files else {"usage_rows": 0, "model_rows": 0, "users": 0}
        latest = conn.execute("SELECT max(report_date) FROM ingest_files").fetchone()[0]

        result = {
            "status": "ok",
            "migrations_applied": applied,
            "settings_applied": cfg.settings is not None,
            "reader_views_granted": views_granted,
            "months": [f"{y:04d}-{m:02d}" for y, m in months],
            "files_listed": len(listed),
            "files_unique": len(objects),
            "files_imported": len(files),
            "files_unchanged": len(objects) - len(files),
            "duplicate_keys": batch.duplicate_keys,
            "unknown_client_types": sorted(batch.unknown_clients),
            "reconcile_mismatches": batch.reconcile_mismatches(),
            "latest_report_date": latest.isoformat() if latest else None,
            **written,
        }
        if result["reconcile_mismatches"]:
            raise IngestError(
                f"{result['reconcile_mismatches']} rows where model counts do not add up "
                "to Total_Messages; the report format may have changed"
            )
        return result
    finally:
        conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_ID,))
