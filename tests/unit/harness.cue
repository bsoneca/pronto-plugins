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
