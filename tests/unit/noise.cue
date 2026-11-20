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

_restart: {
	stop:  "systemd\\[1\\]: Stopping k3s\\.service"
	start: "systemd\\[1\\]: Started k3s\\.service"
	crash: "k3s\\.service: (Main process exited|Failed with result|Scheduled restart job)"
	unit:  "k3s"
	lead:  *5 | int
	tail:  *120 | int
	down:  *300 | int
}
_window: {from: "2026-11-19T18:59:49.000Z", to: "2026-11-19T19:02:09.000Z"}
_done: "2026-11-19T19:10:00Z"
_journal: {
	deliberate: """
		2026-11-19T18:59:54+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:56+00:00 host systemd[1]: Stopped k3s.service - Lightweight Kubernetes.
		2026-11-19T19:00:09+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	slow: """
		2026-11-19T18:59:54+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:56+00:00 host systemd[1]: Stopped k3s.service - Lightweight Kubernetes.
		"""
	crash: """
		2026-11-19T18:59:54+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:55+00:00 host systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
		2026-11-19T19:00:09+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
}
_restartRules: _rules & {"node-restart": {match: "apiserver not ready", during: ["restart"], why: "a case's own rule: the API answers so between k3s's stop and its start"}}
// An "apiserver not ready" line of a service, read from the node or from Cloud Run.
_apiserver: {
	timestamp: string
	service:   string
	node:      bool
	out: {
		"timestamp": timestamp
		severity:    "ERROR"
		textPayload: "Error retrieving lease lock: apiserver not ready"
		resource: labels: service_name: service
		labels: container_name: "postgres"
		if node {source: "node"}
	}
}

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

	// A node's deliberate k3s restart (schema.cue's #Restart), from systemd's journal of 2026-11-19: stopped
	// 18:59:54 UTC, started 19:00:09, so the window is 18:59:49 to 19:02:09 with lead 5 and tail 120.
	"a deliberate restart is a stop with a start within down, no crash in it and NRestarts not risen": {suite: "noise", steps: [
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [_window]},
		{call: "watch.restartWindows", args: [{journal: _journal.slow, activeEnter: "2026-11-19T19:30:00Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [], why: "a stop with no start within down (300 s) opens none"},
		{call: "watch.restartWindows", args: [{journal: _journal.crash, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: null, now: 0}, until: _done}, _restart], expect: [], why: "a crash line in the window, with no baseline for NRestarts"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 1}, until: _done}, _restart], expect: [], why: "NRestarts risen since the last run is a crash restart"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: null}, until: _done}, _restart], expect: [], why: "NRestarts unread: a crash restart cannot be ruled out"},
	]}
	"a window whose tail the journal read does not reach is no window": {suite: "noise", steps: [
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: "2026-11-19T19:02:08Z"}, _restart], expect: [], why: "a second short of start + tail: a crash in the unread second would be missed, so its entries alert"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: "2026-11-19T19:02:09Z"}, _restart], expect: [_window], why: "read to exactly the window's end: complete"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}}, _restart], expect: [], why: "no cutoff said, none is assumed"},
	]}
	"systemctl show's ActiveEnterTimestamp and NRestarts are read from its text": {suite: "noise", steps: [
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=Thu 2026-11-19 19:00:09 UTC\nNRestarts=2"], expect: {activeEnter: "2026-11-19T19:00:09Z", nRestarts: 2}},
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=Thu 2026-11-19 19:00:09 UTC"], expect: {activeEnter: "2026-11-19T19:00:09Z", nRestarts: null}},
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=\nNRestarts=0"], expect: {activeEnter: null, nRestarts: 0}},
	]}
	"the journal is read as far as lead, down and tail say a window can reach": {suite: "noise", steps: [
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart, 1893456000000], expect: {since: "2026-11-19T18:52:55.000Z", until: "2026-11-19T19:12:05.000Z"}, why: "since = from - (tail 120 + down 300 + lead 5); until = to + (lead + down + tail)"},
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart, 1795115160000], expect: {since: "2026-11-19T18:52:55.000Z", until: "2026-11-19T19:06:00.000Z"}, why: "the journal holds nothing past now"},
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart & {lead: 10, tail: 60, down: 100}, 1893456000000], expect: {since: "2026-11-19T18:57:10.000Z", until: "2026-11-19T19:07:50.000Z"}, why: "follows the configured numbers"},
	]}
	"a node's restart window applies to the node's entries, never to a Cloud Run service's": {suite: "noise", steps: [
		{value: [
			(_apiserver & {timestamp: "2026-11-19T19:00:05.100Z", service: "studio-db-1", node: true}).out,
			(_apiserver & {timestamp: "2026-11-19T19:00:05.200Z", service: "studio-builder", node: false}).out,
		]},
		{call: "watch.group", args: ["$", _restartRules, _lifecycle, [_window]]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "node-restart"}, {count: 1, noise: null}]},
	]}
	"a pod's start marker does not hide a node restart from a rule held to it": {suite: "noise", steps: [
		{value: [
			(_at & {container: "-", second: 0, text: "Starting new instance. Reason: AUTOSCALING", level: "INFO"}).out & {source: "node"},
			(_at & {container: "postgres", second: 3, text: "Error retrieving lease lock: apiserver not ready"}).out & {source: "node"},
		]},
		{call: "watch.group", args: ["$", _restartRules, _lifecycle, [{from: "2026-11-02T13:49:55.000Z", to: "2026-11-02T13:52:00.000Z"}]]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "node-restart"}], why: "the entry is in its pod's start phase and in the restart window: the rule held to restart meets it"},
		{call: "watch.noiseOf", args: [(_at & {container: "x", second: 0, text: "a start line"}).out, {r: {match: "start", during: ["shutdown", "restart"], why: "t"}}, ["start", "restart"]], expect: "r", why: "any of a rule's windows, in any of the entry's phases"},
		{call: "watch.noiseOf", args: [(_at & {container: "x", second: 0, text: "a start line"}).out, {r: {match: "start", during: ["shutdown"], why: "t"}}, ["start", "restart"]], expect: null},
	]}
}
