// prod-watch's cursor (prod-watch/watch.js cursorOf, countedOf, settleRun) across runs and across versions (PRONTO-1531).
package unit

_e1: {h: "h1", ts: "2026-11-19T12:02:00.000Z"}
_e2: {h: "h2", ts: "2026-11-19T12:03:00.000Z"}
_e3: {h: "h3", ts: "2026-11-19T12:04:00.000Z"}
_ex: {h: "hx", ts: "2026-11-19T12:04:30.000Z"}
_ey: {h: "hy", ts: "2026-11-19T12:05:00.000Z"}
_ez: {h: "hz", ts: "2026-11-19T12:07:00.000Z"}

cases: {
	"a read a limit cut short commits where it stopped, and the uncapped reads after it never commit behind that: each entry is counted once": {suite: "noise", steps: [
		{call: "watchruns.reads", args: [{
			entries: [_e1, _e2, _e3, _ex, _ey, _ez]
			runs: [{to: "2026-11-19T12:06:00.000Z", cap: 4}, {to: "2026-11-19T12:06:30.000Z"}, {to: "2026-11-19T12:08:00.000Z"}]
		}], expect: {counts: {h1: 1, h2: 1, h3: 1, hx: 1, hy: 1, hz: 1}, committed: ["2026-11-19T12:04:00.000Z", "2026-11-19T12:04:00.000Z", "2026-11-19T12:04:00.000Z"]}, why: "five minutes of lag from 12:06:30 is 12:01:30, behind the capped read's 12:04: it stays at 12:04, or the run after reads e1..e3 again"},
		{call: "watchruns.reads", args: [{
			entries: [_e1, _e2, _e3]
			runs: [{to: "2026-11-19T12:10:00.000Z"}, {to: "2026-11-19T12:11:00.000Z"}, {to: "2026-11-19T12:20:00.000Z"}]
		}], expect: {counts: {h1: 1, h2: 1, h3: 1}, committed: ["2026-11-19T12:05:00.000Z", "2026-11-19T12:06:00.000Z", "2026-11-19T12:15:00.000Z"]}, why: "reads to now keep their lag: the cursor follows it, the overlap's entries are skipped by hash"},
	]}
	"the cursor's `seen` is the hashes as strings, which the older watcher's Set finds, and the occurrences are beside it": {suite: "noise", steps: [
		{call: "watch.cursorOf", args: [{committed: "2026-11-19T12:01:00.000Z", seen: [{h: "h1", at: "2026-11-19T12:02:00.000Z", strict: true}, {h: "h2", at: "2026-11-19T12:03:00.000Z"}]}], expect: {at: "2026-11-19T12:01:00.000Z", seen: ["h1", "h2"], occurrences: [{h: "h1", at: "2026-11-19T12:02:00.000Z", strict: true}, {h: "h2", at: "2026-11-19T12:03:00.000Z"}]}},
		{call: "watchruns.baseSees", args: [{at: "x", seen: ["h1", "h2"], occurrences: [{h: "h1", at: "2026-11-19T12:02:00.000Z", strict: true}, {h: "h2", at: "2026-11-19T12:03:00.000Z"}]}, "h2"], expect: true},
	]}
	"a cursor is read as written by this version, by an older writer (seen alone), by an older writer that saved after this one, and by this version's first form": {suite: "noise", steps: [
		{call: "watch.countedOf", args: [{at: "x", seen: ["h1", "h2"], occurrences: [{h: "h1", at: "2026-11-19T12:02:00.000Z", strict: true}, {h: "h2", at: "2026-11-19T12:03:00.000Z"}]}], expect: [{h: "h1", at: "2026-11-19T12:02:00.000Z", strict: true}, {h: "h2", at: "2026-11-19T12:03:00.000Z"}], why: "the occurrences, as they match `seen`"},
		{call: "watch.countedOf", args: [{at: "x", seen: ["h1", "h2"]}], expect: ["h1", "h2"], why: "an older writer's cursor: bare hashes"},
		{call: "watch.countedOf", args: [{at: "x", seen: ["h9"], occurrences: [{h: "h1", at: "2026-11-19T12:02:00.000Z"}]}], expect: ["h9"], why: "an older writer saved `seen` alone after this one: the occurrences are another run's"},
		{call: "watch.countedOf", args: [{at: "x", seen: [{h: "h1", at: "2026-11-19T12:02:00.000Z"}]}], expect: [{h: "h1", at: "2026-11-19T12:02:00.000Z"}], why: "this version's first form: objects in `seen`"},
		{call: "watch.countedOf", args: [null], expect: [], why: "no cursor"},
	]}
}
