// The alerts watch (PRONTO-2182; devflow/alerts.ts, its pure rules in devflow/flow.js): an alert policy that is down,
// flapping or left open is a bug on the board, filed once. Fixtures carry policy fields only (name, display name, user
// labels, state, times): no resource or metric labels. `queue.alertsRuns` runs the verb on a fake Cloud Monitoring (two
// pages) and the fake Plane of tests/unit/devflow.js.
package unit

import "list"

_alertRules: {flapOpens: 3, flapCloseMin: 30, staleHours: 24, apps: {battlechess: "brawl-chess", "bonk-chess": "brawl-chess"}}
_alertNow: "2026-11-27T20:00:00Z"
_alertLabels: {app: "battlechess", owner: "bonk-chess", severity: "page"}
// 32 opens in eight hours, a quarter hour apart, each closed five minutes after.
_drops: [for n in list.Range(0, 32, 1) {
	let h = 12 + div(n, 4)
	let m = ["00", "15", "30", "45"][mod(n, 4)]
	let c = ["05", "20", "35", "50"][mod(n, 4)]
	policy: "projects/demo-proj/alertPolicies/1", display: "Bonk Chess: play-a-game JourneyTrafficDrop", labels: _alertLabels, state: "CLOSED"
	openTime: "2026-11-27T\(h):\(m):00Z"
	closeTime: "2026-11-27T\(h):\(c):00Z"
}]

cases: {
	"a policy that opened 32 times in a day is flapping, one open for nine days is stale, one open for ten minutes is an outage, one that opened and closed once is ok": {suite: "devflow", steps: [
		{call: "devflow.alertClass", args: [_drops, _alertNow, _alertRules]}, {pick: ["0.class", "0.opens", "0.app", "length"], expect: ["flapping", 32, "brawl-chess", 1], why: "32 opens beat flapOpens 3; the app label battlechess is mapped to the board's brawl-chess"},
		{call: "devflow.alertClass", args: [[{policy: "projects/demo-proj/alertPolicies/2", display: "Contabo node: no heartbeat for 15 minutes", labels: {app: "contabo-node"}, state: "OPEN", openTime: "2026-11-18T20:00:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.openSince", "0.app"], expect: ["stale", "2026-11-18T20:00:00.000Z", null], why: "open nine days; its app label is mapped to no board app"},
		{call: "devflow.alertClass", args: [[{policy: "projects/demo-proj/alertPolicies/3", display: "Synthetic journeys: studio failed 2 runs in a row", labels: {app: "contabo-node"}, state: "OPEN", openTime: "2026-11-27T19:50:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens"], expect: ["outage", 1]},
		{call: "devflow.alertClass", args: [[{policy: "projects/demo-proj/alertPolicies/4", display: "Uptime: bonkchess-com", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:20:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens"], expect: ["ok", 1], why: "a single open and close"},
		{call: "devflow.alertClass", args: [[], _alertNow, _alertRules], expect: []},
	]}
	"flapping is more than flapOpens opens in 24 hours, or two closes within flapCloseMin minutes; it comes before stale and outage": {suite: "devflow", steps: [
		{call: "devflow.alertClass", args: [[for h in ["02", "05", "08", "11"] {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T\(h):00:00Z", closeTime: "2026-11-27T\(h):45:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["flapping"], why: "four opens in a day, 3 hours apart, each closed after 45 minutes: more than 3 opens alone"},
		{call: "devflow.alertClass", args: [[for h in ["02", "05", "08"] {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T\(h):00:00Z", closeTime: "2026-11-27T\(h):45:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["ok"], why: "three opens is not more than 3, and the closes are three hours apart"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:10:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:20:00Z", closeTime: "2026-11-27T10:30:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["flapping"], why: "two opens, but the closes are 20 minutes apart"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:10:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "OPEN", openTime: "2026-11-25T10:20:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:20:00Z", closeTime: "2026-11-27T10:25:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.openSince"], expect: ["flapping", "2026-11-25T10:20:00.000Z"], why: "flapping wins over an open two days: stale is the second rule"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-20T10:00:00Z", closeTime: "2026-11-20T11:00:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens", "0.openSince"], expect: ["ok", 0, "2026-11-20T10:00:00.000Z"], why: "an open from a week ago, closed, is not counted in the last 24 hours"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "OPEN", openTime: "2026-11-27T19:00:00Z"}], _alertNow, {flapOpens: 3, flapCloseMin: 30, staleHours: 0.5, apps: {}}]}, {pick: ["0.class"], expect: ["stale"], why: "staleHours is the flow's"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {owner: "bonk-chess"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}, {policy: "p/2", display: "b", labels: {app: "x", owner: "bonk-chess"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}], _alertNow, _alertRules]}, {pick: ["0.app", "1.app"], expect: ["brawl-chess", "brawl-chess"], why: "no app label: the owner label; an app label that is mapped to none falls to the owner's"},
	]}
	"an alert's title names its class and policy; only a title of that shape is an alert's": {suite: "devflow", steps: [
		{call: "devflow.alertTitle", args: ["flapping", "Bonk Chess: play-a-game JourneyTrafficDrop"], expect: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"},
		{call: "devflow.alertOf", args: ["Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"], expect: {class: "flapping", display: "Bonk Chess: play-a-game JourneyTrafficDrop"}, why: "the display name has its own colon"},
		{call: "devflow.alertOf", args: ["Alert stale: Uptime: x"], expect: {class: "stale", display: "Uptime: x"}},
		{call: "devflow.alertOf", args: ["Alert wobbling: x"], expect: null},
		{call: "devflow.alertOf", args: ["Flip ads on in brawl-chess"], expect: null},
	]}
	"a policy with an open board issue, or filed before, is not filed again; an ok policy never is": {suite: "devflow", steps: [
		{call: "devflow.alertFilings", args: [[
			{policy: "p/1", display: "Bonk Chess: play-a-game JourneyTrafficDrop", app: "brawl-chess", class: "flapping", opens: 32, openSince: "2026-11-27T12:00:00.000Z"},
			{policy: "p/2", display: "Uptime: x", app: null, class: "ok", opens: 1, openSince: null},
			{policy: "p/3", display: "Uptime: y", app: null, class: "outage", opens: 1, openSince: null},
		], [], []]}, {pick: ["length", "0.policy", "1.policy"], expect: [2, "p/1", "p/3"], why: "nothing known: the two that are not ok"},
		{call: "devflow.alertFilings", args: [[
			{policy: "p/1", display: "Bonk Chess: play-a-game JourneyTrafficDrop", app: "brawl-chess", class: "flapping", opens: 32, openSince: null},
		], [{name: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"}, {name: "Fix the crash"}], []], expect: [], why: "an existing board issue: nothing filed"},
		{call: "devflow.alertFilings", args: [[
			{policy: "p/1", display: "Bonk Chess: play-a-game JourneyTrafficDrop", app: "brawl-chess", class: "stale", opens: 1, openSince: null},
		], [{name: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"}], []], expect: [], why: "the issue is about the policy, whatever its class then"},
		{call: "devflow.alertFilings", args: [[
			{policy: "p/1", display: "a", app: null, class: "outage", opens: 1, openSince: null},
			{policy: "p/2", display: "b", app: null, class: "outage", opens: 1, openSince: null},
		], [], ["outage:p/1"]]}, {pick: ["length", "0.policy"], expect: [1, "p/2"], why: "outage:p/1 was filed before; the same policy as another class would not be"},
	]}
	"an alert policy's source file is the longest prefix of its display name that the flow names": {suite: "devflow", steps: [
		{call: "devflow.alertSource", args: ["Bonk Chess: play-a-game JourneyTrafficDrop", [{prefix: "", cue: "infra/gcp/prodwatch.cue"}, {prefix: "Bonk", cue: "short.cue"}, {prefix: "Bonk Chess: ", cue: "apps/brawl-chess/journeys_plugin.cue"}]], expect: "apps/brawl-chess/journeys_plugin.cue"},
		{call: "devflow.alertSource", args: ["Uptime: x", [{prefix: "", cue: "infra/gcp/prodwatch.cue"}, {prefix: "Bonk Chess: ", cue: "j.cue"}]], expect: "infra/gcp/prodwatch.cue", why: "the empty prefix matches all"},
		{call: "devflow.alertSource", args: ["Uptime: x", [{prefix: "Bonk Chess: ", cue: "j.cue"}]], expect: null},
		{call: "devflow.alertSource", args: ["Uptime: x", []], expect: null},
	]}
	"alerts files one bug for each policy that is down, flapping or stale, over two pages of incidents, and a second run writes nothing": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 2]}, {pick: ["runs.0.lines", "runs.0.writes", "runs.1.lines", "runs.1.writes", "requests", "state"], expect: [
			[
				"alerts: 3 filed, 0 known, 0 unavailable",
				"{\"key\":\"ACME-100\",\"class\":\"flapping\",\"policy\":\"Bonk Chess: play-a-game JourneyTrafficDrop\",\"app\":\"aprende\",\"cue\":\"apps/brawl-chess/journeys_plugin.cue\"}",
				"{\"key\":\"ACME-101\",\"class\":\"stale\",\"policy\":\"Contabo node: no heartbeat for 15 minutes\",\"app\":\"plugins\",\"cue\":\"infra/gcp/prodwatch.cue\"}",
				"{\"key\":\"ACME-102\",\"class\":\"outage\",\"policy\":\"Synthetic journeys: studio failed 2 runs in a row\",\"app\":\"plugins\",\"cue\":\"tools/machine/synthetic.cue\"}",
			],
			["createLabel bug", "createIssue Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop", "addToModule aprende", "createIssue Alert stale: Contabo node: no heartbeat for 15 minutes", "addToModule plugins", "createIssue Alert outage: Synthetic journeys: studio failed 2 runs in a row", "addToModule plugins"],
			["alerts: 0 filed, 3 known, 0 unavailable", "{\"key\":\"ACME-100\",\"class\":\"flapping\",\"policy\":\"Bonk Chess: play-a-game JourneyTrafficDrop\",\"app\":\"aprende\",\"cue\":\"apps/brawl-chess/journeys_plugin.cue\",\"known\":true}", "{\"key\":\"ACME-101\",\"class\":\"stale\",\"policy\":\"Contabo node: no heartbeat for 15 minutes\",\"app\":\"plugins\",\"cue\":\"infra/gcp/prodwatch.cue\",\"known\":true}", "{\"key\":\"ACME-102\",\"class\":\"outage\",\"policy\":\"Synthetic journeys: studio failed 2 runs in a row\",\"app\":\"plugins\",\"cue\":\"tools/machine/synthetic.cue\",\"known\":true}"],
			[],
			["page 1", "page 2", "page 1", "page 2"],
			["flapping:projects/demo-proj/alertPolicies/1", "stale:projects/demo-proj/alertPolicies/2", "outage:projects/demo-proj/alertPolicies/3"],
		], why: "the Contabo and Synthetic policies map to no board app (their app label is contabo-node): they are filed under plugins and name the label; the second run reads the same pages and writes nothing"},
	]}
	"--new prints only what is filed, and a dry run files nothing and prints what it would": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed & {onlyNew: true}, _alertsPages, 2]}, {pick: ["runs.0.lines.0", "runs.1.lines"], expect: ["alerts: 3 filed, 0 known, 0 unavailable", ["alerts: 0 filed, 3 known, 0 unavailable"]], why: "the second run has nothing new: only the count line"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {dryRun: true}, _alertsPages, 2]}, {pick: ["runs.0.lines.0", "runs.0.lines.1", "runs.0.writes", "runs.1.writes", "state"], expect: ["alerts: 3 would file, 0 known, 0 unavailable (dry run)", "{\"key\":null,\"class\":\"flapping\",\"policy\":\"Bonk Chess: play-a-game JourneyTrafficDrop\",\"app\":\"aprende\",\"cue\":\"apps/brawl-chess/journeys_plugin.cue\"}", [], [], []]},
	]}
	"an open board issue about a policy is known, not filed again, in whatever state it is open": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed & {issues: [{seq: 7, name: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop", state: "Implementing", module: "aprende"}, {seq: 8, name: "Alert stale: Contabo node: no heartbeat for 15 minutes", state: "Done", module: "aprende"}]}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "runs.0.lines.1", "runs.0.writes"], expect: [
			"alerts: 2 filed, 1 known, 0 unavailable",
			"{\"key\":\"ACME-102\",\"class\":\"stale\",\"policy\":\"Contabo node: no heartbeat for 15 minutes\",\"app\":\"plugins\",\"cue\":\"infra/gcp/prodwatch.cue\"}",
			["createLabel bug", "createIssue Alert stale: Contabo node: no heartbeat for 15 minutes", "addToModule plugins", "createIssue Alert outage: Synthetic journeys: studio failed 2 runs in a row", "addToModule plugins"],
		], why: "ACME-7 is open: known. ACME-8 is Done: the alert is still stale, so it is filed again"},
	]}
	"a project that cannot be read is unavailable, never none; a GET that fails once is asked again; a read cut short at 20 pages counts as unavailable": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed & {status: 403}, _alertsPages, 1]}, {pick: ["runs.0.lines", "runs.0.writes", "requests"], expect: [
			["alerts: 0 filed, 0 known, 1 unavailable", "alerts: unavailable (demo-proj: monitoring alerts of demo-proj: 403 Permission denied)"], [], ["page 1"],
		], why: "a 403 is not asked again, and is no 'none'"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {status: 503}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "requests.length"], expect: ["alerts: 0 filed, 0 known, 1 unavailable", 4], why: "a 5xx is asked again, four tries in all"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {flaky: true}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "requests"], expect: ["alerts: 3 filed, 0 known, 0 unavailable", ["page 1", "page 1", "page 2"]], why: "the first answer was a 503: asked again"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {endless: true}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "runs.0.lines.1", "runs.0.writes", "requests.length"], expect: ["alerts: 0 filed, 0 known, 1 unavailable", "alerts: unavailable (demo-proj: monitoring alerts of demo-proj: more than 20 pages, the read is cut short)", [], 20]},
		{call: "queue.alertsRuns", args: [_alertsSeed & {noToken: true}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "runs.0.lines.1"], expect: ["alerts: 0 filed, 0 known, 1 unavailable", "alerts: unavailable (demo-proj: no access token: gcloud auth print-access-token failed)"]},
	]}
	"an alert issue is a bug at its class's priority, names the file to change for a flapping or stale alert, and carries the console link": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 1]}, {get: "filed"}, {pick: ["0.name", "0.priority", "0.labels.length", "1.priority", "2.priority", "2.state"], expect: [
			"Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop", "high", 1, "medium", "urgent", "Implementing",
		], why: "flapping high, stale medium, outage urgent: a P0 bug starts at once"},
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 1]}, {get: "filed.0.body", matches: "Class: flapping.*Opens in the last 24 hours: 32.*First open: 2026-11-27T12:00:00.000Z.*console.cloud.google.com/monitoring/alerting/policies/1\\?project=demo-proj.*This is a bug in the alert: change `apps/brawl-chess/journeys_plugin.cue` \\(threshold, duration, absence window or auto-close\\), then release@infra"},
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 1]}, {get: "filed.1.body", matches: "labels app=contabo-node owner=\\(none\\) maps to no app"},
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 1]}, {get: "filed.2.body", matches: "^((?!This is a bug in the alert).)*$"},
	]}
}

_alertsSeed: {modules: ["aprende", "plugins"], now: _alertNow}
_toAlerts: [for i in _drops {state: i.state, openTime: i.openTime, closeTime: i.closeTime, policy: {name: i.policy, displayName: i.display, userLabels: i.labels}}]
_alertsPages: [
	list.Concat([list.Slice(_toAlerts, 0, 16), [{state: "OPEN", openTime: "2026-11-18T20:00:00Z", policy: {name: "projects/demo-proj/alertPolicies/2", displayName: "Contabo node: no heartbeat for 15 minutes", userLabels: {app: "contabo-node"}}}]]),
	list.Concat([list.Slice(_toAlerts, 16, 32), [
		{state: "OPEN", openTime: "2026-11-27T19:50:00Z", policy: {name: "projects/demo-proj/alertPolicies/3", displayName: "Synthetic journeys: studio failed 2 runs in a row", userLabels: {app: "contabo-node"}}},
		{state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:20:00Z", policy: {name: "projects/demo-proj/alertPolicies/4", displayName: "Uptime: bonkchess-com", userLabels: {}}},
	]]),
]
