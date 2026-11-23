// pronto-lessons' step engine (lessons/app/lessons.js) on a toy adapter whose board is the applied tokens
// (tests/unit/lessons_toy.js), and the schema's refusals (lessons/schema.cue). The toy course's script is
// a1 b1 a2 b2 a3, the player moving the even plies.
package unit

import (
	"list"
	"strings"
)

// The database half (lessons/app/lessons.sql, lessons_plugin.cue) follows the step engine's cases, on PGlite over a fixture course
// (tests/unit/fixtures/lessons_course.cue; tests/unit/lessons_db.js): two parts, the first with chapters one (a1 b1 a2 b2 a3) and one_b
// (a1 b1 a2), the second with two (a1 b'1$ a2 b2, moved from ply 1). Rewards 15 a chapter and 30 for the first part, a hint 10; FREE
// pays 10 to open, PLUS 5 (and has 7 gold), PAID nothing, POOR has 3 gold, BANNED's plan may not, OTHER is the one the flag is on for.

#LessonsPlay: {
	who: string
	one: [
		{call: "lessonsdb.call", args: ["$pg", who, "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "one", 2, "a2"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "one", 4, "a3"]]},
	]
	two: [
		{call: "lessonsdb.call", args: ["$pg", who, "start", ["toy", "two"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "two", 1, "b'1$"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "two", 3, "b2"]]},
	]
	oneB: [
		{call: "lessonsdb.call", args: ["$pg", who, "start", ["toy", "one_b"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "one_b", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", who, "move", ["toy", "one_b", 2, "a2"]]},
	]
}

_lsDb: [{call: "lessonsdb.db"}, {keep: "pg"}]
_lsWindowWrites: list.Concat([for who in ["FREE", "anon", "service"] for sql in [
	"INSERT INTO public.lesson_progress (id, owner_id, course, chapter, part, step, done) VALUES ('forged', '0c0c0c0c-0000-4000-8000-00000000000c', 'toy', 'one', 'first', 9, true)",
	"UPDATE public.lesson_progress SET done = true",
	"DELETE FROM public.lesson_progress",
] {[
	{call: "lessonsdb.as", args: ["$pg", who, sql]},
	{get: "refused", matches: "^42501: "},
]}])
_lsTrigger: "^42501: (lesson progress is the lessons functions' to write|permission denied for table lesson_progress)$" // the trigger, or the revoked grant that lessons.sql adds first

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
	"a stale page reconciles to the server's row: its step, counters and board win, and nothing is replayed": {suite: "lessons", steps: [
		{call: "toy.stale", args: [[[0, "a1"]]], holds: {before: {state: {step: 0}, board: ""}, state: {step: 2, wrongs: 0, step_wrongs: 0, pool_said: 0, done: false}, board: "a1 b1", out: {step: 2}}, why: "another tab played a1: the page's board is rebuilt from the plies the server says were played"},
		{call: "toy.stale", args: [[[0, "a1"], [2, "zz"]]], holds: {state: {step: 2, wrongs: 1, step_wrongs: 1, pool_said: 1}, board: "a1 b1"}},
		{call: "toy.stale", args: [[[0, "a1"], [2, "a2"], [4, "a3"]]], holds: {state: {step: 5, done: true}, board: "a1 b1 a2 b2 a3"}, why: "a chapter finished elsewhere"},
	]}
	"the same step: the server's counters are adopted, the board stays": {suite: "lessons", steps: [
		{call: "toy.stale", args: [[[0, "zz"], [0, "yy"]]], holds: {state: {step: 0, wrongs: 2, step_wrongs: 2, pool_said: 2}, board: "", before: {board: ""}}},
	]}
	"a move at a step the server has left judges nothing: the page adopts the server's row and says it is stale": {suite: "lessons", steps: [
		{call: "toy.stale", args: [[[0, "a1"]], "zz"], holds: {kind: "stale", state: {step: 2, wrongs: 0}, board: "a1 b1"}, why: "a wrong move at a step already passed counts for nothing"},
		{call: "toy.stale", args: [[[0, "a1"]], "a1"], holds: {kind: "right", state: {step: 2, wrongs: 0}, board: "a1 b1"}, why: "the same move the other tab played: its outcome is what the server says"},
	]}
	"a lesson resumed at the server's row keeps the complaint sequence going, as after a reload": {suite: "lessons", steps: [
		{call: "toy.resume", args: [{step: 2, wrongs: 6, step_wrongs: 0, pool_said: 6}], holds: {board: "a1 b1", after: {wrongs: 7, pool_said: 7}}},
		{get: "line", matches: "^c[0-7]$"},
		{call: "toy.resume", args: [{step: 2, wrongs: 0, step_wrongs: 0, pool_said: 0}]},
		{get: "line", expect: "c4", why: "a fresh pool starts at its first line"},
	]}
	"a move in flight makes the next one busy, and the page shows the server's answer when it comes": {suite: "lessons", steps: [
		{call: "toy.inflight", holds: {during: {busy: true, second: "busy", board: ""}, first: "right", replies: ["b1"], after: {busy: false, state: {step: 2}, board: "a1 b1"}}, why: "the board waits for the server: nothing is drawn before it says right"},
	]}
	"a move the server took after another tab had gone further is stale, and a reconcile during a move leaves the answer to show the server's row": {suite: "lessons", steps: [
		{call: "toy.stale", args: [[[0, "a1"], [2, "a2"]], "a1"], holds: {kind: "stale", state: {step: 4}, board: "a1 b1 a2 b2"}, why: "the token is the one played at ply 0, but the server is two moves on: no reply is drawn"},
		{call: "toy.reconcileDuring", holds: {during: {state: {step: 4}, board: "a1 b1 a2 b2"}, kind: "stale", state: {step: 2}, board: "a1 b1"}},
	]}
	"a call that fails leaves the lesson as it was, and it is not left busy": {suite: "lessons", steps: [
		{call: "toy.failed", holds: {error: "offline", busy: false, same: true}},
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

	// ---- the database half ----
	"a guest and the anonymous role are refused before anything is read, and leave no row, no ledger entry and no call": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"], {guest: true}], expect: {refused: "42501: lessons: a guest has no lessons"}},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "move", ["toy", "one", 0, "a1"], {guest: true}], expect: {refused: "42501: lessons: a guest has no lessons"}},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "hint", ["toy", "one", 0], {guest: true}], expect: {refused: "42501: lessons: a guest has no lessons"}},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"], {claims: {guest: "maybe"}}], expect: {refused: "42501: lessons: a guest has no lessons"}, why: "a claim that is no boolean is a refusal, not a cast error"},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"], {claims: {guest: false}}], holds: {state: {step: 0}}, why: "only an explicit false is no guest"},
		{call: "lessonsdb.call", args: ["$pg", "anon", "start", ["toy", "one"]]},
		{get: "refused", matches: "^42501: permission denied for function lesson_start"},
		{call: "lessonsdb.rows", args: ["$pg"], expect: [{account: "PAID", chapter: "one", step: 0}], why: "only the explicit-false start left a row"},
		{call: "lessonsdb.calls", args: ["$pg"], expect: []},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: ["PAID lesson/toy/one/open open 0"], why: "the one explicit-false start, nothing from the refusals"},
	]])
	}
	"a course whose flag is off for everyone is unavailable, on start, move and hint, before there is a row to ask for": {suite: "lessons", steps: [
		{call: "lessonsdb.db", args: [{flagged: false}]}, {keep: "pg"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], expect: {refused: "42501: lessons: unavailable"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]], expect: {refused: "42501: lessons: unavailable"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 0]], expect: {refused: "42501: lessons: unavailable"}},
		{call: "lessonsdb.rows", args: ["$pg"], expect: []},
	]}
	"a flag on for one account lets that account in and no other": {suite: "lessons", steps: [
		{call: "lessonsdb.db", args: [{flagged: false}]}, {keep: "pg"},
		{call: "lessonsdb.flag", args: ["$pg", "OTHER"]},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"]], expect: {refused: "42501: lessons: unavailable"}},
		{call: "lessonsdb.call", args: ["$pg", "OTHER", "start", ["toy", "one"]], holds: {state: {step: 0, done: false, part: "first"}}},
	]}
	"a plan that may not open lessons is refused, and nothing is written": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "BANNED", "start", ["toy", "one"]], expect: {refused: "42501: lessons: not for this plan"}},
		{call: "lessonsdb.call", args: ["$pg", "BANNED", "hint", ["toy", "one", 0]], expect: {refused: "42501: lessons: not for this plan"}},
		{call: "lessonsdb.rows", args: ["$pg"], expect: []},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: []},
	]])
	}
	"the tier's price is charged once at the chapter's opening, and not at all for a price of nothing": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"]], holds: {state: {step: 0}}},
		{call: "lessonsdb.calls", args: ["$pg"], expect: [], why: "a premium plan's price is 0: recorded, no pay call"},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay PLUS lesson/toy/one/open 5", "pay FREE lesson/toy/one/open 10"]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {step: 0}}},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay PLUS lesson/toy/one/open 5", "pay FREE lesson/toy/one/open 10"], why: "a second start of the same chapter is free"},
		{call: "lessonsdb.wallet", args: ["$pg", "PLUS"], expect: 2},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: ["PAID lesson/toy/one/open open 0", "PLUS lesson/toy/one/open open 5", "FREE lesson/toy/one/open open 10"]},
	]])
	}
	"an account short of gold is refused by the hook and no row or ledger entry is left": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "POOR", "start", ["toy", "one"]], expect: {refused: "23514: short of gold"}},
		{call: "lessonsdb.rows", args: ["$pg"], expect: []},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: []},
		{call: "lessonsdb.wallet", args: ["$pg", "POOR"], expect: 3},
	]])
	}
	"a chapter after another's is locked until that is done, and a locked start charges nothing": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one_b"]], expect: {refused: "23514: lessons: locked"}},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: []},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one_b"]], expect: {refused: "23514: lessons: locked"}, why: "one is begun, not done"},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: ["FREE lesson/toy/one/open open 10"]},
	], (#LessonsPlay & {who: "FREE"}).one[1:], [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one_b"]], holds: {state: {step: 0, chapter: "one_b"}}},
	]])
	}
	"a part's first chapter is locked until every chapter of the part before is done": {suite: "lessons", steps: list.Concat([_lsDb, (#LessonsPlay & {who: "FREE"}).one, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "two"]], expect: {refused: "23514: lessons: locked"}, why: "one is done, one_b is not"},
	], (#LessonsPlay & {who: "FREE"}).oneB, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "two"]], holds: {state: {step: 1, part: "second", done: false}}, why: "the part's first ply is the script's, the player moves from ply 1"},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "two"]], expect: {refused: "23514: lessons: locked"}, why: "locked per account"},
	]])
	}
	"a move at the step advances past the script's reply, a retried move changes nothing": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {step: 0}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]], holds: {state: {step: 2, wrongs: 0, step_wrongs: 0, pool_said: 0, done: false, over: false}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]], holds: {state: {step: 2, wrongs: 0}}, why: "the same move again: the step is no longer 0"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "zz"]], holds: {state: {step: 2, wrongs: 0, step_wrongs: 0}}, why: "a stale wrong move is not counted either"},
	]])
	}
	"the row holds the plies played up to its step and no ply after it, and a stale or wrong move answers with the same": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {step: 0, played: []}}, why: "nothing is played before the player's first move"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "zz"]], holds: {state: {step: 0, wrongs: 1, played: []}}, why: "a wrong move: the board keeps, the answer's count is the server's"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]], holds: {state: {step: 2, played: ["a1", "b1"]}}, why: "the player's move and the script's reply"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "yy"]], holds: {state: {step: 2, wrongs: 1, played: ["a1", "b1"]}}, why: "a stale step: the row as it is, with what is played (a2 is not)"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 2, "a2"]], holds: {state: {step: 4, played: ["a1", "b1", "a2", "b2"]}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 4, "a3"]], holds: {state: {step: 5, over: true, played: ["a1", "b1", "a2", "b2", "a3"]}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {step: 0, played: []}}, why: "a replay starts again from nothing"},
	]])
	}
	"the page of a chapter whose player moves from ply 1 starts with the script's first ply played": {suite: "lessons", steps: list.Concat([_lsDb, (#LessonsPlay & {who: "FREE"}).one, (#LessonsPlay & {who: "FREE"}).oneB, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "two"]], holds: {state: {step: 1, played: ["a1"]}}},
	]])
	}
	"the emitted page holds no move of the script, only each chapter's plies": {suite: "lessons", steps: [
		{call: "lessonsdb.pageHolds", expect: {leaked: [], plies: {one: {plies: 5, hasMoves: false, hasClaim: false}, one_b: {plies: 3, hasMoves: false, hasClaim: false}, two: {plies: 4, hasMoves: false, hasClaim: false}}}},
	]}
	"a wrong move counts, the page's pool counter advances only past the ply's own lines, and a right move starts the step again": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 2, "zz"]], holds: {state: {step: 2, wrongs: 1, step_wrongs: 1, pool_said: 0}}, why: "ply 2 has one own line"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 2, "zz"]], holds: {state: {wrongs: 2, step_wrongs: 2, pool_said: 1}}, why: "the second is the pool's"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 2, "a2"]], holds: {state: {step: 4, wrongs: 2, step_wrongs: 0, pool_said: 1}}},
	]])
	}
	"finishing a chapter marks it done and over and pays its reward once, a replay's finish pays nothing": {suite: "lessons", steps: list.Concat([_lsDb, (#LessonsPlay & {who: "FREE"}).one, [
		{get: "state", holds: {step: 5, done: true, over: true}},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "reward FREE lesson/toy/one/done 15"]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 5, "a3"]], holds: {state: {step: 5, done: true, over: true}}, why: "a move after the end changes nothing"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {step: 0, wrongs: 0, pool_said: 0, hinted: -1, done: true, over: false}}, why: "a replay: counters reset, done kept"},
	], (#LessonsPlay & {who: "FREE"}).one[1:], [
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "reward FREE lesson/toy/one/done 15"], why: "no second reward, no second charge"},
		{call: "lessonsdb.wallet", args: ["$pg", "FREE"], expect: 105},
	]])
	}
	"the last chapter of a part pays the part's bonus once": {suite: "lessons", steps: list.Concat([_lsDb, (#LessonsPlay & {who: "FREE"}).one, [
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "reward FREE lesson/toy/one/done 15"], why: "one_b is still to do"},
	], (#LessonsPlay & {who: "FREE"}).oneB, [
		{call: "lessonsdb.calls", args: ["$pg"], expect: [
			"pay FREE lesson/toy/one/open 10", "reward FREE lesson/toy/one/done 15",
			"pay FREE lesson/toy/one_b/open 10", "reward FREE lesson/toy/one_b/done 15", "reward FREE lesson/toy/first/bonus 30",
		]},
	], (#LessonsPlay & {who: "FREE"}).oneB, [
		{call: "lessonsdb.calls", args: ["$pg"], expect: [
			"pay FREE lesson/toy/one/open 10", "reward FREE lesson/toy/one/done 15",
			"pay FREE lesson/toy/one_b/open 10", "reward FREE lesson/toy/one_b/done 15", "reward FREE lesson/toy/first/bonus 30",
		], why: "replaying and finishing again pays no bonus"
		},
	]])
	}
	"a hint at the step pays its entry once, gives the token and is bought for good": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 2]], holds: {state: {token: "a2", hinted: 2, step: 2}}},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "pay FREE lesson/toy/one/2 10"]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 2]], holds: {state: {token: "a2", hinted: 2}}, why: "the same hint again"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 0]], holds: {state: {step: 2, hinted: 2}}, why: "a stale step: unchanged"},
		{get: "state.token", matches: "^undefined$", why: "and no token"},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "pay FREE lesson/toy/one/2 10"]},
	], (#LessonsPlay & {who: "FREE"}).one[2:], [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 0]], holds: {state: {over: true, hinted: 2}}, why: "a finished chapter: unchanged, free"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]], holds: {state: {hinted: -1}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 2]], holds: {state: {token: "a2", hinted: 2}}, why: "the same step after a replay"},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay FREE lesson/toy/one/open 10", "pay FREE lesson/toy/one/2 10", "reward FREE lesson/toy/one/done 15"]},
	]])
	}
	"a hint the account cannot pay for is refused and leaves the lesson as it was": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "hint", ["toy", "one", 2]], expect: {refused: "23514: short of gold"}, why: "7 gold less the 5 to open is 2, a hint is 10"},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]], holds: {state: {step: 2, hinted: -1}}},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: ["PLUS lesson/toy/one/open open 5"]},
	]])
	}
	"a move or a hint on a chapter never started is refused": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, "a1"]], expect: {refused: "23514: lessons: not started"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 0]], expect: {refused: "23514: lessons: not started"}},
		{call: "lessonsdb.rows", args: ["$pg"], expect: []},
	]])
	}
	"an unknown chapter or course, a name or token too long and a negative step are refused as invalid, a step past the script is the row": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "nope"]], expect: {refused: "22023: lessons: no such chapter"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["nope", "one"]], expect: {refused: "22023: lessons: no such chapter"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", strings.Repeat("x", 65)]], expect: {refused: "22023: lessons: no such chapter"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", [strings.Repeat("x", 65), "one"]], expect: {refused: "22023: lessons: no such chapter"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "two"]], expect: {refused: "23514: lessons: locked"}, why: "a chapter of another part is a chapter"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 6, "a1"]], holds: {state: {step: 0, wrongs: 0}}, why: "past the script (a spec since shortened): the row, unchanged"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", -1, "a1"]], expect: {refused: "22023: lessons: bad move"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "move", ["toy", "one", 0, strings.Repeat("x", 65)]], expect: {refused: "22023: lessons: bad move"}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", 6]], holds: {state: {step: 0, hinted: -1}}},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "hint", ["toy", "one", -1]], expect: {refused: "22023: lessons: bad step"}},
		{call: "lessonsdb.ledger", args: ["$pg"], expect: ["FREE lesson/toy/one/open open 10"]},
		{call: "lessonsdb.rows", args: ["$pg"], expect: [{account: "FREE", chapter: "one", step: 0}]},
	]])
	}
	"on a live upgrade the raw migrations close the table before pgroll's trigger exists: no session role writes it, and they replay": {suite: "lessons", steps: list.Concat([[
		{call: "lessonsdb.windowDb"}, {keep: "pg"},
		{call: "lessonsdb.guarded", args: ["$pg"], expect: "0 privileges, trigger true", why: "the blanket grant is revoked and the trigger is made by the functions' own file"},
	], _lsWindowWrites, [
		{call: "lessonsdb.rerun", args: ["$pg"], expect: "ok"},
		{call: "lessonsdb.rerun", args: ["$pg"], expect: "ok", why: "replayed twice: nothing collides"},
		{call: "lessonsdb.guarded", args: ["$pg"], expect: "0 privileges, trigger true"},
	]])
	}
	"after the window pgroll's migration runs over the guarded table, the functions work and a replay keeps it closed": {suite: "lessons", steps: [
		{call: "lessonsdb.windowDb", args: [{late: true}]}, {keep: "pg"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{get: "state.chapter", expect: "one"},
		{call: "lessonsdb.rerun", args: ["$pg"], expect: "ok"},
		{call: "lessonsdb.replay", args: ["$pg"], expect: "replayed"},
		{call: "lessonsdb.guarded", args: ["$pg"], expect: "0 privileges, trigger true"},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "UPDATE public.lesson_progress SET step = 5"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.rows", args: ["$pg"], expect: [{account: "FREE", chapter: "one", step: 0}]},
	]}
	"a session writes no progress row itself, reads its own and no other's": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]]},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "INSERT INTO public.lesson_progress (id, course, chapter, part, step, wrongs, step_wrongs, pool_said, hinted, done, updated) VALUES ('x', 'toy', 'one_b', 'first', 0, 0, 0, 0, -1, false, now())"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "UPDATE public.lesson_progress SET step = 5, done = true"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "DELETE FROM public.lesson_progress"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "anon", "INSERT INTO public.lesson_progress (id) VALUES ('y')"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "service", "INSERT INTO public.lesson_progress (id) VALUES ('y')"]},
		{get: "refused", matches: _lsTrigger, why: "a service role that may write the table is no exception: only its owner writes it"},
		{call: "lessonsdb.as", args: ["$pg", "service", "UPDATE public.lesson_progress SET done = true"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "service", "DELETE FROM public.lesson_progress"]},
		{get: "refused", matches: _lsTrigger},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT count(*)::int AS n, bool_and(owner_id::text = '0c0c0c0c-0000-4000-8000-00000000000c') AS mine FROM public.lesson_progress"], expect: {rows: [{n: 1, mine: true}]}},
		{call: "lessonsdb.as", args: ["$pg", "anon", "SELECT count(*)::int AS n FROM public.lesson_progress"], expect: {rows: [{n: 0}]}},
		{call: "lessonsdb.rows", args: ["$pg"], expect: [{account: "PLUS", chapter: "one", step: 0}, {account: "FREE", chapter: "one", step: 0}]},
	]])
	}
	"a session reaches neither the app's hooks, nor the ledger, nor the spec": {suite: "lessons", steps: list.Concat([_lsDb, [
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT lessons_app.pay('0c0c0c0c-0000-4000-8000-00000000000c', 'x', 1)"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT lessons_app.reward('0c0c0c0c-0000-4000-8000-00000000000c', 'x', 1000)"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT lessons_app.price('0c0c0c0c-0000-4000-8000-00000000000c')"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT * FROM lessons.paid"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT lessons.spec()"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "FREE", "SELECT lessons.settle('0c0c0c0c-0000-4000-8000-00000000000c', 'x', 'reward', 1000)"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.as", args: ["$pg", "anon", "SELECT public.lesson_hint('toy', 'one', 0)"]},
		{get: "refused", matches: "^42501: "},
		{call: "lessonsdb.calls", args: ["$pg"], expect: []},
	]])
	}
	"an app that has not defined its hooks gets the stubs' refusal, which a session cannot get round": {suite: "lessons", steps: [
		{call: "lessonsdb.db", args: [{hooks: false}]}, {keep: "pg"},
		{call: "lessonsdb.call", args: ["$pg", "FREE", "start", ["toy", "one"]]},
		{get: "refused", matches: "^0A000: lessons: the app defines lessons_app.price$"},
		{call: "lessonsdb.rows", args: ["$pg"], expect: []},
	]}
	"the plugin's migration replayed after the app's hooks exist keeps them, whichever migration ran first": {suite: "lessons", steps: [
		{call: "lessonsdb.db"}, {keep: "pg"},
		{call: "lessonsdb.replay", args: ["$pg"], expect: "replayed"},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]], holds: {state: {step: 0}}},
		{call: "lessonsdb.calls", args: ["$pg"], expect: ["pay PLUS lesson/toy/one/open 5"]},
		{call: "lessonsdb.db", args: [{hooksFirst: true}]}, {keep: "pg2"},
		{call: "lessonsdb.call", args: ["$pg2", "PLUS", "start", ["toy", "one"]], holds: {state: {step: 0}}},
		{call: "lessonsdb.calls", args: ["$pg2"], expect: ["pay PLUS lesson/toy/one/open 5"]},
	]}
	"lessons.spec() holds the tokens, plies, flag, prices and rewards and no word a player reads; a token with a quote and a dollar sign comes back as it was": {suite: "lessons", steps: [
		{call: "lessonsdb.db"}, {keep: "pg"},
		// Keys in alphabetical order, as the probe gives them: exactly what is here, nothing else.
		{call: "lessonsdb.spec", args: ["$pg"], expect: {courses: toy: {
			flag: "toy"
			hint: price: 10
			parts: [{
				bonus: 30
				chapters: [
					{id: "one", moves: ["a1", "b1", "a2", "b2", "a3"], own: {"2": 1}, shown: 0},
					{id: "one_b", moves: ["a1", "b1", "a2"], own: {}, shown: 0},
				]
				id:     "first"
				player: 0
				reward: 15
			}, {
				bonus: 40
				chapters: [{id: "two", moves: ["a1", "b'1$", "a2", "b2"], own: {}, shown: 1}]
				id:     "second"
				player: 1
				reward: 20
			}]
		}}},
	]}
	"the page's lesson and the database's count the same, wrong move by wrong move": {suite: "lessons", steps: [
		{call: "lessonsdb.db"}, {keep: "pg"},
		{call: "lessonsdb.agree", args: ["$pg", "FREE", ["zz", "a1", "zz", "zz", "yy", "xx", "ww", "vv", "uu", "tt", "ss", "rr", "a2", "qq", "a3"]], expect: {n: 15, differ: []}},
		{call: "lessonsdb.db"}, {keep: "pg2"},
		{call: "lessonsdb.agree", args: ["$pg2", "PLUS", ["a1", "a2", "a3", "a3"]], expect: {n: 3, differ: []}, why: "a move after the end is no move for either"},
	]}
	"the emitted page picks message keys, and every key has its line in every locale": {suite: "lessons", steps: [
		{call: "lessonsdb.pickedKeys", args: [3]},
		{get: "0", expect: "lesson_toy_ch_one_2_wrong_0", why: "the ply's own line first"},
		{call: "lessonsdb.pickedKeys", args: [3]},
		{get: "1", matches: "^lesson_toy_part_first_complaint_[0-7]$", why: "then the part's pool"},
		{call: "lessonsdb.catalogues", holds: {keys: 25, missing: {en: [], "pt-BR": [], es: []}, count: {en: 25, "pt-BR": 25, es: 25}}},
	]}
	"a catalogue is rewritten by replacing the courses' entries alone, and again changes nothing": {suite: "lessons", steps: [
		{value: "{\n  \"a\": \"1\",\n  \"lesson_toy_old\": \"x\",\n  \"lesson_other_k\": \"y\",\n  \"z\": \"2\"\n}\n"}, {keep: "text"},
		{call: "lessonsdb.rewrite", args: ["$text", "en"]}, {keep: "once"},
		{call: "lessonsdb.keysOf", args: ["$once"], holds: {first: ["a", "lesson_other_k", "z"], toy: 25, old: false, last: "lesson_toy_ch_one_2_wrong_0"}},
		{call: "lessonsdb.rewrite", args: ["$once", "en"], expect: "$once"},
		{call: "lessonsdb.rewrite", args: ["{\n  \"lesson_toy_old\": \"x\"\n}\n", "es"]},
		{call: "lessonsdb.keysOf", args: ["$"], holds: {first: ["lesson_toy_part_first_complaint_0", "lesson_toy_part_first_complaint_1", "lesson_toy_part_first_complaint_2"], toy: 25, old: false}},
	]}
	"the plugin refuses a token the spec's quoting or the page cannot hold, and an id the progress row's cannot": {suite: "lessons", steps: [
		{call: "lessonsdb.vets", args: ["\"b'1$\"", "\"b'1$\""], expect: true},
		{call: "lessonsdb.vets", args: ["\"b'1$\"", "\"x$spec$y\""], expect: false},
		{call: "lessonsdb.vets", args: ["\"b'1$\"", "\"" + strings.Repeat("x", 64) + "\""], expect: true},
		{call: "lessonsdb.vets", args: ["\"b'1$\"", "\"" + strings.Repeat("x", 65) + "\""], expect: false},
		{call: "lessonsdb.vets", args: ["id: \"two\"", "id: \"" + strings.Repeat("x", 60) + "\""], expect: true},
		{call: "lessonsdb.vets", args: ["id: \"two\"", "id: \"" + strings.Repeat("x", 61) + "\""], expect: false},
		{call: "lessonsdb.vets", args: ["courses: toy:", "courses: " + strings.Repeat("x", 60) + ":"], expect: true},
		{call: "lessonsdb.vets", args: ["courses: toy:", "courses: " + strings.Repeat("x", 61) + ":"], expect: false},
	]}
	"the page's lesson and the database's count the same on a chapter the player moves from ply 1": {suite: "lessons", steps: [
		{call: "lessonsdb.db"}, {keep: "pg"},
		{call: "lessonsdb.agree", args: ["$pg", "FREE", ["zz", "b'1$", "yy", "xx", "b2"], "two"], expect: {n: 5, differ: []}},
	]}
	"a chapter finished and played again resumes on the page at the row's counters, and a page behind adopts them": {suite: "lessons", steps: [
		{call: "lessonsdb.db"}, {keep: "pg"},
		{call: "lessonsdb.reloaded", args: ["$pg", "FREE"], holds: {same: true, resumed: {step: 0, wrongs: 0, step_wrongs: 0, pool_said: 0}, db: {step: 0, wrongs: 1, step_wrongs: 1, pool_said: 1}}},
	]}
	"an app that defines only its price meets the pay and reward stubs' refusal, which undoes the call": {suite: "lessons", steps: [
		{call: "lessonsdb.db", args: [{hooks: "price"}]}, {keep: "pg"},
		{call: "lessonsdb.call", args: ["$pg", "PLUS", "start", ["toy", "one"]]},
		{get: "refused", matches: "^0A000: lessons: the app defines lessons_app.pay$"},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"]], holds: {state: {step: 0}}, why: "a price of nothing calls no pay"},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "move", ["toy", "one", 0, "a1"]]},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "move", ["toy", "one", 2, "a2"]]},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "move", ["toy", "one", 4, "a3"]]},
		{get: "refused", matches: "^0A000: lessons: the app defines lessons_app.reward$"},
		{call: "lessonsdb.call", args: ["$pg", "PAID", "start", ["toy", "one"]], holds: {state: {step: 4, done: false}}, why: "the last move was undone with its reward"},
		{call: "lessonsdb.rows", args: ["$pg"], expect: [{account: "PAID", chapter: "one", step: 4}]},
	]}
	"a catalogue that is empty is filled, and one laid out otherwise is refused, not written twice": {suite: "lessons", steps: [
		{call: "lessonsdb.rewrite", args: ["{}\n", "en"]},
		{call: "lessonsdb.keysOf", args: ["$"], holds: {first: ["lesson_toy_part_first_complaint_0", "lesson_toy_part_first_complaint_1", "lesson_toy_part_first_complaint_2"], toy: 25}},
		{call: "lessonsdb.rewrite", args: ["{ }", "es"]},
		{call: "lessonsdb.keysOf", args: ["$"], holds: {toy: 25}},
		{call: "lessonsdb.rewrite", args: ["{\n    \"lesson_toy_old\": \"x\"\n}\n", "en"], throws: "not laid out with two spaces"},
		{call: "lessonsdb.rewrite", args: ["{\n\t\"lesson_toy_old\": \"x\"\n}\n", "en"], throws: "not laid out with two spaces"},
		{call: "lessonsdb.rewrite", args: ["{\"a\": \"1\"}", "en"], throws: "must end with a `}`"},
		{call: "lessonsdb.rewrite", args: ["{\"a\": \"1\", \"lesson_toy_old\": \"x\"}", "en"], throws: "not laid out with two spaces"},
	]}
	"two courses whose ids run into each other would say one key: the plugin refuses them": {suite: "lessons", steps: [
		{call: "lessonsdb.vetsTwo", args: ["second"], expect: true},
		{call: "lessonsdb.vetsTwo", args: ["b"], expect: false},
	]}
	"a reward, a bonus or a hint price beyond what the app's integer hooks hold is refused": {suite: "lessons", steps: [
		{call: "lessonsdb.vets", args: ["reward:  15", "reward:  2147483647"], expect: true},
		{call: "lessonsdb.vets", args: ["reward:  15", "reward:  2147483648"], expect: false},
		{call: "lessonsdb.vets", args: ["bonus:   30", "bonus:   2147483648"], expect: false},
		{call: "lessonsdb.vets", args: ["hint: price: 10", "hint: price: 2147483647"], expect: true},
		{call: "lessonsdb.vets", args: ["hint: price: 10", "hint: price: 2147483648"], expect: false},
	]}
	"a locale is a language, with a region where it has one": {suite: "lessons", steps: [
		{call: "toy.vets", args: ["regionLocale"], expect: true},
		{call: "toy.vets", args: ["badLocale"], expect: false},
		{call: "toy.vets", args: ["longLocale"], expect: false},
	]}
}

// The installer (lessons/install.ts, bin/pronto-lessons) on a temporary app (tests/unit/lessons_install.js): an app with
// pronto-flags, raw migrations 001, 005 and 799 in its CUE (three digits) and pgroll names 16 and 41 (two).
_lsRaw: ["001_roles.sql", "005_create_tables.sql", "790_blob_claims.sql"]
_lsApp: [{call: "lessonsinstall.app", args: [{raw: _lsRaw, pgroll: ["16_billing", "41_attribution"], list: false}]}, {keep: "dir"}]
_lsInstalled: [
	{call: "lessonsinstall.install", args: ["$dir"]},
	{get: "ok", expect: true},
	{call: "lessonsinstall.snapshot", args: ["$dir"]},
	{keep: "snap"},
]
_lsBase: [{call: "lessonsinstall.app", args: [{raw: _lsRaw, pgroll: ["16_billing"], list: false}]}, {keep: "dir"}]
_lsDone: {call: "lessonsinstall.remove", args: ["$dir"]}

cases: {
	"the installer writes the plugin's files, the functions as a source of the app's and not in pronto's migrations": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.paths", args: ["$snap"], expect: [
			"billing_spec.cue", "flags_plugin.cue", "lessons/lessons.js", "lessons/lessons.nu", "lessons/lessons.sql", "lessons/lessons_spec.js", "lessons/lessons_spec.sql",
			"lessons_plugin.cue", "lessons_schema.cue", "lessons_spec.cue", "program.cue", "pronto/lessons.cue", "spec/raw.cue",
		]},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_plugin.cue", "package shop\n"], expect: true, why: "the templates in the program's package"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_schema.cue", "package shop\n"], expect: true, why: "schema.cue as the app's: package renamed"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_schema.cue", "package lessons"], expect: false},
		{call: "lessonsinstall.has", args: ["$snap", "pronto/lessons.cue", "--sql lessons/lessons_spec.sql --js lessons/lessons_spec.js"], expect: true, why: "generate writes the spec's SQL beside the functions, not into pronto's migrations"},
		{call: "lessonsinstall.first", args: ["$snap", "lessons/lessons.sql"], expect: "-- generated by pronto-lessons from lessons/app/lessons.sql — do not edit"},
		{call: "lessonsinstall.first", args: ["$snap", "lessons_plugin.cue"], expect: "// generated by pronto-lessons from lessons/app/ — do not edit"},
		{call: "lessonsinstall.first", args: ["$snap", "lessons_schema.cue"], expect: "// generated by pronto-lessons from lessons/schema.cue — do not edit"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_spec.cue", "lessons: courses: {}"], expect: true},
		_lsDone,
	]])
	}
	"the plugin lists both raw migrations, after the app's own, and the pgroll name follows the app's pgroll names at their own width": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.names", args: ["$snap"], expect: {spec: "791_lessons_spec.sql", fns: "792_lessons.sql", pgroll: "42_lessons"}, why: "raw 790 at three digits, pgroll 41 at two: each sequence its own"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_plugin.cue", "{name: _lessonsRawNames.spec, src: \"lessons/lessons_spec.sql\"}"], expect: true},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_plugin.cue", "{name: _lessonsRawNames.fns, src: \"lessons/lessons.sql\"}"], expect: true},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_plugin.cue", "\ncode: state: rawMigrations: _lessonsRawMigrations\n"], expect: true, why: "an app that lists none gets the list"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_spec.cue", "_lessonsMigration: \"42_lessons\""], expect: true},
		_lsDone,
	]])
	}
	"the installer's raw names stay below 800 (pronto reserves the 8xx), ignoring 8xx and the fixture, and take the next two free numbers": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: ["790_x.sql", "792_y.sql", "802_signals.sql", "950_fixture.sql"], pgroll: ["1_x"], list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.names", args: ["$"], holds: {spec: "793_lessons_spec.sql", fns: "794_lessons.sql"}, why: "above the highest below 800, never 80x or 95x"},
		_lsDone,
		{call: "lessonsinstall.app", args: [{raw: ["801_a.sql", "810_b.sql"], pgroll: ["1_x"], list: false}]},
		{keep: "only8"},
		{call: "lessonsinstall.install", args: ["$only8"]},
		{call: "lessonsinstall.snapshot", args: ["$only8"]},
		{call: "lessonsinstall.names", args: ["$"], holds: {spec: "100_lessons_spec.sql", fns: "101_lessons.sql"}, why: "only 8xx: they are not the app's, so the start of three digits"},
		{call: "lessonsinstall.remove", args: ["$only8"]},
	]}
	"with no two numbers left above the highest below 800, the two highest free ones are taken (Bonk Chess: 799 is used, 793 and 796 are not)": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: ["790_cutover.sql", "792_trophies.sql", "794_puzzle.sql", "795_api_keys.sql", "797_bots.sql", "798_api_v1.sql", "799_arena_game.sql", "802_signals.sql", "950_fixture.sql"], pgroll: ["1_x"], list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.names", args: ["$"], holds: {spec: "793_lessons_spec.sql", fns: "796_lessons.sql"}},
		_lsDone,
	]}
	"three-digit raw names with fewer than two free numbers below 800 are refused, nothing written": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{full: 798, pgroll: ["1_x"], list: false}]},
		{keep: "wide"},
		{call: "lessonsinstall.install", args: ["$wide"]},
		{get: "err", matches: "leave no two free numbers below 800"},
		{call: "lessonsinstall.snapshot", args: ["$wide"]},
		{call: "lessonsinstall.paths", args: ["$"], expect: ["billing_spec.cue", "flags_plugin.cue", "program.cue", "spec/raw.cue"], why: "nothing written"},
		{call: "lessonsinstall.remove", args: ["$wide"]},
	]}
	"the installer writes lessons/lessons_spec.sql once, equal to the emitter's output for no courses, and generate's later text is kept": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.has", args: ["$snap", "lessons/lessons_spec.sql", "SELECT '{\"courses\":{}}'::jsonb"], expect: true},
		{call: "lessonsinstall.has", args: ["$snap", "lessons/lessons_spec.sql", "SET lock_timeout = '5s';\nSET statement_timeout = '30s';\n"], expect: true},
		{call: "lessonsinstall.text", args: ["$snap", "lessons/lessons_spec.sql"]},
		{keep: "sql"},
		{call: "lessonsdb.emptySpecSql", args: ["$sql"], expect: true, why: "byte-equal to `_lessonsOut.sql` for courses: {}"},
		{call: "lessonsinstall.put", args: ["$dir", "lessons/lessons_spec.sql", "-- generate's\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "after"},
		{call: "lessonsinstall.has", args: ["$after", "lessons/lessons_spec.sql", "-- generate's"], expect: true, why: "a seed: never overwritten by a later install"},
		{call: "lessonsinstall.has", args: ["$after", "lessons/lessons.sql", "SET lock_timeout = '5s';\nSET statement_timeout = '30s';\n"], expect: true, why: "pronto's lint sql wants both on every replayed file"},
		_lsDone,
	]])
	}
	"an app that lists rawMigrations itself adds the plugin's to its list, and is told": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: _lsRaw, pgroll: ["16_billing"]}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "out", matches: "add _lessonsRawMigrations to the app's `code: state: rawMigrations` list"},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "snap"},
		{call: "lessonsinstall.has", args: ["$snap", "lessons_plugin.cue", "\ncode: state: rawMigrations: _lessonsRawMigrations\n"], expect: false, why: "two lists of one field cannot be unified"},
		{call: "lessonsinstall.names", args: ["$snap"], holds: {spec: "791_lessons_spec.sql", fns: "792_lessons.sql"}, why: "a list in program.cue is read too"},
		_lsDone,
	]}
	"two-digit raw names stay two digits: 09 and 10 are followed by 11 and 12": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: ["09_a.sql", "10_b.sql"], pgroll: ["3_x"]}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.names", args: ["$"], expect: {spec: "11_lessons_spec.sql", fns: "12_lessons.sql", pgroll: "4_lessons"}},
		_lsDone,
	]}
	"pronto's fixture number does not count, and an app with no raw migration starts at 100": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: ["950_fixture.sql", "010_a.sql"], pgroll: ["1_x"], list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "snap"},
		{call: "lessonsinstall.names", args: ["$snap"], holds: {spec: "011_lessons_spec.sql", fns: "012_lessons.sql"}},
		_lsDone,
		{call: "lessonsinstall.app", args: [{pgroll: ["1_x"]}]},
		{keep: "bare"},
		{call: "lessonsinstall.install", args: ["$bare"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$bare"]},
		{keep: "bsnap"},
		{call: "lessonsinstall.names", args: ["$bsnap"], holds: {spec: "100_lessons_spec.sql", fns: "101_lessons.sql"}},
		{call: "lessonsinstall.remove", args: ["$bare"]},
	]}
	"a run again over an installed app changes nothing, and neither does one after the app adds a wider migration": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "out", expect: ""},
		{call: "lessonsinstall.put", args: ["$dir", "late.cue", "package shop\n_l: {name: \"1000_late.sql\", src: \"a\"}\n_m: \"150_late\"\n_pMigration: \"150_late\"\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "again"},
		{call: "lessonsinstall.changed", args: ["$snap", "$again"], expect: ["late.cue"], why: "only the app's own new file: the stamped names are reused verbatim, nothing renamed, no duplicate"},
		{call: "lessonsinstall.names", args: ["$again"], expect: {spec: "791_lessons_spec.sql", fns: "792_lessons.sql", pgroll: "42_lessons"}},
		_lsDone,
	]])
	}
	"a fresh install whose number needs more digits than the app's width is refused, nothing written, and --migration names the pgroll one": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: ["97_a.sql", "98_b.sql"], pgroll: ["5_x"], list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.paths", args: ["$"], expect: ["billing_spec.cue", "flags_plugin.cue", "program.cue", "spec/raw.cue"], why: "only the app's own files"},
		_lsDone,
		{call: "lessonsinstall.app", args: [{raw: ["96_a.sql", "97_b.sql"], pgroll: ["5_x"], list: false}]},
		{keep: "ok"},
		{call: "lessonsinstall.install", args: ["$ok"]},
		{get: "ok", expect: true, why: "98 and 99 fit two digits"},
		{call: "lessonsinstall.remove", args: ["$ok"]},
	]}
	"no pgroll name to number after is refused unless --migration gives one, stamped once": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{raw: _lsRaw, list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "err", matches: "--migration <name>"},
		{call: "lessonsinstall.install", args: ["$dir", "--migration", "7_lessons"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "snap"},
		{call: "lessonsinstall.names", args: ["$snap"], holds: {pgroll: "7_lessons"}},
		{call: "lessonsinstall.install", args: ["$dir", "--migration", "9_other"]},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "after"},
		{call: "lessonsinstall.names", args: ["$after"], holds: {pgroll: "7_lessons"}, why: "the stamp is the app's now"},
		_lsDone,
	]}
	"a hand edit of a regenerated file is undone, and the app's own spec is kept": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.put", args: ["$dir", "lessons_spec.cue", "package shop\n// the app's own\nlessons: courses: {}\n_lessonsMigration: \"900_x\"\n_lessonsRawNames: {spec: \"1_a.sql\", fns: \"2_b.sql\"}\n"]},
		{call: "lessonsinstall.put", args: ["$dir", "lessons_plugin.cue", "// generated by pronto-lessons: edited\n"]},
		{call: "lessonsinstall.put", args: ["$dir", "lessons/lessons_spec.js", "// generate's\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{keep: "after"},
		{call: "lessonsinstall.changed", args: ["$snap", "$after"], expect: ["lessons/lessons_spec.js", "lessons_spec.cue"]},
		{call: "lessonsinstall.has", args: ["$after", "lessons_plugin.cue", "edited"], expect: false, why: "regenerated"},
		{call: "lessonsinstall.has", args: ["$after", "lessons_spec.cue", "the app's own"], expect: true, why: "written once"},
		{call: "lessonsinstall.has", args: ["$after", "lessons/lessons_spec.js", "generate's"], expect: true, why: "the page's courses are generate's once written"},
		_lsDone,
	]])
	}
	"a spec written before the names were stamped is refused, with what to add": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.put", args: ["$dir", "lessons_spec.cue", "package shop\nlessons: courses: {}\n_lessonsMigration: \"lessons_01\"\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "err", matches: "_lessonsRawNames"},
		_lsDone,
	]])
	}
	"the page's module carries a commit stamp of twelve characters, and sits where the app names it": {suite: "lessons", steps: list.Concat([_lsApp, _lsInstalled, [
		{call: "lessonsinstall.stamp", args: ["$snap", "lessons/lessons.js"], expect: true, why: "this repository is a git checkout: the header names the commit that last touched lessons/app/lessons.js"},
		_lsDone,
		{call: "lessonsinstall.app", args: [{pgroll: ["1_x"]}]},
		{keep: "other"},
		{call: "lessonsinstall.install", args: ["$other", "web/src/lessons.mjs"]},
		{get: "ok", expect: true},
		{call: "lessonsinstall.snapshot", args: ["$other"]},
		{call: "lessonsinstall.has", args: ["$", "web/src/lessons_spec.js", "export const courses"], expect: true},
		{call: "lessonsinstall.remove", args: ["$other"]},
	]])
	}
	"the module path must be a .js, .mjs or .ts of its own: no installer output, no app file, nothing of the app's own overwritten": {suite: "lessons", steps: list.Concat([_lsBase, [
		{call: "lessonsinstall.install", args: ["$dir", "x.txt"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.install", args: ["$dir", "program.cue"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.install", args: ["$dir", "lessons/lessons_spec.js"]},
		{get: "ok", expect: false, why: "the page's courses are written there"},
		{call: "lessonsinstall.install", args: ["$dir", "../x.js"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.install", args: ["$dir", "/tmp/x.js"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.put", args: ["$dir", "web/app.js", "// the app's own\n"]},
		{call: "lessonsinstall.install", args: ["$dir", "web/app.js"]},
		{get: "err", matches: "not overwritten"},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.has", args: ["$", "web/app.js", "the app's own"], expect: true},
		_lsDone,
	]])
	}
	"an app's own lessons.sql is not the plugin's: refused; its own NNN_lessons.sql in pronto's folder is left alone; an earlier install's copy is refused": {suite: "lessons", steps: list.Concat([_lsBase, [
		{call: "lessonsinstall.put", args: ["$dir", "lessons/lessons.sql", "-- the app's hooks\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "err", matches: "not overwritten"},
		{call: "lessonsinstall.put", args: ["$dir", "lessons/lessons.sql", "-- generated by pronto-lessons: old\n"]},
		{call: "lessonsinstall.put", args: ["$dir", "services/database/migrations/900_lessons.sql", "-- generated by pronto-lessons from lessons/app/lessons.sql — do not edit\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "err", matches: "earlier install's copy"},
		{call: "lessonsinstall.put", args: ["$dir", "services/database/migrations/900_lessons.sql", "-- the app's own hooks\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: true},
		_lsDone,
	]])
	}
	"an app without pronto-flags is refused, nothing written": {suite: "lessons", steps: [
		{call: "lessonsinstall.app", args: [{flags: false, raw: _lsRaw, pgroll: ["1_x"], list: false}]},
		{keep: "dir"},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: false},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "err", matches: "pronto-flags .*bin/pronto-flags"},
		{call: "lessonsinstall.snapshot", args: ["$dir"]},
		{call: "lessonsinstall.paths", args: ["$"], expect: ["billing_spec.cue", "program.cue", "spec/raw.cue"]},
		_lsDone,
	]}
	"no pronto app is refused": {suite: "lessons", steps: list.Concat([_lsBase, [
		{call: "lessonsinstall.put", args: ["$dir", "program.cue", "// nothing\n"]},
		{call: "lessonsinstall.install", args: ["$dir"]},
		{get: "ok", expect: false, why: "a program that names no package"},
		_lsDone,
	]])
	}
}
