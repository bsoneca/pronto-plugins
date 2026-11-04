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
	"only a run that released or failed makes the next one wait": {suite: "cron", steps: [
		{call: "cron.spaced", args: ["released"], expect: true},
		{call: "cron.spaced", args: ["failed"], expect: true},
		{call: "cron.spaced", args: ["skipped"], expect: false},
		{call: "cron.spaced", args: [""], expect: false},
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
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/ume-rental ./saytw integrate@local (weight 10)", "/w/apps/ume-rental", "./saytw integrate@local"], expect: true, why: "an app's own holder"},
		{call: "cron.holds", args: ["70813 2026-11-03T09:19:37.701Z /w/apps/ume-rental verify@local (weight 10)", "/w/apps/ume-rental", "./saytw integrate@local"], expect: false, why: "not the holder it names"},
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
		{call: "cron.detail", args: [[{commit: "c1", queued: "2026-11-03T01:59:59Z", waited: 5}], [], "c1", "2026-11-03T02:00:00Z"], expect: {phases: {}, flaked: [], rc: null}, why: "a record before the run began is an earlier run's"},
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
