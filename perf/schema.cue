// Perf: how a pronto app runs on its readers' devices — frame times, long
// animation frames, interactions, the largest paint, layout shift, WebGL
// contexts lost — measured by a host-DOM hatch on every screen, whatever draws
// it. A game may add what only it knows (draw calls, GPU time, its quality
// tier) as a `pronto:perf` event on its screen. From one spec the plugin
// derives the collector that turns the reports into metrics, the vmalert rules
// that burn each SLO's budget, and a Grafana dashboard by GPU and browser.
//
// This file is written into the app's own package (perf_plugin.cue), so every
// name here is prefixed: it sits beside the program's.
package perf

import (
	"encoding/json"
	"list"
	"math"
	"strconv"
	"strings"
)

// The collector's image, and the same Vector for a host launch and the checks
// (the release that ships a macOS binary).
#PerfVector:        "timberio/vector:0.59.0-alpine"
#PerfVectorVersion: "0.59.0"

#PerfDuration: =~"^[0-9]+(\\.[0-9]+)?(ms|s)$"

// "50ms" → "0.05": a boundary as the collector exports it.
_perfSeconds: {
	in: #PerfDuration
	let s = [
		if strings.HasSuffix(in, "ms") {strconv.ParseFloat(strings.TrimSuffix(in, "ms"), 64) / 1000},
		if !strings.HasSuffix(in, "ms") {strconv.ParseFloat(strings.TrimSuffix(in, "s"), 64)},
	][0]
	value: s
	out:   strconv.FormatFloat(s, 103, -1, 64)
}

// What the reporter measures, each a histogram of its own boundaries: the
// reporter buckets with them, so a report is a few counts, never a frame each.
// The SLOs' boundaries join their metric's spread, so each `le` a rule reads is
// a bucket that exists.
_perfSpread: {
	frame:       [0.008, 0.0167, 0.025, 0.0333, 0.05, 0.1, 0.25]
	gpu:         [0.002, 0.004, 0.008, 0.0167, 0.0333, 0.05, 0.1]
	draws:       [25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2000.0, 5000.0]
	interaction: [0.05, 0.1, 0.2, 0.5, 1.0]
	lcp:         [1.0, 2.5, 4.0, 8.0]
	cls:         [0.05, 0.1, 0.25, 0.5]
}
// Each histogram's exported name and the labels it carries. Frames and what a
// game adds are by screen, device class and the game's tier; a page's paint
// and shift by screen and device class.
_perfHistograms: {
	frame:       {name: "perf_frame_seconds", tags: ["screen", "gpu", "browser", "form", "tier"]}
	gpu:         {name: "perf_gpu_seconds", tags: ["screen", "gpu", "browser", "form", "tier"]}
	draws:       {name: "perf_draw_calls", tags: ["screen", "gpu", "browser", "form", "tier"]}
	interaction: {name: "perf_interaction_seconds", tags: ["screen", "gpu", "browser", "form"]}
	lcp:         {name: "perf_lcp_seconds", tags: ["screen", "browser", "form"]}
	cls:         {name: "perf_cls", tags: ["screen", "browser", "form"]}
}
// What a device is reported as: a family, never the renderer string, so a
// label has few values and no device is told apart from its kind.
_perfDims: {
	gpu:     ["apple", "adreno", "mali", "powervr", "intel", "nvidia", "amd", "software", "none", "other"]
	browser: ["chrome", "edge", "firefox", "safari", "samsung", "other"]
	os:      ["android", "ios", "windows", "macos", "linux", "chromeos", "other"]
	form:    ["mobile", "desktop"]
}

_perfBurns: [
	{name: "Fast", long: "1h", short: "5m", hours: 1, spend: 0.02, severity: "page"},
	{name: "Medium", long: "6h", short: "30m", hours: 6, spend: 0.05, severity: "page"},
	{name: "Slow", long: "3d", short: "6h", hours: 72, spend: 0.10, severity: "ticket"},
]
_perfWindows: {
	let all = [for b in _perfBurns for w in [b.short, b.long] {w}]
	[for i, w in all if !list.Contains(list.Slice(all, 0, i), w) {w}]
}
_perfTitle: {frames: "Frames", interaction: "Interaction", context: "Context"}

#Perf: P={
	// The fraction of sessions that report, decided once per tab.
	sample: *1 | number & >0 & <=1
	owner:  *"app" | =~"^[a-z][a-z0-9-]*$"
	// One budget window for every SLO.
	window: *"28d" | =~"^[1-9][0-9]*d$"
	// How many reports one session may post per window before the collector
	// drops the rest. A reporter sends a handful each 30 seconds.
	limit: {
		events:  *120 | int & >0
		seconds: *60 | int & >0
	}
	slo: {
		// Percent of the frames drawn under `under`, across every reader.
		frames: *{percent: 95, under: "50ms"} | null | {
			percent!: number & >0 & <100
			under!:   #PerfDuration
		}
		// Percent of the interactions answered under `under` (INP's measure).
		interaction: *{percent: 75, under: "200ms"} | null | {
			percent!: number & >0 & <100
			under!:   #PerfDuration
		}
		// Percent of sessions that lose no WebGL context: a lost one is a
		// blank game, and Chrome blocks WebGL for a page that loses too many.
		context: *{percent: 99.5} | null | {
			percent!: number & >0 & <100
		}
	}

	_days: strconv.Atoi(strings.TrimSuffix(P.window, "d"))
	_ratioWindows: list.Concat([_perfWindows, [if !list.Contains(_perfWindows, P.window) {P.window}]])

	// Each histogram's boundaries, the SLO's own among them, ascending.
	buckets: {
		for k, spread in _perfSpread {
			let target = [
				if k == "frame" && P.slo.frames != null {[(_perfSeconds & {in: P.slo.frames.under}).value]},
				if k == "interaction" && P.slo.interaction != null {[(_perfSeconds & {in: P.slo.interaction.under}).value]},
				[],
			][0]
			(k): list.Sort(list.Concat([[for b in spread if !list.Contains(target, b) {b}], target]), list.Ascending)
		}
	}
	// The same, as the `le` labels the collector writes.
	_les: {for k, bs in buckets {(k): list.Concat([[for b in bs {strconv.FormatFloat(b, 103, -1, 64)}], ["+Inf"]])}}

	// The SLIs: a PromQL ratio of bad to all over the range `w`.
	_slis: list.Concat([
		[if P.slo.frames != null {
			let le = strings.Replace((_perfSeconds & {in: P.slo.frames.under}).out, ".", "[.]", -1) + "([.]0)?"
			kind:   "frames"
			budget: (100 - P.slo.frames.percent) / 100
			errors: W={w: string, expr: "1 - sum(increase(perf_frame_seconds_bucket{le=~\"\(le)\"}[\(W.w)])) / sum(increase(perf_frame_seconds_count[\(W.w)]))"}
		}],
		[if P.slo.interaction != null {
			let le = strings.Replace((_perfSeconds & {in: P.slo.interaction.under}).out, ".", "[.]", -1) + "([.]0)?"
			kind:   "interaction"
			budget: (100 - P.slo.interaction.percent) / 100
			errors: W={w: string, expr: "1 - sum(increase(perf_interaction_seconds_bucket{le=~\"\(le)\"}[\(W.w)])) / sum(increase(perf_interaction_seconds_count[\(W.w)]))"}
		}],
		[if P.slo.context != null {
			kind:   "context"
			budget: (100 - P.slo.context.percent) / 100
			// Losses per session: a session that loses twice spends twice.
			errors: W={w: string, expr: "(sum(increase(perf_webgl_context_lost_total[\(W.w)])) or vector(0)) / sum(increase(perf_sessions_total[\(W.w)]))"}
		}],
	])

	rules: groups: [{
		name:     "perf"
		interval: "30s"
		rules: list.Concat([
			[for s in _slis {
				record: "perf:\(s.kind)_budget"
				expr:   "vector(\(s.budget))"
				labels: slo: s.kind
			}],
			[for s in _slis for w in _ratioWindows {
				record: "perf:\(s.kind)_errors:ratio_rate\(w)"
				expr:   (s.errors & {"w": w}).expr
				labels: slo: s.kind
			}],
			[for s in _slis for b in _perfBurns
				let factor = strconv.FormatFloat(math.Round(b.spend*_days*24/b.hours*1000)/1000, 103, -1, 64) {
				alert: "Perf\(_perfTitle[s.kind])Burn\(b.name)"
				expr:  "perf:\(s.kind)_errors:ratio_rate\(b.long) > \(factor) * \(s.budget) and perf:\(s.kind)_errors:ratio_rate\(b.short) > \(factor) * \(s.budget)"
				for:   "2m"
				labels: {slo: s.kind, owner: P.owner, severity: b.severity}
				annotations: summary: "\(s.kind) is spending its budget at \(factor)× (\(strconv.FormatFloat(b.spend*100, 103, -1, 64))% of \(P.window) in \(b.long))"
			}],
			// No session reported reads as no data, never as healthy: a
			// collector down, or a release with nowhere to post, say so here.
			[{
				alert: "PerfNoData"
				expr:  "(sum(increase(perf_sessions_total[6h])) or vector(0)) == 0"
				for:   "15m"
				labels: {owner: P.owner, severity: "ticket"}
				annotations: summary: "no session has reported for six hours: the perf SLOs are measuring nothing"
			}],
		])
	}]

	// The collector: Vector, reading the reporter's batches and writing each
	// report as the counters it adds to. A report is validated field by field:
	// a label is one of its few values or none, a count a bounded integer, and
	// anything else is dropped rather than exported.
	let _dimsVrl = strings.Join([for d, vs in _perfDims {
		"d.\(d) = if includes(\(json.Marshal(vs)), .\(d)) { string!(.\(d)) } else { \"other\" }"
	}], "\n")
	let _histVrl = strings.Join([for k, h in _perfHistograms {
		"""
			if .metric == "\(k)" {
				les = \(json.Marshal(_les[k]))
				tags = {\(strings.Join([for t in h.tags {"\"\(t)\": d.\(t)"}], ", "))}
				if length(counts) != length(les) { abort }
				acc = 0
				for_each(les) -> |i, le| {
					c = get(counts, [i]) ?? 0
					c = if is_integer(c) { int!(c) } else { 0 }
					if c < 0 || c > 1000000 { c = 0 }
					acc = acc + c
					out = push(out, {"name": "\(h.name)_bucket", "kind": "incremental", "tags": merge(tags, {"le": le}), "counter": {"value": to_float(acc)}})
				}
				out = push(out, {"name": "\(h.name)_count", "kind": "incremental", "tags": tags, "counter": {"value": to_float(acc)}})
				out = push(out, {"name": "\(h.name)_sum", "kind": "incremental", "tags": tags, "counter": {"value": sum}})
			}
			"""
	}], "\n")
	collector: {
		sources: perf: {
			type:    "http_server"
			address: "0.0.0.0:8687"
			path:    "/perf"
			method:  "POST"
			framing: method: "bytes"
			decoding: codec: "bytes"
		}
		transforms: {
			// A batch is a JSON array; an array at the root is one event each.
			events: {
				type:   "remap"
				inputs: ["perf"]
				source: ". = parse_json!(string!(.message))"
			}
			per_session: {
				type:        "throttle"
				inputs:      ["events"]
				key_field:   "{{ session }}"
				threshold:   P.limit.events
				window_secs: P.limit.seconds
			}
			// A beacon can be delivered twice; each report carries an id of its own.
			once: {
				type:   "dedupe"
				inputs: ["per_session"]
				fields: match: ["session", "id"]
			}
			// Each report, as the counter events it adds to.
			reports: {
				type:          "remap"
				inputs:        ["once"]
				drop_on_abort: true
				source:        """
					d = {}
					\(_dimsVrl)
					d.screen = if is_string(.screen) && match(string!(.screen), r'^[a-z][a-z0-9_-]{0,31}$') { string!(.screen) } else { "other" }
					d.tier = if is_string(.tier) && match(string!(.tier), r'^[a-z0-9-]{1,16}$') { string!(.tier) } else { "none" }
					out = []
					one = {"kind": "incremental", "counter": {"value": 1.0}}
					if .type == "perf.device" {
						out = push(out, merge(one, {"name": "perf_sessions_total", "tags": {"gpu": d.gpu, "browser": d.browser, "os": d.os, "form": d.form}}))
					} else if .type == "perf.context" {
						name = if .event == "restored" { "perf_webgl_context_restored_total" } else { "perf_webgl_context_lost_total" }
						out = push(out, merge(one, {"name": name, "tags": {"gpu": d.gpu, "browser": d.browser, "os": d.os, "screen": d.screen}}))
					} else if .type == "perf.long" {
						n = if is_integer(.count) { to_float!(.count) } else { 0.0 }
						if n <= 0 || n > 100000 { abort }
						out = push(out, {"name": "perf_long_frames_total", "kind": "incremental", "tags": {"screen": d.screen, "gpu": d.gpu, "browser": d.browser, "form": d.form, "tier": d.tier}, "counter": {"value": n}})
					} else if .type == "perf.loaf" {
						source = if is_string(.source) && match(string!(.source), r'^(shell|other|render|hatch-[a-z0-9_-]{1,32})$') { string!(.source) } else { "other" }
						n = if is_integer(.count) { to_float!(.count) } else { 0.0 }
						if n <= 0 || n > 100000 { abort }
						ms = if is_integer(.ms) || is_float(.ms) { to_float!(.ms) } else { -1.0 }
						if ms < 0 || ms > 3600000 { abort }
						tags = {"screen": d.screen, "source": source, "browser": d.browser, "form": d.form}
						out = push(out, {"name": "perf_loaf_total", "kind": "incremental", "tags": tags, "counter": {"value": n}})
						out = push(out, {"name": "perf_loaf_blocking_seconds_total", "kind": "incremental", "tags": tags, "counter": {"value": ms / 1000.0}})
					} else if .type == "perf.hist" {
						counts = if is_array(.counts) { array!(.counts) } else { abort }
						sum = if is_integer(.sum) || is_float(.sum) { to_float!(.sum) } else { -1.0 }
						if sum < 0 || sum > 100000000 { abort }
					\(strings.Replace(_histVrl, "\n", "\n\t", -1))
					}
					if length(out) == 0 { abort }
					. = out
					"""
			}
			counters: {
				type:        "log_to_metric"
				inputs:      ["reports"]
				all_metrics: true
				metrics: []
			}
			// The throttle's own count of what it dropped.
			throttled: {
				type:      "filter"
				inputs:    ["collector"]
				condition: ".name == \"component_discarded_events_total\" && .tags.component_id == \"per_session\""
			}
			throttled_named: {
				type:   "remap"
				inputs: ["throttled"]
				source: ".name = \"perf_reports_throttled_total\"\ndel(.namespace)\n.tags = {}"
			}
		}
		sources: collector: {
			type:                 "internal_metrics"
			scrape_interval_secs: 15
		}
		sinks: metrics: {
			type:    "prometheus_exporter"
			inputs:  ["counters", "throttled_named"]
			address: "0.0.0.0:9599"
			// A quiet series stays exported across the budget window, so a
			// burn reads it rather than a gap.
			flush_period_secs: P._days * 86400
		}
	}

	// The collector's unit tests, run by `vector test` beside it.
	_report: {
		session: "s"
		id:      "r"
		gpu:     *"mali" | string
		browser: "chrome"
		os:      "android"
		form:    "mobile"
		screen:  "play"
		...
	}
	_frameCounts: [for i, _ in _les.frame {[if i == 0 {3}, 1][0]}]
	collectorTests: tests: [{
		name: "a frame histogram is cumulative, ending at its count"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.hist", metric: "frame", tier: "high", counts: _frameCounts, sum: 0.5}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: """
				.name == "perf_frame_seconds_bucket" && .tags.le == "+Inf" && .counter.value == \(len(_les.frame)+2).0 && .tags.gpu == "mali" && .tags.tier == "high" && .tags.screen == "play"
				"""}]
		}]
	}, {
		name: "a histogram with the wrong number of buckets is dropped"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.hist", metric: "frame", counts: [1, 2], sum: 0.1}}]
		no_outputs_from: ["reports"]
	}, {
		name: "a frame histogram's first bucket holds its own count alone"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.hist", metric: "frame", counts: _frameCounts, sum: 0.5}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: ".name == \"perf_frame_seconds_bucket\" && .tags.le == \"0.008\" && .counter.value == 3.0 && .tags.tier == \"none\""}]
		}]
	}, {
		name: "a device is a session, its labels only the families allowed"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.device", gpu: "PowerVR D-Series DXT-48-1536"}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: ".name == \"perf_sessions_total\" && .tags.gpu == \"other\" && .tags.os == \"android\""}]
		}]
	}, {
		name: "a lost context is counted by its GPU family"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.context", event: "lost", gpu: "powervr"}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: ".name == \"perf_webgl_context_lost_total\" && .tags.gpu == \"powervr\" && .counter.value == 1.0"}]
		}]
	}, {
		name: "long animation frames are counted and their blocking time summed by source"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.loaf", source: "hatch-battle", count: 4, ms: 250}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: ".name == \"perf_loaf_blocking_seconds_total\" && .tags.source == \"hatch-battle\" && .counter.value == 0.25"}]
		}]
	}, {
		name: "a source that is no hatch's or the shell's is other"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "perf.loaf", source: "https://elsewhere.example/x.js", count: 1, ms: 60}}]
		outputs: [{
			extract_from: "reports"
			conditions: [{type: "vrl", source: ".tags.source == \"other\""}]
		}]
	}, {
		name: "an unknown report is dropped"
		inputs: [{insert_at: "reports", type: "log", log_fields: _report & {type: "gesture"}}]
		no_outputs_from: ["reports"]
	}]

	// One dashboard, broken down by GPU family and browser.
	dashboard: {
		uid:           "pronto-perf"
		title:         "Performance"
		schemaVersion: 39
		time: {from: "now-24h", to: "now"}
		refresh: "30s"
		let ds = {type: "prometheus", uid: "${datasource}"}
		templating: list: [{
			name:  "datasource"
			type:  "datasource"
			query: "prometheus"
		}, {
			name:       "screen"
			type:       "query"
			datasource: ds
			query:      "label_values(perf_frame_seconds_count, screen)"
			multi:      true
			includeAll: true
			current: {text: "All", value: "$__all"}
		}]
		let budgetSteps = {mode: "absolute", steps: [{color: "text", value: null}, {color: "red", value: -1e9}, {color: "orange", value: 0.2}, {color: "green", value: 0.5}]}
		let sel = "screen=~\"$screen\""
		let q = {
			p: string
			by: string
			metric: string
			expr: "histogram_quantile(\(p), sum by (\(by), le) (rate(\(metric)_bucket{\(sel)}[$__rate_interval])))"
		}
		panels: list.Concat([
			[for i, s in _slis {
				id: 1 + i, type: "stat", title: "\(_perfTitle[s.kind]) budget left (\(P.window))", datasource: ds
				gridPos: {x: i * 6, y: 0, w: 6, h: 4}
				fieldConfig: defaults: {unit: "percentunit", min: 0, max: 1, thresholds: budgetSteps}
				targets: [{refId: "A", expr: "1 - perf:\(s.kind)_errors:ratio_rate\(P.window) / on(slo) perf:\(s.kind)_budget"}]
			}],
			[{
				id: 10, type: "stat", title: "Sessions", datasource: ds
				gridPos: {x: 18, y: 0, w: 6, h: 4}
				targets: [{refId: "A", expr: "sum(increase(perf_sessions_total[$__range]))"}]
			}, {
				id: 11, type: "timeseries", title: "Frame time p95 by GPU", datasource: ds
				gridPos: {x: 0, y: 4, w: 12, h: 8}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: (q & {p: "0.95", by: "gpu", metric: "perf_frame_seconds"}).expr, legendFormat: "{{gpu}}"}]
			}, {
				id: 12, type: "timeseries", title: "Frame time p95 by browser", datasource: ds
				gridPos: {x: 12, y: 4, w: 12, h: 8}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: (q & {p: "0.95", by: "browser", metric: "perf_frame_seconds"}).expr, legendFormat: "{{browser}}"}]
			}, {
				id: 13, type: "bargauge", title: "Long frames per minute by GPU", datasource: ds
				gridPos: {x: 0, y: 12, w: 8, h: 8}
				targets: [{refId: "A", expr: "sum by (gpu) (rate(perf_long_frames_total{\(sel)}[$__range])) * 60", legendFormat: "{{gpu}}"}]
			}, {
				id: 14, type: "bargauge", title: "WebGL contexts lost per session", datasource: ds
				gridPos: {x: 8, y: 12, w: 8, h: 8}
				fieldConfig: defaults: unit: "percentunit"
				targets: [{refId: "A", expr: "sum by (gpu, browser) (increase(perf_webgl_context_lost_total[$__range])) / ignoring(gpu, browser) group_left sum(increase(perf_sessions_total[$__range]))", legendFormat: "{{gpu}} · {{browser}}"}]
			}, {
				id: 15, type: "bargauge", title: "Main-thread blocking by source (long animation frames)", datasource: ds
				gridPos: {x: 16, y: 12, w: 8, h: 8}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: "sum by (source) (increase(perf_loaf_blocking_seconds_total{\(sel)}[$__range]))", legendFormat: "{{source}}"}]
			}, {
				id: 16, type: "timeseries", title: "Draw calls p95 by tier", datasource: ds
				gridPos: {x: 0, y: 20, w: 12, h: 8}
				targets: [{refId: "A", expr: (q & {p: "0.95", by: "tier", metric: "perf_draw_calls"}).expr, legendFormat: "{{tier}}"}]
			}, {
				id: 17, type: "timeseries", title: "GPU time p95 by GPU (games that measure it)", datasource: ds
				gridPos: {x: 12, y: 20, w: 12, h: 8}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: (q & {p: "0.95", by: "gpu", metric: "perf_gpu_seconds"}).expr, legendFormat: "{{gpu}}"}]
			}, {
				id: 18, type: "stat", title: "Interaction p75 (INP)", datasource: ds
				gridPos: {x: 0, y: 28, w: 8, h: 4}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: "histogram_quantile(0.75, sum by (le) (increase(perf_interaction_seconds_bucket{\(sel)}[$__range])))"}]
			}, {
				id: 19, type: "stat", title: "Largest paint p75 (LCP)", datasource: ds
				gridPos: {x: 8, y: 28, w: 8, h: 4}
				fieldConfig: defaults: unit: "s"
				targets: [{refId: "A", expr: "histogram_quantile(0.75, sum by (le) (increase(perf_lcp_seconds_bucket{\(sel)}[$__range])))"}]
			}, {
				id: 20, type: "stat", title: "Layout shift p75 (CLS)", datasource: ds
				gridPos: {x: 16, y: 28, w: 8, h: 4}
				targets: [{refId: "A", expr: "histogram_quantile(0.75, sum by (le) (increase(perf_cls_bucket{\(sel)}[$__range])))"}]
			}, {
				id: 21, type: "piechart", title: "Sessions by GPU", datasource: ds
				gridPos: {x: 0, y: 32, w: 12, h: 8}
				targets: [{refId: "A", expr: "sum by (gpu) (increase(perf_sessions_total[$__range]))", legendFormat: "{{gpu}}"}]
			}, {
				id: 22, type: "piechart", title: "Sessions by browser", datasource: ds
				gridPos: {x: 12, y: 32, w: 12, h: 8}
				targets: [{refId: "A", expr: "sum by (browser) (increase(perf_sessions_total[$__range]))", legendFormat: "{{browser}}"}]
			}],
		])
	}

	// The program's own checks, unified as `loop: surface: checks: perf.checks`.
	checks: {
		"perf": {
			verb: "lint"
			cmds: ["promtool check rules observability/perf.rules.yaml"]
			note: "the perf SLO rules parse as Prometheus rules, every expression included"
		}
		"perf-collector": {
			verb: "lint"
			cmds: [
				"vector validate --no-environment observability/perf.collector.yaml",
				"vector test observability/perf.collector.yaml observability/perf.collector.test.yaml",
			]
			note: "the collector's config is one Vector accepts, and its report validation passes its own unit tests"
		}
	}

	// What the reporter is given: the sample and each histogram's boundaries.
	reporter: {
		sample: P.sample
		buckets: P.buckets
	}

	out: {
		"perf.rules.yaml":          rules
		"perf.collector.yaml":      collector
		"perf.collector.test.yaml": collectorTests
		"perf.dashboard.json":      dashboard
		"perf.reporter.json":       reporter
	}
}
