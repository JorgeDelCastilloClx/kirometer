# kirometer

Unofficial usage dashboards and subscription alerts for [Kiro](https://kiro.dev),
running entirely in your own AWS account. Not affiliated with or endorsed by
Amazon Web Services.

Kiro writes a daily usage report per user to S3: credits used, messages per
model, client type, subscription tier and overage. This project imports those
reports into PostgreSQL and shows them in Amazon Managed Grafana, so whoever
manages the subscriptions can see per person:

- how much of their plan they have used this month,
- whether a higher plan is already cheaper for what they used,
- where they are heading by the end of the month.

## The reactive tier model

Kiro bills an upgrade mid-month by refunding the lower plan and recalculating
the whole month under the higher plan's limits; a downgrade applies from the
next month. So a user effectively pays for the plan they end the month on,
and upgrading late costs nothing extra. The cheapest way to run subscriptions
is therefore:

- everyone starts the month on a low plan (PRO by default),
- users are raised when their actual usage makes a higher plan cheaper,
  in weekly batches and daily near the end of the month,
- everyone above the low plan is lowered again before the next month.

Quiet months (vacation, sick leave, light workload) then cost the low plan
instead of whatever plan a person usually needs. The dashboard and the alerts
are built around this cycle.

The data is an indicator, not a verdict. People are out of office, try other
tools or have one-off busy months. The alerts are meant to start a
conversation, not to switch plans automatically.

## What you get

![Kiro Credit Consumption dashboard with usernames covered](docs/dashboard.png)

**A dashboard** with credits per user over time, split by client (CLI, IDE,
plugin), model and subscription tier, a per-user summary with usage of the
plan limit in percent, and an action section:

- *This month at a glance*: estimated bill, users to raise now and the saving,
  raises expected later this month, users to lower before the reset.
- *Current status* (actual usage, no projection): per user the plan used,
  the action (raise, overage (ok), stay, at max, inactive), the cheapest plan
  to raise to (it may skip a plan), the saving this month, and when the user
  was last active.
- *Heavy Opus use*: users who sent most of their messages to Opus over the
  last days.
- *Expected usage* (projection): projected month-end credits, trend against
  last month, the plan needed by month end, and who is safe to lower already.

**Alert digests**, evaluated against the current calendar month (Kiro credits
reset monthly), one mail per rule listing everyone:

| Alert | Lists | Delivered (UTC, 07:00) |
|---|---|---|
| Raise before month end | Users a higher plan is already cheaper for, plus users the projection says will need one | Weekly on Mondays, daily from the 22nd |
| Safe to lower now | Users whose projection stays well below their plan's raise point, so the downgrade can be requested already | Mondays from the 15th |
| Lower before reset | Everyone above the reset plan for next month | The 22nd |
| Heavy Opus use | A user sending at least 80% of messages and 750 estimated credits to Opus over 2 days (one mail per user per case) | Any day |
| Usage data is stale | The newest imported report is more than two days old | As soon as it happens (pipeline alerts) |

A plan's raise point is the credit amount at which the next plan becomes
cheaper than paying add-on credits: `included + (next price - current price) /
add-on rate`. With list prices that is 1,500 credits on PRO, 3,500 on PRO_PLUS
and 7,500 on PRO_MAX. Between the plan limit and the raise point a user is in
overage but still cheaper on the current plan. Raise decisions use list
prices; a discount on the whole bill (e.g. an AWS Enterprise Discount Program)
does not change them and is only applied to dollar figures.

Dollar figures are estimates (list prices, the configured discount, seats
prorated from first use). The actual bill is in Cost Explorer.

## How it works

```
Kiro --daily--> S3 bucket --06:30 UTC--> Lambda --> RDS PostgreSQL <-- Managed Grafana --> SNS --> e-mail
```

- A scheduled Lambda imports only new or changed report files. Everything is
  idempotent, so re-running it never duplicates data.
- The Lambda can read only the `user_report/` folder. If Kiro prompt logging
  is enabled, the prompt logs in the same bucket are out of its reach, both by
  IAM policy and in code.
- Database and Grafana sit in private subnets, connections use verified TLS,
  and Grafana reads the data through a role that can only see reporting views.
- Everything is OpenTofu: three small stacks, configured by one file per
  deployment.

## Quick start

Requirements: an AWS account with IAM Identity Center, a VPC with private
subnets in two Availability Zones, the S3 bucket Kiro writes its reports to,
OpenTofu >= 1.13, AWS CLI v2, Python 3.12+ and `make`.

```bash
python3 -m venv .venv && .venv/bin/pip install -r src/ingest/requirements-dev.txt
make test build validate                     # local checks, no AWS access

cp config/example.tfvars config/team-a.tfvars  # fill in; git-ignored
make ENV=team-a bootstrap                    # state bucket + encryption keys
make ENV=team-a platform-plan platform-apply # AWS resources
make ENV=team-a ingest                       # first import
make ENV=team-a grafana-plan grafana-apply   # data source, dashboard, alerts
```

[`infra/README.md`](infra/README.md) has the full configuration reference,
deployment steps, day-to-day operations and security notes.

## Costs

The main running costs are a small RDS instance, Managed Grafana user
licences and, without a NAT gateway, two VPC interface endpoints. Lambda,
EventBridge, SNS and S3 usage are negligible at this data volume. Use the
[AWS Pricing Calculator](https://calculator.aws/) for your region and number
of Grafana users.

## Privacy

The dashboard and alerts show named people's consumption. Limit Grafana access
and alert recipients to the people responsible for subscriptions, and check
with your works council or data protection officer where that applies.

## Contributing

Issues and pull requests are welcome. Run `make test validate` before opening
a pull request. Never commit anything from `config/` except
`config/example.tfvars`.

## License

[MIT](LICENSE)
