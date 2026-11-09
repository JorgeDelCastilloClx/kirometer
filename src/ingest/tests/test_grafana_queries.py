"""Every dashboard panel query and alert rule query runs as the reader role.

Catches panels or rules that reference a removed view, a base table the
reader cannot read, or a column that no longer exists.
"""
import json
import re
from pathlib import Path

import psycopg
import pytest

from kiro_ingest.core import RunConfig, run

from test_integration import MemorySource
from test_tier_model import TODAY, scenario_files

REPO = Path(__file__).resolve().parents[3]
DASHBOARDS = REPO / "infra" / "modules" / "kiro-usage-grafana" / "dashboards"
ALERTING = REPO / "infra" / "modules" / "kiro-usage-grafana" / "alerting.tf"

# Grafana macros and template variables, replaced with "all values".
MACROS = [
    (re.compile(r"\$__timeFilter\((\w+)\)"), r"\1 BETWEEN DATE '2026-10-01' AND DATE '2026-11-30'"),
    (re.compile(r"\$\{client_type:sqlstring\}"), "'cli','ide','plugin'"),
    (re.compile(r"\$\{subscription:sqlstring\}"), "'PRO','PRO_PLUS','PRO_MAX','POWER'"),
    (re.compile(r"\$\{model:sqlstring\}"), "SELECT DISTINCT model FROM v_usage_model_daily"),
    (re.compile(r"\$\{user:sqlstring\}"), "SELECT DISTINCT user_label FROM v_usage_daily"),
]


def grafana_sql(sql: str) -> str:
    for pattern, repl in MACROS:
        sql = pattern.sub(repl, sql)
    assert "${" not in sql and "$__" not in sql, f"unhandled macro in: {sql[:200]}"
    return sql


def dashboard_queries():
    for path in sorted(DASHBOARDS.glob("*.json")):
        d = json.loads(path.read_text())
        for var in d.get("templating", {}).get("list", []):
            if var.get("query"):
                yield f"{path.name}:var:{var['name']}", var["query"]
        for panel in d["panels"]:
            for t in panel.get("targets", []):
                if t.get("rawSql"):
                    yield f"{path.name}:{panel['id']}:{panel['title']}", t["rawSql"]


def alert_queries():
    text = ALERTING.read_text()
    for name, sql in re.findall(r"(\w+) = \{\s+uid[^{]*?sql\s+= <<-SQL\n(.*?)\n\s*SQL\n", text, re.S):
        yield f"alert:{name}", sql


QUERIES = list(dashboard_queries()) + list(alert_queries())


def test_queries_found():
    names = [n for n, _ in QUERIES]
    assert sum(n.startswith("alert:") for n in names) == 5
    assert any("Current status" in n for n in names)


@pytest.fixture(scope="module")
def reader_conn(pg_available, request):
    """A loaded scenario database and a reader connection, shared by the module."""
    import uuid
    from conftest import _admin_connect

    name = f"kiro_q_{uuid.uuid4().hex[:8]}"
    role = f"kiro_reader_q_{uuid.uuid4().hex[:8]}"
    with _admin_connect() as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    owner = _admin_connect(name)
    run(owner, MemorySource(scenario_files()),
        RunConfig(today=TODAY, reader_role=role, reader_password="Reader-Pass-123"))
    info = owner.info
    ro = psycopg.connect(host=info.host, port=info.port, dbname=name, user=role,
                         password="Reader-Pass-123", autocommit=True, connect_timeout=3)
    yield ro
    ro.close()
    owner.close()
    with _admin_connect() as admin:
        admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
        admin.execute(f'DROP ROLE "{role}"')


@pytest.mark.usefixtures("pg_available")
@pytest.mark.parametrize("name,sql", QUERIES, ids=[n for n, _ in QUERIES])
def test_query_runs_as_reader(reader_conn, name, sql):
    rows = reader_conn.execute(grafana_sql(sql)).fetchall()
    assert rows is not None


@pytest.mark.usefixtures("pg_available")
def test_alert_queries_have_one_numeric_value_column(reader_conn):
    """Grafana turns string columns into labels and needs exactly one number."""
    for name, sql in QUERIES:
        if not name.startswith("alert:"):
            continue
        cur = reader_conn.execute(sql)
        rows = cur.fetchall()
        numeric = [c.name for c, v in zip(cur.description, rows[0]) if isinstance(v, (int, float))
                   or type(v).__name__ == "Decimal"] if rows else ["value"]
        assert numeric == ["value"], f"{name}: numeric columns {numeric}"
