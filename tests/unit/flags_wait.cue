package unit

// pronto-flags' wait for pickup (flags/live.nu `await-live`): after each write a push asks every flagd for the written value and
// only then runs its cases or counts a rollback done (2026-11-23, capture_fights: the cases ran when one flagd pod had the value,
// read another that had not, and rolled a correct flip back; the rollback took as long to reach the pods, so the flag was live for
// everyone for two minutes after a "failed" flip). tests/unit/flags_wait.js runs the real wait in nu on a stub of OFREP whose pods
// say the old value until their own answer; each poll asks every pod once.

cases: "a flagd that picks the value up late is waited for, polled until it does": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{pods: 1, pickup: 3, limitSec: 5}], holds: {ok: true, asked: 4}, why: "answers 0 to 2 are the old value, the 4th is the new one: the wait ends there"},
	]
}

cases: "one pod's new answer is not enough: every pod must say it": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{pods: 3, pickup: 0, limitSec: 5}], holds: {ok: true, asked: 3}, why: "pod 0 has it at once, pod 2 only at the 3rd poll: a wait that stopped at the first pod would have run the cases against pod 2"},
	]
}

cases: "a flagd that never picks the value up fails with a named error at the deadline": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{pods: 2, pickup: null, limitSec: 1}], holds: {ok: false, late: true}, why: "it polled until the deadline, not gave up at the first answer"},
		{get: "err", expect: "flagd did not pick up capture_fights=true within 1s"},
	]
}

cases: "one pod that never does fails it too, whatever the others say": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{pods: 3, pickup: 1, limitSec: 1, stuck: true}], holds: {ok: false}},
		{get: "err", expect: "flagd did not pick up capture_fights=true within 1s"},
	]
}

cases: "a rollback is confirmed live: every flagd says the old value again before the push ends": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{from: true, to: false, pods: 2, pickup: 1, limitSec: 5}], holds: {ok: true, asked: 3}, why: "the pods read true until their own answer, then false"},
	]
}

cases: "a rollback no flagd picks up fails naming the old value": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{from: true, to: false, pods: 1, pickup: null, limitSec: 1}], holds: {ok: false, late: true}},
		{get: "err", expect: "flagd did not pick up capture_fights=false within 1s"},
	]
}

cases: "a pod that answers nothing, or no value, is not caught up, whatever the others say": {
	suite: "flags"
	steps: [
		{call: "flagswait.wait", args: [{pods: 3, pickup: 0, limitSec: 1, silent: true}], holds: {ok: false, late: true}, why: "a pod whose mounted file lacks the flag answers FLAG_NOT_FOUND, or an unreachable one nothing: its line has no value, and a wait that dropped it would run the cases against it"},
		{get: "err", expect: "flagd did not pick up capture_fights=true within 1s"},
	]
}
