// pronto-alerts' rules (../../alerts/inbox.js) and its driver (../../alerts/subscriber.ts, on a fake Pub/Sub pull endpoint and a
// fake phone): an incident becomes one line, written to disk before it is acknowledged, told to the phone only when its severity
// is the app's, and never with the labels of its resource, its metric or its condition's query. Every value here is made up.
package unit

// Cloud Monitoring's incident as a Pub/Sub message carries it, with markers where a label could leak.
_incident: {
	st:      *"open" | string
	ended:   *null | int
	id:      *"0.fixture1" | string
	sev:     *"Critical" | string
	started: *1795000000 | number
	policy:  *"Journey: checkout burn" | string
	bare:    *false | bool
	out: {
		version: "1.2"
		incident: {
			incident_id:                id
			scoping_project_id:         "my-project-1"
			scoping_project_number:     123456789012
			url:                        "https://console.cloud.google.com/monitoring/alerting/alerts/\(id)?project=my-project-1"
			started_at:                 started
			ended_at:                   ended
			state:                      st
			resource_id:                ""
			resource_name:              "RESOURCE-NAME-MARKER"
			resource_display_name:      "RESOURCE-NAME-MARKER"
			resource_type_display_name: "Cloud Run Revision"
			resource: {type: "cloud_run_revision", labels: {service_name: "RESOURCE-LABEL-MARKER", location: "RESOURCE-LABEL-MARKER"}}
			metric: {type: "custom.googleapis.com/fixture", displayName: "Fixture", labels: {who: "METRIC-LABEL-MARKER"}}
			observed_value: "1.0"
			policy_name:    policy
			policy_user_labels: [if bare {{}}, {app: "my-app", owner: "sre"}][0]
			documentation: {content: "DOCUMENTATION-MARKER", mime_type: "text/markdown"}
			condition_name: "Checkout burn"
			condition: {name: "projects/my-project-1/alertPolicies/1/conditions/2", displayName: "Checkout burn", conditionPrometheusQueryLanguage: {query: "FILTER-MARKER > 0"}}
			summary:  "SUMMARY-MARKER"
			severity: sev
		}
	}
}

cases: {
	"an open incident is one entry of ten fields, its times in ISO, and nothing of its resource, metric, query or documentation": {suite: "alerts", steps: [
		{call: "alertsrun.message", args: ["m1", (_incident & {}).out]},
		{call: "alerts.entryOf", args: ["$", "fallback-app"], expect: {
			id:       "0.fixture1"
			state:    "open"
			policy:   "Journey: checkout burn"
			display:  "Checkout burn"
			severity: "CRITICAL"
			app:      "my-app"
			owner:    "sre"
			opened:   "2026-11-18T11:06:40Z"
			closed:   null
			url:      "https://console.cloud.google.com/monitoring/alerting/alerts/0.fixture1?project=my-project-1"
		}, why: "exactly these fields"
		},
		{call: "alerts.lineOf", args: ["$"], matches: "^\\{.*\\}\\n$"},
	]}
	"a closed incident has its end": {suite: "alerts", steps: [
		{call: "alertsrun.message", args: ["m2", (_incident & {st: "closed", ended: 1795003600}).out]},
		{call: "alerts.entryOf", args: ["$", "my-app"], holds: {state: "closed", closed: "2026-11-18T12:06:40Z", opened: "2026-11-18T11:06:40Z"}},
	]}
	"the line holds no label of the resource, the metric, the condition's query or the documentation": {suite: "alerts", steps: [
		{call: "alertsrun.message", args: ["m3", (_incident & {}).out]},
		{call: "alerts.entryOf", args: ["$", "my-app"]},
		{call: "alerts.lineOf", args: ["$"]},
		{call: "alertsrun.leaks", args: ["$"], expect: [], why: "none of RESOURCE-LABEL-MARKER, RESOURCE-NAME-MARKER, METRIC-LABEL-MARKER, FILTER-MARKER, DOCUMENTATION-MARKER, SUMMARY-MARKER"},
		{call: "alertsrun.leaks", args: ["RESOURCE-LABEL-MARKER and FILTER-MARKER"], expect: ["RESOURCE-LABEL-MARKER", "FILTER-MARKER"], why: "the check itself finds a marker"},
	]}
	"a policy with no app label takes the subscription's app, and one with no owner has null": {suite: "alerts", steps: [
		{call: "alertsrun.message", args: ["m4", (_incident & {bare: true}).out]},
		{call: "alerts.entryOf", args: ["$", "my-app"], holds: {app: "my-app", owner: null}},
	]}
	"a payload that is no incident is null, so the driver can acknowledge and drop it": {suite: "alerts", steps: [
		{call: "alertsrun.garbage", args: ["g1"]},
		{call: "alerts.entryOf", args: ["$", "my-app"], expect: null},
		{call: "alerts.entryOf", args: [{data: ""}, "my-app"], expect: null},
		{call: "alerts.entryOf", args: [null, "my-app"], expect: null},
	]}
	"a redelivered copy is a duplicate by id and state, and the readers keep one": {suite: "alerts", steps: [
		{call: "alerts.keyOf", args: [{id: "0.a", state: "open"}], expect: "0.a:open"},
		{call: "alerts.isDuplicate", args: [["0.a:open"], {id: "0.a", state: "open"}], expect: true},
		{call: "alerts.isDuplicate", args: [["0.a:open"], {id: "0.a", state: "closed"}], expect: false, why: "closing is its own notification"},
		{call: "alerts.unique", args: [[{id: "0.a", state: "open", n: 1}, {id: "0.b", state: "open", n: 2}, {id: "0.a", state: "open", n: 3}, {id: "0.a", state: "closed", n: 4}]], expect: [{id: "0.a", state: "open", n: 1}, {id: "0.b", state: "open", n: 2}, {id: "0.a", state: "closed", n: 4}]},
		{call: "alerts.parseInbox", args: ["{\"id\":\"1\",\"state\":\"open\"}\n{\"id\":\"1\",\"state\":\"open\"}\n{half a line\n\n{\"id\":\"1\",\"state\":\"closed\"}\n"], expect: [{id: "1", state: "open"}, {id: "1", state: "closed"}], why: "a duplicate and a half-written line are dropped"},
	]}
	"CRITICAL goes to the phone and WARNING does not, and the phone is told the display name and the state only": {suite: "alerts", steps: [
		{call: "alerts.pushes", args: [{severity: "CRITICAL"}, ["CRITICAL"]], expect: true},
		{call: "alerts.pushes", args: [{severity: "WARNING"}, ["CRITICAL"]], expect: false},
		{call: "alerts.pushes", args: [{severity: "WARNING"}, ["CRITICAL", "WARNING"]], expect: true},
		{call: "alerts.ntfyRequest", args: [{display: "Checkout burn", state: "open", id: "0.a", policy: "p", url: "u"}, {url: "https://ntfy.example.com/", topic: "my-app-alerts"}], expect: {url: "https://ntfy.example.com/my-app-alerts", method: "POST", headers: {Priority: "urgent"}, body: "Checkout burn: open"}},
		{call: "alerts.ntfyRequest", args: [{display: "Checkout burn", state: "closed"}, {url: "https://ntfy.example.com", topic: "t"}, "tok"], holds: {headers: {Priority: "default", Authorization: "Bearer tok"}, body: "Checkout burn: closed"}, why: "a token is sent only when there is one"},
	]}
	"rotated inboxes older than seven days go, the day's own and the recent ones stay": {suite: "alerts", steps: [
		{call: "alerts.rotatedName", args: ["my-app", "2026-11-26"], expect: "my-app.2026-11-26.jsonl"},
		{call: "alerts.expired", args: [["my-app.jsonl", "my-app.2026-11-19.jsonl", "my-app.2026-11-20.jsonl", "my-app.2026-11-26.jsonl", "heartbeat", "other.2026-01-01.jsonl"], "2026-11-27"], expect: ["my-app.2026-11-19.jsonl", "my-app.2026-11-20.jsonl", "other.2026-01-01.jsonl"]},
		{call: "alerts.expired", args: [["my-app.jsonl", "my-app.2026-11-21.jsonl"], "2026-11-27"], expect: [], why: "six days is kept"},
	]}
	"the launchd job always runs: KeepAlive, its label, the apps it reads, the log and the variables, escaped": {suite: "alerts", steps: [
		{call: "alerts.plist", args: [{label: "dev.pronto.alerts-inbox", program: "/usr/bin/deno", args: ["run", "-A", "/apps/my-app/alerts/subscriber.ts", "run", "/apps/my-app", "/apps/a&b"], log: "/logs/alerts-inbox.log", env: {PATH: "/usr/bin:/bin", CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto"}}], expect: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key><string>dev.pronto.alerts-inbox</string>\n\t<key>ProgramArguments</key>\n\t<array><string>/usr/bin/deno</string><string>run</string><string>-A</string><string>/apps/my-app/alerts/subscriber.ts</string><string>run</string><string>/apps/my-app</string><string>/apps/a&amp;b</string></array>\n\t<key>RunAtLoad</key><true/>\n\t<key>KeepAlive</key><true/>\n\t<key>ThrottleInterval</key><integer>30</integer>\n\t<key>EnvironmentVariables</key>\n\t<dict><key>PATH</key><string>/usr/bin:/bin</string><key>CLOUDSDK_ACTIVE_CONFIG_NAME</key><string>pronto</string></dict>\n\t<key>StandardOutPath</key><string>/logs/alerts-inbox.log</string>\n\t<key>StandardErrorPath</key><string>/logs/alerts-inbox.log</string>\n\t<key>ProcessType</key><string>Background</string>\n</dict>\n</plist>\n", why: "the plist as it is installed"},
	]}
	"the pull and the acknowledge name the subscription's path": {suite: "alerts", steps: [
		{call: "alerts.subscriptionPath", args: ["my-project-1", "alerts-my-app-inbox"], expect: "projects/my-project-1/subscriptions/alerts-my-app-inbox"},
		{call: "alerts.pullRequest", args: ["https://pubsub.googleapis.com", "projects/p/subscriptions/s"], expect: {url: "https://pubsub.googleapis.com/v1/projects/p/subscriptions/s:pull", body: {maxMessages: 50}}},
		{call: "alerts.ackRequest", args: ["https://pubsub.googleapis.com", "projects/p/subscriptions/s", ["a", "b"]], expect: {url: "https://pubsub.googleapis.com/v1/projects/p/subscriptions/s:acknowledge", body: {ackIds: ["a", "b"]}}},
	]}
	"the driver writes an open and a closed incident, acknowledges only once both are on disk, and tells the phone each CRITICAL state": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{
			batches: [[
				{id: "m1", incident: (_incident & {id: "0.i1"}).out},
				{id: "m2", incident: (_incident & {id: "0.i1", st: "closed", ended: 1795003600}).out},
			]]
		}]},
		{keep: "run"},
		{get: "results.0", expect: {pulled: 2, written: 2, acked: 2, pushed: 2, dropped: 0}},
		{use: "run"},
		{get: "inboxAtAck", expect: [2], why: "both lines were on disk when the acknowledge came in"},
		{use: "run"},
		{get: "calls", expect: ["pull Bearer word1", "ack ack-m1,ack-m2"]},
		{use: "run"},
		{get: "inbox", holds: [{id: "0.i1", state: "open", closed: null}, {id: "0.i1", state: "closed", closed: "2026-11-18T12:06:40Z"}]},
		{use: "run"},
		{get: "told", holds: [{path: "/phone/my-app-alerts", body: "Checkout burn: open", priority: "urgent"}, {path: "/phone/my-app-alerts", body: "Checkout burn: closed", priority: "default"}]},
		{use: "run"},
		{get: "raw"},
		{call: "alertsrun.leaks", args: ["$"], expect: [], why: "the inbox on disk holds none of the payload's labels"},
	]}
	"a redelivered copy is in the inbox twice, once for a reader, and the phone hears it once": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{
			batches: [
				[{id: "m1", incident: (_incident & {id: "0.i2"}).out}],
				[{id: "m1", incident: (_incident & {id: "0.i2"}).out}],
			]
		}]},
		{keep: "run"},
		{get: "results", holds: [{written: 1, pushed: 1}, {written: 1, pushed: 0}]},
		{use: "run"},
		{get: "raw"},
		{call: "alerts.parseInbox", args: ["$"], holds: [{id: "0.i2", state: "open"}], why: "a reader sees one"},
		{use: "run"},
		{get: "told.length", expect: 1},
		{use: "run"},
		{get: "inbox.length", expect: 2, why: "at-least-once delivery shows on disk"},
	]}
	"a WARNING is in the inbox and not on the phone, and a push list that names it sends it": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{batches: [[{id: "m1", incident: (_incident & {id: "0.w1", sev: "Warning"}).out}]]}]},
		{keep: "quiet"},
		{get: "results.0", holds: {written: 1, pushed: 0}},
		{use: "quiet"},
		{get: "told", expect: []},
		{call: "alertsrun.drain", args: [{push: ["CRITICAL", "WARNING"], batches: [[{id: "m1", incident: (_incident & {id: "0.w1", sev: "Warning"}).out}]]}]},
		{get: "results.0", holds: {pushed: 1}},
	]}
	"an app with no phone writes its inbox and tells nobody": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{phone: false, batches: [[{id: "m1", incident: (_incident & {id: "0.i3"}).out}]]}]},
		{get: "results.0", holds: {written: 1, pushed: 0}},
	]}
	"a message that is no incident is acknowledged and dropped, the incident beside it is kept": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{batches: [[{id: "g1", garbage: true}, {id: "m1", incident: (_incident & {id: "0.i4"}).out}]]}]},
		{keep: "run"},
		{get: "results.0", expect: {pulled: 2, written: 1, acked: 2, pushed: 1, dropped: 1}},
		{use: "run"},
		{get: "calls.1", expect: "ack ack-g1,ack-m1", why: "a poison message would come back for ever if left"},
	]}
	"a refused token is fetched again once, and the pull goes through": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{refuseFirst: true, batches: [[{id: "m1", incident: (_incident & {id: "0.i5"}).out}]]}]},
		{keep: "run"},
		{get: "tokens", expect: ["first", "refresh"]},
		{use: "run"},
		{get: "calls.1", expect: "pull Bearer word2", why: "the second try carries the new word"},
		{use: "run"},
		{get: "results.0", holds: {written: 1}},
	]}
	"a 2xx pull, empty too, writes the app's own heartbeat and no inbox": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{batches: [[]]}]},
		{keep: "run"},
		{get: "heartbeat", expect: true},
		{use: "run"},
		{get: "raw", expect: ""},
		{use: "run"},
		{get: "results.0", expect: {pulled: 0, written: 0, acked: 0, pushed: 0, dropped: 0}},
	]}
	"a pull Pub/Sub refuses, or that never gets there, writes no heartbeat": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{fail: 403, batches: [[]]}]},
		{keep: "denied"},
		{get: "heartbeat", expect: false},
		{use: "denied"},
		{get: "errors.0", matches: "403"},
		{call: "alertsrun.drain", args: [{fail: "network", batches: [[]]}]},
		{keep: "down"},
		{get: "heartbeat", expect: false},
		{use: "down"},
		{get: "errors.length", expect: 1},
	]}
	"a rotated day's file that is already there is appended to, never replaced": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{now: "2026-11-27T10:00:00Z", old: {day: "2026-11-26", current: "{\"id\":\"B\"}\n", rotated: "{\"id\":\"A\"}\n"}, batches: [[]]}]},
		{get: "files", holds: {"my-app.2026-11-26.jsonl": "{\"id\":\"A\"}\n{\"id\":\"B\"}\n"}, why: "both days' lines, the earlier first"},
		{call: "alertsrun.drain", args: [{now: "2026-11-27T10:00:00Z", old: {day: "2026-11-26", current: "{\"id\":\"B\"}\n"}, batches: [[]]}]},
		{get: "files", holds: {"my-app.2026-11-26.jsonl": "{\"id\":\"B\"}\n"}, why: "with no file for the day, a rename as before"},
	]}
	"the job's environment is bare, the pronto configuration's, with gcloud's Python as release-cron gives it": {suite: "alerts", steps: [
		{call: "alerts.jobEnv", args: [{env: {PATH: "/x", CLOUDSDK_ACTIVE_CONFIG_NAME: "owners-other-work"}, os: "darwin", home: "/Users/me", gcloud: "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"}], expect: {
			PATH: "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", HOME: "/Users/me", CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto", CLOUDSDK_PYTHON: "/opt/homebrew/bin/python3.13", ALERTS_GCLOUD: "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"
		}, why: "never the caller's PATH or configuration; Homebrew's Python is the macOS default"
		},
		{call: "alerts.jobEnv", args: [{env: {CLOUDSDK_PYTHON: "/pin/python3.12"}, os: "darwin", home: "/h", gcloud: "/g"}], holds: {CLOUDSDK_PYTHON: "/pin/python3.12"}, why: "the caller's Python wins"},
		{call: "alerts.jobEnv", args: [{env: {}, os: "linux", home: "/h", gcloud: "/g"}], expect: {PATH: "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", HOME: "/h", CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto", ALERTS_GCLOUD: "/g"}, why: "elsewhere gcloud finds its own"},
	]}
	"an error that says why a command failed keeps the last lines of its stderr, each cut short": {suite: "alerts", steps: [
		{call: "alerts.tailOf", args: ["a\nb\n\n  c  \nd\ne\nf\ng\n"], expect: "c | d | e | f | g", why: "five lines, blanks and padding gone"},
		{call: "alerts.tailOf", args: ["ERROR: (gcloud.auth.print-access-token) You do not currently have an active account selected.\n", 5, 20], expect: "ERROR: (gcloud.auth.", why: "a long line is cut"},
		{call: "alerts.tailOf", args: [""], expect: ""},
	]}
	"a path is missing when it is not there or its parent is no directory, and any other error is said": {suite: "alerts", steps: [
		{call: "alertsrun.existence", args: [], expect: {there: true, absent: false, belowFile: false, said: "PermissionDenied"}},
	]}
	"a write that takes only part of the bytes goes on from where it stopped, and one that takes none is an error": {suite: "alerts", steps: [
		{call: "alertsrun.shortWrites", args: [{text: "0123456789", most: 3}], expect: {text: "0123456789", calls: 4}, why: "3, 3, 3 and 1 bytes: every byte arrives"},
		{call: "alertsrun.shortWrites", args: [{text: "", most: 3}], expect: {text: "", calls: 0}},
		{call: "alertsrun.stuckWrite", args: [], matches: "^short write: 0 of 3 bytes, then none$", why: "no progress is never taken for done"},
	]}
	"an append after a cut-off line starts a line of its own, so the redelivered record is read": {suite: "alerts", steps: [
		{call: "alertsrun.appended", args: [{before: "{\"id\":\"A\",\"state\":\"open\"}\n{\"id\":\"B\",\"sta", data: "{\"id\":\"C\",\"state\":\"open\"}\n"}], expect: "{\"id\":\"A\",\"state\":\"open\"}\n{\"id\":\"B\",\"sta\n{\"id\":\"C\",\"state\":\"open\"}\n", why: "the fragment keeps its own line"},
		{call: "alerts.parseInbox", args: ["$"], expect: [{id: "A", state: "open"}, {id: "C", state: "open"}], why: "a reader skips the fragment and keeps the record joined to nothing"},
		{call: "alertsrun.appended", args: [{before: "{\"id\":\"A\",\"state\":\"open\"}\n", data: "X\n"}], expect: "{\"id\":\"A\",\"state\":\"open\"}\nX\n", why: "a file that ends in a newline gets no extra one"},
		{call: "alertsrun.appended", args: [{before: null, data: "X\n"}], expect: "X\n", why: "a new file"},
		{call: "alertsrun.appended", args: [{before: "", data: "X\n"}], expect: "X\n", why: "an empty one"},
	]}
	"a redelivery after a cut-off write is in the inbox whole": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{now: "2026-11-27T10:00:00Z", old: {day: "2026-11-27", current: "{\"id\":\"0.i9\",\"sta"}, batches: [[{id: "m1", incident: (_incident & {id: "0.i9"}).out}]]}]},
		{keep: "run"},
		{get: "inbox.length", expect: 1, why: "the fragment is no entry"},
		{use: "run"},
		{get: "raw"},
		{call: "alerts.parseInbox", args: ["$"], holds: [{id: "0.i9", state: "open"}]},
	]}
	"a rotation into a day's file that ends mid-line keeps both days' records apart": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{now: "2026-11-27T10:00:00Z", old: {day: "2026-11-26", current: "{\"id\":\"B\"}\n", rotated: "{\"id\":\"A\""}, batches: [[]]}]},
		{get: "files", holds: {"my-app.2026-11-26.jsonl": "{\"id\":\"A\"\n{\"id\":\"B\"}\n"}},
	]}
	"the heartbeat follows the inbox: a batch that cannot be written leaves it stale, one that is written and acknowledged sets it": {suite: "alerts", steps: [
		{call: "alertsrun.drain", args: [{lockInbox: true, batches: [[{id: "m1", incident: (_incident & {id: "0.i6"}).out}]]}]},
		{keep: "locked"},
		{get: "heartbeat", expect: false, why: "the pull answered, the inbox did not take it"},
		{use: "locked"},
		{get: "errors.length", expect: 1},
		{use: "locked"},
		{get: "calls", expect: ["pull Bearer word1"], why: "no acknowledge: the incident stays with Pub/Sub"},
		{call: "alertsrun.drain", args: [{batches: [[{id: "m1", incident: (_incident & {id: "0.i7"}).out}]]}]},
		{get: "heartbeat", expect: true},
	]}
	"an incident whose time is past what a date holds has no time, and the others of its pull are kept": {suite: "alerts", steps: [
		{call: "alertsrun.message", args: ["m1", (_incident & {started: 1e18}).out]},
		{call: "alerts.entryOf", args: ["$", "my-app"], holds: {opened: null, id: "0.fixture1"}},
		{call: "alertsrun.drain", args: [{batches: [[{id: "m1", incident: (_incident & {id: "0.b1", started: 1e18}).out}, {id: "m2", incident: (_incident & {id: "0.b2"}).out}]]}]},
		{get: "results.0", holds: {pulled: 2, written: 2, acked: 2}},
	]}
}
