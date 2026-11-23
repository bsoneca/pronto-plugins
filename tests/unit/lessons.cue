// pronto-lessons' step engine (lessons/app/lessons.js) on a toy adapter whose board is the applied tokens
// (tests/unit/lessons_toy.js), and the schema's refusals (lessons/schema.cue). The toy course's script is
// a1 b1 a2 b2 a3, the player moving the even plies.
package unit

cases: {
	"shown plies play by themselves, then the scripted reply, and the player moves next": {suite: "lessons", steps: [
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 2, []], holds: {board: "a1 b1", state: {step: 2, wrongs: 0, step_wrongs: 0, done: false}}},
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 1, []], holds: {board: "a1 b1", state: {step: 2}}, why: "the reply after a shown ply is scripted too"},
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 2, ["a2", "a3"]], holds: {board: "a1 b1 a2 b2 a3", kinds: ["right", "right"], state: {done: true}}},
	]}
	"a right move advances, plays the reply and finishes the chapter": {suite: "lessons", steps: [
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 0, ["a1"]], holds: {board: "a1 b1", kinds: ["right"], state: {step: 2, wrongs: 0}}},
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 0, ["a1", "a2", "a3", "a4"]], holds: {kinds: ["right", "right", "right", "done"], state: {done: true, step: 5}}},
	]}
	"a wrong move reverts the board and counts: wrongs for the chapter, step_wrongs for the step": {suite: "lessons", steps: [
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 0, ["zz", "yy"]], holds: {board: "", kinds: ["wrong", "wrong"], state: {step: 0, wrongs: 2, step_wrongs: 2}}},
		{call: "toy.run", args: [8, ["a1", "b1", "a2", "b2", "a3"], 0, ["zz", "a1", "yy"]], holds: {board: "a1 b1", kinds: ["wrong", "right", "wrong"], state: {step: 2, wrongs: 2, step_wrongs: 1}}, why: "step_wrongs starts again at the next step, wrongs does not"},
	]}
	"the take-back keeps the board before the wrong move and shows the one after it": {suite: "lessons", steps: [
		{call: "toy.wrongs", args: [8, 1], holds: {board: "", tried: "zz", state: {wrongs: 1, step_wrongs: 1}}},
	]}
	"a ply's own wrong lines come in order before the pool": {suite: "lessons", steps: [
		{call: "toy.wrongs", args: [8, 2, {"0": ["own0", "own1"]}], holds: {said: ["own0", "own1"]}},
		{call: "toy.wrongs", args: [8, 3, {"0": ["own0", "own1"]}]},
		{get: "said.2", matches: "^c[0-7]$", why: "then the pool, by the chapter's wrongs"},
		{call: "toy.wrongs", args: [8, 1, {"0": ["own0"]}], holds: {said: ["own0"]}},
	]}
	"a chapter's complaint sequence never repeats within N and never twice in a row across the wrap, N = 8": {suite: "lessons", steps: [
		{call: "toy.sequenceReport", args: [8, 3], expect: {count: 24, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.sequenceReport", args: [8, 40], holds: {cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.sequence", args: [8, 16], expect: ["c4", "c7", "c3", "c6", "c0", "c1", "c5", "c2", "c0", "c2", "c3", "c6", "c4", "c1", "c7", "c5"], why: "the sequence of seed fnv1a(crs/ch) is pinned: the same seed, the same lines"},
	]}
	"the same, N = 9": {suite: "lessons", steps: [
		{call: "toy.sequenceReport", args: [9, 3], expect: {count: 27, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.sequenceReport", args: [9, 40], holds: {cyclesComplete: true, noneTwiceInARow: true}},
	]}
	"a ply's own lines mixed with pool picks leave the pool no repeat within N nor twice in a row, over 3 wraps, N = 8, several seeds": {suite: "lessons", steps: [
		{call: "toy.mixedReport", args: [8, 3, 1], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 2], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 3], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 4], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 5], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 6], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 7], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [8, 3, 8], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
	]}
	"own lines mixed with pool picks, the same for N = 9": {suite: "lessons", steps: [
		{call: "toy.mixedReport", args: [9, 3, 1], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 2], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 3], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 4], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 5], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 6], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 7], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
		{call: "toy.mixedReport", args: [9, 3, 8], holds: {enough: true, usedOwn: true, cyclesComplete: true, noneTwiceInARow: true}},
	]}
	"a stale step is reconciled: the server's step and counters win and nothing is replayed": {suite: "lessons", steps: [
		{call: "toy.reconcile", args: [[], {step: 2, wrongs: 3, step_wrongs: 1, pool_said: 2}], holds: {state: {step: 2, wrongs: 3, step_wrongs: 1, pool_said: 2, done: false}, board: "a1 b1", out: {step: 2, wrongs: 3}}},
		{call: "toy.reconcile", args: [["a1", "a2"], {step: 2, wrongs: 1, step_wrongs: 1, pool_said: 1}], holds: {state: {step: 2, wrongs: 1, pool_said: 1}, board: "a1 b1"}, why: "the server is behind: its step wins"},
	]}
	"the same step: the server's counters are adopted, the board stays": {suite: "lessons", steps: [
		{call: "toy.reconcile", args: [["a1"], {step: 2, wrongs: 5, step_wrongs: 0, pool_said: 4}], holds: {state: {step: 2, wrongs: 5, step_wrongs: 0, pool_said: 4}, board: "a1 b1", boardBefore: "a1 b1"}},
	]}
	"a lesson resumed at the server's state keeps the complaint sequence going, as after a reload": {suite: "lessons", steps: [
		{call: "toy.resume", args: [{step: 2, wrongs: 6, step_wrongs: 0, pool_said: 6}], holds: {board: "a1 b1", expected: "a2", after: {wrongs: 7, pool_said: 7}}},
		{get: "line", matches: "^c[0-7]$"},
		{call: "toy.resume", args: [{step: 2, wrongs: 0, step_wrongs: 0, pool_said: 0}]},
		{get: "line", expect: "c4", why: "a fresh pool starts at its first line"},
	]}
	"a reconciled step is played forward to the player's turn, within the script": {suite: "lessons", steps: [
		{call: "toy.reconcile", args: [[], {step: 1, wrongs: 0, step_wrongs: 0, pool_said: 0}, 2], holds: {state: {step: 2}, board: "a1 b1", expected: "a2"}, why: "below shown: the shown plies play"},
		{call: "toy.reconcile", args: [[], {step: 1, wrongs: 0, step_wrongs: 0, pool_said: 0}, 1], holds: {state: {step: 2}, board: "a1 b1", expected: "a2"}, why: "the opponent's ply: its scripted move plays"},
		{call: "toy.reconcile", args: [[], {step: 99, wrongs: 0, step_wrongs: 0, pool_said: 0}], holds: {state: {step: 5, done: true}, expected: null}},
		{call: "toy.reconcile", args: [[], {step: -3, wrongs: 0, step_wrongs: 0, pool_said: 0}], holds: {state: {step: 0}, expected: "a1"}},
	]}
	"FNV-1a of the text's bytes is pinned": {suite: "lessons", steps: [
		{call: "lessons.fnv1a", args: [""], expect: 2166136261},
		{call: "lessons.fnv1a", args: ["a"], expect: 3826002220},
		{call: "lessons.fnv1a", args: ["foobar"], expect: 3214735720},
		{call: "lessons.fnv1a", args: ["crs/ch"], expect: 1876326257},
	]}
	"a permutation is pinned for a seed, cycle 0 by default": {suite: "lessons", steps: [
		{call: "lessons.permutation", args: [5, 8, 0], expect: [4, 2, 6, 0, 3, 1, 7, 5]},
		{call: "lessons.permutation", args: [5, 8], expect: [4, 2, 6, 0, 3, 1, 7, 5]},
		{call: "lessons.permutation", args: [5, 3, 2], expect: [2, 1, 0]},
	]}
	"the schema accepts the example and refuses a missing or an extra translation, a short or identical pool, a shown past the player's last ply, a bad step key, a duplicate chapter and a bad player": {suite: "lessons", steps: [
		{call: "toy.vets", args: ["none"], expect: true},
		{call: "toy.vets", args: ["dropTranslation"], expect: false},
		{call: "toy.vets", args: ["extraLocale"], expect: false},
		{call: "toy.vets", args: ["shortPool"], expect: false},
		{call: "toy.vets", args: ["shownBeyondMoves"], expect: false},
		{call: "toy.vets", args: ["badPlayer"], expect: false},
		{call: "toy.vets", args: ["emptyTranslation"], expect: false, why: "an empty text is no translation"},
		{call: "toy.vets", args: ["identicalPool"], expect: false, why: "eight identical complaints are one"},
		{call: "toy.vets", args: ["noPlayerPly"], expect: false, why: "no ply of the player's at or after shown"},
		{call: "toy.vets", args: ["shownAtEnd"], expect: false},
		{call: "toy.vets", args: ["stepBeyondMoves"], expect: false},
		{call: "toy.vets", args: ["stepZeroPadded"], expect: false},
		{call: "toy.vets", args: ["stepOnOtherSide"], expect: false},
		{call: "toy.vets", args: ["duplicateChapterAcrossParts"], expect: false},
		{call: "toy.vets", args: ["duplicateChapterWithinPart"], expect: false},
	]}
}
