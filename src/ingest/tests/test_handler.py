import json
import os

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-central-1")

from kiro_ingest import handler  # noqa: E402


class FakeConn:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_handler_wires_environment(monkeypatch):
    env = {
        "DB_HOST": "db.example.internal", "DB_NAME": "kiro_usage",
        "DB_SECRET_ARN": "arn:master", "READER_SECRET_ARN": "arn:reader", "READER_ROLE": "grafana_ro",
        "SOURCE_BUCKET": "bucket", "SOURCE_PREFIXES": "kiro-logs/, kiro-logs/kiro-logs/",
        "SOURCE_ACCOUNT_ID": "111122223333", "SOURCE_REGIONS": "eu-central-1", "LOOKBACK_MONTHS": "2",
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    secrets = {"arn:reader": "reader-pass", "arn:master": json.dumps({"username": "u", "password": "p"})}
    monkeypatch.setattr(handler, "_secret", secrets.__getitem__)
    monkeypatch.setattr(handler, "_connect", lambda: FakeConn())
    seen = {}
    monkeypatch.setattr(handler, "run", lambda conn, source, cfg: seen.update(source=source, cfg=cfg) or {"status": "ok"})

    assert handler.lambda_handler({"backfill_months": 6}, None) == {"status": "ok"}
    assert seen["cfg"].lookback_months == 6
    assert seen["cfg"].reader_role == "grafana_ro"
    assert seen["cfg"].reader_password == "reader-pass"
    assert seen["source"].prefixes == ["kiro-logs/", "kiro-logs/kiro-logs/"]
    assert seen["source"].account_id == "111122223333"

    handler.lambda_handler({}, None)
    assert seen["cfg"].lookback_months == 2 and seen["cfg"].force is False
    assert seen["cfg"].settings is None

    monkeypatch.setenv("TIER_MODEL_JSON", json.dumps({"reset_tier": "PRO", "billing_discount_pct": 12.5}))
    handler.lambda_handler({}, None)
    assert seen["cfg"].settings == {"reset_tier": "PRO", "billing_discount_pct": 12.5}
