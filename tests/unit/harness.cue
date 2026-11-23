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
		{call: "harness.sizes", args: ["RUN cat <<EOF > /out\n#!/bin/sh\nbody\nEOF\nCMD c"], expect: [[1, "RUN", 35], [5, "CMD", 1]], why: "an inline command is one argument, so a body that starts with #! still counts"},
		{call: "harness.sizes", args: ["RUN cat <<A > /a && cat <<B > /b\naa\nA\nbbbb\nB\nCMD c"], expect: [[1, "RUN", 40], [6, "CMD", 1]], why: "two heredocs of one command count together: the command, both bodies and both words"},
		{call: "harness.sizes", args: ["RUN <<EOF\n#!/bin/sh\n#!/bin/sh\nEOF"], expect: [[1, "RUN", 5]], why: "a standalone script heredoc with a shebang stays exempt"},
		{call: "harness.sizes", args: ["RUN <<END-SCRIPT\necho very long body here\nEND-SCRIPT\nRUN b"], expect: [[1, "RUN", 25], [4, "RUN", 1]], why: "a hyphenated delimiter is read whole, so its body is measured"},
		{call: "harness.sizes", args: ["RUN <<-'END-SCRIPT'\n\techo very long body here\n\tEND-SCRIPT\nRUN b"], expect: [[1, "RUN", 25], [4, "RUN", 1]], why: "quoted and tab-stripped, still the whole word"},
		{call: "harness.sizes", args: ["RUN <<END-SCRIPT\n#!/bin/sh\nthe script is a file\nEND-SCRIPT\nRUN b"], expect: [[1, "RUN", 12], [5, "RUN", 1]], why: "a hyphenated standalone #! script is still a file, exempt"},
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

// The scenarios loader (harness/files/tests/scenarios/load.ts, PRONTO-1071): the runner's file list and `cue export`
// command, in one place for the runner and a rehearsal.
cases: "scenario files are the folder's .cue files, sorted, whether or not the folder ends in a slash": {
	suite: "harness"
	steps: [
		{call: "harness.scenarioFiles", args: ["/app/tests/scenarios/", ["b.cue", "notes.md", "a.cue", "c.cue.bak", "app.ts"]]},
		{get: "0", expect: "/app/tests/scenarios/a.cue"},
		{call: "harness.scenarioFiles", args: ["/app/tests/scenarios", ["b.cue", "a.cue"]]},
		{get: "1", expect: "/app/tests/scenarios/b.cue"},
	]
}
cases: "the loader runs cue export on the sorted files with --out json and parses what it prints": {
	suite: "harness"
	steps: [
		{call: "harness.loaded", args: ["for a in \"$@\"; do echo \"$a\"; done > \"$(dirname \"$0\")/args\"; echo '{\"parallel\": 3, \"scenarios\": {}}'"]},
		{keep: "r"},
		{get: "spec.parallel", expect: 3},
		{use: "r"},
		{get: "args", expect: ["export", "<dir>/scenarios/a.cue", "<dir>/scenarios/b.cue", "--out", "json"]},
	]
}
cases: "a cue that fails is the scenarios not exporting, with cue's words": {
	suite: "harness"
	steps: [
		{call: "harness.loaded", args: ["echo 'bad field' >&2; exit 1"]},
		{get: "error", matches: "^the scenarios do not export: bad field"},
	]
}
cases: "a timeout kills a cue that does not answer, and says so": {
	suite: "harness"
	steps: [
		{call: "harness.loaded", args: ["exec sleep 30", {timeoutMs: 300}]},
		{keep: "r"},
		{get: "error", matches: "stopped \\(no answer in 300 ms\\), cue was killed"},
		{use: "r"},
		{get: "fast", expect: true, why: "the child was killed, not waited out"},
	]
}
cases: "an aborted signal kills cue and says so": {
	suite: "harness"
	steps: [
		{call: "harness.loaded", args: ["exec sleep 30", {abortAfterMs: 300}]},
		{keep: "r"},
		{get: "error", matches: "stopped \\(aborted\\), cue was killed"},
		{use: "r"},
		{get: "fast", expect: true},
	]
}
cases: "a deadline rejects at once though a descendant of cue holds its pipes, and leaves that descendant dead": {
	suite: "harness"
	steps: [
		{call: "harness.descendant", args: [{timeoutMs: 1000}]},
		{keep: "r"},
		{get: "error", matches: "stopped \\(no answer in 1000 ms\\), cue was killed"},
		{use: "r"},
		{get: "quick", expect: true, why: "not after the descendant's 30 s, nor its pipes' EOF"},
		{use: "r"},
		{get: "started", expect: true},
		{use: "r"},
		{get: "gone", expect: true, why: "the whole tree is stopped, not only cue"},
	]
}
cases: "a signal already aborted rejects before cue is started": {
	suite: "harness"
	steps: [
		{call: "harness.descendant", args: [{preAborted: true}]},
		{keep: "r"},
		{get: "error", matches: "stopped \\(aborted\\), cue was killed"},
		{use: "r"},
		{get: "quick", expect: true},
		{use: "r"},
		{get: "started", expect: false, why: "cue never ran"},
	]
}
cases: "a descendant that ignores TERM is killed after the grace, the rejection still at once": {
	suite: "harness"
	steps: [
		{call: "harness.descendant", args: [{timeoutMs: 1000, ignoreTerm: true}]},
		{keep: "r"},
		{get: "error", matches: "stopped \\(no answer in 1000 ms\\), cue was killed"},
		{use: "r"},
		{get: "quick", expect: true},
		{use: "r"},
		{get: "started", expect: true},
		{use: "r"},
		{get: "gone", expect: true, why: "KILLed after the 2 s grace (the timer keeps the process alive for it)"},
	]
}

// The image guard follows what a driver reads, not the folders it names (PRONTO-870): tests/slot.ts holds ".bayt",
// "cue.mod" and the compose file as strings, load.ts imports it, and the guard asked for them in the image.
cases: "a scenarios runner importing tests/slot.ts, which names .bayt and cue.mod, reports no image problem": {
	suite: "harness"
	steps: [
		{call: "harness.imageGuard", expect: {code: 0, out: "lint image: ok", err: ""}, why: "slot.ts is the host tier's: what it opens is not read in an image"},
	]
}

// A step's gate (harness/files/tests/scenarios/gate.ts): its place and kept value are asked before its flags, so a
// step for another place sends the door nothing (a production flip's run: no OFREP request for a local step).
cases: "a local step on production is skipped and asks no flag": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{on: "local", flag: "f"}, {place: "production"}], expect: {run: false, asked: []}},
		{call: "harness.gate", args: [{on: "local", unless: "f"}, {place: "production"}], expect: {run: false, asked: []}},
	]
}
cases: "a local step on a deployed preview is skipped and asks no flag": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{on: "local", flag: "f"}, {place: "deployed"}], expect: {run: false, asked: []}},
	]
}
cases: "a step whose kept value is missing is skipped and asks no flag": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{flag: "f", ifKept: "live"}, {place: "local"}], expect: {run: false, asked: []}},
	]
}
cases: "a local step at hand asks its flag, and an unless step there is skipped once the flag is on": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{on: "local", flag: "f"}, {place: "local"}], expect: {run: true, asked: ["f"]}},
		{call: "harness.gate", args: [{on: "local", unless: "f"}, {place: "local"}], expect: {run: false, asked: ["f"]}},
	]
}
cases: "a production step of the flag a flip tests runs and asks nothing": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{on: "production", flag: "f"}, {place: "production", flip: "f"}], expect: {run: true, asked: []}},
	]
}

// An `open` step's address: a path or a web address of the app, nothing else, and on production only the app's origin.
cases: "an open step takes a path or a web address, never a file, and on production only the app's origin": {
	suite: "harness"
	steps: [
		{call: "harness.openHref", args: ["/play", "http://localhost:3000/", false], expect: "http://localhost:3000/play"},
		{call: "harness.openHref", args: ["https://other.example/x", "http://localhost:3000/", false], expect: "https://other.example/x", why: "at hand a link to another origin is a page like any"},
		{call: "harness.openHref", args: ["/play", "https://app.example/", true], expect: "https://app.example/play"},
		{call: "harness.openHref", args: ["file:///etc/hosts", "http://localhost:3000/", false], throws: "not an http", why: "never the runner's own files"},
		{call: "harness.openHref", args: ["https://other.example/x", "https://app.example/", true], throws: "only one a production scenario"},
	]
}

// A step's second flag (`with`, PRONTO-1688): it runs only where both flags are on, and each is asked in turn.
cases: "a step with a flag and a with flag runs only where both are on": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{flag: "a", with: "b"}, {place: "local"}], expect: {run: true, asked: ["a", "b"]}},
		{call: "harness.gate", args: [{flag: "a", with: "b"}, {place: "local", off: ["a"]}], expect: {run: false, asked: ["a"]}, why: "the first flag off: the second is never asked"},
		{call: "harness.gate", args: [{flag: "a", with: "b"}, {place: "local", off: ["b"]}], expect: {run: false, asked: ["a", "b"]}, why: "the second flag off alone skips the step"},
		{call: "harness.gate", args: [{on: "local", flag: "a", with: "b"}, {place: "production"}], expect: {run: false, asked: []}, why: "its place is asked first"},
	]
}
cases: "a flip's flag decides first, and the with flag still has to be on": {
	suite: "harness"
	steps: [
		{call: "harness.gate", args: [{flag: "a", with: "b"}, {place: "production", flip: "a"}], expect: {run: true, asked: ["b"]}},
		{call: "harness.gate", args: [{flag: "a", with: "b"}, {place: "production", flip: "a", off: ["b"]}], expect: {run: false, asked: ["b"]}, why: "a flip tests its own flag alone: the other is never forced on"},
	]
}

// A production scenario's one non-GET call: a flag's evaluation (an anonymous POST to /ofrep/v1/evaluate/flags/<name> with only its
// context), which reads and writes nothing; every other write stays barred (bsoneca/pronto#1600: a flip's check of an enabled flag).
cases: "a production scenario may evaluate a flag by POST and make no other write": {
	suite: "harness"
	steps: [
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/preview_pointer_lock", anon: true, body: {context: {}}, expect: {status: 200, json: {value: true}}}}]], expect: null, why: "an anonymous flag evaluation with its context is a read"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f", anon: true, expect: {status: 200}}}]], expect: null, why: "and needs no body"},
		{call: "harness.productionRefused", args: [[{http: {method: "GET", path: "/anything", anon: true, expect: {status: 200}}}]], expect: null, why: "a GET is as before"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/crud/rpc/billing_grant", anon: true, body: {context: {}}, expect: {status: 200}}}]], matches: "_writes", why: "any other POST is still a write"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f/../../crud/x", anon: true, expect: {status: 200}}}]], matches: "_writes", why: "a path that climbs out of the flag's is another POST"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f?x=1", anon: true, expect: {status: 200}}}]], matches: "_writes", why: "no query"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f", expect: {status: 200}}, by: "a"}]], matches: "_writes", why: "a signed-in evaluation is another session's"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f", anon: true, body: {context: {}, extra: 1}, expect: {status: 200}}}]], matches: "_writes", why: "nothing in the body but the context"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f", anon: true, headers: {authorization: "Bearer x"}, expect: {status: 200}}}]], matches: "_writes", why: "no header of its own"},
		{call: "harness.productionRefused", args: [[{http: {method: "PUT", path: "/ofrep/v1/evaluate/flags/f", anon: true, expect: {status: 200}}}]], matches: "_writes", why: "only POST"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f%2F..%2F..%2Fcrud%2Fx", anon: true, expect: {}}}]], matches: "_writes", why: "no encoded climb"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "https://x.example/ofrep/v1/evaluate/flags/f", anon: true, expect: {}}}]], matches: "_writes", why: "only the door's own path"},
		{call: "harness.productionRefused", args: [[{http: {method: "POST", path: "/ofrep/v1/evaluate/flags/f", anon: true, body: "{}", expect: {}}}]], matches: "_writes", why: "the body is the context object, not text"},
	]
}

// PRONTO-419: a production scenario that signs in as no one may open a page and look at it; the runner's browser aborts what it writes.
cases: "a production scenario that signs in as no one may open a page and only look at it": {
	suite: "harness"
	steps: [
		{call: "harness.productionRefused", args: [[{by: "a", open: "/"}, {by: "a", attached: "#army-pick"}, {by: "a", see: "main"}, {by: "a", hidden: ".gone"}, {by: "a", count: {of: ".army", is: 11}}, {by: "a", text: {of: "h1", has: "x"}}, {by: "a", attr: {of: "a", name: "href", is: "/"}}, {by: "a", attrs: {of: "a", name: "href", are: ["/"]}}]], expect: null, why: "open and the looks"},
		{call: "harness.productionRefused", args: [[{by: "a", open: "/"}, {by: "a", click: "#army-pick"}]], matches: "_page", why: "a click is a gesture"},
		{call: "harness.productionRefused", args: [[{by: "a", fill: {in: "input", value: "x"}}]], matches: "_page", why: "so is a fill"},
		{call: "harness.productionRefused", args: [[{by: "a", signUp: true}]], matches: "_barred", why: "signing up is still barred"},
	]
}
cases: "a read-only production page's requests: reads pass, a write to /auth or /crud refuses the run, other writes are aborted and ignored": {
	suite: "harness"
	steps: [
		{call: "harness.sentOf", args: ["GET", true, "/crud/army_catalog"], expect: "pass"},
		{call: "harness.sentOf", args: ["POST", true, "/ofrep/v1/evaluate/flags/army_catalog_live"], expect: "pass", why: "a flag's anonymous evaluation is a read"},
		{call: "harness.sentOf", args: ["POST", true, "/ofrep/v1/evaluate/flags/f/../x"], expect: "abort"},
		{call: "harness.sentOf", args: ["POST", false, "/ofrep/v1/evaluate/flags/f"], expect: "abort", why: "only the app's own door"},
		{call: "harness.sentOf", args: ["POST", true, "/auth/guest"], expect: "refuse", why: "a page that boots a guest is no read"},
		{call: "harness.sentOf", args: ["PATCH", true, "/crud/player"], expect: "refuse"},
		{call: "harness.sentOf", args: ["POST", false, "/crud/player"], expect: "abort", why: "another origin's /crud is not the app's"},
		{call: "harness.sentOf", args: ["POST", true, "/beacon/analytics"], expect: "abort", why: "a beacon is aborted, never a failure"},
	]
}

// PRONTO-892 (Codex on bsoneca/pronto#1520): the browser's and the contexts' closes keep a finished close, a rejected one and a timeout apart,
// and the record, the verdict and the summary share one failed set.
cases: "a close that finished, one Playwright rejected and one that never answers are three different results": {
	suite: "harness"
	steps: [
		{call: "harness.closeOf", args: ["ok"], expect: {state: "closed"}},
		{call: "harness.closeOf", args: ["reject"], expect: {state: "rejected", error: "Target page, context or browser has been closed"}, why: "its first line, the rejection kept: it was once read as a close that finished"},
		{call: "harness.closeOf", args: ["never"], expect: {state: "timeout"}},
	]
}
cases: "a browser that did not close cleanly fails every scenario that ran and records none green, the record and the verdict sharing the set": {
	suite: "harness"
	steps: [
		{call: "harness.settled", args: [{ran: ["a", "b"], browser: {state: "closed"}}], expect: {failedAll: [], green: ["a", "b"]}},
		{call: "harness.settled", args: [{ran: ["a", "b"], browser: {state: "rejected", error: "boom"}}], expect: {failedAll: ["a", "b"], green: []}, why: "all assertions passed and the close was rejected: not a success, and the old green records of both go (the selector deletes those it is told failed)"},
		{call: "harness.settled", args: [{ran: ["a", "b"], browser: {state: "timeout"}}], expect: {failedAll: ["a", "b"], green: []}, why: "every affected id is in the set the record is given, not added after it"},
		{call: "harness.settled", args: [{ran: ["a", "b"], failed: ["b"], browser: {state: "closed"}}], expect: {failedAll: ["b"], green: ["a"]}},
		{call: "harness.settled", args: [{ran: ["a", "b"], pageErrorIds: ["a", "z"], pageErrors: ["x"], browser: {state: "closed"}}], expect: {failedAll: ["a"], green: []}, why: "a scenario whose page threw is failed, and a page error records no green"},
	]
}
