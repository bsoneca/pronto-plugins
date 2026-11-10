# analytics

What an app's business looks like to its operator: accounts, paying users, games played, funnels,
and where visitors come from, in one Grafana beside the journeys' SLOs, without a line of
instrumentation in the app.

## Business numbers are not journeys

`journeys` watches whether the app works and wakes someone when it does not. `analytics` is read,
never heard:

- Its metrics are `business_*`. The schema refuses any other prefix, and `business_journey…`, so a
  business metric can never be a journey's (`journey_*`) or perf's (`perf_*`).
- They have no SLO, no burn rule and no alert policy. The app's vet holds the journeys' alerts to read
  none of them (`#AnalyticsUnalerted`), so an alert cannot be pointed at a business number.
- They reach Grafana by their own exporter and their own dashboard (`business-<app>`), beside
  the journeys' dashboard in the app's folder, never through the journeys' collector.

## What it adds

From one spec (`analytics_spec.cue`: each metric's name, help, labels and SQL, and the panels):

- **Views** (`analytics/views.sql`, a raw migration replayed every release): one view per metric in an
  `analytics` schema, read by a role, `analytics_reader`, that can `SELECT` those views and nothing
  else, read-only. A metric whose table another service makes at its start (`needs`) is empty
  until the table is there, not a failed migration.
- **The exporter** (`observability/analytics.sql_exporter.yml`):
  [sql_exporter](https://github.com/burningalchemist/sql_exporter) asks the views when it is scraped,
  at most once an `interval` (60 s), and answers as Prometheus metrics labelled `app`. In
  production it runs as a Cloud Run service whose Managed Service for Prometheus sidecar scrapes it
  (pronto-infra's state, not the app's release); on a host launch it is a process of the stack.
- **A dashboard** (`observability/analytics.business.dashboard.json`): rows of panels with an `app`
  variable, for the shared Grafana. A panel's `kind` is `stat`, `timeseries`, `table`, `bargauge` or
  `barchart` (bars along the label `x`, split by `series`, stacked with `stack: true`).
- **Umami** for visits and referrers, cookieless: the door routes `/a/s.js` (the tracker) and `/a/e`
  (its events) to Umami, so the page's policy (`script-src` and `connect-src 'self'`, Trusted Types) is
  unchanged, and a host-DOM hatch on every screen adds the tracker, unless the browser sends Global
  Privacy Control or Do Not Track. On a host launch Umami is a small stand-in that counts
  pageviews (`analytics/standin.ts`).

Every number is an aggregate: no email, no id, nothing a person typed reaches a label. A column
that holds what a reader typed (a campaign's name) is bucketed by its query to a top ten and "other".

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-analytics . [journeys=false]
# write the metrics and panels into analytics_spec.cue; list the screens that name their own hatches
# among _analyticsOwnHatches and give each `analytics`; add the views to code: state: rawMigrations:
#   {name: "740_analytics.sql", src: "analytics/views.sql"}
./saytw generate && ./saytw lint
```

`modular=true` is for an app split into modules ([modular-design](../modular-design/README.md)): the schema is written into
`modules/schema/analytics_plugin.cue` (the schema module every module imports), the spec is the module `modules/analytics`
(`modules/analytics/analytics.cue`, list it in `modules/modules.cue` with `join: "join/analytics.json"`, `expr: "analytics"`,
`owns: ["analytics"]`), the program's package embeds that export, and the generate step exports the module. An edit to the
program's package then does not evaluate the schema and the spec again. Without the option nothing changes.

`journeys=false` is for an app without journeys. The host is [`host.cue`](host.cue), the schema
[`schema.cue`](schema.cue), the generate step [`analytics.nu`](analytics.nu). The
[`pronto-analytics` skill](../skills/pronto-analytics/SKILL.md) writes the metrics.

## Umami's website id

Umami makes a site's id when the operator adds the site (Settings, Websites, Add website), and the
tracker needs it: write it in `analytics.umami.website` in `analytics_spec.cue` and release. Until
then the tracker reports under a placeholder id, which Umami ignores.

## Who may read Grafana

That is pronto-infra's state, not this plugin's (`infra/gcp/analytics.cue`): one CUE list of Google
accounts, `grafanaUsers`, each with a role (`Admin`, `Editor`, `Viewer`; a person is a `Viewer`
unless they change dashboards). Adding someone is one line there and `release@infra`.

## On a metal cluster

`bin/pronto-analytics metal` ([`metal.nu`](metal.nu)) runs the operator's Grafana and Umami on a
node the operator runs (pronto's envs.Metal), in namespace `analytics`, behind the node's tunnel:
Grafana reads the cluster's VictoriaMetrics, where each app's exporter (its release's
`analytics-exporter` service) and collectors are scraped; both keep their state in one
CloudNativePG cluster whose logins are generated in the namespace. Grafana's secret key, its Google
client and Umami's app secret are read from the project's Secret Manager and piped into Secrets, so
what Cloud Run's kept still decrypts and signs. Copy the data, then point the two names at the tunnel.

```sh
bin/pronto-analytics metal --ssh bruno@13.140.186.223 --project brawl-chess \
  --grafana-domain metrics.bonkchess.com --umami-domain umami.bonkchess.com \
  --users-file <grafanaUsers as JSON> --titles '{"bonk-chess": "Bonk Chess"}' \
  --dashboards [bonk-chess/business=<pronto>/apps/brawl-chess/observability/analytics.business.dashboard.json]
```

## Tests

- [`tests.cue`](tests.cue): the views, the exporter's files, the dashboard and the names, checked with `cue vet`.
- [`test.nu`](test.nu): the generate step against a fixture app, and each rule the schema holds (a name
  outside `business_`, a counter not `_total`, a panel reading an undeclared metric, an alert on a
  business metric) by a spec that breaks it.

```sh
./saytw --script tools.nu cue vet -c ./analytics
./saytw --script tools.nu cue vet -c -t package=check ./analytics/export
./saytw --script tools.nu nu analytics/test.nu
```
