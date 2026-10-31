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
// a handler by its module or a form by its id, else its action and entity
// (omnishell's docs/telemetry.md).
// The gesture keeps a form id's own case: `id="newTodo"` reports `newTodo`.
#JourneyMoment: =~"^[a-z][a-z0-9_-]*\\.[A-Za-z0-9_-]+$"

// The collector's image, as pronto's observability stack pins Vector.
#JourneysVector: "timberio/vector:0.43.0-alpine"

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

#Journeys: J={
	// Each screen's gestures, derived from its markup by the plugin's generate
	// step (journeys_gestures.cue): what a moment must name.
	gestures: [string]: [...string]
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
	// The ratio windows, the budget window once even where it is one of the
	// burn windows, so no record is declared twice.
	_ratioWindows: list.Concat([_journeysWindows, [if !list.Contains(_journeysWindows, J.window) {J.window}]])

	_violations: list.Concat([
		[for n, j in J.spec for m in j.moments
			let p = strings.Split(m, ".")
			if J.gestures[p[0]] == _|_ {
				"journey \(n) moment \(m) names no screen \(p[0])"
			}],
		[for n, j in J.spec for m in j.moments
			let p = strings.Split(m, ".")
			if J.gestures[p[0]] != _|_
			if !list.Contains(J.gestures[p[0]], p[1]) {
				"journey \(n) moment \(m) names no gesture \(p[1]) on screen \(p[0]); it has \(strings.Join(J.gestures[p[0]], ", "))"
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

	// vmalert's rule file, one group per journey.
	rules: groups: [for n, j in J.spec {
		name:     "journey-\(n)"
		interval: "30s"
		rules: list.Concat([
			[for s in _slis if s.journey == n {
				record: "journey:\(s.kind)_budget"
				expr:   "vector(\(s.budget))"
				labels: journey: n
			}],
			[for s in _slis if s.journey == n for w in _ratioWindows {
				record: "journey:\(s.kind)_errors:ratio_rate\(w)"
				expr:   (s.errors & {"w": w}).expr
				labels: journey: n
			}],
			[for s in _slis if s.journey == n for b in _journeysBurns
				let factor = strconv.FormatFloat(math.Round(b.spend*_days*24/b.hours*1000)/1000, 103, -1, 64) {
				alert: "Journey\(_journeysTitle[s.kind])Burn\(b.name)"
				expr:  "journey:\(s.kind)_errors:ratio_rate\(b.long){journey=\"\(n)\"} > \(factor) * \(s.budget) and journey:\(s.kind)_errors:ratio_rate\(b.short){journey=\"\(n)\"} > \(factor) * \(s.budget)"
				for:   "2m"
				labels: {journey: n, owner: s.owner, severity: b.severity}
				annotations: summary: "\(n) is spending its \(s.kind) budget at \(factor)× (\(strconv.FormatFloat(b.spend*100, 103, -1, 64))% of \(J.window) in \(b.long))"
			}],
			// A journey no run reaches reads as no data, never as healthy: a
			// collector down, a release without telemetry, an app with nowhere to
			// post all say so here rather than in a green dashboard. The exporter
			// keeps a quiet counter for the whole window, so absence alone would
			// miss a collector that is up and hears nothing: no increase is no run.
			[{
				alert: "JourneyNoData"
				expr:  "(sum(increase(journey_runs_total{journey=\"\(n)\"}[1h])) or vector(0)) == 0"
				for:   "15m"
				labels: {journey: n, owner: j.owner, severity: "ticket"}
				annotations: summary: "\(n) has reported no run for an hour: its SLO is measuring nothing"
			}],
		])
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

	// One Grafana row per journey, repeated over the `journey` variable.
	dashboard: {
		uid:           "pronto-journeys"
		title:         "Journeys"
		schemaVersion: 39
		time: {from: "now-6h", to: "now"}
		refresh: "10s"
		templating: list: [{
			name:  "datasource"
			type:  "datasource"
			query: "prometheus"
		}, {
			name:       "journey"
			type:       "query"
			datasource: {type: "prometheus", uid: "${datasource}"}
			query:      "label_values(journey:availability_budget, journey)"
			multi:      true
			includeAll: true
			current: {text: "All", value: "$__all"}
		}]
		let ds = {type: "prometheus", uid: "${datasource}"}
		// Grafana colours a panel's noValue with the base step, so the base is
		// neutral and red starts below any budget a journey can overspend.
		let budgetSteps = {mode: "absolute", steps: [{color: "text", value: null}, {color: "red", value: -1e9}, {color: "orange", value: 0.2}, {color: "green", value: 0.5}]}
		panels: [
			{id: 1, type: "row", title: "$journey", repeat: "journey", gridPos: {x: 0, y: 0, w: 24, h: 1}, collapsed: false, panels: []},
			{
				id: 2, type: "stat", title: "Availability (\(J.window))", datasource: ds
				gridPos: {x: 0, y: 1, w: 6, h: 5}
				// Neutral: each journey has its own target, so the budget beside it
				// carries the colour.
				fieldConfig: defaults: {unit: "percentunit", decimals: 3, color: {mode: "fixed", fixedColor: "text"}}
				targets: [{refId: "A", expr: "1 - journey:availability_errors:ratio_rate\(J.window){journey=\"$journey\"}"}]
			},
			{
				id: 3, type: "stat", title: "Error budget left", datasource: ds
				gridPos: {x: 6, y: 1, w: 6, h: 5}
				fieldConfig: defaults: {unit: "percentunit", min: 0, max: 1, thresholds: budgetSteps}
				targets: [{refId: "A", expr: "1 - journey:availability_errors:ratio_rate\(J.window){journey=\"$journey\"} / on(journey) journey:availability_budget"}]
			},
			{
				id: 4, type: "stat", title: "Burn rate 1h", datasource: ds
				gridPos: {x: 12, y: 1, w: 6, h: 5}
				fieldConfig: defaults: {unit: "x", thresholds: {mode: "absolute", steps: [{color: "green", value: null}, {color: "orange", value: 1}, {color: "red", value: 6}]}}
				targets: [{refId: "A", expr: "journey:availability_errors:ratio_rate1h{journey=\"$journey\"} / on(journey) journey:availability_budget"}]
			},
			{
				id: 5, type: "stat", title: "Latency budget left", datasource: ds
				gridPos: {x: 18, y: 1, w: 6, h: 5}
				fieldConfig: defaults: {unit: "percentunit", min: 0, max: 1, noValue: "no latency SLO", thresholds: budgetSteps}
				targets: [{refId: "A", expr: "1 - journey:latency_errors:ratio_rate\(J.window){journey=\"$journey\"} / on(journey) journey:latency_budget"}]
			},
			{
				id: 6, type: "timeseries", title: "Failed moments", datasource: ds
				gridPos: {x: 0, y: 6, w: 24, h: 8}
				targets: [{refId: "A", expr: "sum by (moment) (increase(journey_moments_total{journey=\"$journey\",outcome=~\"refused|failed\"}[5m]))", legendFormat: "{{moment}}"}]
			},
		]
	}

	// The program's own checks, unified as `loop: surface: checks:
	// journeys.checks`.
	checks: {
		"journeys": {
			verb: "lint"
			cmds: ["promtool check rules observability/journeys.rules.yaml"]
			note: "the journeys' SLO rules parse as Prometheus rules, every expression included"
		}
		// Vector ships no binary for every host, so its own image runs them.
		"journeys-collector": {
			verb: "integrate"
			cmds: ["docker run --rm --volume ($env.PWD | path join observability):/etc/vector:ro \(#JourneysVector) test /etc/vector/journeys.collector.yaml /etc/vector/journeys.collector.test.yaml"]
			note: "the collector's run assembly, executed by Vector against its own unit tests"
		}
	}

	out: {
		"journeys.rules.yaml":     rules
		"journeys.collector.yaml": collector
		"journeys.collector.test.yaml": collectorTests
		"journeys.dashboard.json": dashboard
	}
}
