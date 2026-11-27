// The alerts watch (PRONTO-2182; devflow/alerts.ts, its pure rules in devflow/flow.js): an alert policy that is down,
// flapping or left open is a bug on the board, filed once. Fixtures carry policy fields only (name, display name, user
// labels, state, times): no resource or metric labels. `queue.alertsRuns` runs the verb on a fake Cloud Monitoring (two
// pages) and the fake Plane of tests/unit/devflow.js.
package unit

import "list"

_alertRules: {ignore: [...string], flapOpens: 3, flapCloseMin: 30, staleHours: 24, apps: {battlechess: "brawl-chess", "bonk-chess": "brawl-chess"}}
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
	"a policy that is open now is stale or an outage, never flapping; when it is not open, flapping is more than flapOpens events in 24 hours (incidents opened within 5 minutes are one), or two incidents closed within flapCloseMin minutes of opening": {suite: "devflow", steps: [
		{call: "devflow.alertClass", args: [[for h in ["02", "05", "08", "11"] {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T\(h):00:00Z", closeTime: "2026-11-27T\(h):45:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["flapping"], why: "four opens in a day, 3 hours apart, each closed after 45 minutes: more than 3 opens alone"},
		{call: "devflow.alertClass", args: [[for h in ["02", "05", "08"] {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T\(h):00:00Z", closeTime: "2026-11-27T\(h):45:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["ok"], why: "three opens is not more than 3, and the closes are three hours apart"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:10:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:20:00Z", closeTime: "2026-11-27T10:30:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["flapping"], why: "two opens, each closed after 10 minutes: two quick closes"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:10:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "OPEN", openTime: "2026-11-27T19:00:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:20:00Z", closeTime: "2026-11-27T10:25:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.openSince"], expect: ["outage", "2026-11-27T19:00:00.000Z"], why: "two quick closes, but it is open now: an outage, not flapping"},
		{call: "devflow.alertClass", args: [list.Concat([[for h in ["02", "05", "08", "11"] {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T\(h):00:00Z", closeTime: "2026-11-27T\(h):45:00Z"}], [{policy: "p/1", display: "a", labels: {}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}]]), _alertNow, _alertRules]}, {pick: ["0.class", "0.opens"], expect: ["outage", 5], why: "open now with more than 3 opens: an outage"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T12:00:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:01:00Z", closeTime: "2026-11-27T12:00:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:03:00Z", closeTime: "2026-11-27T12:00:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:04:00Z", closeTime: "2026-11-27T12:00:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:05:00Z", closeTime: "2026-11-27T12:00:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens"], expect: ["ok", 1], why: "five incidents opened within 5 minutes of each other are one event"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:30:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class"], expect: ["ok"], why: "one close within flapCloseMin is not two"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T10:00:00Z", closeTime: "2026-11-27T10:30:00Z"}, {policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-27T14:00:00Z", closeTime: "2026-11-27T14:30:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens"], expect: ["flapping", 2], why: "30 minutes is within flapCloseMin 30: two such incidents, hours apart, are flapping"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "CLOSED", openTime: "2026-11-20T10:00:00Z", closeTime: "2026-11-20T11:00:00Z"}], _alertNow, _alertRules]}, {pick: ["0.class", "0.opens", "0.openSince"], expect: ["ok", 0, "2026-11-20T10:00:00.000Z"], why: "an open from a week ago, closed, is not counted in the last 24 hours"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {}, state: "OPEN", openTime: "2026-11-27T19:00:00Z"}], _alertNow, {flapOpens: 3, flapCloseMin: 30, staleHours: 0.5, apps: {}}]}, {pick: ["0.class"], expect: ["stale"], why: "staleHours is the flow's"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {owner: "bonk-chess"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}, {policy: "p/2", display: "b", labels: {app: "x", owner: "bonk-chess"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}], _alertNow, _alertRules]}, {pick: ["0.app", "1.app"], expect: ["brawl-chess", "brawl-chess"], why: "no app label: the owner label; an app label that is mapped to none falls to the owner's"},
	]}
	"a policy whose app or owner label is ignored files nothing; the others are read as before": {suite: "devflow", steps: [
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "Ume: rent-a-phone JourneyTrafficDrop", labels: {app: "ume_rental", owner: "ume"}, state: "OPEN", openTime: "2026-11-18T20:00:00Z"}, {policy: "p/2", display: "Ume: x", labels: {owner: "ume-ops"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}, {policy: "p/3", display: "b", labels: {app: "battlechess"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}], _alertNow, _alertRules & {ignore: ["ume_rental", "ume-ops"]}]}, {pick: ["length", "0.policy", "0.class"], expect: [1, "p/3", "outage"], why: "p/1 by its app label, p/2 by its owner label"},
		{call: "devflow.alertClass", args: [[{policy: "p/1", display: "a", labels: {app: "ume_rental"}, state: "OPEN", openTime: "2026-11-27T19:55:00Z"}], _alertNow, _alertRules], expect: [{policy: "p/1", display: "a", app: null, class: "outage", opens: 1, openSince: "2026-11-27T19:55:00.000Z"}], why: "no ignore: filed as before"},
	]}
	"an alert's title names its class and policy; only a title of that shape is an alert's": {suite: "devflow", steps: [
		{call: "devflow.alertTitle", args: ["flapping", "Bonk Chess: play-a-game JourneyTrafficDrop"], expect: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"},
		{call: "devflow.alertTitle", args: ["outage", "Uptime: x", "proj-a"], expect: "Alert outage: Uptime: x (proj-a)"},
		{call: "devflow.alertOf", args: ["Alert outage: Uptime: x (proj-a)"], expect: {class: "outage", display: "Uptime: x", project: "proj-a"}, why: "the project is the last word, in parentheses"},
		{call: "devflow.alertOf", args: ["Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"], expect: {class: "flapping", display: "Bonk Chess: play-a-game JourneyTrafficDrop", project: null}, why: "the display name has its own colon"},
		{call: "devflow.alertOf", args: ["Alert stale: Uptime: x"], expect: {class: "stale", display: "Uptime: x", project: null}},
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
		], [{name: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop"}], []]}, {pick: ["length"], expect: [1], why: "an issue of another class does not hide it: a flapping issue never hides an outage or a stale alert"},
		{call: "devflow.alertFilings", args: [[
			{policy: "p/1", display: "a", app: null, class: "outage", opens: 1, openSince: null},
			{policy: "p/2", display: "b", app: null, class: "outage", opens: 1, openSince: null},
		], [], ["outage:p/1"]]}, {pick: ["length", "0.policy"], expect: [1, "p/2"], why: "outage:p/1 was filed before; the same policy as another class would not be"},
	]}
	"a state key blocks a refile after the issue is closed, a change of class files again, and the same display name in two projects is two policies": {suite: "devflow", steps: [
		{call: "devflow.alertFilings", args: [[{policy: "projects/a/alertPolicies/1", display: "x", app: null, class: "stale", opens: 1, openSince: null}], [], ["stale:projects/a/alertPolicies/1"]], expect: [], why: "filed before, its issue closed since: not again while it stays stale"},
		{call: "devflow.alertFilings", args: [[{policy: "projects/a/alertPolicies/1", display: "x", app: null, class: "stale", opens: 1, openSince: null}], [], ["flapping:projects/a/alertPolicies/1"]]}, {pick: ["length"], expect: [1], why: "it was flapping, now it is stale: a new class files"},
		{call: "devflow.alertFilings", args: [[{policy: "projects/a/alertPolicies/9", display: "x", app: null, class: "outage", opens: 1, openSince: null}, {policy: "projects/b/alertPolicies/9", display: "x", app: null, class: "outage", opens: 1, openSince: null}], [{name: "Alert outage: x (a)"}], []]}, {pick: ["length", "0.policy"], expect: [1, "projects/b/alertPolicies/9"], why: "the issue is project a's: project b's policy of the same display name is filed"},
		{call: "devflow.alertFilings", args: [[{policy: "projects/b/alertPolicies/9", display: "x", app: null, class: "outage", opens: 1, openSince: null}], [{name: "Alert outage: x"}], []], expect: [], why: "a title with no project is of any"},
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
			["createLabel bug", "createIssue Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop (demo-proj)", "addToModule aprende", "createIssue Alert stale: Contabo node: no heartbeat for 15 minutes (demo-proj)", "addToModule plugins", "createIssue Alert outage: Synthetic journeys: studio failed 2 runs in a row (demo-proj)", "addToModule plugins"],
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
			["createLabel bug", "createIssue Alert stale: Contabo node: no heartbeat for 15 minutes (demo-proj)", "addToModule plugins", "createIssue Alert outage: Synthetic journeys: studio failed 2 runs in a row (demo-proj)", "addToModule plugins"],
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
	"one project that cannot be read does not hide another; the same display name in two projects is two issues; an incomplete incident or a spent budget is unavailable": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed & {projects: ["proj-a", "proj-b"], statusBy: {"proj-a": 403}, pagesBy: {"proj-b": [[_upB]]}}, _alertsPages, 1]}, {pick: ["runs.0.lines", "runs.0.writes"], expect: [
			["alerts: 1 filed, 0 known, 1 unavailable", "alerts: unavailable (proj-a: monitoring alerts of proj-a: 403 Permission denied)", "{\"key\":\"ACME-100\",\"class\":\"outage\",\"policy\":\"Uptime: x\",\"app\":\"plugins\",\"cue\":\"infra/gcp/prodwatch.cue\"}"],
			["createLabel bug", "createIssue Alert outage: Uptime: x (proj-b)", "addToModule plugins"],
		], why: "proj-a answers 403: unavailable; proj-b is read and its outage filed"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {projects: ["proj-a", "proj-b"], pagesBy: {"proj-a": [[_upA]], "proj-b": [[_upB]]}}, _alertsPages, 2]}, {pick: ["runs.0.lines.0", "runs.0.writes", "runs.1.lines.0", "runs.1.writes"], expect: [
			"alerts: 2 filed, 0 known, 0 unavailable",
			["createLabel bug", "createIssue Alert outage: Uptime: x (proj-a)", "addToModule plugins", "createIssue Alert outage: Uptime: x (proj-b)", "addToModule plugins"],
			"alerts: 0 filed, 2 known, 0 unavailable", [],
		], why: "one policy of the same name in each project: two issues, and a second run writes nothing"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {pagesBy: {"demo-proj": [[{state: "OPEN", openTime: "2026-11-27T19:50:00Z", policy: {displayName: "No name"}}]]}}, _alertsPages, 1]}, {pick: ["runs.0.lines", "runs.0.writes"], expect: [
			["alerts: 0 filed, 0 known, 1 unavailable", "alerts: unavailable (demo-proj: monitoring alerts of demo-proj: an incident with no policy name, state or open time)"], [],
		], why: "never dropped silently"},
		{call: "queue.alertsRuns", args: [_alertsSeed & {budgetMs: -1}, _alertsPages, 1]}, {pick: ["runs.0.lines", "requests"], expect: [
			["alerts: 0 filed, 0 known, 1 unavailable", "alerts: unavailable (demo-proj: monitoring alerts of demo-proj: the read budget is spent)"], [],
		], why: "a read stays under the lock's takeover age"},
	]}
	"what was filed before the board fails is still printed, then the failure; a state key keeps a closed issue from being filed again": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed & {failSecondCreate: true}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "runs.0.lines.1", "runs.0.lines.2", "state"], expect: [
			"alerts: 1 filed, 0 known, 1 unavailable", "alerts: unavailable (board: the board is down)", "{\"key\":\"ACME-100\",\"class\":\"flapping\",\"policy\":\"Bonk Chess: play-a-game JourneyTrafficDrop\",\"app\":\"aprende\",\"cue\":\"apps/brawl-chess/journeys_plugin.cue\"}", ["flapping:projects/demo-proj/alertPolicies/1"],
		]},
		{call: "queue.alertsRuns", args: [_alertsSeed & {kept: ["stale:projects/demo-proj/alertPolicies/2"], issues: [{seq: 7, name: "Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop", state: "Implementing", module: "aprende"}, {seq: 8, name: "Alert stale: Contabo node: no heartbeat for 15 minutes", state: "Done", module: "aprende"}]}, _alertsPages, 1]}, {pick: ["runs.0.lines.0", "runs.0.writes"], expect: [
			"alerts: 1 filed, 2 known, 0 unavailable", ["createLabel bug", "createIssue Alert outage: Synthetic journeys: studio failed 2 runs in a row (demo-proj)", "addToModule plugins"],
		], why: "the stale issue is Done, but its state key says it was filed: not filed again"},
	]}
	"an alert issue is a bug at its class's priority, names the file to change for a flapping or stale alert, and carries the console link": {suite: "devflow", steps: [
		{call: "queue.alertsRuns", args: [_alertsSeed, _alertsPages, 1]}, {get: "filed"}, {pick: ["0.name", "0.priority", "0.labels.length", "1.priority", "2.priority", "2.state"], expect: [
			"Alert flapping: Bonk Chess: play-a-game JourneyTrafficDrop (demo-proj)", "high", 1, "medium", "urgent", "Implementing",
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
_upA: {state: "OPEN", openTime: "2026-11-27T19:50:00Z", policy: {name: "projects/proj-a/alertPolicies/9", displayName: "Uptime: x", userLabels: {}}}
_upB: {state: "OPEN", openTime: "2026-11-27T19:50:00Z", policy: {name: "projects/proj-b/alertPolicies/9", displayName: "Uptime: x", userLabels: {}}}
