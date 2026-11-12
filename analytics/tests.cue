package analytics

import (
	"list"
	"strings"

	"github.com/bsoneca/pronto-plugins/journeys"
)

// A small app: a gauge with a label, a counter, and a metric that waits for another service's
// table.
_a: #Analytics & {
	app: "shop"
	metrics: {
		business_orders: {help: "Orders by state.", labels: ["state"], select: "SELECT state, count(*) AS value FROM orders GROUP BY state"}
		business_signups_total: {type: "counter", help: "Accounts made.", labels: [], select: "SELECT count(*) AS value FROM users"}
		business_logins: {help: "Logins by provider.", labels: ["provider"], needs: ["identity_link"], select: "SELECT provider, count(*) AS value FROM identity_link GROUP BY provider"}
	}
	rows: [{title: "Orders", panels: [{title: "Orders", expr: "business_orders{app=\"$app\"}"}, {title: "Signups a day", kind: "timeseries", w: 18, expr: "increase(business_signups_total{app=\"$app\"}[1d])"}]}, {title: "Orders a day", panels: [
		{title: "By state", kind: "barchart", x: "state", series: "provider", stack: true, expr: "business_orders{app=\"$app\"}"},
		{title: "Plain", kind: "barchart", x: "day", series: "mode", expr: "business_orders{app=\"$app\"}"},
	]}]
}

// The views: one a metric, the app first, in the analytics schema, read by a role that sees
// nothing else; a late table's metric is a function that returns nothing until it is there.
viewFunction:           strings.Contains(_a.views, "DROP FUNCTION IF EXISTS analytics.orders_rows();\nCREATE FUNCTION analytics.orders_rows() RETURNS TABLE (\"state\" text, value double precision) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $f$\n#variable_conflict use_column\nBEGIN\n  RETURN QUERY SELECT q.\"state\"::text, q.value::double precision FROM (\nSELECT state, count(*) AS value FROM orders GROUP BY state\n  ) q;\nEND $f$;") & true
viewOverIt:             strings.Contains(_a.views, "CREATE VIEW analytics.orders AS SELECT 'shop'::text AS app, s.* FROM analytics.orders_rows() s;") & true
viewFunctionGranted:    strings.Contains(_a.views, "GRANT EXECUTE ON FUNCTION analytics.orders_rows() TO analytics_viewer;") & true
viewFunctionNotPublic:  strings.Contains(_a.views, "REVOKE ALL ON FUNCTION analytics.orders_rows() FROM PUBLIC;") & true
viewLate:               strings.Contains(_a.views, "  IF to_regclass('public.identity_link') IS NULL THEN RETURN; END IF;") & true
viewsGranted:           strings.Contains(_a.views, "GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO analytics_viewer;") & true
viewsReadOnly:          strings.Contains(_a.views, "ALTER ROLE analytics_reader SET default_transaction_read_only = on;") & true
viewsNoPublic:          strings.Contains(_a.views, "REVOKE ALL ON SCHEMA analytics FROM PUBLIC;") & true
viewsNarrowed:          strings.Contains(_a.views, "      ALTER ROLE analytics_reader NOCREATEROLE NOCREATEDB;") & true
viewsTakeBackSuperuser: strings.Contains(_a.views, "REVOKE cloudsqlsuperuser FROM analytics_reader;") & true
viewsLoginOnlyOffCloud: strings.Contains(_a.views, "IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudsqlsuperuser') AND NOT EXISTS") & true

// The exporter asks the views and labels each sample with the app, in one file.
_c:                   _a._exporter.collectors[0]
collectorMinInterval: _c.min_interval & "60s"
queryLabels: [for q in _c.queries if q.query_name == "business_orders" {q.query}] & ["SELECT app, \"state\", value FROM analytics.orders"]
metricKeys: [for m in _c.metrics if m.metric_name == "business_orders" {m.key_labels}] & [["app", "state"]]
counterType: [for m in _c.metrics if m.metric_name == "business_signups_total" {m.type}] & ["counter"]
targetDsnFromEnv: _a._exporter.target.data_source_name & "postgres://analytics_reader@localhost/placeholder"
targetUsesIt: _a._exporter.target.collectors & ["business", "process"]

// The Managed Prometheus sidecar adjusts start times by a gauge named process_start_time_seconds
// and warns on every scrape that has none: the file carries one, no labels, a constant (the same
// whatever the app or the scrape).
_p: _a._exporter.collectors[1]
startTimeMetric: [for m in _p.metrics {{name: m.metric_name, type: m.type, labels: m.key_labels | *[]}}] & [{name: "process_start_time_seconds", type: "gauge", labels: []}]
startTimeQuery: [for q in _p.queries if q.query_name == "process_start_time_seconds" {q.query}] & ["SELECT 1735689600::double precision AS value"]
startTimeRef: [for m in _p.metrics {m.query_ref}] & [for q in _p.queries {q.query_name}]

// The dashboard: an app variable, a row a group of panels, laid left to right.
dashApp: [for t in _a.dashboard.templating.list if t.name == "app" {t.query}] & ["label_values(business_accounts, app)"]
rowThenPanels: [for p in _a.dashboard.panels {p.type}] & ["row", "stat", "timeseries", "row", "barchart", "barchart"]
secondPanelRight: _a.dashboard.panels[2].gridPos & {x: 6, y: 1, w: 18, h: 5}
// A stat reads the value now, not the last point of a range (PRONTO-189); a timeseries the range.
statInstant: _a.dashboard.panels[1].targets[0] & {instant: true, range: false}
timeseriesRange: [for k, _ in _a.dashboard.panels[2].targets[0] if k == "instant" {k}] & []

// A barchart reads an instant table, sorted by its axis then pivoted by its split; it stacks only
// when asked.
_bar: _a.dashboard.panels[4]
_plain: _a.dashboard.panels[5]
barchartTarget: _bar.targets & [{refId: "A", expr: "max without (instance, pod, pod_template_hash) (business_orders{app=\"$app\"})", legendFormat: "", format: "table", instant: true}]
barchartSorted: _bar.transformations[0] & {id: "sortBy", options: {sort: [{field: "state"}]}}
barchartMatrix: _bar.transformations[1] & {id: "groupingToMatrix", options: {rowField: "state", columnField: "provider", valueField: "Value", emptyValue: "zero"}}
barchartTwoSteps: len(_bar.transformations) & 2
barchartStacked: _bar.options.stacking & "normal"
barchartUnstacked: _plain.options.stacking & "none"
barchartOptions: _plain.options & {xTickLabelRotation: -45, legend: {displayMode: "list", placement: "bottom", showLegend: true}, showValue: "auto"}
barchartOwnLabels: _plain.transformations[1].options & {rowField: "day", columnField: "mode"}
statHasNoTable: _a.dashboard.panels[1].targets & [{refId: "A", expr: "max without (instance, pod, pod_template_hash) (business_orders{app=\"$app\"})", legendFormat: ""}]
dashUid: _a.dashboard.uid & "business-shop"

// Each pod of the exporter answers the same numbers (PRONTO-370): a panel asks every business
// selector once, the max over the pods; a range over its function; the rest of the query as written.
_once: {
	plain:  (#AnalyticsPanel & {title: "t", expr: "sum by (state) (business_orders{app=\"$app\",state=~\"a|b\"}) / clamp_min(sum(business_logins), 1)"}).once
	ranged: (#AnalyticsPanel & {title: "t", expr: "sum by (mode) (increase(business_signups_total{app=\"$app\"}[1d]))"}).once
}
oncePlain:  _once.plain & "sum by (state) (max without (instance, pod, pod_template_hash) (business_orders{app=\"$app\",state=~\"a|b\"})) / clamp_min(sum(max without (instance, pod, pod_template_hash) (business_logins)), 1)"
onceRanged: _once.ranged & "sum by (mode) (max without (instance, pod, pod_template_hash) (increase(business_signups_total{app=\"$app\"}[1d])))"
onceTimeseries: _a.dashboard.panels[2].targets[0].expr & "max without (instance, pod, pod_template_hash) (increase(business_signups_total{app=\"$app\"}[1d]))"

// Names: every metric starts `business_`; a journey's or perf's is no business metric; a counter
// ends `_total` and a gauge does not.
nameOk: "business_x" & #BusinessName
nameMisses: [for n in ["journey_runs_total", "perf_frames", "business_journey_x", "orders", "Business_x"] if (n & #BusinessName) != _|_ {n}] & []

// The out files the generate step writes.
outFiles: list.SortStrings([for f, _ in _a.out {f}]) & [
	"analytics.business.dashboard.json",
	"analytics.loader.json",
	"analytics.sql_exporter.yml",
	"analytics.views.sql",
]

// The journeys' own alerts, as pronto-journeys derives them, read no business metric.
_j: journeys.#Journeys & {
	app: "shop"
	reported: cart: ["add"]
	spec: buy: {owner: "shop", moments: ["cart.add"], slo: availability: 99}
}
journeysClear: (#AnalyticsUnalerted & {alerts: _j.alerts}).offending & []

// The loader: a host-DOM hatch answers every mount with its cleanup (the terminal refuses one that
// does not, and stops the hatches before it), on the early exits too.
_h: #Host & {package: "shop"}
_loader:            _h.files["shell/hatches/analytics/analytics.js"].text
loaderCleanup:      strings.Contains(_loader, "if (added || optedOut || !config.website) return nothing;") & true
loaderCleanupAtEnd: strings.Contains(_loader, "document.head.append(tag);\n\treturn nothing;\n}") & true
loaderSameOrigin:   strings.Contains(_loader, "tag.src = scriptURL(config.script);") & true
loaderHost:         strings.Contains(_loader, "tag.dataset.hostUrl = location.origin;") & true
loaderPrivacy:      strings.Contains(_loader, "navigator.globalPrivacyControl === true || navigator.doNotTrack === \"1\"") & true

// A modular app (module set): the schema is the schema module's, the spec is modules/analytics's, the
// program's package embeds the module's export and the write step exports the module; a plain app has none of
// that (its schema and spec are in the program's package, as before).
_m: #Host & {package: "shop", module: "example.dev/shop"}
modularSchemaInModule:  strings.Contains(_m.files["modules/schema/analytics_plugin.cue"].text, "\npackage schema\n") & true
modularSpecInModule:    strings.Contains(_m.files["modules/analytics/analytics.cue"].text, "analytics: schema.#Analytics & {app: \"shop\"}") & true
modularSpecSeeded:      _m.files["modules/analytics/analytics.cue"].seed & true
modularProgramEmbeds:   strings.Contains(_m.files["analytics_plugin.cue"].text, "analytics: _ @embed(file=\"join/analytics.json\")") & true
modularProgramHasNoSchema: strings.Contains(_m.files["analytics_plugin.cue"].text, "#BusinessMetric") & false
modularNoRootSpec:      [for p, _ in _m.files if p == "analytics_spec.cue" {p}] & []
modularWritesTheModule: strings.Contains(_m.files["pronto/analytics.cue"].text, "cue export ./modules/analytics -e analytics.out") & true
plainSchemaInProgram:   strings.Contains(_h.files["analytics_plugin.cue"].text, "#BusinessMetric") & true
plainWritesTheProgram:  strings.Contains(_h.files["pronto/analytics.cue"].text, "cue export . -e analytics.out") & true
plainNoModuleFiles:     [for p, _ in _h.files if strings.HasPrefix(p, "modules/") {p}] & []
