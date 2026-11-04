// The noise rules (prod-watch/schema.cue) on the lines they were written for, as Bonk Chess's services
// wrote them (2026-10-30 to 11-02), and on the same lines where they are a bug: a rule held to a
// window meets its line in that window alone.
package unit

import pw "github.com/bsoneca/pronto-plugins/prod-watch:prodwatch"

_rules:     pw.prodWatch.noise
_lifecycle: pw.prodWatch.lifecycle

// An entry of instance i1 a number of seconds past 13:50:00, in a container.
_at: {
	text:      string
	container: string
	second:    int
	level:     *"DEFAULT" | string
	out: {
		textPayload: text
		severity:    level
		timestamp:   "2026-11-02T13:\(50+div(second, 60)):\([if mod(second, 60) < 10 {"0"}, ""][0])\(mod(second, 60)).000Z"
		resource: labels: {service_name: "bonk-chess", revision_name: "bonk-chess-00060-c5h"}
		labels: {container_name: container, instanceId: "i1"}
	}
}
_refused:  "analyst: GET /analysis?select=id: error sending request for url (http://127.0.0.1:3000/analysis): client error (Connect): tcp connect error: Connection refused (os error 111)"
_stopping: "13:59:12.007 pid=<0.3298.0> [warning] Electric.StatusMonitor condition failed: :supervisor_processes_ready. Status %{conn: :up, shape: :read_only}"

cases: {
	"every rule says why it is noise, and those held to a window name only start and shutdown": {suite: "noise", steps: [
		{value: [for n, r in _rules if r.why == "" {n}], expect: []},
		{value: [for n, r in _rules if r.during != _|_ for p in r.during if _lifecycle[p] == _|_ {n}], expect: []},
	]}
	"lines that are noise anywhere": {suite: "noise", steps: [
		{call: "watch.noiseOf", args: [(_at & {container: "electric", second: 0, text: "[UNIX-ESSIO] Failed open sctp dynamic library: libsctp.so.1"}).out, _rules], expect: "erlang-sctp"},
		{call: "watch.noiseOf", args: [(_at & {container: "gmp-collector", second: 0, text: "2026-11-01T06:36:58.936Z\twarn\tinternal/starttimemetricadjuster.go:72\tCouldn't get start time for metrics. Using fallback start time.\t{\"error\": \"start_time metric is missing\"}"}).out, _rules], expect: "gmp-start-time"},
		{call: "watch.noiseOf", args: [(_at & {container: "gmp-collector", second: 0, text: "2026-10-30T15:16:41.218Z\terror\tprometheusreceiver/metrics_receiver.go:273\tDiscovery manager failed\t{\"otelcol.signal\": \"metrics\", \"error\": \"context canceled\"}"}).out, _rules], expect: "gmp-discovery-cancelled"},
		{call: "watch.noiseOf", args: [(_at & {container: "auth", second: 0, level: "WARNING", text: "Container terminated on signal 15."}).out, _rules], expect: "scale-down"},
	]}
	"lines no rule meets: a discovery that failed for a reason, a crash, an export that dropped data": {suite: "noise", steps: [
		{call: "watch.noiseOf", args: [(_at & {container: "gmp-collector", second: 0, text: "error\tprometheusreceiver/metrics_receiver.go:273\tDiscovery manager failed\t{\"error\": \"permission denied\"}"}).out, _rules], expect: null},
		{call: "watch.noiseOf", args: [(_at & {container: "auth", second: 0, level: "WARNING", text: "Container terminated on signal 11."}).out, _rules], expect: null},
		{call: "watch.noiseOf", args: [(_at & {container: "gmp-collector", second: 0, text: "error\tinternal/queue_sender.go:50\tExporting failed. Dropping data."}).out, _rules], expect: null},
	]}
	"a neighbour refusing the connection is noise as the instance starts and stops, a bug in between": {suite: "noise", steps: [
		{value: [
			(_at & {container: "-", second: 0, text: "Starting new instance. Reason: AUTOSCALING - Instance started due to configured scaling factors", level: "INFO"}).out,
			(_at & {container: "analyst", second: 2, text: _refused}).out,
			(_at & {container: "analyst", second: 75, text: _refused}).out,
		]},
		{call: "watch.group", args: ["$", _rules, _lifecycle]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "neighbour-away"}, {count: 1, noise: null}], why: "the start window is a minute; the Cloud Run line opens it and is never reported"},
	]}
	"Electric's status monitor and the proxy's closed socket are noise only around SIGTERM": {suite: "noise", steps: [
		{value: [
			(_at & {container: "electric", second: 1, text: "13:59:12.001 pid=<0.3051.0> [notice] SIGTERM received - shutting down"}).out,
			(_at & {container: "electric", second: 0, text: _stopping}).out,
			(_at & {container: "cloud-sql-proxy", second: 2, text: "2026/11/02 13:59:12 proxy server error: accept tcp 127.0.0.1:5432: use of closed network connection"}).out,
			(_at & {container: "analyst", second: 9, text: _refused}).out,
		]},
		{call: "watch.group", args: ["$", _rules, _lifecycle]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "electric-not-ready"}, {count: 1, noise: "cloud-sql-proxy-stopping"}, {count: 1, noise: "neighbour-away"}], why: "the status line comes a second before Electric's own SIGTERM line: containers hear it at once and write in any order"},
	]}
	"the same status line with no SIGTERM near is reported": {suite: "noise", steps: [
		{call: "watch.group", args: [[(_at & {container: "electric", second: 0, text: _stopping}).out], _rules, _lifecycle]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: null}]},
	]}
}
