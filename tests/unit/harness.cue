package unit

// The scenarios' flake filing (harness/files/tests/scenarios/flakes.ts) on a fake board (PRONTO-649): filing
// is said first, then a board that refuses is thrown (the runner throws it after its report), leaving no marker.
cases: "a board that refuses a flake is said with its whole error, then thrown, and leaves no marker": {
	suite: "harness"
	steps: [
		{call: "harness.refused"},
		{keep: "r"},
		{get: "threw", expect: true, why: "an unfiled flake is lost, so the refusal is thrown after it is said"},
		{use: "r"},
		{get: "error", matches: "^flake demo not filed: the board said: Error: board said no"},
		{use: "r"},
		{get: "marker", expect: null, why: "no marker, so the next run files it again"},
		{use: "r"},
		{get: "said", expect: ["  ⚠ flake demo not filed: the board said:\n    | Error: board said no\n    |     at async board.ts:19:21"], why: "every line of the board's stderr, not its last stack frame"},
	]
}
cases: "a board that refuses a flake on GitHub Actions also warns with an annotation": {
	suite: "harness"
	steps: [
		{call: "harness.refused", args: [true]},
		{get: "said"},
		{get: "1", expect: "::warning title=flake not filed::flake demo not filed: the board said: Error: board said no%0A    at async board.ts:19:21"},
	]
}
cases: "a board that is missing is a refusal too, thrown": {
	suite: "harness"
	steps: [
		{call: "harness.missing"},
		{keep: "r"},
		{get: "threw", expect: true},
		{use: "r"},
		{get: "marker", expect: null},
		{use: "r"},
		{get: "said", expect: ["  ⚠ flake demo not filed: the board said:\n    | board: command not found"]},
	]
}
cases: "a board that files a flake gets its marker, holding what it said": {
	suite: "harness"
	steps: [
		{call: "harness.accepted"},
		{keep: "r"},
		{get: "filed", expect: true},
		{use: "r"},
		{get: "marker", expect: "PRONTO-700 https://board/PRONTO-700"},
		{use: "r"},
		{get: "said", expect: ["  filed: PRONTO-700 https://board/PRONTO-700"]},
	]
}
cases: "a filed flake whose marker cannot be written is thrown (the runner throws it after its report)": {
	suite: "harness"
	steps: [
		{call: "harness.unmarked", expect: {threw: true, said: 1}, why: "said before it throws, so the issue key is in the log; not the board's error: an unwritten marker would file the same flake every run"},
	]
}

// Which files outside the app concern a scenario (harness/files/tests/scenarios/select.ts, PRONTO-870): the
// paths are relative to the app, as the selector sees them. null: none; a string: why it does (fail open).
cases: "a file of a sibling app concerns no scenario, and any other file above the app still concerns every one": {
	suite: "harness"
	steps: [
		{call: "harness.outsideConcerns", args: ["../other/src/page.html"], expect: null, why: "apps/other/… from the top: the selection against a release's commit no longer runs everything for it"},
		{call: "harness.outsideConcerns", args: ["../other/deep/er/x.sql"], expect: null},
		{call: "harness.outsideConcerns", args: ["../other/README.md"], expect: null, why: "documentation"},
		{call: "harness.outsideConcerns", args: ["../../docs/queue.md"], expect: null},
		{call: "harness.outsideConcerns", args: ["../../.github/workflows/gate.yml"], expect: null},
		{call: "harness.outsideConcerns", args: ["../../AGENTS.md"], expect: null},
		{call: "harness.outsideConcerns", args: ["../mise.toml"], expect: "mise.toml is outside the app", why: "a pin in the apps folder is no sibling app's file"},
		{call: "harness.outsideConcerns", args: ["../../mise.lock"], expect: "mise.lock is outside the app", why: "a tool pin above the apps"},
		{call: "harness.outsideConcerns", args: ["../../pronto/runtime.cue"], expect: "pronto/runtime.cue is outside the app", why: "two levels up is the repository's top, not a sibling app"},
		{call: "harness.outsideConcerns", args: ["../../tools/x.nu"], expect: "tools/x.nu is outside the app"},
		{call: "harness.outsideConcerns", args: ["../../apps/other/x.ts"], expect: "apps/other/x.ts is outside the app", why: "a path that climbs to the top and back is not the form the selector gives a sibling"},
		{call: "harness.outsideConcerns", args: ["../.hidden/x"], expect: ".hidden/x is outside the app", why: "a hidden folder is no app"},
		{call: "harness.outsideConcerns", args: ["../other/.hidden/x"], expect: null, why: "a hidden folder inside a sibling app is still the sibling's"},
		{call: "harness.outsideConcerns", args: ["../Makefile"], expect: "Makefile is outside the app", why: "one level up with no directory: fails open"},
		{call: "harness.outsideConcerns", args: ["tests/scenarios/x.ts"], expect: null, why: "inside the app: not this function's to judge"},
	]
}

cases: "an app that reads its siblings lists them, and those fail open again": {
	suite: "harness"
	steps: [
		{call: "harness.outsideConcerns", args: ["../studio/builder/x.ts", ["^\\.\\./[^/]+/"]], expect: "studio/builder/x.ts is outside the app", why: "Studio's builder scans every apps/*"},
		{call: "harness.outsideConcerns", args: ["../other/x.ts", ["^\\.\\./brawl-chess/"]], expect: null, why: "a pattern that does not match the sibling"},
		{call: "harness.outsideConcerns", args: ["../other/README.md", ["^\\.\\./[^/]+/"]], expect: null, why: "documentation is still nothing"},
	]
}

cases: "the exact-tree key holds the outside files that concern a scenario, not the sibling apps'": {
	suite: "harness"
	steps: [
		{call: "harness.outsideKeys", args: [["../../mise.lock", "../other/a.ts", "../../docs/x.md", "tests/x.ts", "../../pronto/b.cue"]], expect: ["outside ../../mise.lock h:../../mise.lock", "outside ../../pronto/b.cue h:../../pronto/b.cue"], why: "pins and pronto/ key it, sorted; a sibling, documentation and the app's own file do not"},
		{call: "harness.outsideKeys", args: [["../other/a.ts", "../../mise.lock"], ["^\\.\\./[^/]+/"]], expect: ["outside ../../mise.lock h:../../mise.lock", "outside ../other/a.ts h:../other/a.ts"], why: "an app that reads its siblings keys them too"},
	]
}
