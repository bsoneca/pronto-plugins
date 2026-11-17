package unit

// The scenarios' flake filing (harness/files/tests/scenarios/flakes.ts) on a fake board (PRONTO-649): filing
// is bookkeeping, so a board that refuses never throws, shows its whole error and leaves no marker.
cases: "a board that refuses a flake is said with its whole error, never thrown, and leaves no marker": {
	suite: "harness"
	steps: [
		{call: "harness.refused"},
		{keep: "r"},
		{get: "threw", expect: false, why: "a refusal is logged, never thrown: the run's exit is the scenarios' alone"},
		{use: "r"},
		{get: "filed", expect: false},
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
cases: "a board that is missing is a refusal too": {
	suite: "harness"
	steps: [
		{call: "harness.missing"},
		{keep: "r"},
		{get: "threw", expect: false},
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
cases: "a filed flake whose marker cannot be written is said, never thrown": {
	suite: "harness"
	steps: [
		{call: "harness.unmarked", expect: {threw: false, filed: true, said: 1}, why: "a cache that cannot be written is bookkeeping too: the next run files it again"},
	]
}
