// How prod-watch (../../prod-watch/watch.js) names what went wrong: a line's varying parts taken out, a
// traceback's exception and the app's frame, the stitched traceback, the fingerprint, and the
// redaction every sample goes through before it can reach a pull request.
package unit

import pw "github.com/bsoneca/pronto-plugins/prod-watch:prodwatch"

// An entry as Cloud Logging returns it, with only what prod-watch reads.
_entry: {
	text:      string
	service:   *"bonk-chess" | string
	container: *"analyst" | string
	at:        *"2026-11-02T13:59:13.481Z" | string
	instance:  *"i1" | string
	out: {
		textPayload: text
		timestamp:   at
		resource: labels: {service_name: service, revision_name: "\(service)-00060-c5h"}
		labels: {container_name: container, instanceId: instance}
	}
}

// A line as VictoriaLogs returns it for a pod of the node (prodWatch.node), as the query's fields
// give it; extra holds a JSON line's json.* fields.
_vl: {
	msg:       string
	container: *"auth" | string
	pod:       *"brawl-chess-auth-5d9c8b7f4-x7k2p" | string
	level:     *"info" | string
	at:        *"2026-11-13T13:24:04.220153425Z" | string
	extra: {...}
	let t = at
	let m = msg
	let p = pod
	let c = container
	let l = level
	out: {"_time": t, "_msg": m, pod: p, container: c, level: l} & extra
}
_rules:     pw.prodWatch.noise
_lifecycle: pw.prodWatch.lifecycle

cases: {
	"a line loses its timestamp, colour codes, ids, addresses, query values and numbers": {suite: "fingerprint", steps: [
		{call: "watch.normalize", args: ["\u001b[33m13:59:12.058 pid=<0.3298.0> [warning] Electric.StatusMonitor condition failed: :pg_lock_acquired\u001b[0m"], expect: "pid=<…> [warning] Electric.StatusMonitor condition failed: :pg_lock_acquired"},
		{call: "watch.normalize", args: ["2026/11/02 13:59:12 proxy server error: accept tcp 127.0.0.1:5432: use of closed network connection"], expect: "proxy server error: accept tcp <ip>: use of closed network connection"},
		{call: "watch.normalize", args: ["analyst: GET /analysis?select=id&taken_at=lt.2026-11-02T13:57:20Z&limit=5: error sending request for url (http://127.0.0.1:3000/analysis)"], expect: "analyst: GET /analysis?select=…&taken_at=…&limit=…: error sending request for url (http://<ip>/analysis)"},
		{call: "watch.normalize", args: ["game 3f0c9a1e-2b4d-4e8f-9a7b-1c2d3e4f5a6b of player@example.com from 2600:1900:0:2d09::1400 failed after 3 tries"], expect: "game <uuid> of <email> from <ip> failed after N tries"},
		{call: "watch.normalize", args: ["2026-11-01T06:36:58.936Z\twarn\tinternal/starttimemetricadjuster.go:72\tCouldn't get start time for metrics.\t{\"resource\": {\"service.instance.id\": \"56e492b4\"}}"], expect: "warn internal/starttimemetricadjuster.go:N Couldn't get start time for metrics.", why: "a collector's fields after its message vary from line to line"},
	]}
	"a traceback is named by its exception and the app's innermost frame, not a dependency's": {suite: "fingerprint", steps: [
		{value: "Traceback (most recent call last):\n  File \"/app/proxy/server.py\", line 12, in reload\n    await db.find()\n  File \"/app/.venv/lib/python3.13/site-packages/httpx/_client.py\", line 88, in send\n    raise ConnectError(msg)\nhttpx.ConnectError: All connection attempts failed"},
		{keep: "tb"},
		{call: "watch.titleOf", args: ["$tb"], expect: "httpx.ConnectError: All connection attempts failed"},
		{call: "watch.frameOf", args: ["$tb"], expect: "proxy/server.py:reload"},
	]}
	"a traceback all in a dependency is named by its innermost frame, from the dependency's root": {suite: "fingerprint", steps: [
		{call: "watch.frameOf", args: ["Traceback (most recent call last):\n  File \"/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py\", line 9294, in _init\n  File \"/app/.venv/lib/python3.13/site-packages/httpx/_transports/default.py\", line 118, in map_httpcore_exceptions\nhttpx.ConnectError: x"], expect: "_transports/default.py:map_httpcore_exceptions"},
	]}
	"a JS stack is named by its first frame outside the runtime and the dependencies": {suite: "fingerprint", steps: [
		{call: "watch.frameOf", args: ["Error: https://id.example's discovery: 500\n    at ext:deno_fetch/26_fetch.js:1:1\n    at discover (file:///app/oidc.ts:41:11)\n    at async main (file:///app/main.ts:9:3)"], expect: "app/oidc.ts:discover"},
	]}
	"a traceback written a line an entry is stitched back into one, a chained one too, and stops at its exception": {suite: "fingerprint", steps: [
		{value: [
			(_entry & {text: "Traceback (most recent call last):", container: "-"}).out,
			(_entry & {text: "  File \"/app/a.py\", line 1, in f", container: "-", at: "2026-11-02T13:59:13.482Z"}).out,
			(_entry & {text: "KeyError: 'x'", container: "-", at: "2026-11-02T13:59:13.483Z"}).out,
			(_entry & {text: "", container: "-", at: "2026-11-02T13:59:13.484Z"}).out,
			(_entry & {text: "During handling of the above exception, another exception occurred:", container: "-", at: "2026-11-02T13:59:13.485Z"}).out,
			(_entry & {text: "Traceback (most recent call last):", container: "-", at: "2026-11-02T13:59:13.486Z"}).out,
			(_entry & {text: "  File \"/app/b.py\", line 2, in g", container: "-", at: "2026-11-02T13:59:13.487Z"}).out,
			(_entry & {text: "ValueError: y", container: "-", at: "2026-11-02T13:59:13.488Z"}).out,
			(_entry & {text: "INFO: served", container: "-", at: "2026-11-02T13:59:13.489Z"}).out,
			(_entry & {text: "  File \"/app/c.py\", line 3, in h", container: "-", at: "2026-11-02T13:59:13.490Z", instance: "i2"}).out,
		]},
		{call: "watch.stitch", args: ["$"]},
		{keep: "stitched"},
		{get: "length", expect: 3, why: "the two chained tracebacks are one entry; the line after the last exception and another instance's line are their own"},
		{use: "stitched"},
		{get: "0.textPayload", matches: "^Traceback[^]*KeyError[^]*During handling[^]*ValueError: y$"},
	]}
	"one fault on two instances and revisions, with other ids and times, is one fingerprint; another container's is another": {suite: "fingerprint", steps: [
		{call: "watch.keyOf", args: [(_entry & {text: "analyst: GET /analysis?taken_at=lt.2026-11-02T13:57:20Z: error sending request for url (http://127.0.0.1:3000/analysis)"}).out]},
		{keep: "a"},
		{call: "watch.keyOf", args: [(_entry & {text: "analyst: GET /analysis?taken_at=lt.2026-10-30T16:29:35Z: error sending request for url (http://127.0.0.1:3000/analysis)", instance: "i9", at: "2026-10-30T16:31:35Z"}).out]},
		{call: "probe.differs", args: ["$", "$a"], expect: false},
		{call: "watch.keyOf", args: [(_entry & {text: "analyst: GET /analysis?taken_at=lt.2026-11-02T13:57:20Z: error sending request for url (http://127.0.0.1:3000/analysis)", container: "billing"}).out]},
		{call: "probe.differs", args: ["$", "$a"], expect: true},
	]}
	"a browser error the journeys collector logs is one fingerprint across sessions, screens and line numbers; another error or frame is another": {suite: "fingerprint", steps: [
		{call: "watch.keyOf", args: [{jsonPayload: {severity: "ERROR", message: "frontend TypeError: x is not a function", stack_trace: "    at render (/assets/app.js:10:5)", screen: "board"}, resource: labels: {service_name: "bonk-chess"}, labels: container_name: "journeys-collector"}]},
		{keep: "a"},
		{call: "watch.keyOf", args: [{jsonPayload: {severity: "ERROR", message: "frontend TypeError: x is not a function", stack_trace: "    at render (/assets/app.js:88:21)", screen: "shop"}, resource: labels: {service_name: "bonk-chess"}, labels: container_name: "journeys-collector"}]},
		{call: "probe.differs", args: ["$", "$a"], expect: false},
		{call: "watch.keyOf", args: [{jsonPayload: {severity: "ERROR", message: "frontend TypeError: y is not a function", stack_trace: "    at render (/assets/app.js:10:5)"}, resource: labels: {service_name: "bonk-chess"}, labels: container_name: "journeys-collector"}]},
		{call: "probe.differs", args: ["$", "$a"], expect: true},
		{call: "watch.frameOf", args: ["    at render (/assets/app.js:10:5)"], expect: "assets/app.js:render"},
	]}
	"a request is named by its status, method and path, never its query": {suite: "fingerprint", steps: [
		{call: "watch.messageOf", args: [{httpRequest: {status: 500, requestMethod: "POST", requestUrl: "https://bonkchess.com/crud/game?select=id&owner=eq.3f0c9a1e"}}], expect: "HTTP 500 POST /crud/game"},
	]}
	"a sample keeps what went wrong and loses every secret, address, id and personal detail": {suite: "fingerprint", steps: [
		{call: "watch.redact", args: ["login of ana.souza@example.com from 177.40.21.150 with Authorization: Bearer abc.def.ghi failed"], expect: "login of <email> from <ip> with Authorization: <redacted> failed"},
		{call: "watch.redact", args: ["token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl&next=/"], expect: "token=<redacted>&next=/"},
		{call: "watch.redact", args: ["{\"display_name\":\"Ana Souza\",\"phone\":\"+55 11 98765-4321\",\"game\":\"3f0c9a1e-2b4d-4e8f-9a7b-1c2d3e4f5a6b\"}"], expect: "{\"display_name\":<redacted>,\"phone\":<redacted>,\"game\":\"<uuid>\"}"},
		{call: "watch.redact", args: ["call me at +55 11 98765-4321, key sk_live_\("Fake0Key9Not")\("Real7Abc2Xyz")"], expect: "call me at <phone>, key <token>"},
		{call: "watch.redact", args: ["Electric.StatusMonitor condition failed: :snapshot_connection_pool_ready"], expect: "Electric.StatusMonitor condition failed: :snapshot_connection_pool_ready", why: "a long name with no digit is no token"},
	]}
	"a node's JSON lines are entries with their level as severity, their error beside the message, and only a warning or worse is kept": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "handled request", container: "caddy", level: "info", extra: {"json.msg": "handled request"}}).out,
			(_vl & {msg: "upstream unreachable", container: "caddy", level: "error", at: "2026-11-13T13:24:05.000000000Z", extra: {"json.msg": "upstream unreachable", "json.error": "dial tcp 10.42.0.9:8080: connect: connection refused", "json.stack_trace": "    at proxy (/app/proxy.js:10:5)"}}).out,
			(_vl & {msg: "slow", container: "caddy", level: "warn", at: "2026-11-13T13:24:06.000000000Z", extra: {"json.msg": "slow", "json.stack": ""}}).out,
		]},
		{call: "watch.logEntries", args: ["$", {}]},
		{keep: "es"},
		{get: "length", expect: 2},
		{use: "es"},
		{pick: ["0.severity", "0.jsonPayload.message", "0.labels.container_name", "0.resource.labels.service_name", "0.resource.labels.revision_name", "0.labels.instanceId"], expect: ["ERROR", "upstream unreachable: dial tcp 10.42.0.9:8080: connect: connection refused", "caddy", "brawl-chess-auth", "5d9c8b7f4", "brawl-chess-auth-5d9c8b7f4-x7k2p"]},
		{use: "es"},
		{get: "0"},
		{call: "watch.messageOf", args: ["$"], matches: "^upstream unreachable: dial tcp[^]*\\n    at proxy", why: "a JSON entry reads as the collector's does: its message and its stack"},
		{use: "es"},
		{get: "1.severity", expect: "WARNING"},
	]}
	"a node's access log line is a request named by its status, method and path, and one answered below 500 is never kept": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "handled request", container: "caddy", level: "error", extra: {"json.msg": "handled request", "json.status": "502", "json.request.method": "GET", "json.request.uri": "/player/3f0c9a1e?select=id"}}).out,
			(_vl & {msg: "handled request", container: "caddy", level: "error", at: "2026-11-13T13:24:05.000000000Z", extra: {"json.msg": "handled request", "json.status": "404", "json.request.method": "GET", "json.request.uri": "/nope"}}).out,
		]},
		{call: "watch.logEntries", args: ["$", {}]},
		{keep: "es"},
		{get: "length", expect: 1},
		{use: "es"},
		{get: "0"},
		{call: "watch.messageOf", args: ["$"], expect: "HTTP 502 GET /player/3f0c9a1e"},
	]}
	"a 5xx access log line is kept at any level, and the query selects it": {suite: "fingerprint", steps: [
		{value: [(_vl & {msg: "handled request", container: "caddy", level: "info", extra: {"json.msg": "handled request", "json.status": "503", "json.request.method": "GET", "json.request.uri": "/table/1"}}).out]},
		{call: "watch.logEntries", args: ["$", {}]},
		{get: "length", expect: 1},
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess"}], matches: "OR json.status:>=500 OR"},
	]}
	"a JSON line that says it failed is kept at any level, as a plain one is": {suite: "fingerprint", steps: [
		{value: [(_vl & {msg: "connection refused", level: "info", extra: {"json.msg": "connection refused"}}).out, (_vl & {msg: "all good", level: "info", at: "2026-11-13T13:24:05.000000000Z", extra: {"json.msg": "all good"}}).out]},
		{call: "watch.logEntries", args: ["$", {}]},
		{map: {get: "jsonPayload.message"}, expect: ["connection refused"]},
	]}
	"a node's pino level is a string of its number": {suite: "fingerprint", steps: [
		{value: [(_vl & {msg: "boom", level: "50", extra: {"json.msg": "boom"}}).out, (_vl & {msg: "fine", level: "30", at: "2026-11-13T13:24:05.000000000Z", extra: {"json.msg": "fine"}}).out]},
		{call: "watch.logEntries", args: ["$", {}]},
		{map: {get: "severity"}, expect: ["ERROR"]},
	]}
	"a node's database record is read by its own severity and message, a line that is no JSON fails the read": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "record", container: "postgres", pod: "brawl-chess-db-1", level: "info", extra: {"json.msg": "record", "json.record.error_severity": "LOG", "json.record.message": "checkpoint starting: time"}}).out,
			(_vl & {msg: "record", container: "postgres", pod: "brawl-chess-db-1", level: "info", at: "2026-11-13T13:24:05.000000000Z", extra: {"json.msg": "record", "json.record.error_severity": "FATAL", "json.record.message": "remaining connection slots are reserved for roles with the SUPERUSER attribute"}}).out,
		]},
		{call: "watch.logEntries", args: ["$", {}]},
		{keep: "es"},
		{get: "length", expect: 1},
		{use: "es"},
		{pick: ["0.severity", "0.textPayload", "0.resource.labels.service_name"], expect: ["CRITICAL", "remaining connection slots are reserved for roles with the SUPERUSER attribute", "brawl-chess-db-1"]},
		{call: "watch.logEntries", args: ["{\"_time\":\"2026-11-13T13:24:04Z\",\"pod\":\"p-1\"}\ncurl: (28) Operation timed out", {}], throws: "not JSON"},
	]}
	"a node's plain lines are kept by their level, their words or their lifecycle, not for being lines; a container's start opens its window": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "listening on :8080", container: "auth"}).out,
			(_vl & {msg: "2026/11/13 13:24:04 traces export: context deadline exceeded", container: "daprd", level: "error", at: "2026-11-13T13:24:05.000000000Z"}).out,
			(_vl & {msg: "level=warn msg=\"slow query\"", container: "auth", at: "2026-11-13T13:24:06.000000000Z"}).out,
			(_vl & {msg: "[error] pool closed", container: "auth", at: "2026-11-13T13:24:07.000000000Z"}).out,
			(_vl & {msg: "connect failed: Connection refused", container: "auth", at: "2026-11-13T13:24:08.000000000Z"}).out,
			(_vl & {msg: "Container terminated on signal 15.", container: "auth", at: "2026-11-13T13:24:09.000000000Z"}).out,
			(_vl & {msg: "served /table/1", container: "auth", at: "2026-11-13T13:24:10.000000000Z"}).out,
		]},
		{call: "watch.logEntries", args: ["$", {from: "2026-11-13T13:00:00.000Z", lifecycle: _lifecycle, starts: [{pod: "brawl-chess-auth-5d9c8b7f4-x7k2p", deployment: "brawl-chess-auth", hash: "5d9c8b7f4", container: "auth", revision: "4b224f25665c", startedAt: "2026-11-13T13:24:03.000Z"}, {pod: "brawl-chess-auth-5d9c8b7f4-x7k2p", deployment: "brawl-chess-auth", hash: "5d9c8b7f4", container: "old", revision: "x", startedAt: "2026-11-10T13:24:03.000Z"}]}]},
		{keep: "es"},
		{map: {get: "textPayload"}, expect: ["2026/11/13 13:24:04 traces export: context deadline exceeded", "level=warn msg=\"slow query\"", "[error] pool closed", "connect failed: Connection refused", "Container terminated on signal 15.", "Starting new instance. Reason: container started"], why: "listening and served are info lines that say nothing is wrong; a container that started before the window opens none"},
		{use: "es"},
		{map: {get: "severity"}, expect: ["ERROR", "WARNING", "ERROR", "INFO", "INFO", "INFO"]},
	]}
	"a node's stacks are one entry: indented frames, causes and goroutines join their line, a traceback goes to its exception and its chain, another pod's line or a late one does not": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "Error: boom", level: "error"}).out,
			(_vl & {msg: "    at discover (file:///app/oidc.ts:41:11)", level: "info", at: "2026-11-13T13:24:04.221000000Z"}).out,
			(_vl & {msg: "    at async main (file:///app/main.ts:9:3)", level: "info", at: "2026-11-13T13:24:04.222000000Z"}).out,
			(_vl & {msg: "java.lang.IllegalStateException: x", level: "error", at: "2026-11-13T13:25:00.000000000Z"}).out,
			(_vl & {msg: "\tat a.B.c(B.java:1)", at: "2026-11-13T13:25:00.001000000Z"}).out,
			(_vl & {msg: "Caused by: java.io.IOException: y", at: "2026-11-13T13:25:00.002000000Z"}).out,
			(_vl & {msg: "... 12 more", at: "2026-11-13T13:25:00.003000000Z"}).out,
			(_vl & {msg: "Traceback (most recent call last):", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.000000000Z"}).out,
			(_vl & {msg: "  File \"/app/a.py\", line 1, in f", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.001000000Z"}).out,
			(_vl & {msg: "    boom()", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.002000000Z"}).out,
			(_vl & {msg: "KeyError: 'x'", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.003000000Z"}).out,
			(_vl & {msg: "During handling of the above exception, another exception occurred:", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.004000000Z"}).out,
			(_vl & {msg: "Traceback (most recent call last):", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.005000000Z"}).out,
			(_vl & {msg: "  File \"/app/b.py\", line 2, in g", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.006000000Z"}).out,
			(_vl & {msg: "ValueError: y", container: "llm", pod: "pronto-llm-7c9d6b5f8-abcde", at: "2026-11-13T13:26:00.007000000Z"}).out,
			(_vl & {msg: "    at late (file:///app/late.ts:1:1)", level: "info", at: "2026-11-13T13:25:30.000000000Z"}).out,
		]},
		{call: "watch.logEntries", args: ["$", {}]},
		{keep: "es"},
		{get: "length", expect: 3, why: "the JS error, the Java error and the chained traceback; a frame 30 seconds on joins nothing, and is no bug on its own"},
		{use: "es"},
		{get: "0.textPayload", matches: "^Error: boom\\n    at discover[^]*at async main[^]*main.ts:9:3\\)$"},
		{use: "es"},
		{get: "0.textPayload"},
		{call: "watch.frameOf", args: ["$"], expect: "app/oidc.ts:discover"},
		{use: "es"},
		{get: "1.textPayload", matches: "^java.lang.IllegalStateException: x\\n\\tat a.B.c[^]*Caused by: java.io.IOException: y\\n... 12 more$"},
		{use: "es"},
		{get: "2.textPayload", matches: "^Traceback[^]*KeyError: 'x'\\nDuring handling[^]*ValueError: y$"},
		{use: "es"},
		{get: "2.textPayload"},
		{call: "watch.titleOf", args: ["$"], expect: "ValueError: y"},
	]}
	"a node's pods are named by their Deployment and ReplicaSet hash, and their image is the tag or, for latest, the digest": {suite: "fingerprint", steps: [
		{call: "watch.ownerOf", args: ["brawl-chess-auth-5d9c8b7f4-x7k2p"], expect: {deployment: "brawl-chess-auth", hash: "5d9c8b7f4"}},
		{call: "watch.ownerOf", args: ["victoria-logs-0"], expect: {deployment: "victoria-logs-0", hash: ""}},
		{call: "watch.revisionOf", args: ["127.0.0.1:5000/brawl-chess-auth:latest@sha256:48039f6261053525216f15661268793797c7cda51ef6b05c331ed202ad460d35", "127.0.0.1:5000/brawl-chess-auth@sha256:48039f6261053525216f15661268793797c7cda51ef6b05c331ed202ad460d35"], expect: "48039f626105"},
		{call: "watch.revisionOf", args: ["registry.example.com/app:28838831"], expect: "28838831"},
		{call: "watch.revisionOf", args: ["sha256:2a2340bdb53d0940dd83da999a464bcdad173647b72c8336cf7ee0990127f8f7", "docker.io/library/x@sha256:2a2340bdb53d0940dd83da999a464bcdad173647b72c8336cf7ee0990127f8f7"], expect: "2a2340bdb53d", why: "an image that is its digest has no tag"},
		{value: {items: [
			{metadata: {name: "brawl-chess-auth-5d9c8b7f4-x7k2p", ownerReferences: [{kind: "ReplicaSet", name: "brawl-chess-auth-5d9c8b7f4"}]}, status: containerStatuses: [{name: "auth", image: "r/auth:latest", imageID: "r/auth@sha256:48039f6261053525216f15661268793797c7cda51ef6b05c331ed202ad460d35", state: running: startedAt: "2026-11-13T13:24:03Z"}]},
			{metadata: {name: "brawl-chess-crud-6b7d9c5f4-q1w2e", ownerReferences: [{kind: "ReplicaSet", name: "brawl-chess-crud-6b7d9c5f4"}]}, status: containerStatuses: [{name: "crud", image: "r/crud:latest", imageID: "r/crud@sha256:d4aafa388e1fcbd3d582001b4883a0b55c3c8f0a2d30081d2686a08a8c008f69"}]},
			{metadata: {name: "brawl-chess-db-1", ownerReferences: [{kind: "Cluster", name: "brawl-chess-db"}]}, status: containerStatuses: [{name: "postgres", image: "pg:16"}]},
		]}},
		{keep: "list"},
		{call: "watch.podsOf", args: ["$list", ["brawl-chess-auth"]], expect: [{pod: "brawl-chess-auth-5d9c8b7f4-x7k2p", deployment: "brawl-chess-auth", hash: "5d9c8b7f4", container: "auth", revision: "48039f626105", startedAt: "2026-11-13T13:24:03Z"}], why: "the named Deployment's pod only, and a pod a Cluster owns is no Deployment's"},
		{call: "watch.podsOf", args: ["$list"]},
		{get: "length", expect: 2, why: "none named: every Deployment's"},
	]}
	"the revision a node's app is serving is release-cron's last release, and only that app's": {suite: "fingerprint", steps: [
		{call: "watch.releasedOf", args: ["2026-11-13T06:42:27-03:00 brawl-chess failed 2d2a1e9f (the rehearsal failed (exit 1)): 24.4 min\n2026-11-13T08:00:16-03:00 brawl-chess released 28838831 28838831198fcaf67f5afddd8a7e0ab54b35571b: 32.1 min = release 6.0\n2026-11-13T09:00:16-03:00 brawl-chess skipped 074595f2 (nothing changed)\n2026-11-13T09:10:00-03:00 other released 11111111 1111111111111111111111111111111111111111: 1 min\n", "brawl-chess"], expect: {at: "2026-11-13T08:00:16-03:00", short: "28838831", sha: "28838831198fcaf67f5afddd8a7e0ab54b35571b"}},
		{call: "watch.releasedOf", args: ["", "brawl-chess"], expect: null},
		{call: "watch.brt", args: ["2026-11-13T11:00:16Z"], expect: "13/11 08:00 BRT"},
	]}
	"the query asks for the namespace's lines that may be a bug or go on a stack, of the containers and Deployments named, and refuses a name that is no plain word": {suite: "fingerprint", steps: [
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess", containers: ["auth", "crud"], deployments: ["brawl-chess-auth"]}], matches: "^\\{namespace=\"brawl-chess\"\\} container:in\\(\"auth\",\"crud\"\\) pod:~`\\^\\(brawl-chess-auth\\)-\\[a-z0-9\\]\\+-\\[a-z0-9\\]\\+\\$` \\(level:~"},
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess"}], matches: "json.record.error_severity:~`\\^\\(WARNING\\|ERROR\\|FATAL\\|PANIC\\)\\$` OR json.status:>=500 OR _msg", why: "CloudNativePG's records are info at the outer level, with the database's severity inside"},
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess"}], matches: "\\| fields _time,_msg,pod,container,level,json.error[^|]*\\| sort by \\(_time\\)$"},
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess"}, _lifecycle], matches: "OR _msg:~`\\^Starting new instance` OR _msg:~`\\^Shutting down \\.\\*instance\\|SIGTERM\\|\\^Container terminated on signal`\\)", why: "the markers of prodWatch.lifecycle are lines to read, as the plugin's CUE gives them"},
		{call: "watch.logsQuery", args: [{namespace: "brawl-chess"}], matches: "\\|50\\|60\\)\\$`", why: "Vector writes pino's numbers as strings"},
		{call: "watch.logsQuery", args: [{namespace: "x\"} | drop"}], throws: "not a plain name"},
	]}
	"a node's Electric line while its container starts is noise, and the same line an hour on is a bug": {suite: "fingerprint", steps: [
		{value: [
			(_vl & {msg: "13:24:05.058 pid=<0.3298.0> [warning] Electric.StatusMonitor condition failed: :pg_lock_acquired", container: "electric", pod: "brawl-chess-electric-8f6d5c7b9-aaaaa", at: "2026-11-13T13:24:05.000000000Z"}).out,
			(_vl & {msg: "14:24:05.058 pid=<0.3298.0> [warning] Electric.StatusMonitor condition failed: :pg_lock_acquired", container: "electric", pod: "brawl-chess-electric-8f6d5c7b9-aaaaa", at: "2026-11-13T14:24:05.000000000Z"}).out,
		]},
		{call: "watch.logEntries", args: ["$", {from: "2026-11-13T13:00:00.000Z", lifecycle: _lifecycle, starts: [{pod: "brawl-chess-electric-8f6d5c7b9-aaaaa", deployment: "brawl-chess-electric", hash: "8f6d5c7b9", container: "electric", revision: "r", startedAt: "2026-11-13T13:24:03.000Z"}]}]},
		{call: "watch.group", args: ["$", _rules, _lifecycle]},
		{call: "watch.triage", args: ["$", {}, "2026-11-13T15:00:00.000Z"]},
		{get: "report"},
		{pick: ["0.verdict", "0.noise", "1.verdict", "1.noise"], expect: ["new", null, "noise", "electric-not-ready"]},
	]}
}
