# The generate step against a fixture app: `./saytw --script tools.nu nu analytics/test.nu`.
# Patches the door three times beside the other hosts' blocks, writes a program's `analytics.out`,
# and holds the schema to its rules by vetting specs that break them.
use analytics.nu

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"analytics/test.nu: ($what)"} }
	print $"ok  ($what)"
}

# Whether `cue vet` refuses a spec written beside the schema.
def refused [spec: string] {
	let dir = mktemp --directory
	cp analytics/schema.cue $dir
	$spec | save $"($dir)/spec.cue"
	let out = do { cd $dir; ^cue vet -c . } | complete
	rm --recursive $dir
	$out.exit_code != 0
}

def main [] {
	let dir = mktemp --directory
	cd $dir
	mkdir docker
	"(app) {\n  # pronto-journeys:begin — the terminal's telemetry\n  handle /telemetry {\n  }\n  # pronto-journeys:end\n  # The auth service, unstripped.\n  # Its comment is its own.\n  handle /auth/* {\n    reverse_proxy auth:9999\n  }\n}\n" | save docker/Caddyfile

	analytics route /a/s.js /a/e https://umami.example.com
	let caddy = open --raw docker/Caddyfile
	let stamp = ls docker/Caddyfile | get modified.0
	analytics route /a/s.js /a/e https://umami.example.com
	check "a second patch leaves the door untouched" ((ls docker/Caddyfile | get modified.0) == $stamp)
	check "a second patch changes nothing" ((open --raw docker/Caddyfile) == $caddy)
	check "the tracker and its collector are the only routes" (($caddy | str contains "handle /a/s.js {") and ($caddy | str contains "handle /a/e {"))
	check "the door caps an event's size" ($caddy | str contains "    request_body {\n      max_size 16KB\n    }")
	check "a request for localhost reaches the peer the host door rewrites" (($caddy | str contains "@local host localhost 127.0.0.1") and ($caddy | str contains "reverse_proxy @local umami:8697"))
	check "any other request reaches Umami's address" ($caddy | str contains "      reverse_proxy https://umami.example.com {")
	check "neither upstream is sent the app's cookies, authorization or referrer" (($caddy | split row "header_up -Cookie" | length) == 5 and ($caddy | split row "header_up -Authorization" | length) == 5 and ($caddy | split row "header_up -Referer" | length) == 5)
	check "the proxy sends the upstream's own Host" ($caddy | str contains "header_up Host {upstream_hostport}")
	check "the route lands above the auth route's comment" (($caddy | str index-of "pronto-analytics:end") < ($caddy | str index-of "# The auth service"))
	check "another host's block is not nested in ours" (($caddy | str index-of "pronto-journeys:end") < ($caddy | str index-of "pronto-analytics:begin"))

	analytics route /v/s.js /v/e https://u2.example.com
	let moved = open --raw docker/Caddyfile
	check "a changed address replaces the routes" (($moved | str contains "handle /v/s.js {") and not ($moved | str contains "handle /a/s.js {") and not ($moved | str contains "umami.example.com"))

	{
		"analytics.views.sql": "CREATE SCHEMA IF NOT EXISTS analytics;\n"
		"analytics.loader.json": {website: "00000000-0000-4000-8000-000000000001", script: "/a/s.js"}
		"analytics.sql_exporter.yml": "global:\n  min_interval: 60s\n"
		"analytics.business.dashboard.json": {uid: "business-shop"}
	} | to json | analytics write
	check "the views are the app's raw migration" ((open --raw analytics/views.sql) == "CREATE SCHEMA IF NOT EXISTS analytics;\n")
	check "the loader's settings are its module" ((open --raw shell/hatches/analytics/config.js) | str contains 'export default {"website":"00000000-0000-4000-8000-000000000001","script":"/a/s.js"};')
	check "the loader's settings are not in observability/" (not ("observability/analytics.loader.json" | path exists))
	check "the exporter's files are text, as written" ((open --raw observability/analytics.sql_exporter.yml) == "global:\n  min_interval: 60s\n")
	check "the dashboard is JSON in observability/" ((open observability/analytics.business.dashboard.json).uid == "business-shop")

	"(app) {\n}\n" | save --force docker/Caddyfile
	check "a door with no auth route refuses" (try { analytics route /a/s.js /a/e https://umami.example.com; false } catch { true })

	cd -
	rm --recursive $dir

	# The schema's rules, each by a spec that breaks it.
	let head = "package analytics\n#Analytics: _\n"
	let base = {app: "shop"}
	check "a business metric is named business_" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: orders: {help: \"h\", select: \"SELECT 1 AS value\"}}\n")
	check "a journey's metric name is no business metric" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: journey_runs_total: {type: \"counter\", help: \"h\", select: \"SELECT 1 AS value\"}}\n")
	check "a name under business_journey is refused too" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: business_journey_runs: {help: \"h\", select: \"SELECT 1 AS value\"}}\n")
	check "a counter must be named _total" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: business_orders: {type: \"counter\", help: \"h\", select: \"SELECT 1 AS value\"}}\n")
	check "a gauge must not be named _total" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: business_orders_total: {help: \"h\", select: \"SELECT 1 AS value\"}}\n")
	check "a panel reads only declared metrics" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: business_orders: {help: \"h\", select: \"SELECT 1 AS value\"}, rows: [{title: \"r\", panels: [{title: \"p\", expr: \"business_ordres\"}]}]}\n")
	check "a label cannot be app or value" (refused "package analytics\nx: #Analytics & {app: \"shop\", metrics: business_orders: {help: \"h\", labels: [\"app\"], select: \"SELECT 1 AS value\"}}\n")
	check "an alert on a business metric is refused" (refused "package analytics\nx: #AnalyticsUnalerted & {alerts: [{alert: \"JourneyBurn\", expr: \"sum(business_orders) > 3\"}]}\n")
	check "an alert that selects by __name__ what could be a business metric is refused" (refused "package analytics\nx: #AnalyticsUnalerted & {alerts: [{alert: \"JourneyBurn\", expr: \"sum({__name__=~\\\"business.*\\\"}) > 3\"}]}\n")
	check "an alert on a journey's metric is fine" (not (refused "package analytics\nx: #AnalyticsUnalerted & {alerts: [{alert: \"JourneyBurn\", expr: \"sum(journey_runs_total) > 3\"}]}\n"))
}
