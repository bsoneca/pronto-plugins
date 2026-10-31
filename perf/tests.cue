package perf

import (
	"list"
	"strings"
)

_p: #Perf & {}
_rules: _p.rules.groups[0].rules
_alert: {for r in _rules if r.alert != _|_ {(r.alert): r}}

// Every SLO burns as the workbook's three pairs at 28 days.
framesFast: _alert.PerfFramesBurnFast.expr & "perf:frames_errors:ratio_rate1h > 13.44 * 0.05 and perf:frames_errors:ratio_rate5m > 13.44 * 0.05"
contextSlow: _alert.PerfContextBurnSlow & {labels: {severity: "ticket", slo: "context"}}
interactionMedium: _alert.PerfInteractionBurnMedium.labels.severity & "page"
noData: _alert.PerfNoData.expr & "(sum(increase(perf_sessions_total[6h])) or vector(0)) == 0"
// The frame SLI reads the bucket at its budget, as either exporter spells it.
framesLe: strings.Contains([for r in _rules if r.record != _|_ if r.record == "perf:frames_errors:ratio_rate5m" {r.expr}][0], "le=~\"0[.]05([.]0)?\"") & true

// A budget off the spread joins it, once and in order; the reporter buckets
// with the same boundaries the collector labels.
_odd: #Perf & {slo: frames: {percent: 99, under: "40ms"}}
oddJoins: _odd.buckets.frame & [0.008, 0.0167, 0.025, 0.0333, 0.04, 0.05, 0.1, 0.25]
_whole: #Perf & {slo: interaction: {percent: 75, under: "1s"}}
wholeOnce: len([for b in _whole.buckets.interaction if b == 1 {b}]) & 1
reporterBuckets: _odd.reporter.buckets.frame & _odd.buckets.frame
collectorLabels: strings.Contains(_odd.collector.transforms.reports.source, "les = [\"0.008\",\"0.0167\",\"0.025\",\"0.0333\",\"0.04\",\"0.05\",\"0.1\",\"0.25\",\"+Inf\"]") & true

// An SLO set to null has no series and no alert.
_noContext: #Perf & {slo: context: null}
noContextRules: len([for r in _noContext.rules.groups[0].rules if r.labels.slo != _|_ if r.labels.slo == "context" {r}]) & 0

// The collector: one session's rate capped, a redelivered report counted once,
// every report's labels from its few values.
throttled: _p.collector.transforms.per_session & {type: "throttle", key_field: "{{ session }}", threshold: 120, window_secs: 60}
deduped: _p.collector.transforms.once & {type: "dedupe", fields: match: ["session", "id"]}
metricsShaped: _p.collector.transforms.counters & {type: "log_to_metric", all_metrics: true}
familiesOnly: strings.Contains(_p.collector.transforms.reports.source, "d.gpu = if includes([\"apple\",\"adreno\",\"mali\",\"powervr\",\"intel\",\"nvidia\",\"amd\",\"software\",\"none\",\"other\"], .gpu)") & true
wholeBody: _p.collector.sources.perf.framing.method & "bytes"
seriesKept: _p.collector.sinks.metrics.flush_period_secs & 2419200
throttleExported: list.Contains(_p.collector.sinks.metrics.inputs, "throttled_named") & true

// The host: a seat beside pronto's, the schema in the program's package, the
// app's spec and reporter settings written once.
_h: #Host & {package: "shop"}
seat: strings.HasPrefix(strings.Split(_h.files["pronto/perf.cue"].text, "\n")[1], "package prontoproject") & true
seatOneStep: strings.Contains(_h.files["pronto/perf.cue"].text, "perf route /perf; run-mise exec -- cue export . -e perf.out --out json | perf write") & true
seatTools: strings.Contains(_h.files["pronto/perf.cue"].text, "\"aqua:vectordotdev/vector\":\"0.59.0\"") & true
schemaInPackage: strings.Contains(_h.files["perf_plugin.cue"].text, "\npackage shop\n") & true
seeded: list.SortStrings([for p, f in _h.files if f.seed {p}]) & ["perf_spec.cue", "shell/hatches/perf/config.js"]
_dirs: {for p, _ in _h.files {(strings.Split(p, "/")[0]): true}}
noVetPairs: [for p, _ in _h.files if strings.HasSuffix(p, ".cue") if _dirs[strings.TrimSuffix(p, ".cue")] != _|_ {p}] & []
reporterPosts: strings.Contains(_h.files["shell/hatches/perf/perf.js"].text, "const ENDPOINT = \"/perf\";") & true
reporterMounts: strings.Contains(_h.files["shell/hatches/perf/perf.js"].text, "export default function mount(screen, { signal })") & true
reporterEverywhere: strings.Contains(_h.files["perf_hatch.cue"].text, "code: surface: screens: [!~\"^(\\(strings.Join(_perfOwnHatches, \"|\")))$\"]: hatches: [\"perf\"]") & true
reporterRequired: strings.Contains(_h.files["perf_hatch.cue"].text, "_perfUnreported: [for n, s in code.surface.screens if !list.Contains(s.hatches, \"perf\") {n}] & []") & true
reporterServesConfig: strings.Contains(_h.files["perf_hatch.cue"].text, "files: [\"shell/hatches/perf/perf.js\", \"shell/hatches/perf/config.js\"]") & true
collectorBaked: strings.Contains(_h.files["perf_hatch.cue"].text, "copy: [{srcs: [\"observability/perf.collector.yaml\"], dst: \"/etc/vector/vector.yaml\"}]") & true
collectorPeer: strings.Contains(_h.files["perf_hatch.cue"].text, "code: meta: hostPeers: \"perf-collector\": 8687") & true
// The seeded settings are the defaults' own.
seedSettings: strings.Contains(_h.files["shell/hatches/perf/config.js"].text, "\"frame\":[0.008,0.0167,0.025,0.0333,0.05,0.1,0.25]") & true
stepShipped: strings.Contains(_h.files["perf/perf.nu"].text, "export def route [endpoint: string]") & true
