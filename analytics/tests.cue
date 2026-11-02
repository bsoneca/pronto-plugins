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
	rows: [{title: "Orders", panels: [{title: "Orders", expr: "business_orders{app=\"$app\"}"}, {title: "Signups a day", kind: "timeseries", w: 18, expr: "increase(business_signups_total{app=\"$app\"}[1d])"}]}]
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
viewsNarrowed:          strings.Contains(_a.views, "ALTER ROLE analytics_reader NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS LOGIN;") & true
viewsTakeBackSuperuser: strings.Contains(_a.views, "REVOKE cloudsqlsuperuser FROM analytics_reader;") & true
viewsLoginOnlyOffCloud: strings.Contains(_a.views, "IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudsqlsuperuser') AND NOT EXISTS") & true

// The exporter asks the views and labels each sample with the app, in one file.
_c:                   _a._exporter.collectors[0]
collectorMinInterval: _c.min_interval & "60s"
queryLabels: [for q in _c.queries if q.query_name == "business_orders" {q.query}] & ["SELECT app, \"state\", value FROM analytics.orders"]
metricKeys: [for m in _c.metrics if m.metric_name == "business_orders" {m.key_labels}] & [["app", "state"]]
counterType: [for m in _c.metrics if m.metric_name == "business_signups_total" {m.type}] & ["counter"]
targetDsnFromEnv: _a._exporter.target.data_source_name & "postgres://analytics_reader@localhost/placeholder"
targetUsesIt: _a._exporter.target.collectors & ["business"]

// The dashboard: an app variable, a row a group of panels, laid left to right.
dashApp: [for t in _a.dashboard.templating.list if t.name == "app" {t.query}] & ["label_values(business_accounts, app)"]
rowThenPanels: [for p in _a.dashboard.panels {p.type}] & ["row", "stat", "timeseries"]
secondPanelRight: _a.dashboard.panels[2].gridPos & {x: 6, y: 1, w: 18, h: 5}
dashUid: _a.dashboard.uid & "business-shop"

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
