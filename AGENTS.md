# AGENTS.md

Instructions for AI coding agents working in this repository. Read this
before changing anything. Humans start with [README.md](README.md); the
deployment reference is [infra/README.md](infra/README.md).

## Hard rules

1. **Never read Kiro prompt or completion logs.** The source bucket may hold
   `GenerateAssistantResponse/` and `GenerateCompletions/` objects with full
   prompts and source code of named people. Only `.../KiroLogs/user_report/`
   is in scope. Do not list, download or open anything else, not even to
   "check the format".
2. **Never commit or print deployment data.** `config/*.tfvars` (except
   `example.tfvars`) and `config/*.tfstate*` contain account IDs, network IDs,
   bucket names and e-mail addresses. Do not paste their values into code,
   docs, tests, commit messages or chat output. Use placeholders
   (`123456789012`, `vpc-0123456789abcdef0`, `@example.com`) in anything
   public; tests use account `111122223333`.
3. **Never echo secrets.** Database passwords live in Secrets Manager and in
   the encrypted grafana state. Reference them by ARN or name only.
4. **Plan before apply, and ask before apply.** `make ENV=<env> *-plan`
   writes a plan file; only apply that reviewed plan, and only after the user
   has seen it. Any plan that destroys or replaces the RDS instance, the
   state bucket or a KMS key needs an explicit go from the user.
5. **No personal data in logs.** The Lambda logs counts only. Keep it that way.

## Repository map

| Path | What it is |
|---|---|
| `src/ingest/kiro_ingest/parse.py` | Pure parsing of S3 keys and CSVs; the only place that decides what a `user_report` key is |
| `src/ingest/kiro_ingest/source.py` | S3 (lists exact `user_report` prefixes per month) and local-directory sources |
| `src/ingest/kiro_ingest/core.py` | One run: advisory lock, migrations, reader role, ETag-based incremental import |
| `src/ingest/kiro_ingest/store.py` | Upserts, SCRAM verifier, read-only role and grants |
| `src/ingest/kiro_ingest/migrate.py` | Migration runner |
| `src/ingest/kiro_ingest/migrations/V###__*.sql` | Versioned schema; applied once, never edited |
| `src/ingest/kiro_ingest/migrations/R__views.sql` | All views and functions; dropped and recreated when the file changes. Tier logic for panels and alerts lives here (`v_current_status`, `v_expected_usage`, `v_month_glance`, `v_alert_*`) |
| `src/ingest/kiro_ingest/migrations/V002__tier_model.sql` | `settings`: one row of reactive tier model settings, written from `TIER_MODEL_JSON` on every run |
| `src/ingest/kiro_ingest/handler.py` | Lambda entry point (env vars documented in its docstring) |
| `src/ingest/tests/` | pytest; DB tests need `PG*` env vars and skip otherwise. `test_grafana_queries.py` runs every dashboard and alert query as the reader role |
| `scripts/build_lambda.py` | Deterministic arm64 / Python 3.13 zip into `build/` |
| `scripts/with-grafana-token.sh` | Runs a command with a 1-hour Grafana token in `GRAFANA_AUTH`, deleted afterwards |
| `infra/modules/*` | Reusable modules; no deployment-specific values |
| `infra/live/{bootstrap,platform,grafana}` | Generic stacks; `variables.tf` in each is a symlink to `infra/live/variables.tf` |
| `config/example.tfvars` | Every setting, with placeholders |
| `certs/rds-global-bundle.pem` | Public RDS CA bundle, used by the Lambda and Grafana for `verify-full` |

## Commands

```bash
make test                         # pytest (set PG* to run the DB tests)
make build                        # Lambda zip; same source => same sha256
make fmt validate                 # tofu fmt + offline validate of all stacks
make ENV=<env> platform-plan      # always rebuilds the zip first
make ENV=<env> platform-apply     # applies the saved plan only
make ENV=<env> ingest             # invoke the Lambda once
make ENV=<env> grafana-plan       # needs the workspace from platform
make ENV=<env> grafana-apply
```

Run tofu through the Makefile. It sets `TF_DATA_DIR=.terraform/<env>` and
passes `-var-file=config/<env>.tfvars` to init, plan, apply and output via
`TF_CLI_ARGS_*`. The backend and encryption blocks use variables (OpenTofu
early evaluation), so a bare `tofu init` without the var file fails.

## Data model essentials

- Kiro writes one CSV per client type and UTC day at about 02:00 UTC the next
  day. The newest data is always yesterday.
- Credits reset per **calendar month**. Every utilisation and alert metric is
  scoped to the month; never compare a multi-month sum with a monthly limit.
- Identity is `UserId`. `User_Email` can be empty; views expose `user_label`
  (email, or `unknown-<id prefix>`).
- Keys include `account_id`; one database can hold several Kiro accounts.
- Per-model message counts are stored long (`usage_model_daily`) because each
  CSV only contains columns for models used that day. Per-model credits are
  an estimate (split by message share); Kiro does not report them.
- Kiro only lists active users. Downgrade logic therefore also looks at the
  previous month to find people with no usage this month.
- A mid-month plan change leaves several tiers in a month; the newest row wins.
- `plans` holds list prices and the derived thresholds (raise point =
  included + threshold). Change prices with a new `V###` migration, never by
  editing `V001`.
- Reactive tier model: everyone starts the month on `settings.reset_tier`,
  is raised when actual usage makes a higher tier cheaper (an upgrade
  recalculates the whole month), and is lowered before the next month (a
  downgrade applies next month). Raise decisions use list prices; the
  `billing_discount_pct` only scales dollar figures.
- `settings` is a single row. Deployment values come from `tier_model` in
  `config/<env>.tfvars` via `TIER_MODEL_JSON`; never put a deployment's
  discount or thresholds into a migration.
- Dollar figures are estimates (list prices, discount, seats prorated from
  `users.first_seen` in the current month). There is no billing import.

## Invariants and known pitfalls

These each cost a debugging round; don't reintroduce them.

- **Grafana data source type** must be `grafana-postgresql-datasource`. The
  alias `postgres` works for panels but alert rules fail with
  `plugin.notRegistered`.
- **Alert rule queries** need a non-zero `relative_time_range` (we use 600s)
  even though the SQL ignores it, and expression nodes need
  `datasource = {type = "__expr__", uid = "__expr__"}` in their model.
- **Grafana normalises durations.** Write `repeat_interval` the way Grafana
  stores it (`27d`, `6d23h`), or every plan shows a false change. Check with a
  second plan after apply.
- **SNS contact points (Grafana 13):** the provider's `topic` is not enough;
  `settings = { topic_arn = ... }` is required.
- **Time intervals are not inherited** by child notification policies; repeat
  `active_timings` on children.
- **The RDS master user is not a superuser.** No `ALTER ROLE ... SUPERUSER`
  clauses, not even `NOSUPERUSER`. Tests cover this with a non-superuser
  fixture (`rds_like_db`).
- **Views run functions with the caller's rights.** `plan_cost()` and
  `cheapest_tier()` are `SECURITY DEFINER` with a pinned `search_path` so the
  read-only role does not need table access. Any new function used in a view
  needs the same, and the reader test queries every `v_*` view to catch it.
- **Removed views stay in the `DROP VIEW` list** of `R__views.sql`, or they
  survive on deployed databases and keep their reader grant.
- **Alert views return exactly one numeric column, `value`.** Grafana turns
  string columns into labels; display numbers are formatted as text in SQL.
  `test_grafana_queries.py` checks this.
- **SNS message templates:** the message goes into the contact point's
  `settings` map (`message`), like `topic_arn`; the subject goes into the
  provider's `subject` attribute (it is read back there, so putting it in
  `settings` shows a change on every plan). Grafana stores 7 days as `1w`.
- **The reader role is granted per view.** `R__views.sql` drops views, which
  drops grants; the Lambda re-grants all `v_*` views on every run. Reporting
  objects must be named `v_*`.
- **`encrypted_metadata_alias`** in the encryption blocks must stay a literal
  (`kiro-usage-platform`, `kiro-usage-grafana`); changing it breaks
  decryption of existing state.
- **Tags set by outside automation** (e.g. a backup policy) must be listed in
  `ignore_tag_prefixes`, or applies keep removing them.
- **Alert evaluation vs. delivery:** rules evaluate every 10 minutes; delivery
  is restricted by the `kiro-raise-windows`, `kiro-lower-windows`,
  `kiro-reset-window` and `kiro-daily-window` time intervals. Evaluating
  hourly risks sending results computed before the 06:30 import.
- **Plan files are encrypted** with the stack's KMS key; read them with
  `tofu show`, not by unzipping.

## How to verify a change

- Python or SQL: `make test` with a reachable PostgreSQL. For SQL changes,
  also query every view as the reader role (the integration test does this).
- Lambda: `make build`, then `make ENV=<env> platform-plan`; expect only the
  function (and the scheduler policy re-read) to change. Invoke with
  `make ENV=<env> ingest` and check `status`, `reconcile_mismatches == 0` and
  `migrations_applied`.
- Grafana: after apply, check data source health
  (`/api/datasources/uid/kiro-usage/health`), that every rule has
  `health=ok` (`/api/prometheus/grafana/api/v1/rules`), and that a second plan
  shows no changes.
- Before publishing: confirm `git ls-files` contains nothing from `config/`
  except `example.tfvars`, and run a secret scanner (e.g. gitleaks).
