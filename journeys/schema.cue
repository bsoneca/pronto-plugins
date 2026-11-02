// Journeys: an app's critical user journeys, each an ordered list of the
// gestures a reader makes on its screens, with an SLO. From one spec the
// plugin derives the collector that turns the terminal's telemetry into runs,
// the vmalert rules that burn their error budget, and a Grafana dashboard.
//
// This file is written into the app's own package (journeys_plugin.cue), so
// every name here is prefixed: it sits beside the program's.
package journeys

import (
	"list"
	"math"
	"strconv"
	"strings"
)

// A moment is a gesture the terminal reports on a screen: "<screen>.<gesture>",
// a handler by its module or a form by its id, else its data-gesture, else its action and entity
// (omnishell's docs/telemetry.md).
// The gesture keeps a form id's own case: `id="newTodo"` reports `newTodo`.
#JourneyMoment: =~"^[a-z][a-z0-9_-]*\\.[A-Za-z0-9_-]+$"

// The collector's image, and the same Vector as a host tool (mise's aqua
// backend) for a host launch and the unit tests, as pronto-perf pins it.
#JourneysVector:        "timberio/vector:0.59.0-alpine"
#JourneysVectorVersion: "0.59.0"

#JourneyDuration: =~"^[0-9]+(\\.[0-9]+)?(ms|s)$"

#Journey: {
	owner!: =~"^[a-z][a-z0-9-]*$"
	moments!: [#JourneyMoment, ...#JourneyMoment]
	slo!: {
		// Percent of valid runs that reach the last moment. A run the reader
		// abandons is not valid; one the app fails is bad.
		availability!: number & >0 & <100
		// Percent of moments that answer under `under`.
		latency?: {
			percent!: number & >0 & <100
			under!:   #JourneyDuration
		}
	}
	// How long a run waits for its next moment before it is abandoned: the
	// reader left, which is no failure of the app's.
	idle: *"30m" | =~"^[1-9][0-9]*(m|h)$"
	// How long without a single run reads as the journey measuring nothing
	// (JourneyNoData): an hour for a journey readers take all day, longer for
	// one they take rarely.
	quiet: *"1h" | =~"^[1-9][0-9]*(m|h|d)$"
}

// The burn-rate pairs of the SRE workbook, as fractions of the budget spent
// in the long window; the factor is derived from the SLO's own window, so a
// 28-day window pages at 13.44× rather than the 30-day 14.4×.
_journeysBurns: [
	{name: "Fast", long: "1h", short: "5m", hours: 1, spend: 0.02, severity: "page"},
	{name: "Medium", long: "6h", short: "30m", hours: 6, spend: 0.05, severity: "page"},
	{name: "Slow", long: "3d", short: "6h", hours: 72, spend: 0.10, severity: "ticket"},
]
// Every window a burn pair reads, each once.
_journeysWindows: {
	let all = [for b in _journeysBurns for w in [b.short, b.long] {w}]
	[for i, w in all if !list.Contains(list.Slice(all, 0, i), w) {w}]
}

// "3s" → "3", "250ms" → "0.25": the `le` a latency SLI reads.
_journeysLe: {
	in: #JourneyDuration
	let seconds = [
		if strings.HasSuffix(in, "ms") {strconv.ParseFloat(strings.TrimSuffix(in, "ms"), 64) / 1000},
		if !strings.HasSuffix(in, "ms") {strconv.ParseFloat(strings.TrimSuffix(in, "s"), 64)},
	][0]
	out: strconv.FormatFloat(seconds, 103, -1, 64)
}

_journeysTitle: {availability: "Availability", latency: "Latency"}

// A `quiet` in hours: "30m" → 0.5, "1d" → 24.
_journeysHours: {
	in: string
	let n = strconv.Atoi(strings.TrimRight(in, "mhd"))
	out: [
		if strings.HasSuffix(in, "m") {n / 60},
		if strings.HasSuffix(in, "h") {n},
		if strings.HasSuffix(in, "d") {n * 24},
	][0]
}

#Journeys: J={
	// The app, as its alerts and dashboard are named where several apps'
	// share one Grafana and one Cloud Monitoring: the program's package,
	// which the host fills in (journeys_hatch.cue), and a title for people.
	app!:  =~"^[a-z][a-z0-9_-]*$"
	title: *app | string & !=""
	// Each screen's gestures, derived from its markup by the plugin's generate
	// step (journeys_gestures.cue): what a moment must name.
	gestures: [string]: [...string]
	// Gestures a hatch reports itself (a "journeys:gesture" event, telemetry.js),
	// by screen: work the terminal never sees as a submit, such as a form a
	// hatch holds while it calls a service, or a token it hands over by fetch.
	reported: [string]: [...=~"^[A-Za-z0-9_-]+$"]
	// What a moment may name: the markup's gestures and the reported ones.
	_known: {
		for s, _ in {for s, _ in gestures {(s): _}, for s, _ in reported {(s): _}} {
			(s): list.Concat([[if gestures[s] != _|_ for g in gestures[s] {g}], [if reported[s] != _|_ for g in reported[s] {g}]])
		}
	}
	spec: [Name=string & =~"^[a-z][a-z0-9-]*$"]: #Journey
	// One budget window for the app's journeys, so the dashboard reads one
	// series per journey.
	window: *"28d" | =~"^[1-9][0-9]*d$"
	// How many events one session may post per window before the collector
	// drops the rest. The door caps each batch's size; this caps their rate,
	// which the door's stock Caddy cannot. A keydown gesture is an event per
	// key, so the default leaves room for typing.
	limit: {
		events:  *600 | int & >0
		seconds: *60 | int & >0
	}
	_days: strconv.Atoi(strings.TrimSuffix(J.window, "d"))
	// The ratio windows: every burn window, and the budget window once even
	// where it is one of them.
	_ratioWindows: list.Concat([_journeysWindows, [if !list.Contains(_journeysWindows, J.window) {J.window}]])

	_violations: list.Concat([
		[for n, j in J.spec for m in j.moments
			let p = strings.Split(m, ".")
			if J._known[p[0]] == _|_ {
				"journey \(n) moment \(m) names no screen \(p[0])"
			}],
		[for n, j in J.spec for m in j.moments
			let p = strings.Split(m, ".")
			if J._known[p[0]] != _|_
			if !list.Contains(J._known[p[0]], p[1]) {
				"journey \(n) moment \(m) names no gesture \(p[1]) on screen \(p[0]); it has \(strings.Join(J._known[p[0]], ", "))"
			}],
		[for n, j in J.spec if len({for m in j.moments {(m): true}}) != len(j.moments) {
			"journey \(n) repeats a moment"
		}],
	])
	_refusal: [if len(_violations) == 0 {true}, error(_violations[0])][0]

	// The SLIs, one per journey and kind. `errors` is a PromQL ratio of bad to
	// valid over the range `w`, which each record unifies in; a journey that has
	// never failed has no bad series, and reads 0 rather than no data.
	_slis: [for n, j in J.spec for s in [
		{
			kind:   "availability"
			budget: (100 - j.slo.availability) / 100
			errors: W={w: string, expr: "(sum(increase(journey_runs_total{journey=\"\(n)\",outcome=\"bad\"}[\(W.w)])) or vector(0)) / sum(increase(journey_runs_total{journey=\"\(n)\",outcome=~\"good|bad\"}[\(W.w)]))"}
		},
		if j.slo.latency != _|_ {
			kind:   "latency"
			le:     (_journeysLe & {in: j.slo.latency.under}).out
			// Prometheus 3 ingests a whole-second boundary as "3.0", an older
			// exporter as "3": the matcher takes either.
			let leMatch = strings.Replace(le, ".", "[.]", -1) + "([.]0)?"
			budget: (100 - j.slo.latency.percent) / 100
			errors: W={w: string, expr: "1 - sum(increase(journey_moment_seconds_bucket{journey=\"\(n)\",le=~\"\(leMatch)\"}[\(W.w)])) / sum(increase(journey_moment_seconds_count{journey=\"\(n)\"}[\(W.w)]))"}
		},
	] {
		journey: n
		owner:   j.owner
		s
	}]

	// Every latency SLI's `le`, ascending by value as histogram boundaries
	// must be: the collector buckets at each, so the matcher has a bucket to
	// read.
	buckets: list.Sort([for le, _ in {for s in _slis if s.kind == "latency" {(s.le): true}} {le}],
		{x: string, y: string, less: strconv.ParseFloat(x, 64) < strconv.ParseFloat(y, 64)})

	// Each SLI's error ratio over a window, as plain PromQL on the collector's
	// own series: no recording rule stands between them, so the same
	// expression reads a local VictoriaMetrics and Google Cloud Managed Service
	// for Prometheus, where nothing evaluates recording rules.
	_ratio: {for s in _slis for w in _ratioWindows {"\(s.journey)/\(s.kind)/\(w)": (s.errors & {"w": w}).expr}}

	// The alerts, once: vmalert's rule file reads them locally, and
	// journeys.alerts.json carries them to Cloud Monitoring's PromQL alerting
	// policies in production (pronto-plugins' infra, `alerts`).
	alerts: list.Concat([
		[for s in _slis for b in _journeysBurns
			let factor = strconv.FormatFloat(math.Round(b.spend*_days*24/b.hours*1000)/1000, 103, -1, 64)
			let limit = "\(factor) * \(s.budget)" {
			alert:    "Journey\(_journeysTitle[s.kind])Burn\(b.name)"
			hours:    b.hours
			journey:  s.journey
			owner:    s.owner
			severity: b.severity
			for:      "2m"
			expr:     "(\(_ratio["\(s.journey)/\(s.kind)/\(b.long)"])) > \(limit) and (\(_ratio["\(s.journey)/\(s.kind)/\(b.short)"])) > \(limit)"
			summary:  "\(s.journey) is spending its \(s.kind) budget at \(factor)× (\(strconv.FormatFloat(b.spend*100, 103, -1, 64))% of \(J.window) in \(b.long))"
		}],
		// A journey no run reaches reads as no data, never as healthy: a
		// collector down, a release without telemetry, an app with nowhere to
		// post all say so here rather than in a green dashboard. The exporter
		// keeps a quiet counter for the whole window, so absence alone would
		// miss a collector that is up and hears nothing: no increase is no run.
		// A journey readers take rarely says how long a quiet spell may be
		// (`quiet`), so its silence is no false alarm.
		[for n, j in J.spec {
			alert:    "JourneyNoData"
			hours:    (_journeysHours & {in: j.quiet}).out
			journey:  n
			owner:    j.owner
			severity: "ticket"
			for:      "15m"
			expr:     "(sum(increase(journey_runs_total{journey=\"\(n)\"}[\(j.quiet)])) or vector(0)) == 0"
			summary:  "\(n) has reported no run for \(j.quiet): its SLO is measuring nothing"
		}],
	])

	// vmalert's rule file, one group per journey.
	rules: groups: [for n, j in J.spec {
		name:     "journey-\(n)"
		interval: "30s"
		rules: [for a in alerts if a.journey == n {
			alert: a.alert
			expr:  a.expr
			for:   a.for
			labels: {journey: n, owner: a.owner, severity: a.severity}
			annotations: summary: a.summary
		}]
	}]

	// The same alerts as Cloud Monitoring takes them: one PromQL alerting
	// policy each, named for its journey and alert, its `for` in seconds. Cloud
	// Monitoring holds no `for` on a query that looks back past 25 hours (the
	// slow burn's 3 days, a rare journey's quiet), so those fire on the first
	// evaluation that holds, their long window being slow to move anyway, and
	// evaluates them every 5 minutes, the least it allows a look back of days.
	_seconds: {"2m": "120s", "15m": "900s"}
	alertPolicies: [for a in alerts {
		name:          "\(J.app)-\(a.journey)-\(strings.ToLower(strings.TrimPrefix(a.alert, "Journey")))"
		displayName:   "\(J.title): \(a.journey) \(a.alert)"
		expr:          a.expr
		duration:      [if a.hours > 25 {"0s"}, _seconds[a.for]][0]
		interval:      [if a.hours > 25 {"300s"}, "60s"][0]
		severity:      a.severity
		documentation: "\(a.summary) (owner: \(a.owner))"
		labels: {journey: a.journey, owner: a.owner, severity: a.severity, app: J.app}
	}]

	// The collector: Vector, reading the terminal's telemetry batches and
	// assembling each session's runs of each journey. A moment opens or extends
	// a run; a refused or failed moment closes it bad; the last moment ok
	// closes it good; a run idle past its journey's `idle` is abandoned. A
	// refusal that opens a run belongs to one already closed, so it is counted
	// on its moment and not as a run of its own. `invalid` — the reader's own input refused by a form — neither moves nor
	// closes a run.
	_mark: [for n, j in J.spec for i, m in j.moments {
		journey: n
		moment:  m
		step:    i
		last:    i == len(j.moments)-1
	}]
	_idleMs: {
		for n, j in J.spec {
			let v = strconv.Atoi(strings.TrimRight(j.idle, "mh"))
			(n): v * [if strings.HasSuffix(j.idle, "h") {3600000}, 60000][0]
		}
	}
	collector: {
		sources: telemetry: {
			type:    "http_server"
			address: "0.0.0.0:8686"
			path:    "/telemetry"
			method:  "POST"
			// A batch is the whole body, however it is laid out: newline framing
			// would split a pretty-printed one into lines no parser takes.
			framing: method: "bytes"
			decoding: codec: "bytes"
		}
		transforms: {
			// A batch is a JSON array; an array at the root is one event each.
			events: {
				type:   "remap"
				inputs: ["telemetry"]
				source: ". = parse_json!(string!(.message))"
			}
			// One session's rate, past which its events are dropped and counted.
			per_session: {
				type:        "throttle"
				inputs:      ["events"]
				key_field:   "{{ session }}"
				threshold:   J.limit.events
				window_secs: J.limit.seconds
			}
			// A beacon can be delivered twice; a trace is minted once per gesture,
			// so a repeat of (session, trace, type, outcome) is the same event.
			once: {
				type:   "dedupe"
				inputs: ["per_session"]
				fields: match: ["session", "trace", "type", "outcome"]
			}
			// Each gesture or late refusal, once per journey it is a moment of.
			moments: {
				type:   "remap"
				inputs: ["once"]
				drop_on_abort: true
				source: strings.Join(list.Concat([
					["if .type != \"gesture\" && .type != \"refusal\" { abort }",
						"m = (string(.screen) ?? \"\") + \".\" + (string(.gesture) ?? \"\")",
						"bad = .outcome == \"refused\" || .outcome == \"failed\"",
						"base = { \"session\": .session, \"trace\": .trace, \"moment\": m, \"outcome\": .outcome, \"bad\": bad, \"late\": .type == \"refusal\" }",
						"if is_integer(.ms) || is_float(.ms) { base.seconds = to_float!(.ms) / 1000.0 }",
						"out = []"],
					[for k in _mark {
						"if m == \"\(k.moment)\" { out = push(out, merge(base, { \"journey\": \"\(k.journey)\", \"step\": \(k.step), \"started\": \(k.step == 0), \"closed\": bad || (\(k.last) && .outcome == \"ok\") })) }"
					}],
					["if length(out) == 0 { abort }", ". = out"],
				]), "\n")
			}
			for n, _ in J.spec {
				"runs-\(n)": {
					type:   "filter"
					inputs: ["moments"]
					condition: ".journey == \"\(n)\" && .outcome != \"invalid\""
				}
				"reduce-\(n)": {
					type:   "reduce"
					inputs: ["runs-\(n)"]
					group_by: ["session"]
					ends_when: ".closed == true"
					expire_after_ms: J._idleMs[n]
					merge_strategies: {journey: "retain", closed: "retain", bad: "retain", outcome: "retain", step: "max", late: "discard", started: "discard"}
				}
			}
			ended: {
				type:   "remap"
				inputs: [for n, _ in J.spec {"reduce-\(n)"}]
				drop_on_abort: true
				// A run is the journey from its first moment. One a late refusal
				// opened is none: that refusal is counted on its moment. One that
				// began past the first moment — a reader repeating the last gesture
				// after the run closed, or a later batch overtaking an earlier one —
				// is `unstarted`: outside the SLI, which reads good and bad alone,
				// but counted, so how often moments arrive out of order is a number
				// rather than a silence.
				source: """
					if .late == true { abort }
					.run = if .started != true { "unstarted" } else if .closed != true { "abandoned" } else if .bad == true { "bad" } else { "good" }
					"""
			}
			run_metrics: {
				type:   "log_to_metric"
				inputs: ["ended"]
				metrics: [{type: "counter", field: "run", name: "journey_runs_total", tags: {journey: "{{ journey }}", outcome: "{{ run }}"}}]
			}
			// One transform per field: log_to_metric drops an event whole when any
			// of its metrics lacks its field, and a refusal has no duration.
			moment_metrics: {
				type:   "log_to_metric"
				inputs: ["moments"]
				metrics: [{type: "counter", field: "outcome", name: "journey_moments_total", tags: {journey: "{{ journey }}", moment: "{{ moment }}", outcome: "{{ outcome }}"}}]
			}
			timed: {
				type:   "filter"
				inputs: ["moments"]
				condition: "exists(.seconds)"
			}
			latency_metrics: {
				type:   "log_to_metric"
				inputs: ["timed"]
				metrics: [{type: "histogram", field: "seconds", name: "journey_moment_seconds", tags: {journey: "{{ journey }}", moment: "{{ moment }}"}}]
			}
		}
		// The throttle's own count of what it dropped, exported beside the
		// journeys' series as journey_telemetry_throttled_total.
		sources: collector: {
			type:            "internal_metrics"
			scrape_interval_secs: 15
		}
		transforms: throttled: {
			type:   "filter"
			inputs: ["collector"]
			condition: ".name == \"component_discarded_events_total\" && .tags.component_id == \"per_session\""
		}
		transforms: throttled_named: {
			type:   "remap"
			inputs: ["throttled"]
			source: ".name = \"journey_telemetry_throttled_total\"\ndel(.namespace)\n.tags = {}"
		}
		sinks: metrics: {
			type:    "prometheus_exporter"
			inputs:  ["run_metrics", "moment_metrics", "latency_metrics", "throttled_named"]
			address: "0.0.0.0:9598"
			// A series not updated within this is dropped from the export, which
			// would read a quiet journey's counters as gaps across its budget
			// window: keep them as long as the window itself.
			flush_period_secs: J._days * 86400
			// The latency SLIs' boundaries among a general spread, so each `le`
			// a rule reads is a bucket that exists.
			// Floats throughout: list.Contains holds an int 1 apart from a parsed
			// 1.0, and a "1s" target would export its boundary twice.
			let slo = [for x in J.buckets {strconv.ParseFloat(x, 64)}]
			buckets: list.Sort(list.Concat([
				[for b in [0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0] if !list.Contains(slo, b) {b}],
				slo,
			]), list.Ascending)
		}
	}

	// The collector's own unit tests, run by `vector test` beside it: what
	// each journey's first and last moments map to, how a reduced run is named,
	// and that a redelivered event counts once. The VRL above is checked by
	// executing it, not by reading it.
	_event: {
		session: "s"
		trace:   "00-t-s-01"
		type:    "gesture"
		outcome: "ok"
		ms:      40
		...
	}
	collectorTests: tests: list.Concat([
		[for k in _mark if k.step == 0 || k.last {
			let p = strings.SplitN(k.moment, ".", 2)
			name: "\(k.moment) is step \(k.step) of \(k.journey)"
			inputs: [{insert_at: "moments", type: "log", log_fields: _event & {screen: p[0], gesture: p[1]}}]
			outputs: [{
				extract_from: "moments"
				conditions: [{type: "vrl", source: ".journey == \"\(k.journey)\" && .step == \(k.step) && .started == \(k.step == 0) && .closed == \(k.last) && .seconds == 0.04"}]
			}]
		}],
		[for c in [
			{name: "a run from its first moment to its last ok is good", fields: {started: true, closed: true, bad: false}, run: "good"},
			{name: "a run closed by a refused or failed moment is bad", fields: {started: true, closed: true, bad: true}, run: "bad"},
			{name: "a run idle past its window is abandoned", fields: {started: true, closed: false, bad: false}, run: "abandoned"},
			{name: "a run begun past its first moment is unstarted", fields: {started: false, closed: true, bad: false}, run: "unstarted"},
		] {
			name: c.name
			inputs: [{insert_at: "ended", type: "log", log_fields: c.fields & {journey: "j", late: false}}]
			outputs: [{extract_from: "ended", conditions: [{type: "vrl", source: ".run == \"\(c.run)\""}]}]
		}],
		[{
			name: "a run a late refusal opened is no run"
			inputs: [{insert_at: "ended", type: "log", log_fields: {journey: "j", late: true, started: false, closed: true, bad: true}}]
			no_outputs_from: ["ended"]
		}, {
			name: "a gesture that is no moment of any journey is dropped"
			inputs: [{insert_at: "moments", type: "log", log_fields: _event & {screen: "nowhere", gesture: "nothing"}}]
			no_outputs_from: ["moments"]
		}],
	])

	// One Grafana row per journey, each panel its journey's own PromQL with its
	// own budget in it: no variable or recording rule to resolve, so the
	// dashboard reads the same in a local VictoriaMetrics and in Managed
	// Service for Prometheus. Named for the app, as several apps' dashboards
	// share one Grafana.
	_names: list.SortStrings([for n, _ in J.spec {n}])
	_rowHeight: 14
	dashboard: {
		uid:           "journeys-\(J.app)"
		title:         "\(J.title) journeys"
		tags: ["journeys", J.app]
		schemaVersion: 39
		time: {from: "now-24h", to: "now"}
		refresh: "1m"
		templating: list: [{
			name:  "datasource"
			type:  "datasource"
			query: "prometheus"
		}]
		let ds = {type: "prometheus", uid: "${datasource}"}
		// Grafana colours a panel's noValue with the base step, so the base is
		// neutral and red starts below any budget a journey can overspend.
		let budgetSteps = {mode: "absolute", steps: [{color: "text", value: null}, {color: "red", value: -1e9}, {color: "orange", value: 0.2}, {color: "green", value: 0.5}]}
		panels: list.Concat([for i, n in _names
			let j = J.spec[n]
			let top = i * _rowHeight
			let base = i * 10
			let avail = [for s in _slis if s.journey == n if s.kind == "availability" {s}][0]
			let lat = [for s in _slis if s.journey == n if s.kind == "latency" {s}]
			let sel = "journey=\"\(n)\"" {
			[
				{id: base + 1, type: "row", title: "\(n) — \(j.moments[0]) → \(j.moments[len(j.moments)-1]) (SLO \(j.slo.availability)%)", gridPos: {x: 0, y: top, w: 24, h: 1}, collapsed: false, panels: []},
				{
					id: base + 2, type: "stat", title: "Success rate (\(J.window))", datasource: ds
					gridPos: {x: 0, y: top + 1, w: 5, h: 5}
					description: "Runs that reached \(j.moments[len(j.moments)-1]) of the runs the reader finished or the app failed; the target is \(j.slo.availability)%."
					fieldConfig: defaults: {unit: "percentunit", decimals: 3, noValue: "no runs", thresholds: {mode: "absolute", steps: [{color: "red", value: null}, {color: "green", value: j.slo.availability / 100}]}}
					targets: [{refId: "A", expr: "1 - (\(_ratio["\(n)/availability/\(J.window)"]))"}]
				},
				{
					id: base + 3, type: "stat", title: "Error budget left", datasource: ds
					gridPos: {x: 5, y: top + 1, w: 5, h: 5}
					fieldConfig: defaults: {unit: "percentunit", min: 0, max: 1, noValue: "no runs", thresholds: budgetSteps}
					targets: [{refId: "A", expr: "1 - (\(_ratio["\(n)/availability/\(J.window)"])) / \(avail.budget)"}]
				},
				{
					id: base + 4, type: "stat", title: "Burn rate 1h", datasource: ds
					gridPos: {x: 10, y: top + 1, w: 4, h: 5}
					fieldConfig: defaults: {unit: "x", noValue: "no runs", thresholds: {mode: "absolute", steps: [{color: "green", value: null}, {color: "orange", value: 1}, {color: "red", value: 6}]}}
					targets: [{refId: "A", expr: "(\(_ratio["\(n)/availability/1h"])) / \(avail.budget)"}]
				},
				{
					id: base + 5, type: "stat", title: "Moment latency p95 (\(J.window))", datasource: ds
					gridPos: {x: 14, y: top + 1, w: 5, h: 5}
					fieldConfig: defaults: {unit: "s", decimals: 2, noValue: "no timings"}
					targets: [{refId: "A", expr: "histogram_quantile(0.95, sum by (le) (increase(journey_moment_seconds_bucket{\(sel)}[\(J.window)])))"}]
				},
				{
					id: base + 6, type: "stat", title: "Latency budget left", datasource: ds
					gridPos: {x: 19, y: top + 1, w: 5, h: 5}
					if len(lat) > 0 {
						description: "Moments under \(j.slo.latency.under): the target is \(j.slo.latency.percent)%."
						fieldConfig: defaults: {unit: "percentunit", min: 0, max: 1, noValue: "no timings", thresholds: budgetSteps}
						targets: [{refId: "A", expr: "1 - (\(_ratio["\(n)/latency/\(J.window)"])) / \(lat[0].budget)"}]
					}
					if len(lat) == 0 {
						fieldConfig: defaults: {noValue: "no latency SLO", color: {mode: "fixed", fixedColor: "text"}}
						targets: []
					}
				},
				{
					id: base + 7, type: "timeseries", title: "Runs by outcome", datasource: ds
					gridPos: {x: 0, y: top + 6, w: 8, h: 8}
					fieldConfig: defaults: {unit: "short", custom: {drawStyle: "bars", stacking: mode: "normal"}}
					targets: [{refId: "A", expr: "sum by (outcome) (increase(journey_runs_total{\(sel)}[1h]))", legendFormat: "{{outcome}}", interval: "1h"}]
				},
				{
					id: base + 8, type: "timeseries", title: "Moment latency p50 / p95", datasource: ds
					gridPos: {x: 8, y: top + 6, w: 8, h: 8}
					fieldConfig: defaults: unit: "s"
					targets: [
						{refId: "A", expr: "histogram_quantile(0.5, sum by (le) (increase(journey_moment_seconds_bucket{\(sel)}[1h])))", legendFormat: "p50", interval: "1h"},
						{refId: "B", expr: "histogram_quantile(0.95, sum by (le) (increase(journey_moment_seconds_bucket{\(sel)}[1h])))", legendFormat: "p95", interval: "1h"},
					]
				},
				{
					id: base + 9, type: "timeseries", title: "Failed moments", datasource: ds
					gridPos: {x: 16, y: top + 6, w: 8, h: 8}
					fieldConfig: defaults: unit: "short"
					targets: [{refId: "A", expr: "sum by (moment, outcome) (increase(journey_moments_total{\(sel),outcome=~\"refused|failed\"}[1h]))", legendFormat: "{{moment}} {{outcome}}", interval: "1h"}]
				},
			]
		}])
	}

	// The program's own checks, unified as `loop: surface: checks:
	// journeys.checks`.
	checks: {
		"journeys": {
			verb: "lint"
			cmds: ["promtool check rules observability/journeys.rules.yaml"]
			note: "the journeys' SLO rules parse as Prometheus rules, every expression included"
		}
		// Vector's own binary, a host tool, executes the run assembly.
		"journeys-collector": {
			verb: "lint"
			cmds: ["vector test observability/journeys.collector.yaml observability/journeys.collector.test.yaml"]
			note: "the collector's run assembly, executed by Vector against its own unit tests"
		}
	}

	out: {
		"journeys.rules.yaml":     rules
		"journeys.collector.yaml": collector
		"journeys.collector.test.yaml": collectorTests
		"journeys.dashboard.json": dashboard
		"journeys.alerts.json":    alertPolicies
	}
}
