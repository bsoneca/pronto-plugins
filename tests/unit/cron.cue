// release-cron's rules (../../release-cron/cron.js) on the inputs they were written for.
package unit

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
	"only a run that released or failed makes the next one wait": {suite: "cron", steps: [
		{call: "cron.spaced", args: ["released"], expect: true},
		{call: "cron.spaced", args: ["failed"], expect: true},
		{call: "cron.spaced", args: ["skipped"], expect: false},
		{call: "cron.spaced", args: [""], expect: false},
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
		{call: "cron.detail", args: [[{commit: "c1", queued: "2026-11-03T01:59:59Z", waited: 5}], [], "c1", "2026-11-03T02:00:00Z"], expect: {phases: {}, flaked: [], rc: null}, why: "a record before the run began is an earlier run's"},
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
}
