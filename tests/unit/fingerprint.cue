// How prod-watch (../../prod-watch/watch.js) names what went wrong: a line's varying parts taken out, a
// traceback's exception and the app's frame, the stitched traceback, the fingerprint, and the
// redaction every sample goes through before it can reach a pull request.
package unit

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
}
