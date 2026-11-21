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
