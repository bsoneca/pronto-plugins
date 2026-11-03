// Analytics: what an app's business looks like to its operator, apart from whether the app is
// healthy. From one spec the plugin derives the read-only views the numbers are computed by, the
// exporter that publishes them as Prometheus metrics (business_*), and a Grafana dashboard. The
// metrics are the operator's to read and never page anyone: journeys (pronto-journeys) holds the
// SLOs and the alerts, and the two share no metric, no collector and no dashboard.
//
// This file is written into the app's own package (analytics_plugin.cue), so every name here is
// prefixed: it sits beside the program's.
package analytics

import (
	"encoding/yaml"
	"list"
	"math"
	"strings"
)

// The exporter: sql_exporter runs a collector's queries when it is scraped, at most once a
// `interval`, and answers with the rows as metrics. The same release as a host tool (mise's
// github backend) for a host launch.
#AnalyticsExporter:        "burningalchemist/sql_exporter:0.24.13@sha256:befda03e0eae3f0c9b9dd0e5e5b968152f50e44dbdc04c1b68370c6fcbda2b7d"
#AnalyticsExporterVersion: "0.24.13"

// The exporter publishes no process_start_time_seconds (sql_exporter 0.24 has no flag for its own
// process metrics: its /metrics is only the collectors' answers), and the Managed Prometheus
// sidecar warns on every scrape that finds none, which it needs to adjust the start time of
// cumulative series. So the file carries one: a gauge, no labels, a constant. The series are gauges
// and database totals that no restart of the exporter resets, so the honest start of a total is
// the data's, not the instance's: any instant before the first row, fixed, so it does not move on a
// scrape, a new revision or a restart (a start that did would read as a counter reset). This one is
// 2025-01-01T00:00:00Z.
#AnalyticsStartTime: 1735689600

#AnalyticsLabel: =~"^[a-z][a-z0-9_]*$" & !="app" & !="value"

// A business metric: `business_` and a name. It shares nothing with journeys' (`journey_`), which
// feed SLOs and alerts.
#BusinessName: =~"^business_[a-z][a-z0-9_]*$" & !~"^business_journey"

#BusinessMetric: {
	help!: string & !=""
	type:  *"gauge" | "counter"
	// The labels a sample carries besides `app`. A label's values are few: a column that holds
	// whatever a reader typed is bucketed by the query (a top ten and "other").
	labels: [...#AnalyticsLabel]
	// A SELECT of the labels and a numeric `value`, over the app's tables: the body of a view in
	// the `analytics` schema (through a function that runs as the migration's owner), which the
	// exporter's role reads and the tables it cannot. Labels are cast to text and the value to
	// double precision.
	select!: string & !=""
	// Tables another service makes when it starts (the auth service's), which a migration may
	// run before: with any of them missing the metric is empty rather than the migration failed.
	needs: [...string & =~"^[a-z_]+$"]
}

// One panel of the dashboard. `expr` is PromQL over the declared metrics; the dashboard's
// variable is `$app`.
#AnalyticsPanel: {
	title!:      string & !=""
	kind:        *"stat" | "timeseries" | "table" | "bargauge"
	expr!:       string & !=""
	unit:        *"short" | string
	legend:      *"" | string
	description: *"" | string
	// Width out of 24, and height in grid rows.
	w: *6 | int & >=3 & <=24
	h: *5 | int & >=3
}

#AnalyticsRow: {
	title!: string & !=""
	panels!: [#AnalyticsPanel, ...#AnalyticsPanel]
}

#Analytics: A={
	// The app, as its metrics are labelled where several apps' share one Grafana and one Managed
	// Service for Prometheus: the program's package, which the host fills in, and a title.
	app!:  =~"^[a-z][a-z0-9_-]*$"
	title: *app | string & !=""

	metrics: [Name=string]: #BusinessMetric & {_named: Name & #BusinessName}
	rows: [...#AnalyticsRow]

	// How often the exporter may ask the database: a scrape inside this is answered from the last.
	interval: *"60s" | =~"^[1-9][0-9]*s$"

	// Umami (cookieless visits and referrers), reached through the app's door at `script` and
	// `collect`, so the page's policy (script-src and connect-src 'self') holds. `website` is
	// Umami's own id of the site, which Umami makes when the operator adds it. `upstream` is where
	// the door sends them in production; a host launch sends them to a stand-in.
	umami: {
		website:  *"00000000-0000-4000-8000-000000000000" | =~"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
		script:   *"/a/s.js" | =~"^/[a-z0-9/_.-]+$"
		collect:  *"/a/e" | =~"^/[a-z0-9/_.-]+$"
		upstream: *"https://umami.invalid" | =~"^https://[a-z0-9.-]+(:[0-9]+)?$"
		// Where the operator reads them: Umami's own address, which the dashboard links.
		console: *"https://umami.invalid" | =~"^https://"
	}

	_names: list.SortStrings([for n, _ in A.metrics {n}])

	// A counter is named `_total` and a gauge is not, as Prometheus names them.
	_misnamed: [for n, m in A.metrics if (m.type == "counter") != strings.HasSuffix(n, "_total") {n}]
	_misnamed: []

	// A panel's expression names the metrics it reads; each must be declared.
	_read: [for r in A.rows for p in r.panels for tok in strings.Split(strings.Join([for c in strings.Split(p.expr, "") {
		[if c =~ "^[a-z0-9_]$" {c}, " "][0]
	}], ""), " ") if strings.HasPrefix(tok, "business_") {tok}]
	_undeclared: [for t in _read if A.metrics[t] == _|_ {t}]
	_undeclared: []

	// The views and the role they are read by, replayed on every release like the app's other raw
	// migrations. The role is the exporter's: it reads `analytics` and nothing else, read-only. On
	// Cloud SQL a user made through the API starts in cloudsqlsuperuser, which is taken from it
	// here; on a developer's machine, with no such role, the login is made too.
	views: strings.Join(list.Concat([[
		"-- Written by pronto-analytics from analytics_spec.cue: change that, never this.",
		"SET lock_timeout = '30s';",
		"SET statement_timeout = '60s';",
		"CREATE SCHEMA IF NOT EXISTS analytics;",
		"REVOKE ALL ON SCHEMA analytics FROM PUBLIC;",
		"DO $r$ BEGIN",
		"  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_viewer') THEN CREATE ROLE analytics_viewer NOLOGIN; END IF;",
		"  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudsqlsuperuser') AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_reader') THEN",
		"    CREATE ROLE analytics_reader LOGIN PASSWORD 'dev-analytics-password';",
		"  END IF;",
		"END $r$;",
		"GRANT USAGE ON SCHEMA analytics TO analytics_viewer;",
	], [for n in _names {
		let v = strings.TrimPrefix(n, "business_")
		let m = A.metrics[n]
		let body = strings.TrimSpace(m.select)
		let cols = strings.Join([for l in m.labels {"q.\"\(l)\"::text, "}], "")
		let decl = strings.Join([for l in m.labels {"\"\(l)\" text, "}], "") + "value double precision"
		let guard = [if len(m.needs) > 0 {"  IF \(strings.Join([for t in m.needs {"to_regclass('public.\(t)') IS NULL"}], " OR ")) THEN RETURN; END IF;\n"}, ""][0]

		// A function, because the privilege to run one is the caller's, never the view owner's: a
		// view over the app's own functions (the plan prices, the funnel) would be refused the
		// role. This one runs as its owner and is granted to the role, whose reach is these and the
		// views over them, each an aggregate.
		"DROP VIEW IF EXISTS analytics.\(v);\nDROP FUNCTION IF EXISTS analytics.\(v)_rows();\nCREATE FUNCTION analytics.\(v)_rows() RETURNS TABLE (\(decl)) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $f$\n#variable_conflict use_column\nBEGIN\n\(guard)  RETURN QUERY SELECT \(cols)q.value::double precision FROM (\n\(body)\n  ) q;\nEND $f$;\nREVOKE ALL ON FUNCTION analytics.\(v)_rows() FROM PUBLIC;\nGRANT EXECUTE ON FUNCTION analytics.\(v)_rows() TO analytics_viewer;\nCREATE VIEW analytics.\(v) AS SELECT '\(A.app)'::text AS app, s.* FROM analytics.\(v)_rows() s;"
	}], [
		"GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO analytics_viewer;",
		"DO $r$ BEGIN",
		"  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_reader') THEN",
		"    BEGIN",
		"      ALTER ROLE analytics_reader NOCREATEROLE NOCREATEDB;",
		"    EXCEPTION WHEN insufficient_privilege THEN",
		"      RAISE WARNING 'analytics_reader keeps the attributes it was made with: its session is the views role (options) and read-only';",
		"    END;",
		"    GRANT analytics_viewer TO analytics_reader;",
		"    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudsqlsuperuser') AND pg_has_role('analytics_reader', 'cloudsqlsuperuser', 'member') THEN",
		"      REVOKE cloudsqlsuperuser FROM analytics_reader;",
		"    END IF;",
		"    ALTER ROLE analytics_reader SET default_transaction_read_only = on;",
		"    ALTER ROLE analytics_reader SET statement_timeout = '15s';",
		"  END IF;",
		"END $r$;",
		"",
	]]), "\n")

	// The exporter's one file (sql_exporter): the target, whose data source is the
	// SQLEXPORTER_TARGET_DSN of its environment, and the collector, a metric a view.
	_exporter: {
		global: {
			scrape_timeout:        "20s"
			scrape_timeout_offset: "500ms"
			min_interval:          A.interval
			max_connections:       2
			max_idle_connections:  1
		}
		target: {
			data_source_name: "postgres://analytics_reader@localhost/placeholder"
			collectors: ["business", "process"]
		}
		collectors: [{
			collector_name: "business"
			min_interval:   A.interval
			metrics: [for n in _names let m = A.metrics[n] {
				metric_name: n
				type:        m.type
				help:        m.help
				key_labels: list.Concat([["app"], m.labels])
				values: ["value"]
				query_ref: n
			}]
			queries: [for n in _names let m = A.metrics[n] {
				query_name: n
				query:      "SELECT \(strings.Join(list.Concat([["app"], [for l in m.labels {"\"\(l)\""}], ["value"]]), ", ")) FROM analytics.\(strings.TrimPrefix(n, "business_"))"
			}]
		}, {
			// The start time the sidecar looks for (#AnalyticsStartTime): one gauge, no labels.
			collector_name: "process"
			min_interval:   A.interval
			metrics: [{
				metric_name: "process_start_time_seconds"
				type:        "gauge"
				help:        "When the totals begin, in unix seconds: a fixed instant before the first row (the exporter publishes no process metrics of its own)."
				values: ["value"]
				query_ref: "process_start_time_seconds"
			}]
			queries: [{
				query_name: "process_start_time_seconds"
				query:      "SELECT \(#AnalyticsStartTime)::double precision AS value"
			}]
		}]
	}

	// The dashboard: one per app, on the shared Grafana, with the app a variable. Rows lay their
	// panels left to right and wrap at 24; a row is as tall as its tallest panel.
	_lines: [for r in A.rows {math.Ceil(list.Sum([for p in r.panels {p.w}]) / 24)}]
	_rowH: [for r in A.rows {list.Max([for p in r.panels {p.h}])}]
	_top: [for i, _ in A.rows {list.Sum([0, for j, _ in A.rows if j < i {1 + _lines[j]*_rowH[j]}])}]
	dashboard: {
		uid:   "business-\(A.app)"
		title: "\(A.title) business"
		tags: ["business", A.app]
		schemaVersion: 39
		time: {from: "now-30d", to: "now"}
		refresh: "5m"
		links: [{title: "Umami: visits and referrers", type: "link", url: A.umami.console, targetBlank: true, icon: "external link"}]
		templating: list: [{
			name:  "datasource"
			type:  "datasource"
			query: "prometheus"
		}, {
			name:  "app"
			type:  "query"
			label: "App"
			datasource: {type: "prometheus", uid: "${datasource}"}
			query:      "label_values(business_accounts, app)"
			definition: "label_values(business_accounts, app)"
			refresh:    2
			sort:       1
			current: {text: A.app, value: A.app}
		}]
		let ds = {type: "prometheus", uid: "${datasource}"}
		panels: list.Concat([for ri, r in A.rows {
			list.Concat([[{id: ri*100 + 1, type: "row", title: r.title, gridPos: {x: 0, y: _top[ri], w: 24, h: 1}, collapsed: false, panels: []}],
				[for pi, p in r.panels {
					let before = list.Sum([0, for j, q in r.panels if j < pi {q.w}])
					{
						id:          ri*100 + 2 + pi
						type:        p.kind
						title:       p.title
						datasource:  ds
						description: p.description
						gridPos: {x: mod(before, 24), y: _top[ri] + 1 + div(before, 24)*_rowH[ri], w: p.w, h: p.h}
						fieldConfig: defaults: {unit: p.unit, noValue: "no data"}
						targets: [{refId: "A", expr: p.expr, legendFormat: p.legend, if p.kind == "table" {format: "table", instant: true}}]
						if p.kind == "stat" {options: {reduceOptions: {calcs: ["lastNotNull"]}}}
					}
				}]])
		}])
	}

	out: {
		"analytics.views.sql": views
		"analytics.loader.json": {website: A.umami.website, script: A.umami.script}
		"analytics.sql_exporter.yml":        yaml.Marshal(_exporter)
		"analytics.business.dashboard.json": dashboard
	}
}

// Business metrics never alert. The journeys' alerts (their `alerts`, the burn-rate rules that
// become Cloud Monitoring policies) are handed here, and one that so much as names a business metric (or a selector by `__name__` that could
// match one) fails the app's vet: a number the operator reads must not wake anyone.
#AnalyticsUnalerted: {
	alerts: [...{alert: string, expr: string, ...}]
	offending: [for a in alerts if strings.Contains(a.expr, "business") {a.alert}]
	offending: []
}
