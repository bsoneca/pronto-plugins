// The noise rules (prod-watch/schema.cue) on the lines they were written for, as Bonk Chess's services
// wrote them (2026-10-30 to 11-02), and on the same lines where they are a bug: a rule held to a
// window meets its line in that window alone.
package unit

import "encoding/json"
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

// What an app says of the restart: its unit; the patterns, lead, tail and down come from the schema.
_restart: pw.#Restart & {unit: "k3s"}
// What the three patterns were when each app wrote them out (Studio's prod_watch.cue, before they derived).
_restartWritten: {
	stop:  "systemd\\[1\\]: Stopping k3s\\.service"
	start: "systemd\\[1\\]: Started k3s\\.service"
	crash: "k3s\\.service: (Main process exited|Failed with result|Scheduled restart job)"
}
_n: {
	ts:   string
	node: *true | bool
	out: {
		timestamp:   ts
		severity:    "ERROR"
		textPayload: "Error retrieving lease lock: apiserver not ready"
		resource: labels: service_name: "s"
		labels: container_name: "postgres"
		if node {source: "node"}
	}
}
_window: {from: "2026-11-19T18:59:49.000Z", to: "2026-11-19T19:02:09.000Z"}
_done: "2026-11-19T19:10:00Z"
_journal: {
	deliberate: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:56.000995+00:00 host systemd[1]: Stopped k3s.service - Lightweight Kubernetes.
		2026-11-19T19:00:09.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	slow: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:56.000995+00:00 host systemd[1]: Stopped k3s.service - Lightweight Kubernetes.
		"""
	crash: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T18:59:55.000995+00:00 host systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
		2026-11-19T19:00:09.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	precise: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:00:09.900995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	preciseCrash: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:00:09.900995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		2026-11-19T19:02:09.400995+00:00 host systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
		"""
	twice: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:00:09.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		2026-11-19T19:30:00.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:30:10.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	outside: """
		2026-11-19T18:50:00.000995+00:00 host systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:00:09.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	lead: """
		2026-11-19T18:59:50.000995+00:00 host systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
		2026-11-19T19:00:09.000995+00:00 host systemd[1]: Started k3s.service - Lightweight Kubernetes.
		"""
	stopOnly: """
		2026-11-19T18:59:54.000995+00:00 host systemd[1]: Stopping k3s.service - Lightweight Kubernetes...
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
	"every rule says why it is noise, and the shared rules held to a window name only start and shutdown": {suite: "noise", steps: [
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
	"systemctl show's ActiveEnterTimestamp and NRestarts are read from its text, a LoadState as null when unasked": {suite: "noise", steps: [
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=Thu 2026-11-19 19:00:09 UTC\nNRestarts=2"], expect: {loadState: null, activeEnter: "2026-11-19T19:00:09Z", nRestarts: 2}},
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=Thu 2026-11-19 19:00:09 UTC"], expect: {loadState: null, activeEnter: "2026-11-19T19:00:09Z", nRestarts: null}},
		{call: "watch.unitOf", args: ["ActiveEnterTimestamp=\nNRestarts=0"], expect: {loadState: null, activeEnter: null, nRestarts: 0}},
	]}
	"the journal is read as far as lead, down and tail say a window can reach": {suite: "noise", steps: [
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart, 1893456000000], expect: {since: "2026-11-19T18:52:55.000Z", until: "2026-11-19T19:12:05.000Z"}, why: "since = from - (tail 120 + down 300 + lead 5); until = to + (lead + down + tail)"},
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart, 1795115160000], expect: {since: "2026-11-19T18:52:55.000Z", until: "2026-11-19T19:06:00.000Z"}, why: "the journal holds nothing past now"},
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart & {lead: 10, tail: 60, down: 100}, 1893456000000], expect: {since: "2026-11-19T18:57:10.000Z", until: "2026-11-19T19:07:50.000Z"}, why: "follows the configured numbers"},
	]}
	"a first run, a crash outside the window, a counter reset, two restarts, a crash in the lead margin, a start by ActiveEnterTimestamp alone": {suite: "noise", steps: [
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: null, restarts: {was: null, now: 0}, until: _done}, _restart], expect: [_window], why: "first run: no baseline for NRestarts, a clean restart is a window"},
		{call: "watch.restartWindows", args: [{journal: _journal.outside, activeEnter: null, restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [_window], why: "a crash line ten minutes before the stop is not in the window"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: null, restarts: {was: 3, now: 0}, until: _done}, _restart], expect: [_window], why: "NRestarts reset (a reboot): not a rise"},
		{call: "watch.restartWindows", args: [{journal: _journal.twice, activeEnter: null, restarts: {was: 0, now: 0}, until: "2026-11-19T20:00:00Z"}, _restart], expect: [_window, {from: "2026-11-19T19:29:55.000Z", to: "2026-11-19T19:32:10.000Z"}]},
		{call: "watch.restartWindows", args: [{journal: _journal.lead, activeEnter: null, restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [], why: "a crash line 4 s before the stop is inside the lead margin (5 s): the window is not deliberate"},
		{call: "watch.restartWindows", args: [{journal: _journal.stopOnly, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [_window], why: "no start line in the journal read: the unit's ActiveEnterTimestamp is the start"},
	]}
	"a stop pairs with the first journal start after it, never an earlier whole-second ActiveEnterTimestamp": {suite: "noise", steps: [
		{call: "watch.restartWindows", args: [{journal: _journal.precise, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [{from: "2026-11-19T18:59:49.000Z", to: "2026-11-19T19:02:09.900Z"}], why: "the start is 19:00:09.900: the tail ends there + 120 s, not at ActiveEnter's whole second"},
		{call: "watch.restartWindows", args: [{journal: _journal.preciseCrash, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [], why: "a crash at precise start + tail - 0.5 s is in the window: it is no window"},
		{call: "watch.restartPending", args: [{journal: _journal.precise, activeEnter: "2026-11-19T19:00:09Z", until: "2026-11-19T19:02:09.500Z"}, _restart], expect: {from: "2026-11-19T18:59:49.000Z"}, why: "the tail is read to 19:02:09.5, the precise start's ends at .900: still held"},
		{call: "watch.restartWindows", args: [{journal: _journal.stopOnly, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 0, now: 0}, until: _done}, _restart], expect: [_window], why: "ActiveEnterTimestamp alone still pairs"},
	]}
	"a rise of NRestarts voids the windows it rejected until the cursor passes them": {suite: "noise", steps: [
		{call: "watch.completeWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", until: _done}, _restart], expect: [_window]},
		{keep: "rejected"},
		{call: "watch.restartVoids", args: [{voided: [], windows: "$rejected", restarts: {was: 5, now: 6}, committed: "2026-11-19T19:01:00.000Z"}], expect: [_window], why: "run 1: a rise and a completed window, its log page ends before the restart (the cursor is inside the window)"},
		{keep: "voided"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 6, now: 6}, until: _done, voided: "$voided"}, _restart], expect: [], why: "run 2: equal counters, the voided window is still rejected"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 6, now: 6}, until: _done, voided: []}, _restart], expect: [_window], why: "without the void, the same run would accept it"},
		{call: "watch.restartVoids", args: [{voided: "$voided", windows: [], restarts: {was: 6, now: 6}, committed: "2026-11-19T19:01:30.000Z"}], expect: [_window], why: "run 2 ends with the cursor still inside the window: kept"},
		{call: "watch.restartVoids", args: [{voided: "$voided", windows: [], restarts: {was: 6, now: 6}, committed: "2026-11-19T19:02:10.000Z"}], expect: [], why: "run 3: the cursor is past its end: dropped"},
		{call: "watch.restartVoids", args: [{windows: "$rejected", restarts: {was: 6, now: 6}, committed: "2026-11-19T19:01:00.000Z"}], expect: [], why: "no rise and a k3s.json of {nRestarts} alone (no voided): nothing voided"},
		{call: "watch.restartVoids", args: [{windows: "$rejected", restarts: {was: null, now: 6}, committed: "2026-11-19T19:01:00.000Z"}], expect: [], why: "no baseline is no rise"},
		{call: "watch.restartWindows", args: [{journal: _journal.twice, activeEnter: null, restarts: {was: 0, now: 0}, until: "2026-11-19T20:00:00Z", voided: [_window]}, _restart], expect: [{from: "2026-11-19T19:29:55.000Z", to: "2026-11-19T19:32:10.000Z"}], why: "a void rejects only the windows it overlaps"},
	]}
	"a restart not finished at the cutoff holds the cursor at its stop minus lead": {suite: "noise", steps: [
		{call: "watch.restartPending", args: [{journal: _journal.stopOnly, activeEnter: null, until: "2026-11-19T19:00:00Z"}, _restart], expect: {from: "2026-11-19T18:59:49.000Z"}, why: "stopped, no start yet, 6 s down of 300"},
		{call: "watch.restartPending", args: [{journal: _journal.stopOnly, activeEnter: null, until: "2026-11-19T19:10:00Z"}, _restart], expect: null, why: "no start within down: never a window, nothing to wait for"},
		{call: "watch.restartPending", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", until: "2026-11-19T19:02:08Z"}, _restart], expect: {from: "2026-11-19T18:59:49.000Z"}, why: "started, tail not yet read to its end"},
		{call: "watch.restartPending", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", until: _done}, _restart], expect: null, why: "complete"},
		{call: "watch.restartPending", args: [{journal: _journal.twice, activeEnter: null, until: "2026-11-19T19:30:30Z"}, _restart], expect: {from: "2026-11-19T19:29:55.000Z"}, why: "the first is complete, the second's tail is not"},
		{call: "watch.restartPending", args: [{journal: _journal.deliberate, activeEnter: null, until: null}, _restart], expect: null, why: "no cutoff said, none is assumed"},
	]}
	"systemctl show's LoadState is read, and the cutoff is floored to the second": {suite: "noise", steps: [
		{call: "watch.unitOf", args: ["LoadState=loaded\nActiveEnterTimestamp=Thu 2026-11-19 19:00:09 UTC\nNRestarts=2"], expect: {loadState: "loaded", activeEnter: "2026-11-19T19:00:09Z", nRestarts: 2}},
		{call: "watch.unitOf", args: ["LoadState=not-found\nActiveEnterTimestamp=\nNRestarts=0"], expect: {loadState: "not-found", activeEnter: null, nRestarts: 0}},
		{call: "watch.unitOf", args: ["NRestarts=0"], expect: {loadState: null, activeEnter: null, nRestarts: 0}, why: "unread: the driver refuses it"},
		{call: "watch.restartRange", args: ["2026-11-19T19:00:00.000Z", "2026-11-19T19:05:00.000Z", _restart, 1795115160999], expect: {since: "2026-11-19T18:52:55.000Z", until: "2026-11-19T19:06:00.000Z"}, why: "now 19:06:00.999 reads to 19:06:00: the whole second the journal's --until takes"},
	]}
	"an entry's hash input does not hold the driver's source tag, so a cursor written before it still matches": {suite: "noise", steps: [
		{call: "watch.hashInput", args: [(_apiserver & {timestamp: "2026-11-19T19:00:05.100Z", service: "studio-db-1", node: false}).out], expect: json.Marshal((_apiserver & {timestamp: "2026-11-19T19:00:05.100Z", service: "studio-db-1", node: false}).out)},
		{call: "watch.hashInput", args: [(_apiserver & {timestamp: "2026-11-19T19:00:05.100Z", service: "studio-db-1", node: true}).out], expect: json.Marshal((_apiserver & {timestamp: "2026-11-19T19:00:05.100Z", service: "studio-db-1", node: false}).out), why: "the node's entry, tagged source node, hashes as the untagged one did before the tag"},
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

	"the restart's patterns derive from its unit, as the apps wrote them out, and stay overridable": {suite: "noise", steps: [
		{value: {stop: _restart.stop, start: _restart.start, crash: _restart.crash}, expect: _restartWritten},
		{value: (pw.#Restart & {unit: "k3s.io"}).stop, expect: "systemd\\[1\\]: Stopping k3s\\.io\\.service", why: "the unit is quoted, its dot is not a wildcard"},
		{value: (pw.#Restart & {unit: "k3s", stop: "Stopping the lot"}).stop, expect: "Stopping the lot"},
		{value: {lead: _restart.lead, tail: _restart.tail, down: _restart.down}, expect: {lead: 5, tail: 120, down: 300}},
	]}
	"a rise of NRestarts seen while a restart is held is still seen by the run that judges the window": {suite: "noise", steps: [
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: 5, now: 6}, until: "2026-11-19T19:02:08Z"}, _restart], expect: [], why: "run 1: the rise, and the window not yet complete"},
		{call: "watch.restartBaseline", args: [{was: 5, now: 6, hold: {from: "2026-11-19T18:59:49.000Z"}}], expect: 5, why: "the held run leaves the old counter"},
		{keep: "baseline"},
		{call: "watch.restartWindows", args: [{journal: _journal.deliberate, activeEnter: "2026-11-19T19:00:09Z", restarts: {was: "$baseline", now: 6}, until: _done}, _restart], expect: [], why: "run 2: the window is complete, and the rise is still a rise: its entries alert"},
		{call: "watch.restartBaseline", args: [{was: 5, now: 6, hold: null}], expect: 6, why: "with nothing held the counter moves on"},
		{call: "watch.restartBaseline", args: [{was: 5, now: 0, hold: {from: "2026-11-19T18:59:49.000Z"}}], expect: 0, why: "a reset lowers it: a later crash making it 1 stays a rise"},
		{call: "watch.restartBaseline", args: [{was: null, now: 6, hold: {from: "2026-11-19T18:59:49.000Z"}}], expect: null, why: "no earlier counter: none is written"},
	]}
	"a --since run holds nothing back and counts what it reads": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.000Z"}).out], hashes: ["h1", "h2"], hold: {from: "2026-11-19T19:00:00.000Z"}, since: true, counted: ["h2"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.000Z"}).out]}, why: "the held node entry is reported, windows only if complete (restartWindows)"},
	]}
	"a held node entry stays out of the next run's seen unless an earlier run counted it": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [
			(_n & {ts: "2026-11-19T18:59:00.000Z"}).out,
			(_n & {ts: "2026-11-19T19:00:05.000Z"}).out,
			(_n & {ts: "2026-11-19T19:00:06.000Z"}).out,
			(_n & {ts: "2026-11-19T19:00:07.000Z", node: false}).out,
		], hashes: ["h1", "h2", "h3", "h4"], hold: {from: "2026-11-19T19:00:00.000Z"}, counted: ["h3"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], expect: {
			entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:07.000Z", node: false}).out]
			committed: "2026-11-19T19:00:00.000Z"
			seen: ["h3", "h4"]
		}, why: "h2 was never counted, so the next run counts it; h3 was, so it stays known"},
	]}
	"the cursor is the source's own boundary when a limit cut the read, and no hold or lag gives an earlier one": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:00:05.100000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.123456Z"}).out], hashes: ["h1", "h2"], reached: "2026-11-19T19:00:05.123456Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:00:05.123456Z", seen: ["h2"]}, why: "verbatim, to the microsecond; the entry in the cursor's own millisecond is read again (the next read starts inclusive), so its hash is kept"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000500Z"}).out, (_n & {ts: "2026-11-19T19:04:59.999999Z"}).out], hashes: ["h1", "h2"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.000Z", seen: ["h1"]}, why: "a read to now commits to - lag in ms; an entry 0.5 ms after it is still read again, so its hash is kept"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000Z"}).out], hashes: ["h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.000Z", seen: ["h1"]}, why: "a node entry (ms) at the cursor's millisecond is read again, so its hash is kept"},
		{call: "watch.settleRun", args: [{entries: [], hashes: [], hold: {from: "2026-11-19T19:08:00.000Z"}, reached: "2026-11-19T19:05:00.123456Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.123456Z"}, why: "a hold later than the boundary does not move it"},
		{call: "watch.settleRun", args: [{entries: [], hashes: [], hold: {from: "2026-11-19T19:02:00.000Z"}, reached: "2026-11-19T19:05:00.123456Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:02:00.000Z"}, why: "a hold earlier than it does"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.123456Z", "2026-11-19T19:00:05.123Z"], expect: true},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.1234Z", "2026-11-19T19:00:05.123456Z"], expect: false},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05Z", "2026-11-19T19:00:05.000000000Z"], expect: false, why: "equal is not after"},
	]}
	"an entry in its pod's start and shutdown windows at once meets a rule held to shutdown": {suite: "noise", steps: [
		{value: [
			(_at & {container: "-", second: 0, text: "Starting new instance. Reason: AUTOSCALING", level: "INFO"}).out,
			(_at & {container: "-", second: 10, text: "Container terminated on signal 15.", level: "INFO"}).out,
			(_at & {container: "analyst", second: 12, text: "half-stopped: the queue's lease was dropped"}).out,
		]},
		{call: "watch.group", args: ["$", _rules & {"shutdown-only": {match: "half-stopped", during: ["shutdown"], why: "a case's own rule: said only as the instance stops"}}, _lifecycle]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "shutdown-only"}], why: "second 12 is a minute-window start entry and a shutdown-window one: both phases apply"},
	]}
}
