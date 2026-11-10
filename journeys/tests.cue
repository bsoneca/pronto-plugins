package journeys

import (
	"encoding/json"
	"encoding/yaml"
	"list"
	"strings"
)

_j: #Journeys & {
	app:      "shop"
	gestures: {cart: ["pay", "view"], done: ["confirm"], todo: ["create-todo"]}
	spec: {
		checkout: {owner: "payments", moments: ["cart.view", "cart.pay", "done.confirm"], slo: {availability: 99.9, latency: {percent: 95, under: "250ms"}}}
		first: {owner: "growth", moments: ["todo.create-todo"], slo: availability: 99, idle: "2h"}
	}
}
_rules: {for g in _j.rules.groups {(g.name): g.rules}}
_alert: {for n, rs in _rules for r in rs if r.alert != _|_ {"\(n)/\(r.alert)": r}}

// The workbook's three pairs at 28 days, each long window and its short one
// over the same budget.
// Each a plain ratio of the collector's series, no recording rule between:
// Managed Service for Prometheus evaluates none.
_bad: {w: string, out: "(sum(increase(journey_runs_total{journey=\"checkout\",outcome=\"bad\"}[\(w)])) or vector(0)) / sum(increase(journey_runs_total{journey=\"checkout\",outcome=~\"good|bad\"}[\(w)]))"}
fastPages: _alert["journey-checkout/JourneyAvailabilityBurnFast"].expr & "(\((_bad & {w: "1h"}).out)) > 13.44 * 0.001 and (\((_bad & {w: "5m"}).out)) > 13.44 * 0.001"
mediumPages: _alert["journey-checkout/JourneyAvailabilityBurnMedium"].expr & "(\((_bad & {w: "6h"}).out)) > 5.6 * 0.001 and (\((_bad & {w: "30m"}).out)) > 5.6 * 0.001"
noRecords: [for _, rs in _rules for r in rs if r.record != _|_ {r}] & []
slowTickets: _alert["journey-checkout/JourneyAvailabilityBurnSlow"] & {labels: {severity: "ticket", owner: "payments"}}
// 30 days is the workbook's own 14.4×.
_thirty: #Journeys & {app: "shop", gestures: _j.gestures, spec: first: _j.spec.first, window: "30d"}
thirtyFast: strings.Contains([for g in _thirty.rules.groups for r in g.rules if r.alert != _|_ if r.alert == "JourneyAvailabilityBurnFast" {r.expr}][0], "> 14.4 * 0.01") & true

// A journey with no latency target has no latency series; every journey has
// the alert that says it is measuring nothing.
firstAvailabilityOnly: len([for r in _rules["journey-first"] if strings.HasPrefix(r.alert, "JourneyLatency") {r}]) & 0
noData: _alert["journey-first/JourneyNoData"].expr & "(sum(increase(journey_runs_total{journey=\"first\"}[1h])) or vector(0)) == 0"
// A journey readers take rarely waits longer before its silence alerts.
_rare: #Journeys & {app: "shop", gestures: _j.gestures, spec: first: _j.spec.first & {quiet: "3d"}}
quietRare: strings.Contains([for a in _rare.alerts if a.alert == "JourneyNoData" {a.expr}][0], "[3d]") & true
// A journey too rare to say has no NoData alert (and no rule for one), its other alerts kept.
_never: #Journeys & {app: "shop", gestures: _j.gestures, spec: first: _j.spec.first & {quiet: false}}
quietOffNoAlert: len([for a in _never.alerts if a.alert == "JourneyNoData" {a}]) & 0
quietOffNoRule: len([for g in _never.rules.groups for r in g.rules if r.alert == "JourneyNoData" {r}]) & 0
quietOffBurns: len([for a in _never.alerts if a.alert == "JourneyAvailabilityBurnFast" {a}]) & 1

// The latency SLI reads a bucket the collector exports, as either exporter
// spells a boundary.
latencyLe: strings.Contains(_alert["journey-checkout/JourneyLatencyBurnFast"].expr, "le=~\"0[.]25([.]0)?\"") & true
// A whole-second target is one boundary, not the spread's 1 beside its 1.0.
_whole: #Journeys & {app: "shop", gestures: _j.gestures, spec: first: _j.spec.first & {slo: latency: {percent: 95, under: "1s"}}}
bucketsOnce: len([for b in _whole.collector.sinks.metrics.buckets if b == 1 {b}]) & 1
seriesKept: _j.collector.sinks.metrics.flush_period_secs & 2419200

// The collector: each moment marks its journey, step and whether it closes the
// run; each journey reduces its own runs, abandoned after its idle.
_k: #Journeys & {
	app:      "shop"
	gestures: {cart: ["view"], todo: ["create-todo"]}
	spec: {
		first: {owner: "growth", moments: ["todo.create-todo"], slo: availability: 99}
		invited: {owner: "growth", moments: ["cart.view", "todo.create-todo"], slo: availability: 99, unstarted: false}
	}
}
_moments: _k.collector.transforms.moments.source
idleDefault: _j.collector.transforms["reduce-checkout"].expire_after_ms & 1800000
idleHours: _j.collector.transforms["reduce-first"].expire_after_ms & 7200000
invalidMovesNothing: _j.collector.transforms["runs-checkout"].condition & ".journey == \"checkout\" && .outcome != \"invalid\""
endedFromEveryJourney: list.SortStrings(_j.collector.transforms.ended.inputs) & ["reduce-checkout", "reduce-first"]

// The host: a seat beside pronto's, the schema in the program's package, the
// app's spec and gestures written once.
_h: #Host & {package: "shop"}
seat: strings.HasPrefix(strings.Split(_h.files["pronto/journeys.cue"].text, "\n")[1], "package prontoproject") & true
seatAfterWriter: strings.Contains(_h.files["pronto/journeys.cue"].text, "\"priority\":2") & true
seatOneStep: strings.Contains(_h.files["pronto/journeys.cue"].text, "journeys derive shop click,dblclick,change,submit,keydown,drop; journeys route /telemetry; use ./pronto/exports.nu; exports of journeys | journeys write") & true
schemaInPackage: strings.Contains(_h.files["journeys_plugin.cue"].text, "\npackage shop\n") & true
seeded: list.SortStrings([for p, f in _h.files if f.seed {p}]) & ["journeys_gestures.cue", "journeys_spec.cue"]
// No X.cue the host writes beside a path X it writes: sayt's lint would vet
// one against the other.
_dirs: {for p, _ in _h.files {(strings.Split(p, "/")[0]): true}}
noVetPairs: [for p, _ in _h.files if strings.HasSuffix(p, ".cue") if _dirs[strings.TrimSuffix(p, ".cue")] != _|_ {p}] & []
collectorHatch: strings.Contains(_h.files["journeys_hatch.cue"].text, "kind: \"container\"") & true
collectorBaked: strings.Contains(_h.files["journeys_hatch.cue"].text, "copy: [{srcs: [\"observability/journeys.collector.yaml\"], dst: \"/etc/vector/vector.yaml\"}]") & true
// The step shipped is the module itself, not the line that uses it.
stepShipped: strings.Contains(_h.files["journeys/journeys.nu"].text, "export def derive [package: string, events: string]") & true
// A batch is the whole request body.
wholeBody: _j.collector.sources.telemetry.framing.method & "bytes"
// `sayt launch@journeys` brings the collector up, server or not.
launchRule: json.Unmarshal(_h.files[".say.json"].text).say.launch.rulemap.journeys & {platform: "journeys"}
merged: [for p, f in _h.files if f.merge != _|_ if f.merge {p}] & [".say.json"]
startKept: _j.collector.transforms["reduce-checkout"].merge_strategies.started & "discard"
// A redelivered batch is the same events: dropped before any moment counts.
deduped: _j.collector.transforms.once & {type: "dedupe", fields: match: ["session", "trace", "type", "outcome"]}
// The SLI reads good and bad alone: unstarted and abandoned runs are counted
// apart.
sliValid: strings.Contains(_rules["journey-checkout"][0].expr, "outcome=~\"good|bad\"") & true
// The reporter: a host-DOM hatch on every screen, posting to the endpoint.
reporterHatch: strings.Contains(_h.files["journeys_hatch.cue"].text, "kind:  \"host-dom\"") & true
reporterEverywhere: strings.Contains(_h.files["journeys_hatch.cue"].text, "code: surface: screens: [!~\"^(\\(strings.Join(_journeysOwnHatches, \"|\")))$\"]: hatches: [\"journeys-telemetry\"]") & true
reporterRequired: strings.Contains(_h.files["journeys_hatch.cue"].text, "_journeysUnreported: [for n, s in code.surface.screens if !list.Contains(s.hatches, \"journeys-telemetry\") {n}] & []") & true
reporterPosts: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "const ENDPOINT = \"/telemetry\";") & true
reporterMounts: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "export default function mount(screen, { signal })") & true
// One session's rate is capped, and what is dropped is counted.
throttled: _j.collector.transforms.per_session & {type: "throttle", key_field: "{{ session }}", threshold: 600, window_secs: 60}
dedupeAfterThrottle: _j.collector.transforms.once.inputs & ["per_session"]
throttleExported: list.Contains(_j.collector.sinks.metrics.inputs, "throttled_named") & true
// The sidecar dates counters by process_start_time_seconds, which Vector does not export.
startExported: list.Contains(_j.collector.sinks.metrics.inputs, "process_start") & true
// The local dashboard: parses, scrapes the collector, loads the rules and the
// dashboard, on the app's network.
_dash: yaml.Unmarshal(_h.files["journeys/dashboard.compose.yaml"].text)
dashboardServices: [for k, _ in _dash.services {k}] & ["victoriametrics", "vmalert", "grafana"]
dashboardScrapes: strings.Contains(_dash.configs.scrape.content, "journeys-collector:9598") & true
dashboardRules: _dash.configs.rules.file & "../observability/journeys.rules.yaml"
dashboardOnAppNetwork: _dash.networks.app & {external: true}
launchUp: json.Unmarshal(_h.files[".say.json"].text).say.launch.rulemap.journeys.cmds[0].do & "use ./journeys/journeys.nu; journeys up"
// A batch goes on a timer too: the terminal's screens change without a
// pagehide, and a dashboard is only live if the events arrive.
reporterFlushesOnTime: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "else timer ??= setTimeout(flush, FLUSH_MS);") & true
// What a page holds as it goes is kept for the tab's next load.
reporterKeepsUnsent: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "sessionStorage.setItem(UNSENT, JSON.stringify([...kept, ...queue]));") & true

// Production: each alert a Cloud Monitoring PromQL policy, named for the app
// and journey, its `for` in seconds, the same expression vmalert reads.
_policy: {for p in _j.alertPolicies {(p.name): p}}
policyPerAlert: len(_j.alertPolicies) & len(_j.alerts)
policyFast: _policy["shop-checkout-availabilityburnfast"] & {
	duration: "120s"
	severity: "page"
	expr:     _alert["journey-checkout/JourneyAvailabilityBurnFast"].expr
	labels: {app: "shop", journey: "checkout"}
}
policyNoData: _policy["shop-first-nodata"].duration & "900s"
policiesOut: _j.out["journeys.alerts.json"] & _j.alertPolicies
// The dashboard: the app's own, a row per journey with its own budget, no
// variable but the datasource.
dashboardUid: _j.dashboard.uid & "journeys-shop"
dashboardRows: [for p in _j.dashboard.panels if p.type == "row" {p.title}] & ["checkout — cart.view → done.confirm (SLO 99.9%)", "first — todo.create-todo → todo.create-todo (SLO 99%)"]
dashboardOnlyDatasource: [for v in _j.dashboard.templating.list {v.name}] & ["datasource"]
_panel: {for p in _j.dashboard.panels {(p.title + "/\(p.gridPos.y)"): p}}
budgetInline: _panel["Error budget left/1"].targets[0].expr & "1 - (\((_bad & {w: "28d"}).out)) / 0.001"
latencyBudget: strings.HasSuffix(_panel["Latency budget left/1"].targets[0].expr, "/ 0.05") & true
noLatencySlo: _panel["Latency budget left/15"].fieldConfig.defaults.noValue & "no latency SLO"
panelIdsUnique: len({for p in _j.dashboard.panels {"\(p.id)": true}}) & len(_j.dashboard.panels)
// A host launch runs the collector too, as a host peer the door reaches, with
// Vector from mise; the alerts and dashboard carry the program's package.
_hatch: _h.files["journeys_hatch.cue"].text
hostPeer: strings.Contains(_hatch, "PRONTO_UPSTREAM_JOURNEYS_COLLECTOR: {peer: \"journeys-collector\", port: \"http\"}") & true
hostCollects: strings.Contains(_hatch, "do:    \"exec nu -c 'use journeys/journeys.nu; journeys collect'\"") & true
hostPorts: strings.Contains(_hatch, "metrics: {port: 9598, env: \"JOURNEYS_METRICS_PORT\"}") & true
appNamed: strings.Contains(_hatch, "journeys: app: \"shop\"") & true
vectorTool: strings.Contains(_h.files["pronto/journeys.cue"].text, "\"aqua:vectordotdev/vector\":\"0.59.0\"") & true
collectShipped: strings.Contains(_h.files["journeys/journeys.nu"].text, "export def collect []") & true
// The collector's tests run on the host's Vector: no container on a developer's machine.
collectorTestsNative: _j.checks["journeys-collector"] & {verb: "lint", cmds: ["vector test observability/journeys.collector.yaml observability/journeys.collector.test.yaml"]}
// Cloud Monitoring takes no `for` past 25 hours of lookback: the slow burn and
// a long quiet fire on their first holding evaluation.
policySlowNoFor: _policy["shop-checkout-availabilityburnslow"] & {duration: "0s", interval: "300s"}
policyFastEveryMinute: _policy["shop-checkout-availabilityburnfast"].interval & "60s"
policyMediumFor: _policy["shop-checkout-availabilityburnmedium"].duration & "120s"
_rarePolicy: {for p in (_rare & {app: "shop"}).alertPolicies {(p.name): p}}
policyRareNoData: _rarePolicy["shop-first-nodata"].duration & "0s"
// A hatch's own gesture: declared by screen, a moment may name it, and the
// reporter takes it from the screen.
_reported: #Journeys & {app: "shop", gestures: _j.gestures, reported: cart: ["coupon-check"], spec: c: {owner: "payments", moments: ["cart.coupon-check", "cart.pay"], slo: availability: 99}}
reportedMoment: _reported.collector.transforms["reduce-c"].type & "reduce"
reportedKnown: _reported._known.cart & ["pay", "view", "coupon-check"]
reportedOnlyThere: _reported._known.done & ["confirm"]
reporterTakesHatchGestures: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "screen.addEventListener(\"journeys:gesture\"") & true

// A browser error is no moment: it leaves as an ERROR line on stdout that prod-watch reads, after
// its own rate caps (a session's, then one error's across sessions) and the collector's redaction.
errorsLogged: _j.collector.sinks.errors & {type: "console", inputs: ["errors_log"], target: "stdout", encoding: codec: "json"}
errorsCappedPerSession: _j.collector.transforms.errors_per_session & {type: "throttle", key_field: "{{ session }}", threshold: 5, window_secs: 60}
errorsCappedPerError: _j.collector.transforms.errors_per_error & {type: "throttle", key_field: "{{ fingerprint }}", threshold: 20, window_secs: 60}
errorsRedactedBeforeCap: _j.collector.transforms.errors_per_error.inputs & ["errors_clean"]
errorsOnlyErrors: _j.collector.transforms.errors_in.condition & ".type == \"error\""
// The reporter sends the name, a trimmed message, the top frame and the screen; a page reports a few, once each.
reporterSendsError: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "const event = { type: \"error\", kind, name: nameOf(thrown), message: messageOf(thrown) || String(fallback ?? \"\").slice(0, ERROR_TEXT), frame: frameOf(thrown), screen: current };") & true
reporterCapsErrors: strings.Contains(_h.files["shell/hatches/journeys/telemetry.js"].text, "if (reported.has(key) || reported.size >= ERRORS_PER_PAGE) return;") & true

// A journey may count no unstarted runs: each moment says which, and the run
// it reduces to is dropped when it began past the first moment.
_k: #Journeys & {
	app:      "shop"
	gestures: {cart: ["view"], todo: ["create-todo"]}
	spec: {
		first: {owner: "growth", moments: ["todo.create-todo"], slo: availability: 99}
		invited: {owner: "growth", moments: ["cart.view", "todo.create-todo"], slo: availability: 99, unstarted: false}
	}
}
_moments: _k.collector.transforms.moments.source
unstartedCounted: strings.Contains(_moments, "\"journey\": \"first\", \"step\": 0, \"started\": true, \"unstarted\": true,") & true
unstartedDropped: strings.Contains(_moments, "\"journey\": \"invited\", \"step\": 1, \"started\": false, \"unstarted\": false,") & true
unstartedKept: _k.collector.transforms["reduce-invited"].merge_strategies.unstarted & "discard"
unstartedAborts: strings.Contains(_k.collector.transforms.ended.source, "if .started != true && .unstarted == false { abort }") & true
// A moment's tens of milliseconds read as a number: finer buckets below 50 ms.
finerBuckets: _j.collector.sinks.metrics.buckets[0:4] & [0.005, 0.01, 0.025, 0.05]
