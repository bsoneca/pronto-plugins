// release-cron's retry, probe, preview, bisect and board rules (../../release-cron/cron.js): the cases pronto's
// apps/brawl-chess carried (release_cron_{retry,bisect,probe,board}.cue) before the rules moved here.
package unit

_rehearsal: {kind: "rehearsal", names: []}
_lint: ["integrate@local"]
_specs: [{id: "menu", flags: true, slow: false}, {id: "seek_race", flags: false, slow: true}, {id: "guest", flags: false, slow: false}]

cases: {
	"a failed rehearsal's summary names its failed checks": {suite: "cron", steps: [
		{call: "cron.failedRehearsal", args: ["rehearse: SLOW=1, in 1112s\n  ✗ integrate@local\n  ✓ stack, slot 11: https://localhost:34000\n  ✗ premium\n  ✓ scenarios, pass 1: flaked, passed on its one retry: trial_failed\n"], expect: ["integrate@local", "premium"], why: "2026-11-07 17:56 BRT"},
		{call: "cron.failedRehearsal", args: ["  ✗ scenarios, pass 1: 1 failed\n"], expect: ["scenarios, pass 1"]},
		{call: "cron.failedRehearsal", args: ["  ✗ analytics (19s) at step 5 (the tracker's pageview): {}\n"], expect: [], why: "a scenario's own failure line is not a check"},
	]}
	"a failed run is retried early only by a change that concerns what failed": {suite: "cron", steps: [
		{call: "cron.concerns", args: [[".github/workflows/ci.yml", "docs/metrics.md", "tools/metrics/metrics.js", "tools/metrics/pr-slo.ts"], "apps/brawl-chess", _rehearsal, _lint], expect: null, why: "2026-11-07: 17:56 failed the visual lint; main moved by #831 and #832 alone and 18:16 failed it again 8 minutes later"},
		{call: "cron.concerns", args: [["apps/brawl-chess/shell/hatches/battle/messages.js"], "apps/brawl-chess", _rehearsal, _lint], expect: {file: "apps/brawl-chess/shell/hatches/battle/messages.js", why: "read by integrate@local"}, why: "a served file: the pages the visual lint loads"},
		{call: "cron.concerns", args: [["apps/brawl-chess/README.md", "apps/brawl-chess/journal/2026-11-07.md", "apps/brawl-chess/tests/unit/slot.cue", "apps/brawl-chess/tests/premium.ts", "apps/brawl-chess/tests/scenarios/seek.cue"], "apps/brawl-chess", _rehearsal, _lint], expect: null, why: "documentation, unit cases, and the runners of checks that passed"},
		{call: "cron.concerns", args: [["apps/brawl-chess/tests/premium.ts"], "apps/brawl-chess", _rehearsal, ["premium"]], expect: {file: "apps/brawl-chess/tests/premium.ts", why: "premium's runner, and premium failed"}},
		{call: "cron.concerns", args: [["apps/brawl-chess/tests/scenarios/seek.cue"], "apps/brawl-chess", {kind: "rehearsal", names: ["seek"]}, ["scenarios, pass 1"]], expect: {file: "apps/brawl-chess/tests/scenarios/seek.cue", why: "a scenario's steps, and scenarios failed"}},
		{call: "cron.concerns", args: [["mise.lock"], "apps/brawl-chess", _rehearsal, _lint], expect: {file: "mise.lock", why: "a tool pin above the app"}, why: "the toolchain every check runs on"},
		{call: "cron.concerns", args: [["apps/studio/mise.lock"], "apps/brawl-chess", _rehearsal, _lint], expect: null, why: "another app's pin"},
		{call: "cron.concerns", args: [["infra/gcp/main.cue"], "apps/brawl-chess", {kind: "release", names: []}, []], expect: {file: "infra/gcp/main.cue", why: "the cloud's configuration, which a release reads"}},
		{call: "cron.concerns", args: [["apps/brawl-chess/tests/scenarios/seek.cue"], "apps/brawl-chess", _rehearsal, []], expect: {file: "apps/brawl-chess/tests/scenarios/seek.cue", why: "a scenario's steps, and scenarios failed"}, why: "no check could be read from the log: everything concerns it"},
	]}
}

cases: {
	"a failure that a flag, time or the load decides is not bisected": {suite: "cron", steps: [
		{call: "cron.undecidable", args: [{kind: "rehearsal", names: ["menu"]}, "", _specs, 2, 18], expect: "menu depends on a flag (flags or slow in its CUE), which the commit under test does not decide, not bisected", why: "#771's flag-off menu path was blamed on #773"},
		{call: "cron.undecidable", args: [{kind: "rehearsal", names: ["seek_race"]}, "", _specs, 2, 18], expect: "seek_race depends on time (flags or slow in its CUE), which the commit under test does not decide, not bisected"},
		{call: "cron.undecidable", args: [{kind: "rehearsal", names: ["guest"]}, "", _specs, 2, 18], expect: null, why: "a plain scenario is the commit's"},
		{call: "cron.undecidable", args: [{kind: "rehearsal", names: ["guest"]}, "", _specs, 185, 18], expect: "the machine is under load (185 on 18 cores): a timing check would fail by itself, not bisected"},
		{call: "cron.undecidable", args: [{kind: "rehearsal", names: []}, "check-menu-budget failed", _specs, 2, 18], expect: "the menu budget is a timing check, not bisected"},
		{call: "cron.undecidable", args: [{kind: "release", names: []}, "  menu time 9327 ms > 6000 ms\nverify: failed: check-menu-budget\n", _specs, 2, 18], expect: "the menu budget is a timing check, not bisected", why: "2026-11-07 10:11 BRT: the rc failed only the menu budget, and its bisect ran a whole local check to say so"},
		{call: "cron.undecidable", args: [{kind: "release", names: ["analytics"]}, "verify: failed: check-menu-budget check-online\n", _specs, 2, 18], expect: null, why: "11:29: a scenario failed beside the menu budget: the commit's to find"},
		{call: "cron.undecidable", args: [{kind: "release", names: []}, "verify: failed: check-online\n", _specs, 185, 18], expect: null, why: "a release's failure is the cloud's: the load here now says nothing of it"},
		{call: "cron.failedChecks", args: ["verify: failed: check-online\n...\nverify: failed: check-menu-budget check-online\n"], expect: ["check-menu-budget", "check-online"], why: "the last verify line"},
		{call: "cron.failedChecks", args: ["scenarios: 48 passed"], expect: []},
	]}
	"a bisect never holds a release up": {suite: "cron", steps: [
		{call: "cron.stopsBisect", args: [4242, 4100, true, null, null], expect: "a release-cron run (4242) is going: the bisect yields to it, its verdicts kept", why: "2026-11-07: a bisect held the release runner 12:12-15:12 BRT"},
		{call: "cron.stopsBisect", args: [4100, 4100, true, null, null], expect: null, why: "the run that started it, letting the lock go as it ends"},
		{call: "cron.stopsBisect", args: [4242, 4100, false, null, null], expect: null, why: "a dead run's lock"},
		{call: "cron.stopsBisect", args: [0, 0, false, "8bec01a55a56ea06b3d2554b592845cda8ed4acf", null], expect: "a run since released 8bec01a5: nothing to bisect"},
		{call: "cron.stopsBisect", args: [0, 0, false, null, "69468094aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], expect: "main is green for this failure at 69468094: fixed, not bisected"},
		{call: "cron.fixedBy", args: [["a1", "b2", "c3"], {kind: "rehearsal", names: []}, {rehearsals: [{commit: "b2", outcome: "failed", queued: "1"}, {commit: "c3", outcome: "passed", queued: "2"}]}], expect: "c3", why: "the first commit after the failed one that the records find green"},
		{call: "cron.fixedBy", args: [["a1", "b2"], {kind: "release", names: []}, {releases: [{commit: "a1", outcome: "failed", failure: "the tests failed against x", started: "1"}]}], expect: null, why: "still red on main: bisect it"},
	]}
	"a release failure with nothing a local check can run is not bisected": {suite: "cron", steps: [
		{call: "cron.undecidable", args: [{kind: "release", names: []}, "release@gcp failed\n", _specs, 2, 18], expect: "a release failure that names no scenario and no check: a failure only the cloud shows, not bisected", why: "2026-11-03 16:41: the check passed on the failing commit, after a whole local run"},
		{call: "cron.undecidable", args: [{kind: "release", names: ["online", "chat"]}, "verify: failed: check-premium integrate\n", _specs, 2, 18, ["chat", "online"]], expect: "online, chat flaked in the run itself: a failure only the cloud shows, not bisected", why: "2026-11-06 19:17: both flaked in the run and passed here"},
		{call: "cron.undecidable", args: [{kind: "release", names: ["online"]}, "verify: failed: check-online\n", _specs, 2, 18, ["chat"]], expect: null, why: "a scenario that did not flake is the commit's to find"},
		{call: "cron.undecidable", args: [{kind: "release", names: []}, "verify: failed: check-online\n", _specs, 2, 18], expect: null, why: "a failed check is named: run it"},
	]}
	"a bisect runs in the background": {suite: "cron", steps: [
		{call: "cron.lowPriority", args: [["sh", "-c", "./saytw integrate@local"]], expect: ["taskpolicy", "-b", "nice", "-n", "19", "sh", "-c", "./saytw integrate@local"], why: "a gate or a release always outranks a bisect (2026-11-07: a bisect of 11:29 held the release runner)"},
		{call: "cron.lowPriority", args: [["sh", "-c", "./saytw integrate@local"], "linux"], expect: ["nice", "-n", "19", "sh", "-c", "./saytw integrate@local"], why: "Linux has no taskpolicy: a systemd host's bisect still starts (PRONTO-141)"},
		{call: "cron.schedulerEnv", args: [{}, "darwin"], expect: {CLOUDSDK_PYTHON: "/opt/homebrew/bin/python3.13", CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto"}, why: "a Mac's launchd run finds Homebrew's Python (#294)"},
		{call: "cron.schedulerEnv", args: [{}, "linux"], expect: {CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto"}, why: "on Linux gcloud picks its own Python"},
		{call: "cron.schedulerEnv", args: [{CLOUDSDK_PYTHON: "/usr/bin/python3", CLOUDSDK_ACTIVE_CONFIG_NAME: "x"}, "linux"], expect: {CLOUDSDK_PYTHON: "/usr/bin/python3", CLOUDSDK_ACTIVE_CONFIG_NAME: "x"}, why: "the caller's settings win"},
	]}
}

cases: {
	"a probe with a location checks where the redirect sends, not the page behind it": {suite: "cron", steps: [
		{call: "cron.probe", args: [{path: "/auth/oidc/google/start?return=/", status: 303, location: "https://id.bonkchess.com/authorize?"}, 303, "", "https://id.bonkchess.com/authorize?provider=google&client_id=x"], expect: null, why: "PRONTO-6: Google sign-in's start, a 303 to the identity broker"},
		{call: "cron.probe", args: [{path: "/auth/oidc/google/start?return=/", status: 303, location: "https://id.bonkchess.com/authorize?"}, 504, "error code: 504", null], expect: "/auth/oidc/google/start?return=/: 504, expected 303", why: "2026-11-09 12:10 BRT: the start hung behind Cloudflare, a 504"},
		{call: "cron.probe", args: [{path: "/auth/oidc/google/start?return=/", status: 303, location: "https://id.bonkchess.com/authorize?"}, 303, "", "https://bonkchess.com/"], expect: "/auth/oidc/google/start?return=/: to https://bonkchess.com/, expected https://id.bonkchess.com/authorize?", why: "a redirect somewhere else is no sign-in"},
		{call: "cron.probe", args: [{path: "/", status: 200, has: ["Bonk Chess"]}, 200, "<title>Bonk Chess</title>"], expect: null, why: "a probe without a location is as before"},
	]}
	"the release preview is asked every probe that does not say preview: false": {suite: "cron", steps: [
		{call: "cron.previewProbes", args: [{home: {path: "/", status: 200}, player: {path: "/player/x", status: 200, preview: false}, table: {path: "/table/y", status: 404}}], expect: [["home", {path: "/", status: 200}], ["table", {path: "/table/y", status: 404}]], why: "the player's row is production's alone"},
		{call: "cron.previewProbes", args: [{}], expect: []},
	]}
}

cases: {
	"the board's hook is handed mise's newest cue, since launchd's PATH has none": {suite: "cron", steps: [
		{call: "cron.boardEnv", args: [{PATH: "/usr/bin"}, "/Users/me", ["0.9.2", "latest", "0.16.1", "0.16", "0.15.4"]], expect: {PATH: "/usr/bin", CUE: "/Users/me/.local/share/mise/installs/github-cue-lang-cue/0.16.1/cue"}, why: "PRONTO-77, 2026-11-08 21:18 BRT: the board step failed, Failed to spawn 'cue'"},
		{call: "cron.boardEnv", args: [{CUE: "/opt/cue"}, "/Users/me", ["0.16.1"]], expect: {CUE: "/opt/cue"}, why: "a CUE already set is the one used"},
		{call: "cron.boardEnv", args: [{PATH: "/usr/bin"}, "/Users/me", []], expect: {PATH: "/usr/bin"}, why: "no cue installed: unchanged, and the hook says what it misses"},
	]}
}

_held: {branch: "release/studio/20261119-1015", base: "aaaa1111", opened: "2026-11-19T10:15:00-03:00", limits: {abandonHours: 12, abandonAttempts: 2}}
_cut: {tip: "aaaa1111", verdict: "red", at: "2026-11-19T10:15:00-03:00"}
_open: _held & {attempts: [_cut]}

cases: {
	"a held release's branch is named for the minute it was cut, in Brasília time": {suite: "cron", steps: [
		{call: "cron.branchName", args: ["studio", 1795094100000], expect: "release/studio/20261119-1015", why: "2026-11-19 13:15 UTC is 10:15 BRT"},
		{call: "cron.branchName", args: ["studio", 1795137300000], expect: "release/studio/20261119-2215", why: "the zone's day, not UTC's, when they differ"},
		{call: "cron.branchName", args: ["brawl-chess", 1795094100000], expect: "release/brawl-chess/20261119-1015"},
	]}
	"a held release is due only for a branch tip no attempt judged": {suite: "cron", steps: [
		{call: "cron.heldDue", args: [_open, "aaaa1111"], expect: false, why: "the cut's own failure was this tip: no gap, no run"},
		{call: "cron.heldDue", args: [_open, "bbbb2222"], expect: true, why: "a fix was pushed"},
		{call: "cron.heldDue", args: [_open, null], expect: false, why: "the remote could not be read: wait for the next wake"},
	]}
	"an attempt is added to the open release without changing it": {suite: "cron", steps: [
		{call: "cron.attempted", args: [_open, "bbbb2222", "red", "2026-11-19T11:00:00-03:00"], expect: _held & {attempts: [_cut, {tip: "bbbb2222", verdict: "red", at: "2026-11-19T11:00:00-03:00"}]}},
	]}
	"a held release is abandoned after its hours or its red attempts": {suite: "cron", steps: [
		{call: "cron.abandoned", args: [_open, 1795094100000 + 3_600_000, {abandonHours: 12, abandonAttempts: 2}], expect: false, why: "an hour old, one red attempt"},
		{call: "cron.abandoned", args: [_open, 1795094100000 + 12 * 3_600_000 + 1, {abandonHours: 12, abandonAttempts: 2}], expect: true, why: "past 12 h"},
		{call: "cron.abandoned", args: [_open, 1795094100000 + 12 * 3_600_000, {abandonHours: 12, abandonAttempts: 2}], expect: false, why: "exactly 12 h is not older"},
		{call: "cron.abandoned", args: [_held & {attempts: [{tip: "a", verdict: "red", at: "x"}, {tip: "b", verdict: "red", at: "y"}]}, 1795094100000 + 3_600_000, {abandonHours: 12, abandonAttempts: 2}], expect: true, why: "two red attempts"},
		{call: "cron.abandoned", args: [_held & {attempts: [{tip: "a", verdict: "red", at: "x"}, {tip: "b", verdict: "green", at: "y"}]}, 1795094100000 + 3_600_000, {abandonHours: 12, abandonAttempts: 2}], expect: false, why: "the newest is not red"},
		{call: "cron.abandoned", args: [_open, 1795094100000 + 3_600_000, {abandonHours: 12, abandonAttempts: 3}], expect: false, why: "the app allows three"},
	]}
	"an abandoned run waits the gap, a held one none": {suite: "cron", steps: [
		{call: "cron.spaced", args: ["abandoned release/studio/20261119-1015"], expect: true},
		{call: "cron.spaced", args: ["held release/studio/20261119-1015"], expect: false},
		{call: "cron.spaced", args: ["released"], expect: true},
		{call: "cron.spaced", args: ["skipped"], expect: false},
	]}
	"status says the open release": {suite: "cron", steps: [
		{call: "cron.heldLine", args: [_open], expect: "held release/studio/20261119-1015 since 2026-11-19T10:15:00-03:00, cut from aaaa1111: 1 attempt (aaaa1111 red); abandoned after 12 h or 2 red attempts"},
		{call: "cron.heldLine", args: [null], expect: null},
	]}
}

cases: {
	"a release branch's commits are backported when main holds a cherry-pick of each or an equal patch": {suite: "cron", steps: [
		{call: "cron.parseLog", args: ["aaa\u001ffix a\n\n(cherry picked from commit 111)\n\u001e\nbbb\u001ffix b\n\u001e\n"], expect: [{sha: "aaa", body: "fix a\n\n(cherry picked from commit 111)\n"}, {sha: "bbb", body: "fix b\n"}]},
		{call: "cron.patchIds", args: ["p1 aaa\np2 bbb\n"], expect: {aaa: "p1", bbb: "p2"}},
		{call: "cron.backported", args: [[{sha: "111", patch: "p1", body: "x"}, {sha: "222", patch: "p2", body: "y"}, {sha: "333", patch: "p3", body: "z"}], [{sha: "m1", patch: "q", body: "x\n\n(cherry picked from commit 111)\n"}, {sha: "m2", patch: "p2", body: "y, resolved by hand"}]], expect: [{sha: "333", patch: "p3", body: "z"}], why: "111 by its -x line, 222 by its patch id, 333 on neither"},
		{call: "cron.backported", args: [[{sha: "444", body: "w"}], [{sha: "m3", body: "empty"}]], expect: [{sha: "444", body: "w"}], why: "a commit with no patch id matches only by its line"},
		{call: "cron.backported", args: [[], [{sha: "m3", patch: "p", body: ""}]], expect: []},
		{call: "cron.backportWhy", args: [[{sha: "3333333333", body: "fix c\n"}]], expect: "1 commit not on main: 33333333 fix c"},
	]}
	"a held branch's tip is run only when it is merged pull requests into the branch and no migration": {suite: "cron", steps: [
		{call: "cron.unmerged", args: [["a", "b", "c", "d"], {a: [{merged_at: "t", base: {ref: "release/x/1"}}], b: [{merged_at: null, base: {ref: "release/x/1"}}], c: [{merged_at: "t", base: {ref: "main"}}], d: []}, "release/x/1"], expect: ["b", "c", "d"], why: "an open PR, a PR into main and a push with none are not the branch's"},
		{call: "cron.unmerged", args: [["e"], {}, "release/x/1"], expect: ["e"]},
		{call: "cron.migrationFiles", args: [["apps/studio/services/database/migrations/0042.sql", "apps/studio/src/a.js", "apps/other/services/database/migrations/1.sql"], "apps/studio"], expect: ["apps/studio/services/database/migrations/0042.sql"]},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: [], migrations: []}], expect: null},
		{call: "cron.refusedTip", args: [{descends: false, unmerged: [], migrations: []}], expect: "the tip does not descend from the commit the branch was cut at"},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: ["abcdef012345"], migrations: ["m/1.sql"]}], expect: "1 commit not brought by a merged pull request into the branch: abcdef01; migrations changed (m/1.sql): migrations go to main only"},
	]}
	"last keeps main from being skipped as behind a branch, and a branch's failure out of main's retry": {suite: "cron", steps: [
		{call: "cron.lastFields", args: ["failed", "c1", false], expect: ["c1", "c1", "-"]},
		{call: "cron.lastFields", args: ["released", "c1", false], expect: ["-", "c1", "-"]},
		{call: "cron.lastFields", args: ["abandoned release/x/1", "c1", true], expect: ["-", "-", "-"], why: "the branch tip is not what main tried"},
		{call: "cron.lastFields", args: ["abandoned release/x/1", null, false], expect: ["-", "-", "-"]},
		{call: "cron.lastFields", args: ["failed", "c1", true], expect: ["-", "-", "c1"], why: "a release or confirm failure on the branch: its tip is kept to wait the gap"},
		{call: "cron.lastFields", args: ["released", "c1", true], expect: ["-", "c1", "-"]},
	]}
	"a held tip that failed outside the rehearsal waits the gap, a new tip does not": {suite: "cron", steps: [
		{call: "cron.heldWait", args: ["t1", "t1", 1000, 0, 60], expect: true, why: "the same tip inside the gap"},
		{call: "cron.heldWait", args: ["t1", "t1", 3_600_000, 0, 60], expect: false, why: "the gap is over"},
		{call: "cron.heldWait", args: ["t1", "t2", 1000, 0, 60], expect: false, why: "a pushed fix runs at once"},
		{call: "cron.heldWait", args: [null, "t1", 1000, 0, 60], expect: false},
	]}
	"a branch commit is carried by the ledger's Backport-of line for its pull request": {suite: "cron", steps: [
		{call: "cron.backported", args: [[{sha: "1", body: "fix the thing (#12)\n"}, {sha: "2", body: "other (#123)\n"}, {sha: "3", body: "no number\n"}], [{sha: "m", patch: "q", body: "fix the thing again (#40)\n\nBackport-of: #12\n"}]], expect: [{sha: "2", body: "other (#123)\n"}, {sha: "3", body: "no number\n"}], why: "#12 is answered; #123 is not #12"},
	]}
	"a held release says what a fix merged to main must do": {suite: "cron", steps: [
		{call: "cron.heldNotice", args: ["release/x/1"], expect: "fixes merged to main do not release until release/x/1 closes: `abandon` releases main again"},
	]}
}

// The safety of the release-branch path (PRONTO-1099, 1100, 1101).
_sha1: "1111111111111111111111111111111111111111"
_sha2: "2222222222222222222222222222222222222222"

cases: {
	"a merge whose resolution changed code is missing from main, as the ledger counts it (git show --cc)": {suite: "cron", steps: [
		{call: "cron.missingFromMain", args: [[], [], [{sha: "m1", subject: "Merge fix into branch", cc: "diff --cc a.js\n+fixed\n"}]], expect: [{sha: "m1", body: "Merge fix into branch (a merge whose resolution changed code: carry it to main by hand)"}], why: "a fix made in a conflict resolution has no commit of its own"},
		{call: "cron.missingFromMain", args: [[], [], [{sha: "m2", subject: "Merge main into branch", cc: ""}, {sha: "m3", subject: "Merge", cc: "\n"}]], expect: [], why: "a merge that carries nothing of its own is nothing to carry"},
		{call: "cron.missingFromMain", args: [[{sha: "c1", patch: "p1", body: "fix (#1)\n"}], [{sha: "m", patch: "q", body: "x"}], [{sha: "m1", subject: "Merge", cc: "+x"}]], holds: [{sha: "m1"}, {sha: "c1"}], why: "the merges first, then the commits main has no counterpart of"},
		{call: "cron.missingFromMain", args: [[{sha: "c1", patch: "p1", body: "x"}], [{sha: "m", patch: "p1", body: "y"}], []], expect: [], why: "an equal patch id is a counterpart"},
	]}
	"with no merge to resolve, the ledger's answer is backported's: branches off change nothing": {suite: "cron", steps: [
		{call: "cron.missingFromMain", args: [[{sha: "c1", patch: "p1", body: "a"}, {sha: "c2", patch: "p2", body: "b"}], [{sha: "m", patch: "p2", body: "b"}]], expect: [{sha: "c1", patch: "p1", body: "a"}]},
		{call: "cron.backported", args: [[{sha: "c1", patch: "p1", body: "a"}, {sha: "c2", patch: "p2", body: "b"}], [{sha: "m", patch: "p2", body: "b"}]], expect: [{sha: "c1", patch: "p1", body: "a"}]},
	]}
	"the backport check and the deletion name commits, not refs that move": {suite: "cron", steps: [
		{call: "cron.isSha", args: [_sha1], expect: true},
		{call: "cron.isSha", args: ["origin/main"], expect: false, why: "re-fetched under the check"},
		{call: "cron.isSha", args: ["abc123"], expect: false, why: "short ids are ambiguous"},
		{call: "cron.isSha", args: [null], expect: false},
	]}
	"a migration moved out of the folder refuses the tip, by its old path (git diff --no-renames lists both)": {suite: "cron", steps: [
		{call: "cron.migrationFiles", args: [["apps/studio/services/database/migrations/0042.sql", "apps/studio/db/0042.sql"], "apps/studio"]},
		{keep: "moved"},
		{use: "moved", expect: ["apps/studio/services/database/migrations/0042.sql"]},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: [], migrations: "$moved"}], matches: "migrations changed \\(apps/studio/services/database/migrations/0042.sql\\)"},
	]}
	"a branch is deleted only as the tip that was checked, by an explicit lease": {suite: "cron", steps: [
		{call: "cron.leaseDelete", args: ["release/x/1", _sha1], expect: ["--force-with-lease=refs/heads/release/x/1:1111111111111111111111111111111111111111", "origin", ":refs/heads/release/x/1"]},
		{call: "cron.leaseLost", args: ["release/x/1", _sha1, _sha2], expect: {deleted: false, tip: _sha2, why: "release/x/1 was kept: its tip moved from the checked 11111111 to 22222222, which nothing checked"}, why: "a push since the check: the branch and its record stay, the new tip is said"},
		{call: "cron.leaseLost", args: ["release/x/1", _sha1, null], expect: {deleted: true, why: "release/x/1 was already gone from origin"}},
		{call: "cron.leaseLost", args: ["release/x/1", _sha1, _sha1], expect: {deleted: false, tip: _sha1, why: "release/x/1 was not deleted: the push failed with the tip unchanged at 11111111"}},
	]}
	"a held tip that is already serving resumes at confirmation": {suite: "cron", steps: [
		{call: "cron.heldLanded", args: [{branch: "release/x/1"}, "c1", "c1"], expect: true, why: "the release landed, its confirmation did not"},
		{call: "cron.heldLanded", args: [{branch: "release/x/1"}, "c0", "c1"], expect: false},
		{call: "cron.heldLanded", args: [{branch: "release/x/1"}, null, "c1"], expect: false, why: "nothing known to serve"},
	]}
	"a refused tip's notice names the branch, the commit and why": {suite: "cron", steps: [
		{call: "cron.refusal", args: ["studio", "release/studio/1", _sha1, "the tip does not descend from the commit the branch was cut at"], expect: "release-cron (studio) refused release/studio/1 at 11111111: the tip does not descend from the commit the branch was cut at. Nothing was rehearsed and no attempt counted; push a tip that is only merged pull requests into the branch."},
	]}
}

// The ledger's parity and the plans (the driver executes them in order; the cases hold the decisions).
_main: [{sha: "m1", patch: "q", body: "unrelated"}]
_all: [{sha: "m0", body: "fix a\n\n(cherry picked from commit c1)\n"}, {sha: "mb", body: "port (#12)\n\nBackport-of: #7\n"}, {sha: "m1", patch: "q", body: "unrelated"}]

cases: {
	"a pick or Backport-of line anywhere in main's history carries a branch commit, not only since the merge base": {suite: "cron", steps: [
		{call: "cron.backported", args: [[{sha: "c1", patch: "p1", body: "fix a\n"}, {sha: "c2", patch: "p2", body: "fix b (#7)\n"}, {sha: "c3", patch: "p3", body: "fix c (#8)\n"}], _main, _all], expect: [{sha: "c3", patch: "p3", body: "fix c (#8)\n"}], why: "a fix picked before the branch was cut is on main; the ledger reads main's whole history for both lines"},
		{call: "cron.backported", args: [[{sha: "c1", patch: "p1", body: "fix a\n"}], _main], expect: [{sha: "c1", patch: "p1", body: "fix a\n"}], why: "read only since the merge base, the pick is not seen: the gap that was"},
	]}
	"an empty commit has no patch id: nothing to carry, as the ledger skips it, unless a line names it": {suite: "cron", steps: [
		{call: "cron.backported", args: [[{sha: "e1", patch: null, body: "empty\n"}, {sha: "c1", patch: "p1", body: "real\n"}], _main], expect: [{sha: "c1", patch: "p1", body: "real\n"}]},
		{call: "cron.missingFromMain", args: [[{sha: "e1", patch: null, body: "empty\n"}], _main, []], expect: []},
	]}
	"a held tip that fails provenance is refused before any checkout, trust or config read": {suite: "cron", steps: [
		{call: "cron.heldPlan", args: ["1 commit not brought by a merged pull request into the branch: abcdef01", null], expect: ["mark-refused", "notify", "end-refused"], why: "nothing of the tip is checked out, so the scheduler's entry point stays out of it"},
		{call: "cron.heldPlan", args: [null, null], expect: ["checkout", "trust", "config"], why: "only a passed tip is checked out, then trusted, then its config read"},
		{call: "cron.heldPlan", args: ["x", null]},
		{keep: "refused"},
		{call: "cron.mutations", args: ["$refused"], expect: ["mark-refused", "notify", "end-refused"]},
	]}
	"a dry run's plans list no mutation, and check nothing out": {suite: "cron", steps: [
		{call: "cron.heldPlan", args: ["x", "1"], expect: ["report-refusal"]},
		{call: "cron.heldPlan", args: [null, "1"], expect: ["report-checkout"], why: "a dry run of a good tip says it would check it out"},
		{call: "cron.backportPlan", args: [[{sha: "c"}], false, "1"], expect: ["end-held-backport"], why: "waits but tells nobody and writes no marker"},
		{call: "cron.backportPlan", args: [[], false, "1"], expect: ["report-delete"]},
		{call: "cron.limitPlan", args: ["android"], expect: ["report-abandon"]},
		{call: "cron.mutations", args: [["report-refusal", "report-checkout", "report-delete", "report-abandon"]], expect: []},
	]}
	"a real run tells once, then deletes or closes": {suite: "cron", steps: [
		{call: "cron.backportPlan", args: [[{sha: "c"}], false, null], expect: ["tell", "mark-told", "end-held-backport"]},
		{call: "cron.backportPlan", args: [[{sha: "c"}], true, null], expect: ["end-held-backport"], why: "this set was told already"},
		{call: "cron.backportPlan", args: [[], false, null], expect: ["delete-branch"]},
		{call: "cron.limitPlan", args: [null], expect: ["close-hold", "drop-branch", "end-abandoned"]},
	]}
	"abandon drops a hold that never shipped, and keeps a shipped one's backport hold": {suite: "cron", steps: [
		{call: "cron.abandonPlan", args: [{branch: "release/a/1"}, null, [], null], expect: {shipped: false, closeHold: true, dropBranch: true, removeRecord: false, why: ""}, why: "never shipped: the hold and its branch go"},
		{call: "cron.abandonPlan", args: [{branch: "release/a/2"}, {branch: "release/a/1"}, null, null], expect: {shipped: false, closeHold: true, dropBranch: true, removeRecord: false, why: ""}, why: "the record is another branch's: untouched"},
		{call: "cron.abandonPlan", args: [{branch: "release/a/1"}, {branch: "release/a/1"}, [{sha: "c"}], null], expect: {shipped: true, closeHold: true, dropBranch: false, removeRecord: false, why: "commits released from it are still missing from main"}, why: "shipped, a fix not on main: hold closed, record and branch kept"},
		{call: "cron.abandonPlan", args: [null, {branch: "release/a/1"}, [{sha: "c"}], null], expect: {shipped: true, closeHold: false, dropBranch: false, removeRecord: false, why: "commits released from it are still missing from main"}, why: "no hold, a fix missing: the record stays"},
		{call: "cron.abandonPlan", args: [null, {branch: "release/a/1"}, null, null], expect: {shipped: true, closeHold: false, dropBranch: false, removeRecord: false, why: "the commits missing from main could not be read"}, why: "unreadable: kept"},
		{call: "cron.abandonPlan", args: [null, {branch: "release/a/1"}, [], false], expect: {shipped: true, closeHold: false, dropBranch: false, removeRecord: false, why: "it moved since its release"}, why: "the branch moved: kept"},
		{call: "cron.abandonPlan", args: [null, {branch: "release/a/1"}, [], "unknown"], expect: {shipped: true, closeHold: false, dropBranch: false, removeRecord: false, why: "origin could not be asked"}},
		{call: "cron.abandonPlan", args: [null, {branch: "release/a/1"}, [], true], expect: {shipped: true, closeHold: false, dropBranch: false, removeRecord: true, why: ""}, why: "every commit on main and the branch gone: the record goes"},
	]}
	"a held tip confirms itself by the trusted checkout's probes and serving command": {suite: "cron", steps: [
		{call: "cron.heldConfig", args: [{gap: 60, ready: ["a"], probes: {home: {path: "/evil"}}, target: {kind: "command", release: ["./rel"], serving: ["./evil-serving"], origin: "https://evil"}}, {ready: ["b"], probes: {home: {path: "/"}}, target: {kind: "command", release: ["x"], serving: ["ssh", "node", "serving"], origin: "https://app"}}], expect: {gap: 60, ready: ["b"], probes: {home: {path: "/"}}, target: {kind: "command", release: ["./rel"], serving: ["ssh", "node", "serving"], origin: "https://app"}}, why: "the candidate's release command still runs; what says it landed is the trusted one's"},
		{call: "cron.heldConfig", args: [{ready: ["a"], probes: {}, target: {kind: "cloud-run"}}, {probes: {p: {path: "/"}}, target: {kind: "cloud-run"}}], expect: {ready: ["a"], probes: {p: {path: "/"}}, target: {kind: "cloud-run"}}},
	]}
	"an unreadable open file is reported by abandon, and removed only with --force": {suite: "cron", steps: [
		{call: "cron.corruptOpen", args: ["/s/open", "Unexpected token", false], expect: {remove: false, text: "/s/open could not be read (Unexpected token): delete that file by hand, or run `abandon --force` to remove it"}},
		{call: "cron.corruptOpen", args: ["/s/open", "Unexpected token", true], expect: {remove: true, text: "/s/open could not be read (Unexpected token): removed by --force"}},
	]}
}
