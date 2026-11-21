// release-cron's rules (../../release-cron/cron.js) on the inputs they were written for.
package unit

import "github.com/bsoneca/pronto-plugins/release-cron:releasecron"

// releaseCron.causes: the phrases the cases expect are the schema's, as cron.js's are (causes.js is emitted from them).
_causes: releasecron.#Cron.causes

_cronRec: {
	outcome: *"live" | string
	preview?: string
	revision: string
	commit:   string
}

cases: {
	"a wake starts a run when none has released or failed, or the gap is over since the last": {suite: "cron", steps: [
		{call: "cron.due", args: [1000, null, 60], expect: true, why: "no run has released or failed yet"},
		{call: "cron.due", args: [3599999, 0, 60], expect: false},
		{call: "cron.due", args: [3600000, 0, 60], expect: true, why: "exactly the gap"},
		{call: "cron.due", args: [5000000, 1000000, 60], expect: true},
		{call: "cron.due", args: [1000, 1000, 0], expect: true, why: "no gap"},
	]}
	"a run never releases a commit that is a strict ancestor of the one the last run tried": {suite: "cron", steps: [
		{call: "cron.behind", args: [true, "665bad95", "dc909b53"], expect: true, why: "an older ci-finished commit: skipped"},
		{call: "cron.behind", args: [true, "dc909b53", "dc909b53"], expect: false, why: "the same commit follows today's rules"},
		{call: "cron.behind", args: [false, "0b2206c3", "dc909b53"], expect: false, why: "newer or unrelated"},
		{call: "cron.behind", args: [false, "dc909b53", null], expect: false, why: "no run has tried one"},
		{call: "cron.behind", args: [true, "665bad95", null], expect: false, why: "no last commit to be behind"},
	]}
	"a run holds the machine as one line of JSON: its app, pid, start and phase": {suite: "cron", steps: [
		{call: "cron.activeLine", args: ["brawl-chess", 4242, "2026-11-03T20:00:00Z", "slot"], expect: "{\"app\":\"brawl-chess\",\"pid\":4242,\"started\":\"2026-11-03T20:00:00Z\",\"phase\":\"slot\"}\n"},
		{call: "cron.activeLine", args: ["brawl-chess", 4242, "2026-11-03T20:00:00Z", "confirm"], expect: "{\"app\":\"brawl-chess\",\"pid\":4242,\"started\":\"2026-11-03T20:00:00Z\",\"phase\":\"confirm\"}\n", why: "the phase is the only field that moves"},
	]}
	"a release whose ssh dropped counts as landed when the node serves its commit": {suite: "cron", steps: [
		{call: "cron.sshDropped", args: [255], expect: true, why: "PRONTO-758: ssh's own failure"},
		{call: "cron.sshDropped", args: [1], expect: false},
		{call: "cron.landed", args: [255, "f203025f", "f203025f", true], expect: true, why: "2026-11-18 11:34 BRT: Studio landed, its ssh dropped"},
		{call: "cron.landed", args: [255, "ebd25c98", "f203025f", true], expect: false},
		{call: "cron.landed", args: [1, "f203025f", "f203025f", true], expect: false, why: "the release command failed: not a drop"},
		{call: "cron.landed", args: [255, "", "f203025f", true], expect: false},
	]}
	"the android step runs in an allowlisted environment: PATH and the SDK's kept, every credential dropped": {suite: "cron", steps: [
		{call: "cron.androidSpawn", args: [{}], expect: {env: {STACK_WAIT_MINUTES: "525600"}, clearEnv: true}, why: "PRONTO-870: Deno.Command inherits the parent's env unless cleared"},
		{call: "cron.androidSpawn", args: [{PATH: "/p", ANDROID_HOME: "/sdk", PRONTO_BASE: "http://localhost:1", CUE_MEM_GB: "8", INTEGRATE_LOCAL_DRIVERS: "all", GOMAXPROCS: "4", MISE_TRUSTED_CONFIG_PATHS: "/w"}], expect: {env: {PATH: "/p", ANDROID_HOME: "/sdk", PRONTO_BASE: "http://localhost:1", CUE_MEM_GB: "8", INTEGRATE_LOCAL_DRIVERS: "all", GOMAXPROCS: "4", MISE_TRUSTED_CONFIG_PATHS: "/w", STACK_WAIT_MINUTES: "525600"}, clearEnv: true}, why: "what integrate@android reads"},
		{call: "cron.androidSpawn", args: [{PATH: "/p", GH_TOKEN: "t", CLOUDFLARE_API_TOKEN: "c", GOOGLE_APPLICATION_CREDENTIALS: "/g", ANDROID_KEYSTORE_PASS: "a", ANDROID_KEY_ALIAS_PWD: "b", STACK_PASSPHRASE: "c", PRONTO_APIKEY: "d", PRONTO_AUTH: "e", PRONTO_STRIPE_SK: "f", DENO_AUTH_TOKENS: "g", MISE_GITHUB_TOKEN: "h", SOPS_AGE_KEY: "i", SSH_AUTH_SOCK: "/s", PRONTO_DATABASE_URL: "postgres://u:p@h/db", STACK_DB_URL: "postgres://u:p@h/db", PRONTO_DB_DSN: "x"}], expect: {env: {PATH: "/p", STACK_WAIT_MINUTES: "525600"}, clearEnv: true}, why: "every name that says it is a secret, and a URL that carries one, is dropped"},
		{call: "cron.androidSpawn", args: [{PATH: "/p", STACK_ORIGIN: "http://h:8080/x", PRONTO_BASE: "http://localhost:1"}], expect: {env: {PATH: "/p", STACK_ORIGIN: "http://h:8080/x", PRONTO_BASE: "http://localhost:1", STACK_WAIT_MINUTES: "525600"}, clearEnv: true}, why: "a URL with a port and no password stays"},
		{call: "cron.androidSpawn", args: [{PATH: "/p", PRONTO_OTHER: "x", GRADLE_USER_HOME: "/g", MISE_DATA_DIR: "/m", DENO_DIR: "/d"}], expect: {env: {PATH: "/p", STACK_WAIT_MINUTES: "525600"}, clearEnv: true}, why: "PRONTO_, MISE_, GRADLE_ and DENO_ are exact names, not prefixes"},
	]}
	"a 255 is rescued only when serving reads a ref written after the release finished": {suite: "cron", steps: [
		{call: "cron.rescuable", args: [255, true], expect: true, why: "Studio's refs/released/studio"},
		{call: "cron.rescuable", args: [255, false], expect: false, why: "PRONTO-870: a worktree HEAD moves before the release runs"},
		{call: "cron.rescuable", args: [255, null], expect: false, why: "unset is the default, false"},
		{call: "cron.rescuable", args: [1, true], expect: false},
		{call: "cron.landed", args: [255, "f203025f", "f203025f", false], expect: false, why: "the node's HEAD already names the commit; the old pods still serve"},
		{call: "cron.landed", args: [255, "f203025f", "f203025f"], expect: false},
	]}
	"only a run that is not dry records or changes anything (the flags record, skips' notes)": {suite: "cron", steps: [
		{call: "cron.mutates", args: [""], expect: true},
		{call: "cron.mutates", args: ["1"], expect: false},
	]}
	"only a run that released or failed makes the next one wait": {suite: "cron", steps: [
		{call: "cron.spaced", args: ["released"], expect: true},
		{call: "cron.spaced", args: ["failed"], expect: true},
		{call: "cron.spaced", args: ["skipped"], expect: false},
		{call: "cron.spaced", args: [""], expect: false},
	]}
	"last keeps the commit a failed run failed on, and the commit any spaced run tried": {suite: "cron", steps: [
		{call: "cron.lastFields", args: ["failed", "c1"], expect: ["c1", "c1"], why: "retry reads the first, behind the second"},
		{call: "cron.lastFields", args: ["released", "c1"], expect: ["-", "c1"], why: "a release failed on nothing"},
		{call: "cron.lastFields", args: ["failed", ""], expect: ["-", "-"], why: "a run that never got a commit tried none"},
	]}
	"after a failed run, the next starts without the gap once main has moved past the commit it failed on": {suite: "cron", steps: [
		{call: "cron.retry", args: ["291a52a9", "0b2206c3"], expect: true, why: "a new commit on main: the fix may be in"},
		{call: "cron.retry", args: ["291a52a9", "291a52a9"], expect: false, why: "the same commit waits the gap"},
		{call: "cron.retry", args: ["291a52a9", null], expect: false, why: "main unreadable: the gap holds"},
		{call: "cron.retry", args: [null, "0b2206c3"], expect: false, why: "the last spaced run released"},
	]}
	"a change is the app's when the path is a watched one or lies beneath it": {suite: "cron", steps: [
		{call: "cron.changed", args: [["apps/brawl-chess/a.js", "apps/brawl-chess/sub/dir/b.js", "apps/brawl-chess", "README.md"], ["apps/brawl-chess"]], expect: ["apps/brawl-chess/a.js", "apps/brawl-chess/sub/dir/b.js", "apps/brawl-chess"]},
		{call: "cron.changed", args: [["apps/brawl-chess-x/a.js", "apps/brawl-chess2"], ["apps/brawl-chess"]], expect: [], why: "a sibling that only shares the prefix is another folder"},
		{call: "cron.changed", args: [["apps/brawl-chess/a.js", "lib/x.js"], ["apps/brawl-chess/"]], expect: ["apps/brawl-chess/a.js"], why: "a trailing slash in the watch changes nothing"},
		{call: "cron.changed", args: [["lib/x.js", "tools/y.js"], ["apps/brawl-chess", "lib"]], expect: ["lib/x.js"], why: "any of several watched paths"},
		{call: "cron.changed", args: [[], ["apps/brawl-chess"]], expect: []},
	]}
	"the commit serving is the newest live production record of the revision": {suite: "cron", steps: [
		{call: "cron.serving", args: [[
			(_cronRec & {revision: "r1", commit: "aaa"}),
			(_cronRec & {revision: "r1", commit: "bbb"}),
			(_cronRec & {revision: "r2", commit: "ccc"}),
		], "r1"], expect: "bbb"},
		{call: "cron.serving", args: [[
			(_cronRec & {revision: "r1", commit: "aaa"}),
			(_cronRec & {revision: "r1", commit: "ppp", preview: "rc"}),
		], "r1"], expect: "aaa", why: "a preview is not production"},
		{call: "cron.serving", args: [[
			(_cronRec & {revision: "r1", commit: "aaa"}),
			(_cronRec & {revision: "r1", commit: "fff", outcome: "failed"}),
		], "r1"], expect: "aaa", why: "a release that failed never served"},
		{call: "cron.serving", args: [[(_cronRec & {revision: "r1", commit: "aaa", preview: ""})], "r1"], expect: "aaa", why: "an empty preview is production"},
		{call: "cron.serving", args: [[(_cronRec & {revision: "r1", commit: "aaa"})], "r9"], expect: null, why: "released from another machine: no record names it"},
		{call: "cron.serving", args: [[], "r1"], expect: null},
	]}
	"the revision serving is the one taking all the traffic, none while it is split": {suite: "cron", steps: [
		{call: "cron.whole", args: [[{revisionName: "r1", percent: 100}]], expect: "r1"},
		{call: "cron.whole", args: [[{revisionName: "r1", percent: 90}, {revisionName: "r2", percent: 10}]], expect: null},
		{call: "cron.whole", args: [[{revisionName: "r1", percent: 0}, {revisionName: "r2", percent: 100}]], expect: "r2"},
		{call: "cron.whole", args: [[]], expect: null},
		{call: "cron.whole", args: [null], expect: null},
	]}
	"production serves the release when the revision taking every request is the one its newest live record names": {suite: "cron", steps: [
		{call: "cron.served", args: ["r2", [(_cronRec & {revision: "r1", commit: "aaa"}), (_cronRec & {revision: "r2", commit: "bbbbbbbbbb"})], "bbbbbbbbbb"], expect: []},
		{call: "cron.served", args: ["r1", [(_cronRec & {revision: "r1", commit: "aaa"}), (_cronRec & {revision: "r1", commit: "cccccccccc"})], "cccccccccc"], expect: [], why: "a release that changed nothing Cloud Run runs keeps the revision (2026-11-03, c5492c22 on bonk-chess-00064-xx9)"},
		{call: "cron.served", args: ["r1", [(_cronRec & {revision: "r1", commit: "aaa"})], "cccccccccc"], expect: ["r1 takes every request, but no live record of cccccccc names it"]},
		{call: "cron.served", args: [null, [], "cccccccccc"], expect: ["traffic split: no revision takes every request"]},
	]}
	"a run compares main with the newest run that released, while its revision still serves": {suite: "cron", steps: [
		{call: "cron.base", args: [[{outcome: "released", commit: "aaa", revision: "r1"}, {outcome: "skipped", commit: "bbb"}], "r1"], expect: "aaa"},
		{call: "cron.base", args: [[{outcome: "released", commit: "aaa", revision: "r1"}, {outcome: "failed", commit: "bbb", revision: "r1"}], "r1"], expect: "aaa", why: "a failed run is never the base, though it may have deployed (2026-11-03, 075abd4f)"},
		{call: "cron.base", args: [[{outcome: "failed", commit: "bbb", revision: "r1"}], "r1"], expect: null, why: "no run released: release"},
		{call: "cron.base", args: [[{outcome: "released", commit: "aaa", revision: "r1"}], "r2"], expect: null, why: "another revision serves since: a rollback or a release from elsewhere"},
		{call: "cron.base", args: [[{outcome: "released", commit: "aaa", revision: "r1"}], null], expect: null, why: "traffic split"},
		{call: "cron.base", args: [[{outcome: "released", commit: "aaa", revision: "r1"}, {outcome: "released", commit: "ccc", revision: "r1"}], "r1"], expect: "ccc", why: "the newest; a release that kept the revision"},
		{call: "cron.base", args: [[], "r1"], expect: null},
	]}
	"the rehearsal holds its slot when a slot's owner names its app and verify@local, not a lane": {suite: "cron", steps: [
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/brawl-chess verify@local (weight 10)\n", "/w/apps/brawl-chess"], expect: true},
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/brawl-chess verify@local (weight 10)", "/w/apps/brawl-chess/"], expect: true, why: "a trailing slash names the same folder"},
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/brawl-chess verify@local, lane 2 (weight 4)", "/w/apps/brawl-chess"], expect: false, why: "a lane is taken after the slot, not the slot"},
		{call: "cron.holds", args: ["64280 2026-11-02T19:14:01.539Z /other/apps/brawl-chess verify@local (weight 10)", "/w/apps/brawl-chess"], expect: false, why: "another checkout's rehearsal"},
		{call: "cron.holds", args: ["55266 2026-11-02T19:13:22.102Z /w/apps/brawl-chess ./saytw launch@local (weight 1)", "/w/apps/brawl-chess"], expect: false},
		{call: "cron.holds", args: ["", "/w/apps/brawl-chess"], expect: false},
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/rental ./saytw integrate@local (weight 10)", "/w/apps/rental", "./saytw integrate@local"], expect: true, why: "an app's own holder"},
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/rental verify@local (weight 10)", "/w/apps/rental", "./saytw integrate@local"], expect: false, why: "not the holder it names"},
	]}
	"a probe is fine when the status and the text are what it expects": {suite: "cron", steps: [
		{call: "cron.probe", args: [{path: "/health"}, 200, "ok"], expect: null, why: "status defaults to 200"},
		{call: "cron.probe", args: [{path: "/login", status: 302}, 302, ""], expect: null},
		{call: "cron.probe", args: [{path: "/", has: ["Brawl", "Chess"]}, 200, "Brawl Chess"], expect: null},
	]}
	"a probe says what was wrong: the status, or the text missing": {suite: "cron", steps: [
		{call: "cron.probe", args: [{path: "/health"}, 503, "down"], expect: "/health: 503, expected 200"},
		{call: "cron.probe", args: [{path: "/login", status: 302}, 200, ""], expect: "/login: 200, expected 302"},
		{call: "cron.probe", args: [{path: "/", has: ["Brawl", "Chess"]}, 200, "Brawl only"], expect: "/: 200 without \"Chess\""},
		{call: "cron.probe", args: [{path: "/", has: ["a", "b"]}, 200, ""], expect: "/: 200 without \"a\", \"b\""},
	]}
	"a time a person reads is Brasília's with its offset, whatever the machine's zone": {suite: "cron", steps: [
		{call: "cron.local", args: [1793748492000], expect: "2026-11-03T20:28:12-03:00"},
		{call: "cron.local", args: [1793748492999], expect: "2026-11-03T20:28:12-03:00", why: "to the second"},
		{call: "cron.local", args: [1793761199000], expect: "2026-11-03T23:59:59-03:00", why: "already the 4th in UTC, still the 3rd there"},
		{call: "cron.local", args: [1793748492000, "UTC"], expect: "2026-11-03T23:28:12+00:00", why: "another zone, named"},
	]}
	"the log line names when, the app, the outcome, the commit and each step in minutes": {suite: "cron", steps: [
		{call: "cron.line", args: [{started: "2026-11-03T02:00:00Z", app: "brawl-chess", outcome: "released", commit: "0123456789abcdef", revision: "bonk-chess-00061-abc", steps: {prepare: 30, rehearse: 1050, release: 560}}], expect: "2026-11-03T02:00:00Z brawl-chess released 01234567 bonk-chess-00061-abc: 27.3 min = prepare 0.5, rehearse 17.5, release 9.3"},
		{call: "cron.line", args: [{started: "t", app: "a", outcome: "skipped", why: "nothing changed", steps: {prepare: 30}}], expect: "t a skipped (nothing changed): 0.5 min = prepare 0.5"},
		{call: "cron.line", args: [{started: "t", app: "a", outcome: "failed", steps: {}}], matches: "^t a failed: 0\\.0 min$", why: "no step ran: no steps part"},
		{call: "cron.line", args: [{started: "t", app: "a", outcome: "failed", commit: "abcdef1234", steps: {prepare: 30}}], matches: "^t a failed abcdef12: 0\\.5 min = prepare 0\\.5$", why: "a commit is eight characters"},
	]}
	"the launchd job has its label, the program, the wake interval, the log and the variables, escaped": {suite: "cron", steps: [
		{call: "cron.plist", args: [{label: "dev.pronto.release-cron.brawl-chess", program: "/usr/bin/deno", args: ["run", "-A", "a&b.ts", "<x>"], poll: 10, log: "/tmp/rc.log", env: {PATH: "/usr/bin:/bin", NOTE: "a&b<c>"}}]},
		{keep: "p"},
		{use: "p", matches: "<key>Label</key><string>dev\\.pronto\\.release-cron\\.brawl-chess</string>"},
		{use: "p", matches: "<array><string>/usr/bin/deno</string><string>run</string><string>-A</string><string>a&amp;b\\.ts</string><string>&lt;x&gt;</string></array>"},
		{use: "p", matches: "<key>StartInterval</key><integer>600</integer>"},
		{use: "p", matches: "<key>NOTE</key><string>a&amp;b&lt;c&gt;</string>"},
		{use: "p", matches: "<key>StandardOutPath</key><string>/tmp/rc\\.log</string>"},
		{use: "p", matches: "<key>StandardErrorPath</key><string>/tmp/rc\\.log</string>"},
		{call: "probe.dictEntries", args: ["$p"], expect: 2, why: "the job's own and the variables"},
	]}
	"a run's phases come from the newest record of its commit after the run began, cached checks left out": {suite: "cron", steps: [
		{call: "cron.detail", args: [
			[
				{commit: "c1", queued: "2026-11-03T01:00:00Z", waited: 999, checks: {old: {s: 1}}},
				{commit: "c1", queued: "2026-11-03T02:00:00Z", waited: 12, checks: {scenarios: {s: 600, flaked: ["a.cue"]}, lint: {s: 5, cached: true}, premium: {s: 40}}},
				{commit: "c2", queued: "2026-11-03T03:00:00Z", waited: 777, checks: {}},
			],
			[
				{commit: "c1", started: "2026-11-03T01:00:00Z", phases: {build: 1}, rc: 1},
				{commit: "c1", started: "2026-11-03T02:30:00Z", phases: {build: 120.4, push: null, deploy: 90, total: 500}, rc: 0},
			],
			"c1", "2026-11-03T02:00:00Z"],
			expect: {phases: {"rehearse.queue": 12, "rehearse.scenarios": 600, "rehearse.premium": 40, "release.build": 120, "release.deploy": 90}, flaked: ["a.cue (scenarios)"], rc: 0}},
		{call: "cron.detail", args: [[], [], "c1", "2026-11-03T02:00:00Z"], expect: {phases: {}, flaked: [], rc: null}, why: "nothing recorded for the commit"},
		{call: "cron.detail", args: [[{commit: "c1", queued: "2026-11-03T02:00:00Z", waited: 3, checks: {scenarios: {s: 600}, premium: {s: 0, skipped: true}}}], [], "c1", "2026-11-03T02:00:00Z"], expect: {phases: {"rehearse.queue": 3, "rehearse.scenarios": 600}, flaked: [], rc: null}, why: "a check the rehearsal skipped took no time (pronto#1546)"},
		{call: "cron.detail", args: [[{commit: "c1", queued: "2026-11-03T01:59:59Z", waited: 5}], [], "c1", "2026-11-03T02:00:00Z"], expect: {phases: {}, flaked: [], rc: null}, why: "a record before the run began is an earlier run's"},
	]}
	"a rehearsal that ended without judging the tree is no verdict, never bisected": {suite: "cron", steps: [
		for c in [1, 2] {{call: "cron.noVerdictExit", args: [c], expect: false, why: "a failure of the tree"}},
		for c in [3, 124, 130, 137] {{call: "cron.noVerdictExit", args: [c], expect: true, why: "no verdict, a timeout or a signal"}},
		{call: "cron.noVerdictRun", args: ["the rehearsal gave no verdict (exit 3): nothing released"], expect: true, why: "the bisect skips it"},
		{call: "cron.noVerdictRun", args: ["the rehearsal failed (exit 1): nothing released"], expect: false},
		{call: "cron.noVerdictRun", args: [null], expect: false},
		{call: "cron.noVerdictRun", args: ["any reason at all", "noVerdict"], expect: true, why: "a record's cause key is read, not its text"},
		{call: "cron.noVerdictRun", args: ["\(_causes.noVerdict): x", "rehearsalFailed"], expect: false, why: "the key decides when the record has one"},
		{call: "cron.noVerdictRun", args: ["x", "rehearsalStopped"], expect: true},
		{call: "cron.noVerdictRun", args: ["failed: x", "signal"], expect: true, why: "a run a signal stopped says nothing of a commit: never bisected"},
		{call: "cron.noVerdictRun", args: ["the release preview failed: up failed; \(_causes.rehearsalStopped): nothing released", null], expect: true, why: "a record with no cause key (written before it existed) is read by its why"},
		{call: "cron.noVerdictRun", args: ["the release preview failed: up failed: nothing released", null], expect: false},
	]}
	"the driver's reasons and cause keys for a failed run come from releaseCron.causes": {suite: "cron", steps: [
		{call: "cron.failureOf", args: ["beforeSlot", {noVerdict: true, command: "verify@local", code: 3, downFailed: ""}], expect: {why: "\(_causes.noVerdict): verify@local \(_causes.endedBeforeSlot) (exit 3): nothing released", cause: "noVerdict"}},
		{call: "cron.failureOf", args: ["beforeSlot", {noVerdict: false, command: "verify@local", code: 1, downFailed: "; removing the preview x"}], expect: {why: "verify@local \(_causes.endedBeforeSlot) (exit 1): nothing released; removing the preview x", cause: "endedBeforeSlot"}},
		{call: "cron.failureOf", args: ["noVerdict", {code: 124, downFailed: ""}], expect: {why: "\(_causes.noVerdict) (exit 124): nothing released", cause: "noVerdict"}},
		{call: "cron.failureOf", args: ["rehearsalFailed", {code: 1, downFailed: ""}], expect: {why: "\(_causes.rehearsalFailed) (exit 1): nothing released", cause: "rehearsalFailed"}},
		{call: "cron.failureOf", args: ["previewFailed", {bad: ["home /: 502", "x"], stopped: false}], expect: {why: "\(_causes.previewFailed): home /: 502; x: nothing released", cause: "previewFailed"}, why: "the after and first paths"},
		{call: "cron.failureOf", args: ["previewFailed", {bad: ["up failed"], stopped: true}], expect: {why: "\(_causes.previewFailed): up failed; \(_causes.rehearsalStopped): nothing released", cause: "rehearsalStopped"}, why: "the beside path with the rehearsal stopped"},
	]}
	// The overlap writes no `slot` step, so a beside run keeps the rehearsal's slot wait in run.beside.slot (PRONTO-870).
	"a beside run's rehearsal splits its time into the slot wait and the run, in seconds": {suite: "cron", steps: [
		{call: "cron.besideTimes", args: [1000000, 1600000, 5200000], expect: {slot: 600, rehearse: 3600}, why: "10 min queued, then 60 min run"},
		{call: "cron.besideTimes", args: [1000000, 1000000, 1900400], expect: {slot: 0, rehearse: 900}, why: "no slot wanted, or every check already green: no wait"},
		{call: "cron.besideTimes", args: [1000000, null, 1250000], expect: {slot: 250, rehearse: 0}, why: "ended before it had a slot: all waiting, none run"},
		{call: "cron.besideTimes", args: [1000000, 1000400, 1000900], expect: {slot: 0, rehearse: 1}, why: "rounded to the second"},
	]}
	"a preview beside the rehearsal: the first to fail stops the other, both pass releases": {suite: "cron", steps: [
		{call: "cron.besideOutcome", args: [null, {bad: ["home /: 502, expected 200"], at: 40}], expect: {stop: "rehearsal", failed: "preview", why: "the release preview failed: home /: 502, expected 200; the rehearsal was stopped"}, why: "the preview failed first: the rehearsal is stopped, and says so"},
		{call: "cron.besideOutcome", args: [{code: 1, at: 900}, null], expect: {stop: "preview", failed: "rehearsal", why: "the rehearsal failed (exit 1); the preview was stopped"}, why: "the rehearsal failed first: the preview is stopped"},
		{call: "cron.besideOutcome", args: [{code: 0, at: 4500}, null], expect: {stop: null, failed: null, why: ""}, why: "the rehearsal passed, the preview still runs"},
		{call: "cron.besideOutcome", args: [null, {bad: [], at: 840}], expect: {stop: null, failed: null, why: ""}, why: "the preview passed, the rehearsal still runs"},
		{call: "cron.besideOutcome", args: [{code: 0, at: 4500}, {bad: [], at: 840}], expect: {stop: null, failed: null, why: ""}, why: "both passed: release"},
		{call: "cron.besideOutcome", args: [{code: 1, at: 900}, {bad: ["up failed"], at: 950}], expect: {stop: null, failed: "rehearsal", why: "the rehearsal failed (exit 1)"}, why: "both failed: the earlier one is the verdict"},
		{call: "cron.besideOutcome", args: [{code: 143, at: 60}, {bad: ["up failed"], at: 50}, true], expect: {stop: null, failed: "preview", why: "the release preview failed: up failed; the rehearsal was stopped"}, why: "the rehearsal the driver stopped, asked once it ended (143): still says so"},
		{call: "cron.besideOutcome", args: [{code: 0, at: 55}, {bad: ["up failed"], at: 50}, false], expect: {stop: null, failed: "preview", why: "the release preview failed: up failed"}, why: "a rehearsal that passed just before its stop landed was not stopped"},
		{call: "cron.noVerdictRun", args: ["the release preview failed: up failed; the rehearsal was stopped: nothing released"], expect: true, why: "so it is never bisected"},
		{call: "cron.besideOutcome", args: [{code: 1, at: 900}, {bad: [], at: 800}], expect: {stop: null, failed: "rehearsal", why: "the rehearsal failed (exit 1)"}, why: "the preview already passed: nothing to stop"},
		{call: "cron.noVerdictRun", args: ["the release preview failed: home /: 502, expected 200; the rehearsal was stopped: nothing released"], expect: true, why: "a stopped rehearsal says nothing of a commit: never bisected"},
		{call: "cron.noVerdictRun", args: ["the release preview failed: home /: 502, expected 200: nothing released"], expect: false},
	]}
	"overlapping phases are one step, counted once": {suite: "cron", steps: [
		{call: "cron.line", args: [{started: "t", app: "a", outcome: "released", steps: {prepare: 30, "rehearse+preview": 4500, release: 600}}], expect: "t a released: 85.5 min = prepare 0.5, rehearse+preview 75.0, release 10.0", why: "the total sums the wall time once"},
	]}
	"a bisect check that judged nothing leaves its run open": {suite: "cron", steps: [
		for c in [3, 124, 126, 127, 130, 137] {{call: "cron.inconclusiveExit", args: [c], expect: true}},
		for c in [0, 1, 2] {{call: "cron.inconclusiveExit", args: [c], expect: false}},
	]}
	"a cloud rehearsal is named in the log line with its minutes and cost": {suite: "cron", steps: [
		{call: "cron.line", args: [{started: "t", app: "a", outcome: "released", steps: {prepare: 30, release: 1500}, rehearsal: {ok: true, seconds: 672, usd: 0.1183}}], expect: "t a released: 25.5 min = prepare 0.5, release 25.0; cloud rehearsal 11.2 min, $0.1183"},
	]}
	"a release record's cloud rehearsal is carried in the run's detail": {suite: "cron", steps: [
		{call: "cron.detail", args: [[], [{commit: "c1", started: "2026-11-03T02:30:00Z", phases: {rc: 600}, rc: "ran", rehearsal: {ok: true, seconds: 600, usd: 0.1}}], "c1", "2026-11-03T02:00:00Z"],
			expect: {phases: {"release.rc": 600}, flaked: [], rc: "ran", rehearsal: {ok: true, seconds: 600, usd: 0.1}}},
	]}
	"the report prices the cloud rehearsal per run and per month at 16 releases a day": {suite: "cron", steps: [
		{call: "cron.report", args: [[
			{started: "2026-11-02", outcome: "failed", commit: "aaaaaaaa11", steps: {release: 600}, detail: {phases: {}, rehearsal: {ok: false, seconds: 600, usd: 0.1}}},
			{started: "2026-11-03", outcome: "released", commit: "bbbbbbbb22", steps: {release: 900}, detail: {phases: {}, rehearsal: {ok: true, seconds: 900, usd: 0.2}}},
		]]},
		{keep: "r"},
		{use: "r", matches: "\\ncloud rehearsal: 2 runs, mean 12\\.5 min and \\$0\\.1500, \\$0\\.30 in all; at 16 a day, \\$72\\.00 a month$"},
	]}
	"the report is empty with no released run": {suite: "cron", steps: [
		{call: "cron.report", args: [[]], expect: "no released run yet"},
		{call: "cron.report", args: [[{started: "t", outcome: "skipped", steps: {prepare: 30}}]], expect: "no released run yet"},
	]}
	"three released runs: a row each, then the newest's phases, slowest first, against the median before": {suite: "cron", steps: [
		{call: "cron.report", args: [[
			{started: "2026-11-01", outcome: "released", commit: "aaaaaaaa11", steps: {rehearse: 600, release: 300}, detail: {phases: {"release.build": 100}}},
			{started: "2026-11-02", outcome: "skipped", steps: {prepare: 30}},
			{started: "2026-11-02", outcome: "released", commit: "bbbbbbbb22", steps: {rehearse: 700, release: 300}, detail: {phases: {"release.build": 140}}},
			{started: "2026-11-03", outcome: "released", commit: "cccccccc33", steps: {rehearse: 800, release: 300}, detail: {phases: {"release.build": 200, "rehearse.scenarios": 500}, flaked: ["a.cue (scenarios)"]}},
		]]},
		{keep: "r"},
		{use: "r", matches: "^2026-11-01 aaaaaaaa 15\\.0 min = rehearse 10\\.0, release 5\\.0\n2026-11-02 bbbbbbbb 16\\.7 min = rehearse 11\\.7, release 5\\.0\n2026-11-03 cccccccc 18\\.3 min = rehearse 13\\.3, release 5\\.0\n"},
		{use: "r", matches: "newest: 18\\.3 min, median before 15\\.8; its phases, slowest first:\n  rehearse\\.scenarios 8\\.3 min\n  release\\.build 3\\.3 min \\(median before 2\\.0, \\+1\\.3\\)", why: "a phase with nothing before it has no median"},
		{use: "r", matches: "\n  flaked, passed on retry: a\\.cue \\(scenarios\\)$"},
	]}
	"a failed run's signature is its kind and the scenarios its output marks failed": {suite: "cron", steps: [
		{call: "cron.signature", args: ["release@gcp failed (exit 1)", "[pass 2]   ✗ guest (202s) at step 39: {}\n[pass 1] ✗ seek (0s) at step 1: {}\n✗ guest (3s) at step 2"], expect: {kind: "release", names: ["guest", "seek"]}},
		{call: "cron.signature", args: ["the rehearsal failed (exit 1): nothing released", "verify: failed: integrate"], expect: {kind: "rehearsal", names: []}},
		{call: "cron.signature", args: ["the rehearsal failed (exit 1): nothing released", "rehearse: scenario failed: chat\n"], expect: {kind: "rehearsal", names: ["chat"]}, why: "a page that threw while its steps completed prints no step line (PRONTO-683)"},
		{call: "cron.signature", args: ["the rehearsal failed (exit 1): nothing released", "✗ online (12s) at step 3: {}\nrehearse: scenario failed: online\nrehearse: scenario failed: chat\n"], expect: {kind: "rehearsal", names: ["online", "chat"]}, why: "each name once, from step lines and the rehearsal's verdict lines"},
		{call: "cron.signature", args: ["released, production not confirmed: home 500", ""], expect: {kind: "release", names: []}},
	]}
	"merges are read oldest first with their pull request and branch": {suite: "cron", steps: [
		{call: "cron.merges", args: [["ccc Merge pull request #12 from bsoneca/fix/x", "bbb Direct push", "aaa Merge pull request #11 from o/feat/y z", ""]], expect: [
			{sha: "aaa", subject: "Merge pull request #11 from o/feat/y z", pr: 11, branch: "feat/y"},
			{sha: "bbb", subject: "Direct push", pr: null, branch: null},
			{sha: "ccc", subject: "Merge pull request #12 from bsoneca/fix/x", pr: 12, branch: "fix/x"},
		]},
	]}
	"the records say whether a commit is good or bad for the failure's kind, the newest evidence counting, a dirty tree none": {suite: "cron", steps: [
		{call: "cron.verdict", args: ["c1", {kind: "release", names: []}, {releases: [{commit: "c1", dirty: false, outcome: "live", started: "1"}]}], expect: "good"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1"}]}], expect: "good", why: "an app whose records say no mode keeps every clean record"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1"}, {commit: "c2", dirty: false, outcome: "passed", queued: "2", mode: "release"}]}], expect: "unknown", why: "once records say their mode, one from before modes proves nothing"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1", mode: "hand"}]}], expect: "unknown", why: "a hand run is not release evidence"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1", mode: "release", excused: ["new-thing"]}]}], expect: "unknown", why: "a pass that excused a new feature's failure proves nothing of that scenario"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1", mode: "release"}]}], expect: "good"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {strict: true, rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1"}]}], expect: "unknown", why: "an app in release mode trusts no untagged record, even before its first tagged one"},
		{call: "cron.releaseModes", args: [["env", "REHEARSE_RELEASE=1", "./saytw", "verify@local"]], expect: true},
		{call: "cron.releaseModes", args: [["./saytw", "verify@local"]], expect: false},
		{call: "cron.releaseModes", args: [null], expect: false},
		{call: "cron.verdict", args: ["c1", {kind: "release", names: []}, {releases: [{commit: "c1", dirty: false, outcome: "failed", failure: "the tests failed against https://x", started: "1"}]}], expect: "bad"},
		{call: "cron.verdict", args: ["c1", {kind: "release", names: ["a"]}, {releases: [{commit: "c1", dirty: false, outcome: "failed", failure: "the tests failed against https://x", started: "1"}]}], expect: "unknown", why: "a failed rc names no scenario: it may be another one"},
		{call: "cron.verdict", args: ["c1", {kind: "release", names: ["a"]}, {releases: [{commit: "c1", dirty: false, outcome: "live", started: "1"}]}], expect: "good"},
		{call: "cron.verdict", args: ["c1", {kind: "release", names: []}, {releases: [{commit: "c1", dirty: false, outcome: "failed", failure: "gcloud run services replace died", started: "1"}]}], expect: "unknown", why: "another failure is no evidence about this one"},
		{call: "cron.verdict", args: ["c1", {kind: "release", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "passed", queued: "1"}]}], expect: "unknown", why: "a local rehearsal pass says nothing of the cloud's rc"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: false, outcome: "failed", queued: "1"}, {commit: "c1", dirty: false, outcome: "passed", queued: "2"}]}], expect: "good", why: "the newer pass"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: []}, {rehearsals: [{commit: "c1", dirty: true, outcome: "passed", queued: "1"}]}], expect: "unknown"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: ["a"]}, {ledger: [{commit: "c1", kind: "rehearsal", names: ["a"], verdict: "bad", at: "1"}]}], expect: "bad", why: "a verdict an earlier bisect ran for the same scenarios"},
		{call: "cron.verdict", args: ["c1", {kind: "rehearsal", names: ["b"]}, {ledger: [{commit: "c1", kind: "rehearsal", names: ["a"], verdict: "good", at: "1"}]}], expect: "unknown", why: "a pass of other scenarios proves nothing of these"},
	]}
	"the rehearsal's env names the serving commit only for a command target": {suite: "cron", steps: [
		{call: "cron.rehearsalEnv", args: [{A: "1"}, "abc123", true], expect: {A: "1", REHEARSE_LIVE: "abc123"}, why: "a command target with a serving commit"},
		{call: "cron.rehearsalEnv", args: [{A: "1"}, null, true], expect: {A: "1"}, why: "the serving commit did not resolve"},
		{call: "cron.rehearsalEnv", args: [{A: "1"}, "abc123", false], expect: {A: "1"}, why: "Cloud Run: the release record serves"},
		{call: "cron.rehearsalEnv", args: [{A: "1", REHEARSE_LIVE: "stale"}, null, true], expect: {A: "1"}, why: "an inherited value is dropped"},
		{call: "cron.rehearsalEnv", args: [{REHEARSE_LIVE: "stale"}, "abc123", true], expect: {REHEARSE_LIVE: "abc123"}, why: "and replaced"},
	]}
	"the rehearsal's env carries the commit it rehearses, and a baseline read as it starts": {suite: "cron", steps: [
		{call: "cron.rehearsalEnv", args: [{A: "1"}, "abc123", true, "def456"], expect: {A: "1", REHEARSE_LIVE: "abc123", REHEARSE_COMMIT: "def456"}, why: "both named"},
		{call: "cron.rehearsalEnv", args: [{REHEARSE_LIVE: "stale", REHEARSE_COMMIT: "stale"}, null, true, "def456"], expect: {REHEARSE_COMMIT: "def456"}, why: "an inherited baseline is dropped, never left for the child to read"},
		{call: "cron.rehearsalEnv", args: [{A: "1"}, "abc123", false, "def456"], expect: {A: "1", REHEARSE_COMMIT: "def456"}, why: "Cloud Run: no REHEARSE_LIVE, REHEARSE_COMMIT still set"},
		{call: "cron.rehearsalBase", args: ["bbb", "aaa", "head1"], expect: {live: "bbb", rehearsed: "head1", moved: true}, why: "another release landed while the run waited: the baseline is the one now"},
		{call: "cron.rehearsalBase", args: ["aaa", "aaa", "head1"], expect: {live: "aaa", rehearsed: "head1", moved: false}, why: "unchanged"},
		{call: "cron.rehearsalBase", args: [null, "aaa", "head1"], expect: {live: null, rehearsed: "head1", moved: false}, why: "unread as the rehearsal starts: unknown, not the stale earlier one"},
		{call: "cron.rehearsalBase", args: ["bbb", null, "head1"], expect: {live: "bbb", rehearsed: "head1", moved: false}, why: "none known at the run's start: nothing moved"},
	]}
	"the search tests the middle of what the verdicts leave and names the first bad commit after the last good": {suite: "cron", steps: [
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}, {sha: "d"}, {sha: "e"}], {e: "bad"}], expect: {test: {sha: "b"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}, {sha: "d"}, {sha: "e"}], {b: "good", e: "bad"}], expect: {test: {sha: "c"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}, {sha: "d"}, {sha: "e"}], {b: "good", d: "bad", e: "bad"}], expect: {test: {sha: "c"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}, {sha: "d"}, {sha: "e"}], {c: "good", d: "bad", e: "bad"}], expect: {culprit: {sha: "d"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}], {a: "bad", b: "bad"}], expect: {culprit: {sha: "a"}}, why: "nothing good in between: the first of them"},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}], {a: "unknown", b: "unknown", c: "bad"}], expect: {test: {sha: "a"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}], {a: "good", b: "unknown", c: "bad"}], expect: {test: {sha: "b"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}], {a: "good", b: "unknown", c: "bad"}], expect: {test: {sha: "b"}}},
		{call: "cron.next", args: [[{sha: "a"}, {sha: "b"}, {sha: "c"}], {a: "good", c: "bad", b: "good"}], expect: {culprit: {sha: "c"}}},
	]}
	"a pull request names its author session by a Claude Desktop session id": {suite: "cron", steps: [
		{call: "cron.sessionOf", args: ["Opened by local_ac4f76fa-5c86-4a47-96d1-e2d01cf8bf95, gate green"], expect: "local_ac4f76fa-5c86-4a47-96d1-e2d01cf8bf95"},
		{call: "cron.sessionOf", args: ["no session here"], expect: null},
		{call: "cron.sessionOf", args: [null], expect: null},
	]}
	"a bisect reads as one line": {suite: "cron", steps: [
		{call: "cron.bisectLine", args: [{of: "r1", culprit: "0123456789ab", pr: 5, branch: "fix/x", ran: 2, fromRecords: 3, notified: "PR #5 comment"}], expect: "r1: culprit 01234567 (PR #5, fix/x); checks run 2, from records 3; told PR #5 comment"},
		{call: "cron.bisectLine", args: [{of: "r1", range: ["aaaaaaaa11", "bbbbbbbb22"], ran: 0, fromRecords: 1}], expect: "r1: narrowed to aaaaaaaa bbbbbbbb; checks run 0, from records 1"},
	]}
	"a bisect names a commit only when the failing commit's own check fails too": {suite: "cron", steps: [
		{call: "cron.unreproduced", args: ["rehearsal", "bad"], expect: null, why: "reproduced: the search goes on"},
		{call: "cron.unreproduced", args: ["rehearsal", "good"], expect: "the check passes here on the failing commit: a failure of the run's conditions (a service stopped from outside, the machine), not of a commit, not bisected", why: "2026-11-06: every flagd killed from outside mid-rehearsal, and the last PR merged was blamed"},
		{call: "cron.unreproduced", args: ["release", "good"], expect: "the check passes here on the failing commit: a failure only the cloud shows, not bisected"},
		{call: "cron.unreproduced", args: ["release", "timeout"], expect: "the check did not finish here on the failing commit: a failure only the cloud shows, not bisected"},
	]}
	"an unreproduced bisect reads as its why": {suite: "cron", steps: [
		{call: "cron.bisectLine", args: [{of: "r1", why: "the check passes here on the failing commit: not bisected", ran: 1, fromRecords: 0, notified: "notes of lead"}], expect: "r1: the check passes here on the failing commit: not bisected; checks run 1, from records 0; told notes of lead"},
	]}
	"a release line names the new-feature scenarios that failed": {suite: "cron", steps: [
		{call: "cron.newFeatureNames", args: ["gcp: 2026-11-04T10:00:00-03:00 new-feature scenarios failed, released anyway: a, b (absent from 0123abcd, live release)"], expect: ["a", "b"]},
		{call: "cron.newFeatureNames", args: ["gcp: 2026-11-04T10:00:00-03:00 released on stable features; new-feature scenarios failed: a, b (absent from 0123abcd, live release)"], expect: ["a", "b"], why: "the rule's name since the rename"},
		{call: "cron.newFeatureNames", args: ["released on stable features; new-feature scenarios failed: solo"], expect: ["solo"], why: "new line, no tail"},
		{call: "cron.newFeatureNames", args: ["new-feature scenarios failed, released anyway: solo"], expect: ["solo"], why: "no tail, one name"},
		{call: "cron.newFeatureNames", args: ["gcp: released"], expect: []},
		{call: "cron.newFeatureNames", args: [null], expect: []},
	]}
	"the merge that added a scenario is the first whose tree has it": {suite: "cron", steps: [
		{call: "cron.introducedBy", args: [[{sha: "a", pr: 1}, {sha: "b", pr: 2}, {sha: "c", pr: 3}], {a: false, b: true, c: true}, false], expect: {sha: "b", pr: 2}},
		{call: "cron.introducedBy", args: [[{sha: "a", pr: 1}], {a: true}, true], expect: null, why: "the last release already had it"},
		{call: "cron.introducedBy", args: [[{sha: "a", pr: 1}], {a: false}, false], expect: null, why: "no merge has it"},
	]}
	"a new-feature scenario's PR is told once": {suite: "cron", steps: [
		{call: "cron.untold", args: [[{scenario: "a", pr: 2}, {scenario: "b", pr: 3}], [{scenario: "a", pr: 2, told: "PR #2 comment"}]], expect: [{scenario: "b", pr: 3}]},
		{call: "cron.untold", args: [[{scenario: "a", pr: 4}], [{scenario: "a", pr: 2}]], expect: [{scenario: "a", pr: 4}], why: "another PR re-adding it is told"},
	]}
	"a rehearsal's output names the scenarios that flaked": {suite: "cron", steps: [
		{call: "cron.flakedNames", args: ["rehearse: 1011s scenarios, pass 2: passed (flaked, passed on its one retry: seek_notify, gold)"], expect: ["seek_notify", "gold"], why: "the per-check line"},
		{call: "cron.flakedNames", args: ["  ⚠ flaked, passed on its one retry: seek_notify (scenarios)"], expect: ["seek_notify"], why: "the summary line, a name the real 15:34 BRT run flaked"},
		{call: "cron.flakedNames", args: ["rehearse: passed (flaked, passed on its one retry: a)\n  ⚠ flaked, passed on its one retry: a, b (scenarios)"], expect: ["a", "b"], why: "both lines, once each"},
		{call: "cron.flakedNames", args: ["✓ online (198s): accept-online-challenge\n⚠ online flaked, passed on its one retry\n✓ table-link (16s): accept-online-guest"], expect: ["online"], why: "release@gcp's rc test line, the real 19:15 BRT run's"},
		{call: "cron.flakedNames", args: ["⚠ online flaked, passed on its one retry\n⚠ online flaked, passed on its one retry\n  ⚠ flaked, passed on its one retry: online, gold (scenarios)"], expect: ["online", "gold"], why: "the same scenario in both formats, once"},
		{call: "cron.flakedNames", args: ["rehearse: 12s scenarios: passed"], expect: []},
		{call: "cron.flakedNames", args: [null], expect: []},
		{call: "cron.newFeatureNames", args: ["rehearse: released on stable features; new-feature scenarios failed: a, b (absent from 0123abcd, live release)"], expect: ["a", "b"], why: "the rehearsal's line reads as the release's"},
	]}
	"the merge that last changed a scenario is the newest whose diff touched it": {suite: "cron", steps: [
		{call: "cron.changedBy", args: [[{sha: "a", pr: 1}, {sha: "b", pr: 2}, {sha: "c", pr: 3}], {a: true, b: true, c: false}], expect: {sha: "b", pr: 2}},
		{call: "cron.changedBy", args: [[{sha: "a", pr: 1}], {a: false}], expect: null},
	]}
	"a run line names the scenarios that flaked": {suite: "cron", steps: [
		{call: "cron.line", args: [{app: "x", started: "t", outcome: "released", steps: {release: 60}, newFailing: ["a"], flaked: ["b", "c"]}], expect: "t x released; new-feature scenarios failing: a; flaked: b, c: 1.0 min = release 1.0"},
	]}
	"a release that shipped past new-feature failures says so in its line": {suite: "cron", steps: [
		{call: "cron.line", args: [{app: "x", started: "t", outcome: "released", steps: {release: 60}, newFailing: ["a", "b"]}], expect: "t x released; new-feature scenarios failing: a, b: 1.0 min = release 1.0"},
	]}
}

cases: {
	"the launchd job is the plist it always was": {suite: "cron", steps: [
		{call: "cron.plist", args: [{"label": "dev.pronto.release-cron.brawl-chess", "program": "/usr/bin/deno", "args": ["run", "-A", "/wt/apps/brawl-chess/release-cron/release-cron.ts", "brawl-chess", "run"], "poll": 10, "log": "/c/launchd.log", "env": {"PATH": "/usr/bin:/bin", "HOME": "/Users/me"}}], expect: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key><string>dev.pronto.release-cron.brawl-chess</string>\n\t<key>ProgramArguments</key>\n\t<array><string>/usr/bin/deno</string><string>run</string><string>-A</string><string>/wt/apps/brawl-chess/release-cron/release-cron.ts</string><string>brawl-chess</string><string>run</string></array>\n\t<key>StartInterval</key><integer>600</integer>\n\t<key>EnvironmentVariables</key>\n\t<dict><key>PATH</key><string>/usr/bin:/bin</string><key>HOME</key><string>/Users/me</string></dict>\n\t<key>StandardOutPath</key><string>/c/launchd.log</string>\n\t<key>StandardErrorPath</key><string>/c/launchd.log</string>\n\t<key>ProcessType</key><string>Standard</string>\n</dict>\n</plist>\n", why: "the launchd scheduler's output, unchanged by the systemd one beside it (PRONTO-141)"},
	]}
	"the systemd job is a oneshot service and a timer from the same inputs": {suite: "cron", steps: [
		{call: "cron.systemdUnits", args: [{"label": "dev.pronto.release-cron.brawl-chess", "program": "/usr/bin/deno", "args": ["run", "-A", "/wt/apps/brawl-chess/release-cron/release-cron.ts", "brawl-chess", "run"], "poll": 10, "log": "/c/systemd.log", "env": {"PATH": "/usr/bin:/bin", "HOME": "/Users/me"}}]},
		{keep: "u"},
		{get: "service", expect: "[Unit]\nDescription=release-cron dev.pronto.release-cron.brawl-chess\n\n[Service]\nType=oneshot\nExecStart=\"/usr/bin/deno\" \"run\" \"-A\" \"/wt/apps/brawl-chess/release-cron/release-cron.ts\" \"brawl-chess\" \"run\"\nEnvironment=\"PATH=/usr/bin:/bin\"\nEnvironment=\"HOME=/Users/me\"\nStandardOutput=append:/c/systemd.log\nStandardError=append:/c/systemd.log\n", why: "the service runs the program once, its output appended to the log"},
		{use: "u"},
		{get: "timer", expect: "[Unit]\nDescription=release-cron dev.pronto.release-cron.brawl-chess, every 10 min\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=10min\nUnit=dev.pronto.release-cron.brawl-chess.service\n\n[Install]\nWantedBy=timers.target\n", why: "OnUnitActiveSec is the poll minutes, OnBootSec starts a run after a restart"},
		{call: "cron.systemdUnits", args: [{"label": "dev.pronto.release-cron.brawl-chess", "program": "/usr/bin/deno", "args": ["a b", "50%$HOME", "q\"x"], "poll": 10, "log": "/l", "env": {"N": "a%b"}}]},
		{get: "service", expect: "[Unit]\nDescription=release-cron dev.pronto.release-cron.brawl-chess\n\n[Service]\nType=oneshot\nExecStart=\"/usr/bin/deno\" \"a b\" \"50%%$$HOME\" \"q\\\"x\"\nEnvironment=\"N=a%%b\"\nStandardOutput=append:/l\nStandardError=append:/l\n", why: "words quoted, a quote escaped, % and $ doubled: a unit file expands both"},
	]}
	"a finding reaches the channels its notify names": {suite: "cron", steps: [
		{call: "cron.channels", args: [{kind: "none"}, "darwin"], expect: ["log"], why: "none logs only"},
		{call: "cron.channels", args: [{kind: "github-comment"}, "linux"], expect: ["comment"]},
		{call: "cron.channels", args: [{kind: "claude-session", lead: "L", notes: "n"}, "darwin"], expect: ["comment", "notes", "toast"]},
		{call: "cron.channels", args: [{kind: "claude-session", lead: "L", notes: "n"}, "linux"], expect: ["comment", "notes"], why: "the macOS notification only on darwin"},
	]}
	"a hook is its command with the worktree, the app and the commit appended, for its event only": {suite: "cron", steps: [
		{call: "cron.hookArgv", args: [{on: "released", command: ["deno", "run", "-A", "--reload=https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/", "https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/hook.ts", "released"]}, "/state/wt", "brawl-chess", "c9ecd1f7a0b1"], expect: ["deno", "run", "-A", "--reload=https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/", "https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/hook.ts", "released", "/state/wt", "brawl-chess", "c9ecd1f7a0b1"], why: "the dev flow's released hook, as Bonk Chess's and Book a time's releaseCron names it (PRONTO-1's board step, before hooks)"},
		{call: "cron.hooksOf", args: [[{on: "released", command: ["a"]}, {on: "other", command: ["b"]}, {on: "released", command: ["c"]}], "released"], expect: [{on: "released", command: ["a"]}, {on: "released", command: ["c"]}], why: "in the order named"},
	]}
	"the flags' released command is the app's own with its folder appended, and none where the app names none": {suite: "cron", steps: [
		{call: "cron.flagsReleasedArgv", args: [["pronto-flags", "released"], "/state/wt/apps/brawl-chess"], expect: ["pronto-flags", "released", "/state/wt/apps/brawl-chess"], why: "run once production serves the release, and when a run finds main already serving (PRONTO-680)"},
		{call: "cron.flagsReleasedArgv", args: [null, "/state/wt/apps/brawl-chess"], expect: null, why: "an app with no flagsReleased records nothing, and nothing runs"},
	]}
	"a run records the served release's flags with a limit, and a failure of it is only said": {suite: "cron", steps: [
		{call: "cron.recordFlagsReleased", args: [["true"], "/state/wt/apps/shop"], expect: "ok", why: "a confirmed release calls it, and it succeeds"},
		{call: "cron.recordFlagsReleased", args: [["sh", "-c", "echo boom >&2; exit 3"], "/state/wt/apps/shop"], expect: "failed (exit 3: boom)", why: "a failing command returns a result and throws nothing, so the run's outcome stays"},
		{call: "cron.recordFlagsReleased", args: [["sh", "-c", "sleep 5"], "/state/wt/apps/shop", {timeoutMs: 100}], expect: "failed (timed out after 0.1s)", why: "a command that hangs is stopped"},
		{call: "cron.recordFlagsReleased", args: [null, "/state/wt/apps/shop"], expect: null, why: "an app that names none runs nothing"},
	]}
	"a run that finds main already serving records the flags again only when the last record was for another commit": {suite: "cron", steps: [
		{call: "cron.flagsReleasedDue", args: [null, "c9ecd1f7a0b1"], expect: true, why: "no record yet"},
		{call: "cron.flagsReleasedDue", args: ["c9ecd1f7a0b1\n", "c9ecd1f7a0b1"], expect: false, why: "recorded for the commit served"},
		{call: "cron.flagsReleasedDue", args: ["0b2206c3aaaa", "c9ecd1f7a0b1"], expect: true},
	]}
	"the android step runs only where it is declared and the run is on a Mac": {suite: "cron", steps: [
		{call: "cron.androidRuns", args: [{command: ["x"]}, "darwin"], expect: true},
		{call: "cron.androidRuns", args: [null, "darwin"], expect: false, why: "none declared: none run"},
		{call: "cron.androidRuns", args: [{command: ["x"]}, "linux"], expect: false, why: "the emulator needs a Mac"},
	]}
	"a declared android step is skipped, and the log says so, where the run is not on a Mac": {suite: "cron", steps: [
		{call: "cron.androidSkip", args: [{command: ["x"]}, "linux"], expect: "android: skipped, release-cron runs on linux and the emulator needs a Mac; the release goes on without the phone's scenarios"},
		{call: "cron.androidSkip", args: [{command: ["x"]}, "darwin"], expect: null},
		{call: "cron.androidSkip", args: [null, "linux"], expect: null, why: "none declared: nothing to skip"},
	]}
	"the android step's failed scenarios are the FAIL lines of its output": {suite: "cron", steps: [
		{call: "cron.androidFailed", args: ["pass  board  8.1 s\nFAIL  sealed  12.3 s  nothing matches #board2d\nskip  x  asserts on private files"], expect: ["sealed"]},
		{call: "cron.androidFailed", args: ["pass  board  8.1 s"], expect: [], why: "none failed"},
	]}
	"a failed android step is its own kind of failure, and its bisect says it does not run it": {suite: "cron", steps: [
		{call: "cron.androidWhy", args: [2, []], expect: "the android step failed (exit 2): nothing released", why: "no scenario named: no empty \": :\""},
		{call: "cron.androidWhy", args: [1, ["sealed", "fullscreen"]], expect: "the android step failed (exit 1): sealed, fullscreen: nothing released"},
		{keep: "why"},
		{call: "cron.signature", args: ["$why", "FAIL  sealed  12.3 s  nothing matches #board2d"], holds: {kind: "android", names: ["sealed"]}, why: "the driver's own why is read back as the android kind"},
		{call: "cron.undecidable", args: [{kind: "android", names: ["sealed"]}, "", [], 0, 18], expect: "the android step runs on an emulator, which the bisect's check (integrate@local) does not: not bisected"},
	]}
	"a signal gives the lock back only after the children are gone and the preview beside has torn down, each bounded": {suite: "cron", steps: [
		{call: "cron.signalStep", args: [true, 1, 1000, 60000, 300000], expect: "wait", why: "children still within their grace"},
		{call: "cron.signalStep", args: [true, 1, 60000, 60000, 300000], expect: "kill", why: "their grace is over"},
		{call: "cron.signalStep", args: [false, 1, 61000, 60000, 300000], expect: "wait", why: "the children are gone but the preview's down still runs: the lock is held"},
		{call: "cron.signalStep", args: [false, 0, 61000, 60000, 300000], expect: "done", why: "down finished: the lock goes"},
		{call: "cron.signalStep", args: [false, 0, 0, 60000, 300000], expect: "done", why: "nothing was running"},
		{call: "cron.signalStep", args: [false, 1, 360000, 60000, 300000], expect: "done", why: "a down that never ends is waited for a bounded time"},
	]}
	"the serving command is read again only after an ssh transport failure": {suite: "cron", steps: [
		{call: "cron.servingRetryable", args: [255], expect: true, why: "ssh's own failure, the case the retry exists for"},
		{call: "cron.servingRetryable", args: [1], expect: false, why: "the command ran and failed: said at once"},
		{call: "cron.servingRetryable", args: [127], expect: false},
		{call: "cron.servingRetryable", args: [142], expect: false, why: "killed by the alarm"},
	]}
	"a run that ends after a signal ends as stopped, whatever it reached": {suite: "cron", steps: [
		{call: "cron.endWhenInterrupted", args: [true, "failed"], expect: "stopped", why: "a killed child's failure is no verdict"},
		{call: "cron.endWhenInterrupted", args: [true, "skipped"], expect: "stopped"},
		{call: "cron.endWhenInterrupted", args: [true, "stopped"], expect: "stopped", why: "the handler's own end"},
		{call: "cron.endWhenInterrupted", args: [true, "released"], expect: "released", why: "a release that landed stays one"},
		{call: "cron.endWhenInterrupted", args: [false, "failed"], expect: "failed", why: "no signal, no change"},
	]}
}
