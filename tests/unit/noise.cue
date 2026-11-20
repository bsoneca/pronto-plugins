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
// An entry at a time (a line of a service's container), as a source gave it.
_n: {
	ts: string
	out: {
		timestamp:   ts
		severity:    "ERROR"
		textPayload: "Error retrieving lease lock: apiserver not ready"
		resource: labels: service_name: "s"
		labels: container_name: "postgres"
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
		{call: "watch.noiseOf", args: [(_at & {container: "x", second: 0, text: "bye"}).out, {r: {container: "x", match: "bye", during: ["shutdown"]}}, ["start", "shutdown"]], expect: "r", why: "one of the entry's phases meets the rule"},
		{call: "watch.noiseOf", args: [(_at & {container: "x", second: 0, text: "bye"}).out, {r: {container: "x", match: "bye", during: ["shutdown"]}}, ["start"]], expect: null, why: "no phase the rule is held to"},
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

	"an entry's hash input does not hold a source tag, so a cursor written before one still matches": {suite: "noise", steps: [
		{call: "watch.hashInput", args: [(_n & {ts: "2026-11-19T19:00:05.100Z"}).out], expect: json.Marshal((_n & {ts: "2026-11-19T19:00:05.100Z"}).out)},
		{call: "watch.hashInput", args: [(_n & {ts: "2026-11-19T19:00:05.100Z"}).out & {source: "node"}], expect: json.Marshal((_n & {ts: "2026-11-19T19:00:05.100Z"}).out), why: "an entry tagged source node hashes as the untagged one did before the tag"},
	]}
	"a --since run counts what it reads, an entry an earlier run counted included": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.000Z"}).out], hashes: ["h1", "h2"], since: true, counted: ["h2"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.000Z"}).out]}},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.000Z"}).out], hashes: ["h1", "h2"], counted: ["h2"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T18:59:00.000Z"}).out]}, why: "a cursor run does not count it twice"},
	]}
	"the cursor is the source's own boundary when a limit cut the read, and a read to now gives the lag before it": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:00:05.100000Z"}).out, (_n & {ts: "2026-11-19T19:00:05.123456Z"}).out], hashes: ["h1", "h2"], reached: "2026-11-19T19:00:05.123456Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:00:05.123456Z", seen: ["h2"]}, why: "verbatim, to the microsecond; the entry in the cursor's own millisecond is read again (the next read starts inclusive), so its hash is kept"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000500Z"}).out, (_n & {ts: "2026-11-19T19:04:59.999999Z"}).out], hashes: ["h1", "h2"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.000Z", seen: ["h1"]}, why: "a read to now commits to - lag in ms; an entry 0.5 ms after it is still read again, so its hash is kept"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000Z"}).out], hashes: ["h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.000Z", seen: ["h1"]}, why: "a node entry (ms) at the cursor's millisecond is read again, so its hash is kept"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.123456Z", "2026-11-19T19:00:05.123Z"], expect: true},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.1234Z", "2026-11-19T19:00:05.123456Z"], expect: false},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05Z", "2026-11-19T19:00:05.000000000Z"], expect: false, why: "equal is not after"},
		{call: "watch.timeAfter", args: ["not a time", "2026-11-19T19:00:05Z"], throws: "an unparseable timestamp", why: "NaN would pass the cursor filter while the run advances"},
	]}
	"seen is a multiset: two identical entries in one ms, one counted, leave one to count; a bad timestamp throws before any state": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000Z"}).out, (_n & {ts: "2026-11-19T19:05:00.000Z"}).out], hashes: ["h1", "h1"], counted: ["h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T19:05:00.000Z"}).out], seen: ["h1", "h1"]}, why: "one saved occurrence skips one entry; the excess goes to triage, and both stay in seen"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "nope"}).out], hashes: ["h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], throws: "an unparseable timestamp"},
		{call: "watch.settleRun", args: [{entries: [], hashes: [], reached: "nope", to: "2026-11-19T19:10:00.000Z", lag: 300000}], throws: "an unparseable timestamp", why: "a reached the sources never gave is no cursor"},
		{call: "watch.settleRun", args: [{entries: [((_n & {ts: "2026-11-19T19:05:00.000Z"}).out & {insertId: "a"}), ((_n & {ts: "2026-11-19T19:05:00.000Z"}).out & {insertId: "b"}), ((_n & {ts: "2026-11-19T19:05:00.000Z"}).out & {insertId: "a"})], hashes: ["h1", "h2", "h1"], counted: ["h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [((_n & {ts: "2026-11-19T19:05:00.000Z"}).out & {insertId: "b"}), ((_n & {ts: "2026-11-19T19:05:00.000Z"}).out & {insertId: "a"})], seen: ["h1", "h2", "h1"]}, why: "the first a is the saved one; b and the second a count, in order"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:00.000Z"}).out], hashes: ["h1"], counted: ["h1", "h1", "h1"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {entries: [], seen: ["h1"]}, why: "more saved than read counts nothing, and seen holds only what this run read"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05Z", "not a time"], throws: "an unparseable timestamp"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.123+00:00", "2026-11-19T19:00:05.123Z"], throws: "an unparseable timestamp", why: "an offset form of the same instant could order differently at the cursor: only Z is read"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05", "2026-11-19T19:00:04Z"], throws: "only RFC 3339 in UTC", why: "no zone is no instant"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.1Z", "2026-11-19T19:00:05.099999999Z"], expect: true, why: "Z at every precision still compares"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.100000Z", "2026-11-19T19:00:05.1Z"], expect: false, why: "the same instant at two precisions is not after"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:06Z", "2026-11-19T19:00:05.999Z"], expect: true},
		{call: "watch.timeAfter", args: ["2026-02-30T00:00:00Z", "2026-03-01T00:00:00Z"], throws: "an unparseable timestamp", why: "Feb 30 would read as 2 March: a date the calendar has not fails the run"},
		{call: "watch.timeAfter", args: ["2026-11-19T24:00:00Z", "2026-11-19T00:00:00Z"], throws: "an unparseable timestamp", why: "hour 24 would roll to the next day"},
		{call: "watch.timeAfter", args: ["2028-02-29T00:00:00.5Z", "2028-02-29T00:00:00Z"], expect: true, why: "a real leap day still reads"},
		{call: "watch.timeAfter", args: ["2026-02-29T00:00:00.5Z", "2026-03-01T00:00:00Z"], throws: "an unparseable timestamp", why: "Feb 29 of a common year, a fraction on it included"},
		{call: "watch.timeAfter", args: ["2016-12-31T23:59:60Z", "2016-12-31T23:59:59Z"], throws: "an unparseable timestamp", why: "a leap second no source writes (Google smears them) fails rather than reading as the next day"},
		{call: "watch.timeAfter", args: ["2026-11-19T19:00:05.1234567890Z", "2026-11-19T19:00:05Z"], throws: "only RFC 3339 in UTC", why: "past nanoseconds is no source's time, and as text it would order wrong"},
		{call: "watch.settleRun", args: [{entries: [], hashes: [], reached: "2026-11-19T19:10:00.000+00:00", to: "2026-11-19T19:10:00.000Z", lag: 300000}], throws: "only RFC 3339 in UTC", why: "where the cursor is decided, an offset form fails before any state"},
	]}
	"a read a limit cut short keeps the saved occurrences it did not meet, so the catch-up counts nothing twice; a read to now prunes them": {suite: "noise", steps: [
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:06:00.000Z"}).out, (_n & {ts: "2026-11-19T19:08:00.000Z"}).out], hashes: ["hA", "hB"], reached: "2026-11-19T19:10:00.000Z", to: "2026-11-19T19:10:00.000Z", lag: 300000}], holds: {committed: "2026-11-19T19:05:00.000Z", seen: ["hA", "hB"]}, why: "the full read counts A and B and keeps both in its overlap"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:05:30.000Z"}).out, (_n & {ts: "2026-11-19T19:06:00.000Z"}).out], hashes: ["hL", "hA"], counted: ["hA", "hB"], reached: "2026-11-19T19:06:00.000Z", to: "2026-11-19T19:40:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T19:05:30.000Z"}).out], committed: "2026-11-19T19:06:00.000Z", seen: ["hA", "hB"]}, why: "Codex on #1531: late lines fill the limit before B; B's saved occurrence is carried, or the next run counts B again"},
		{call: "watch.settleRun", args: [{entries: [(_n & {ts: "2026-11-19T19:06:00.000Z"}).out, (_n & {ts: "2026-11-19T19:08:00.000Z"}).out, (_n & {ts: "2026-11-19T19:30:00.000Z"}).out], hashes: ["hA", "hB", "hC"], counted: ["hA", "hB"], reached: "2026-11-19T19:50:00.000Z", to: "2026-11-19T19:50:00.000Z", lag: 300000}], holds: {entries: [(_n & {ts: "2026-11-19T19:30:00.000Z"}).out], committed: "2026-11-19T19:45:00.000Z", seen: []}, why: "the catch-up counts only C, and a read to now keeps nothing unmet"},
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

	// The shutdown marker a run saw is not read again as new, and the line it explains may come the next run.
	"a shutdown marker an earlier run counted still opens its instance's window for a later line": {suite: "noise", steps: [
		{value: [
			(_at & {container: "electric", second: 0, text: "13:59:12.001 pid=<0.3051.0> [notice] SIGTERM received - shutting down"}).out,
			(_at & {container: "analyst", second: 10, text: "scheduler disconnected: the stream was closed"}).out,
		]},
		{keep: "read"},
		{call: "watch.group", args: [[(_at & {container: "analyst", second: 10, text: "scheduler disconnected: the stream was closed"}).out], _rules & {"scheduler-shutdown": {match: "scheduler disconnected", during: ["shutdown"], why: "a case's own rule: the scheduler drops the stream as the instance stops"}}, _lifecycle]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: null}], why: "the marker was counted by run 1 and is not among run 2's entries: with no context the line is a bug"},
		{call: "watch.group", args: [[(_at & {container: "analyst", second: 10, text: "scheduler disconnected: the stream was closed"}).out], _rules & {"scheduler-shutdown": {match: "scheduler disconnected", during: ["shutdown"], why: "a case's own rule: the scheduler drops the stream as the instance stops"}}, _lifecycle, "$read"]},
		{call: "probe.verdicts", args: ["$"], expect: [{count: 1, noise: "scheduler-shutdown"}], why: "run 2 reads the marker again in the overlap: its window comes from every entry read, only the new line is counted"},
	]}
}
