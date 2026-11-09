"""AWS Lambda entry point.

Environment:
  DB_HOST, DB_PORT, DB_NAME     RDS endpoint
  DB_SECRET_ARN                 RDS-managed master secret (JSON username/password)
  DB_SSLMODE                    default verify-full
  READER_SECRET_ARN             password of the Grafana read-only role
  READER_ROLE                   name of that role
  SOURCE_BUCKET                 Kiro log bucket
  SOURCE_PREFIXES               comma-separated, e.g. "kiro-logs/,kiro-logs/kiro-logs/"
  SOURCE_ACCOUNT_ID             account whose reports to read
  SOURCE_REGIONS                comma-separated Kiro profile regions
  LOOKBACK_MONTHS               default 2 (current and previous month)
  TIER_MODEL_JSON               optional JSON object with tier-model settings
                                (keys: see store.SETTINGS_COLUMNS)

Event (all optional): {"backfill_months": 12, "force": true}
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import boto3
import psycopg

from .core import RunConfig, run
from .source import S3Source

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("kiro_ingest")

CA_BUNDLE = Path(__file__).with_name("rds-ca-bundle.pem")

_secrets = boto3.client("secretsmanager")
_s3 = boto3.client("s3")


def _env_list(name: str) -> list[str]:
    return [item.strip() for item in os.environ[name].split(",") if item.strip()]


def _secret(arn: str) -> str:
    return _secrets.get_secret_value(SecretId=arn)["SecretString"]


def _connect() -> psycopg.Connection:
    # Fetched on every invocation: RDS rotates the master secret on its own.
    master = json.loads(_secret(os.environ["DB_SECRET_ARN"]))
    sslmode = os.environ.get("DB_SSLMODE", "verify-full")
    params = {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": os.environ["DB_NAME"],
        "user": master["username"],
        "password": master["password"],
        "sslmode": sslmode,
        "connect_timeout": 10,
        "application_name": "kiro-ingest",
    }
    if sslmode in ("verify-ca", "verify-full"):
        params["sslrootcert"] = str(CA_BUNDLE)
    return psycopg.connect(autocommit=True, **params)


def lambda_handler(event, context):
    event = event or {}
    reader_secret = os.environ.get("READER_SECRET_ARN")
    tier_model = os.environ.get("TIER_MODEL_JSON")
    cfg = RunConfig(
        lookback_months=int(event.get("backfill_months") or os.environ.get("LOOKBACK_MONTHS", "2")),
        force=bool(event.get("force", False)),
        reader_role=os.environ.get("READER_ROLE"),
        reader_password=_secret(reader_secret) if reader_secret else None,
        settings=json.loads(tier_model) if tier_model else None,
    )
    source = S3Source(
        _s3,
        bucket=os.environ["SOURCE_BUCKET"],
        prefixes=_env_list("SOURCE_PREFIXES"),
        account_id=os.environ["SOURCE_ACCOUNT_ID"],
        regions=_env_list("SOURCE_REGIONS"),
    )
    with _connect() as conn:
        result = run(conn, source, cfg)
    # Counts only; never log user names or e-mail addresses.
    log.info(json.dumps({"event": "ingest_complete", **result}, default=str))
    return result
