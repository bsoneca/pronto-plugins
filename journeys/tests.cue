package journeys

import (
	"encoding/json"
	"encoding/yaml"
	"list"
	"strings"
)

_j: #Journeys & {
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
fastPages: _alert["journey-checkout/JourneyAvailabilityBurnFast"].expr & "journey:availability_errors:ratio_rate1h{journey=\"checkout\"} > 13.44 * 0.001 and journey:availability_errors:ratio_rate5m{journey=\"checkout\"} > 13.44 * 0.001"
mediumPages: _alert["journey-checkout/JourneyAvailabilityBurnMedium"].expr & "journey:availability_errors:ratio_rate6h{journey=\"checkout\"} > 5.6 * 0.001 and journey:availability_errors:ratio_rate30m{journey=\"checkout\"} > 5.6 * 0.001"
slowTickets: _alert["journey-checkout/JourneyAvailabilityBurnSlow"] & {labels: {severity: "ticket", owner: "payments"}}
// 30 days is the workbook's own 14.4×.
_thirty: #Journeys & {gestures: _j.gestures, spec: first: _j.spec.first, window: "30d"}
thirtyFast: strings.Contains([for g in _thirty.rules.groups for r in g.rules if r.alert != _|_ if r.alert == "JourneyAvailabilityBurnFast" {r.expr}][0], "> 14.4 * 0.01") & true

// A journey with no latency target has no latency series; every journey has
// the alert that says it is measuring nothing.
firstAvailabilityOnly: len([for r in _rules["journey-first"] if r.record != _|_ if strings.HasPrefix(r.record, "journey:latency") {r}]) & 0
noData: _alert["journey-first/JourneyNoData"].expr & "(sum(increase(journey_runs_total{journey=\"first\"}[1h])) or vector(0)) == 0"

// The latency SLI reads a bucket the collector exports, as either exporter
// spells a boundary.
latencyLe: strings.Contains([for r in _rules["journey-checkout"] if r.record != _|_ if r.record == "journey:latency_errors:ratio_rate5m" {r.expr}][0], "le=~\"0[.]25([.]0)?\"") & true
// A whole-second target is one boundary, not the spread's 1 beside its 1.0.
_whole: #Journeys & {gestures: _j.gestures, spec: first: _j.spec.first & {slo: latency: {percent: 95, under: "1s"}}}
bucketsOnce: len([for b in _whole.collector.sinks.metrics.buckets if b == 1 {b}]) & 1
seriesKept: _j.collector.sinks.metrics.flush_period_secs & 2419200

// The collector: each moment marks its journey, step and whether it closes the
// run; each journey reduces its own runs, abandoned after its idle.
_moments: _j.collector.transforms.moments.source
idleDefault: _j.collector.transforms["reduce-checkout"].expire_after_ms & 1800000
idleHours: _j.collector.transforms["reduce-first"].expire_after_ms & 7200000
invalidMovesNothing: _j.collector.transforms["runs-checkout"].condition & ".journey == \"checkout\" && .outcome != \"invalid\""
endedFromEveryJourney: list.SortStrings(_j.collector.transforms.ended.inputs) & ["reduce-checkout", "reduce-first"]

// The host: a seat beside pronto's, the schema in the program's package, the
// app's spec and gestures written once.
_h: #Host & {package: "shop"}
seat: strings.HasPrefix(strings.Split(_h.files["pronto/journeys.cue"].text, "\n")[1], "package prontoproject") & true
seatAfterWriter: strings.Contains(_h.files["pronto/journeys.cue"].text, "\"priority\":2") & true
seatOneStep: strings.Contains(_h.files["pronto/journeys.cue"].text, "journeys derive shop click,dblclick,change,submit,keydown,drop; journeys route /telemetry; run-mise exec -- cue export . -e journeys.out --out json | journeys write") & true
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
sliValid: strings.Contains(_rules["journey-checkout"][2].expr, "outcome=~\"good|bad\"") & true
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
