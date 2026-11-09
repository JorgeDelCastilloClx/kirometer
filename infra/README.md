# Kiro usage analytics on AWS

Imports [Kiro](https://kiro.dev)'s daily `user_report` CSVs into PostgreSQL and
shows them in Amazon Managed Grafana, with per-user alerts for subscription
upgrades, month-end overshoot and downgrade candidates. One deployment per AWS
account, no cross-account dependencies.

```
Kiro --02:00 UTC--> S3 (your Kiro log bucket, unchanged)
                     |  GetObject on .../KiroLogs/user_report/* only (S3 gateway endpoint)
EventBridge Scheduler 06:30 UTC (daily)
                     v
Lambda kiro-usage-ingest (Python 3.13, private subnets)
                     |  TLS verify-full
                     v
RDS PostgreSQL 18 (private, encrypted) <-- read-only role -- Managed Grafana 13.2
                                                               | dashboard + alert digests
                                                               v  07:00 UTC: weekly / month end / reset day
                                                     SNS (VPC endpoint) --> e-mail
```

If Kiro prompt logging is enabled, prompt and completion logs
(`GenerateAssistantResponse`, `GenerateCompletions`) live in the same bucket.
The ingest role has no permission to list or read them, and the code rejects
any key outside `user_report/`.

## Layout

| Path | Content |
|---|---|
| `config/example.tfvars` | All settings of a deployment; copy to `config/<env>.tfvars` |
| `src/ingest/` | Ingest Lambda, SQL migrations (`kiro_ingest/migrations`), tests |
| `infra/modules/state-bootstrap` | State bucket and one KMS key per stack |
| `infra/modules/kiro-usage-platform` | VPC endpoints, security groups, RDS, Lambda, schedule, SNS, Grafana workspace |
| `infra/modules/kiro-usage-grafana` | Data source, dashboard, alert rules, delivery window |
| `infra/live/{bootstrap,platform,grafana}` | The three stacks; generic, configured only by the config file |
| `certs/rds-global-bundle.pem` | Public RDS CA bundle (Lambda and Grafana verify the DB certificate) |

The schema is managed by the Lambda, not by OpenTofu: `V###__*.sql` files are
applied once in order, `R__views.sql` is re-applied whenever it changes. Each
run also creates or updates the Grafana read-only role and its view grants.

## Prerequisites

- OpenTofu >= 1.13, AWS CLI v2, Python 3.12+, `make`
- Admin rights in the target AWS account
- IAM Identity Center enabled (Managed Grafana uses it for sign-in); the
  people in the config must exist there
- A VPC with private subnets in at least two AZs and an S3 gateway endpoint
  on their route tables. Without a NAT gateway the platform creates the
  Secrets Manager and SNS interface endpoints.

```bash
python3 -m venv .venv && .venv/bin/pip install -r src/ingest/requirements-dev.txt
make test build validate          # local only, no AWS access
```

`make test` runs the database tests against the PostgreSQL in the `PG*`
environment variables and skips them if none is set.

## Configure

```bash
cp config/example.tfvars config/team-a.tfvars   # git-ignored
```

| Setting | Meaning |
|---|---|
| `aws_profile`, `aws_account_id`, `aws_region` | Where to deploy. Every stack refuses to run against another account. |
| `vpc_id`, `subnet_ids` | Private subnets in 2+ AZs |
| `source_bucket`, `user_report_paths` | The Kiro log bucket and the path to `user_report/` in it, as shown in the S3 console |
| `grafana_admin_emails`, `grafana_editor_emails`, `grafana_viewer_emails` | IAM Identity Center users and their Grafana role. Editors can create silences; viewers are read-only. |
| `alert_emails` | Usage alerts. Each address gets an SNS confirmation mail first. |
| `ops_emails` | Pipeline alerts: ingest errors, schedule not running, data older than two days |
| `interface_endpoint_services` | Set to `[]` if the VPC already has Secrets Manager and SNS endpoints or a NAT gateway |
| `ignore_tag_prefixes` | Tag prefixes set by automation outside OpenTofu (e.g. a backup policy); OpenTofu leaves them alone. An organisation AWS Backup policy that enrols the database by tag typically needs `["Backup", "OrgBackup"]` or similar. Backup retention and window are only set at creation; later changes by such a policy are left alone. |
| `tier_model` | Reactive tier model: `reset_tier` (default PRO), `billing_discount_pct` (discount on the whole Kiro bill, e.g. an AWS EDP; default 0), safe-to-lower day and margin, trend ratios, heavy-Opus thresholds. All optional; see `config/example.tfvars`. Written to the `settings` table by every ingest run. |

The state bucket (`<name_prefix>-tofu-state-<account>-<region>`) and the KMS
key aliases are derived from these values.

## Deploy

```bash
make ENV=team-a bootstrap         # state bucket + KMS keys; review and confirm
make ENV=team-a platform-plan     # builds the Lambda zip, then plans; review
make ENV=team-a platform-apply    # ~10-15 min (RDS and the Grafana workspace)
make ENV=team-a ingest            # first import: schema, reader role, data
make ENV=team-a grafana-plan      # needs the Grafana workspace
make ENV=team-a grafana-apply
```

The bootstrap state stays local in `config/team-a.bootstrap.tfstate`
(git-ignored, no secrets); back it up, e.g. into the state bucket.

Afterwards:

1. Confirm the SNS e-mail subscriptions: one "Subscription Confirmation" mail
   per address and topic. The link must be clicked within three days, or SNS
   drops the subscription and alerts are published to nobody. Check with
   `aws sns list-subscriptions-by-topic` that none is `PendingConfirmation`;
   re-apply the platform to re-create lapsed ones.
2. Open the `grafana_url` from the platform-apply output and sign in with IAM Identity Center.
3. In Grafana, *Alerting -> Contact points -> kiro-finops -> Test*, and the same for `kiro-ops`. If no mail arrives, add `"sts"` to `interface_endpoint_services` and re-apply the platform.

## Delivery schedule

Rules are evaluated every 10 minutes; mails are only sent inside their
windows (07:00-07:15 UTC by default, after the 06:30 import):

| Digest | Window | Repeats |
|---|---|---|
| Raise before month end | Mondays, and daily from the 22nd | at every window while users are listed |
| Safe to lower now | Mondays from the 15th | at every window |
| Lower before reset | The 22nd | monthly |
| Heavy Opus use | Daily, one mail per user | when a case starts; a reminder after 7 days if it continues |

Usage digests send no "resolved" mails. Weekday, days and times are variables
of the grafana module. Silence a user after talking to them: *Alerting ->
Silences*, matcher `user_label`, with a comment and end date.

If the bucket uses SSE-KMS, set `source_kms_key_arn` on the platform module
and allow the ingest role in the key policy.

## Operations

| Task | How |
|---|---|
| Re-import older months | `aws lambda invoke --function-name kiro-usage-ingest --payload '{"backfill_months": 12}' --cli-binary-format raw-in-base64-out /dev/stdout` |
| Re-read every file | payload `{"force": true}` |
| Add or remove people | edit `config/<env>.tfvars`; `make ENV=<env> platform-plan platform-apply` |
| Change prices | new migration `V###__...sql` updating `plans`; `make ENV=<env> platform-plan platform-apply` |
| Change the reset plan, discount or alert thresholds | edit `tier_model` in `config/<env>.tfvars`; `make ENV=<env> platform-plan platform-apply`; the next ingest writes them |
| Change a view | edit `R__views.sql`; rebuild and apply the platform; the next run re-applies it |
| Change dashboards | edit `infra/modules/kiro-usage-grafana/dashboards/*.json`; `make ENV=<env> grafana-plan grafana-apply` |
| Rotate the Grafana DB password | increase `reader_password_version` on the platform module; apply platform; `make ingest`; apply grafana |
| Silence a user after talking to them | Grafana: *Alerting -> Silences*, matcher `user_label`, with a comment and end date |

## Security notes

- Database: private subnets only, `rds.force_ssl=1`, SCRAM passwords, encrypted storage. The master password is generated and rotated by RDS in Secrets Manager.
- Grafana connects as a role that can only `SELECT` from the `v_*` views.
- State is encrypted client-side with KMS (`enforced = true`) in addition to bucket encryption. The grafana state contains the read-only DB password (the Grafana provider has no write-only field for it); the platform state contains no passwords.
- Grafana tokens for OpenTofu are created per run with a one-hour lifetime and deleted afterwards (`scripts/with-grafana-token.sh`).
- The dashboard and alerts show named people's consumption. Restrict Grafana access and alert recipients to the people responsible for subscriptions.
