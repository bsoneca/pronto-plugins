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

// The unit runner's lock (UNIT_LOCK, PRONTO-973): unset, its runs take no lock flag, so nothing changes; set, deno runs frozen to it.
cases: "a suite with no UNIT_LOCK runs with no lock flag": {
	suite: "harness"
	steps: [
		{call: "harness.lockFlags", args: [null], expect: [], why: "deno's own lookup, as before UNIT_LOCK"},
		{call: "harness.lockFlags", args: [""], expect: []},
	]
}
cases: "a suite held to a lock runs frozen to it, and a module the lock lacks fails": {
	suite: "harness"
	steps: [
		{call: "harness.lockFlags", args: ["/app/builder/deno.lock"], expect: ["--lock=/app/builder/deno.lock", "--frozen"]},
		{call: "harness.lockHonoured"},
		{keep: "r"},
		{get: "frozen", expect: false, why: "the lock names nothing, so frozen deno refuses the import"},
		{use: "r"},
		{get: "said", matches: "lockfile is out of date"},
		{use: "r"},
		{get: "free", expect: true, why: "the same module with no lock flag resolves, and its import is in deno info's graph"},
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
		{call: "harness.outsideConcerns", args: ["../other/README.md", ["^\\.\\./[^/]+/"]], expect: "other/README.md is outside the app", why: "a sibling's documentation the app reads is its input: Studio's builder falls back to README.md for the app card"},
		{call: "harness.outsideConcerns", args: ["../brawl-chess/brief.md", ["^\\.\\./[^/]+/"]], expect: "brawl-chess/brief.md is outside the app", why: "Studio's builder reads a sibling's brief.md for its app card: the opt-in is asked before the documentation rule"},
		{call: "harness.outsideConcerns", args: ["../brawl-chess/brief.md"], expect: null, why: "without the opt-in a sibling's brief is nothing"},
		{call: "harness.outsideConcerns", args: ["../../docs/queue.md", ["^\\.\\./[^/]+/"]], expect: null, why: "the repository's documentation is no sibling's, opt-in or not"},
	]
}

cases: "the exact-tree key holds the outside files that concern a scenario, not the sibling apps'": {
	suite: "harness"
	steps: [
		{call: "harness.outsideKeys", args: [["../../mise.lock", "../other/a.ts", "../../docs/x.md", "tests/x.ts", "../../pronto/b.cue"]], expect: ["outside ../../mise.lock h:../../mise.lock", "outside ../../pronto/b.cue h:../../pronto/b.cue"], why: "pins and pronto/ key it, sorted; a sibling, documentation and the app's own file do not"},
		{call: "harness.outsideKeys", args: [["../other/a.ts", "../../mise.lock"], ["^\\.\\./[^/]+/"]], expect: ["outside ../../mise.lock h:../../mise.lock", "outside ../other/a.ts h:../other/a.ts"], why: "an app that reads its siblings keys them too"},
		{call: "harness.declaredKeys", args: [[["../other/brief.md", "b1"], ["../brawl-chess/brief.md", "b2"], ["../../mise.lock", "m"], ["tests/x.ts", "t"]], ["^\\.\\./[^/]+/"]], expect: ["declared ../brawl-chess/brief.md b2", "declared ../other/brief.md b1"], why: "every sibling file the pattern names, as it is now, sorted: the app's own and the root's files are outsideKeys' and the tree's"},
		{call: "harness.declaredKeys", args: [[["../other/brief.md", "b1"], ["../brawl-chess/brief.md", "b3"]], ["^\\.\\./[^/]+/"]], expect: ["declared ../brawl-chess/brief.md b3", "declared ../other/brief.md b1"], why: "only a sibling's brief.md moved on main, no diff against it: the key still changes (bsoneca/pronto#1555)"},
		{call: "harness.declaredKeys", args: [[["../other/brief.md", "b1"]]], expect: [], why: "an app with no pattern keys no sibling (PRONTO-870)"},
	]
}

// A step's own fields against the scenarios' schema (harness/files/tests/scenarios/schema.cue): its common fields
// against those every step takes and the rest against its one kind's shape, each closed (bsoneca/pronto#1555).
cases: "a step keeps its kind's optional field and is refused a field neither its kind nor every step takes": {
	suite: "harness"
	steps: [
		{call: "harness.stepRefused", args: [{play: "e2e4", refused: true, by: "a"}], expect: null, why: "a gesture's optional `refused` and a common `by` are kept"},
		{call: "harness.stepRefused", args: [{play: "e2e4", bogus: 1}], matches: "_checked\\.0\\.shape\\.bogus: field not allowed", why: "a field no kind names was accepted while the whole shape stayed open"},
		{call: "harness.stepRefused", args: [{play: "e2e4", poll: 2}], matches: "_checked\\.0\\.shape\\.poll: field not allowed", why: "an http's `poll` is that kind's alone, not a gesture's"},
	]
}

// A scenario green at its last run, then main moves only a sibling's brief.md that Studio reads, then a by-hand run on main:
// its diff against main is empty, so the diff path asks siblingsMoved with the digest the green run recorded (bsoneca/pronto#1555).
cases: "a by-hand run after a sibling file the app reads moved on main runs the scenario, though no diff concerns it": {
	suite: "harness"
	steps: [
		{call: "harness.siblingsMoved", args: ["d1", "d2"], expect: "a sibling file it reads changed since its last green run", why: "brief.md moved on main: the digest differs, the scenario runs"},
		{call: "harness.siblingsMoved", args: ["d1", "d1"], expect: null, why: "the siblings as they were at the green run: nothing to run for them"},
		{call: "harness.siblingsMoved", args: [null, "d1"], expect: "a sibling file it reads changed since its last green run", why: "a record made before the digest was kept runs once"},
		{call: "harness.siblingsMoved", args: [null, ""], expect: null, why: "an app that reads no sibling records and compares nothing"},
		{call: "harness.siblingsMoved", args: ["d1", null], expect: "the sibling files it reads cannot be listed", why: "an unreadable list runs it"},
	]
}

// A sibling's brief.md staged but not committed: Studio's builder clones HEAD, so the run tests the committed brief and
// the key is HEAD's blob; committing the edit then changes the key, so it is no cache hit (bsoneca/pronto#1555).
cases: "a staged sibling edit keys as HEAD holds it until it is committed, then as the new commit": {
	suite: "harness"
	steps: [
		{call: "harness.siblingStaged", expect: {firstIsHead: true, stagedIsHead: true, afterIsNewHead: true}, why: "keyed by HEAD's blob, not the index's"},
	]
}

// The run guard of tests/lint.ts (PRONTO-867): the largest argument of every RUN, CMD, ENTRYPOINT and HEALTHCHECK of a
// Dockerfile, as BuildKit reads it. Linux refuses one argv string over 131072 B, and a shell-form RUN is one.
cases: "a shell-form RUN is one argument, counted in bytes after its keyword": {
	suite: "harness"
	steps: [
		{call: "harness.sizes", args: ["FROM scratch\nRUN echo hi\n"], expect: [[2, "RUN", 7]]},
		{call: "harness.sizes", args: ["RUN echo é"], expect: [[1, "RUN", 7]], why: "UTF-8 bytes, not characters"},
		{call: "harness.ofSize", args: [131072], expect: [131072]},
	]
}
cases: "continuation lines are joined as BuildKit joins them, and comments inside them dropped": {
	suite: "harness"
	steps: [
		{call: "harness.sizes", args: ["RUN a \\\n  && b \\\n# a comment\n  && c\nCMD x"], expect: [[1, "RUN", 15], [5, "CMD", 1]], why: "the line is the instruction's first; the escape and newline go, the comment line too"},
		{call: "harness.sizes", args: ["# escape=`\nRUN a `\n b\\\nRUN c"], expect: [[2, "RUN", 5], [4, "RUN", 1]], why: "with escape=`, a backslash ends nothing"},
		{call: "harness.sizes", args: ["RUN a\n\n# between\nRUN b"], expect: [[1, "RUN", 1], [4, "RUN", 1]]},
	]
}
cases: "an exec form is as large as its largest element, CMD, ENTRYPOINT and HEALTHCHECK CMD count, other instructions do not": {
	suite: "harness"
	steps: [
		{call: "harness.sizes", args: ["CMD [\"a\", \"bcd\"]\nENTRYPOINT [\"ef\"]"], expect: [[1, "CMD", 3], [2, "ENTRYPOINT", 2]]},
		{call: "harness.sizes", args: ["HEALTHCHECK --interval=5s --timeout=2s CMD curl -f x\nHEALTHCHECK NONE"], expect: [[1, "HEALTHCHECK", 9]], why: "flags and CMD are not the argument; NONE has none"},
		{call: "harness.sizes", args: ["RUN --mount=type=cache,target=/c make\nCOPY a b\nENV A=1\nARG B"], expect: [[1, "RUN", 4]], why: "a RUN's flags are not the command"},
		{call: "harness.sizes", args: ["run lower"], expect: [[1, "RUN", 5]], why: "keywords are case-insensitive"},
	]
}
cases: "a heredoc's body is a file for COPY, ADD and a script, an argument for any other RUN": {
	suite: "harness"
	steps: [
		{call: "harness.sizes", args: ["RUN <<EOF\necho very long body here\nEOF\nRUN b"], expect: [[1, "RUN", 25], [4, "RUN", 1]], why: "RUN <<W alone: the body goes to sh -c"},
		{call: "harness.sizes", args: ["RUN <<EOF\n#!/bin/sh\nthe script is a file\nEOF\nRUN b"], expect: [[1, "RUN", 5], [5, "RUN", 1]], why: "a body that starts with #! is run as a script, not passed"},
		{call: "harness.sizes", args: ["COPY <<EOF /f\nlong long long long body\nEOF\nRUN b"], expect: [[4, "RUN", 1]], why: "a COPY heredoc is a file"},
		{call: "harness.sizes", args: ["RUN cat <<-'X' > /f\n\tbody\n\tX\nCMD c"], expect: [[1, "RUN", 22], [4, "CMD", 1]], why: "command, newline, body (tabs stripped by <<-) and the word; a quoted word is the word"},
		{call: "harness.sizes", args: ["CMD cat <<EOF\nbody\nEOF"], expect: [[1, "CMD", 9]], why: "only a RUN's heredoc is passed"},
		{call: "harness.ofHeredoc", args: [70000], expect: [70000], why: "a RUN heredoc body over the ceiling is counted"},
	]
}
cases: "a << that opens no heredoc, or one never closed, swallows nothing": {
	suite: "harness"
	steps: [
		{call: "harness.sizes", args: ["RUN echo $((a<<b))\nRUN y"], expect: [[1, "RUN", 14], [2, "RUN", 1]], why: "a shift is not at the start of a word"},
		{call: "harness.sizes", args: ["RUN echo $((1<<2)) <<<hi\nRUN y"], expect: [[1, "RUN", 20], [2, "RUN", 1]], why: "a here-string opens none"},
		{call: "harness.sizes", args: ["RUN cat <<EOF\nRUN y\nCMD z"], expect: [[1, "RUN", 9], [2, "RUN", 1], [3, "CMD", 1]], why: "no terminator: the instruction ends where it did, the next ones are still read"},
	]
}
cases: "the ceiling is whole bytes, above 0 and under what Linux passes in one string": {
	suite: "harness"
	steps: [
		{call: "harness.parseCeiling", args: ["65536"], expect: 65536},
		{call: "harness.parseCeiling", args: ["131071"], expect: 131071},
		{call: "harness.parseCeiling", args: ["131072"], expect: null, why: "MAX_ARG_STRLEN counts the NUL"},
		{call: "harness.parseCeiling", args: ["0"], expect: null},
		{call: "harness.parseCeiling", args: ["-1"], expect: null},
		{call: "harness.parseCeiling", args: ["abc"], expect: null},
		{call: "harness.parseCeiling", args: [""], expect: null, why: "a check that passes nothing gets the default only by passing no argument"},
		{call: "harness.parseCeiling", args: ["Infinity"], expect: null},
		{call: "harness.parseCeiling", args: ["1e3"], expect: null},
		{call: "harness.parseCeiling", args: ["0x10000"], expect: null},
		{call: "harness.parseCeiling", args: [], expect: 65536, why: "no argument: the default"},
	]
}
cases: "the guard reads .bayt/Dockerfile.* and the root Dockerfile, fails one byte over the ceiling and passes the ceiling itself": {
	suite: "harness"
	steps: [
		{call: "harness.problems", args: [100, 100, 101], expect: ["Dockerfile:1 RUN 101 B > ceiling 100 B"]},
		{call: "harness.problems", args: [100, 101, 100], expect: [".bayt/Dockerfile.x:1 RUN 101 B > ceiling 100 B"]},
		{call: "harness.problems", args: [100, 100, 100], expect: [], why: "exactly the ceiling passes"},
		{call: "harness.linked", args: [100], expect: [".bayt/Dockerfile.link:1 RUN 101 B > ceiling 100 B", ".bayt/Dockerfile.real:1 RUN 101 B > ceiling 100 B"], why: "a symlinked Dockerfile is read too"},
		{call: "harness.unreadable", args: [], expect: [true], why: "a Dockerfile that cannot be read is a problem, not an empty one"},
	]
}
cases: "a served image's RUN names the folders that weigh most, root files as (root)": {
	suite: "harness"
	steps: [
		{call: "harness.served", args: [[["shell/hatches/fala/voz/", "a.ogg"], ["shell/hatches/fala/voz/", "b.ogg"], ["shell/screens/", "play.html"]]], expect: {bytes: 278, heaviest: [["shell/hatches/fala/voz/", 188], ["shell/screens/", 84]]}, why: "four levels at most, the bytes of the statements installing into each"},
		{call: "harness.served", args: [[["", "index.html"]]], expect: {bytes: 64, heaviest: [["(root)", 58]]}},
	]
}
