// The Ready queue (PRONTO-658; devflow/queue.ts, its pure rules in devflow/flow.js): Ready is first in,
// first out by when each issue became Ready, a bug at P1 or P0 jumps it, and there are no sprints, so no
// verb touches a cycle. `queue` is a fake Plane (tests/unit/devflow.js) that logs each write, its issues
// `{seq, state, module, priority, bug, ready, created, completed, moves}` and its clock `now`.
package unit

import "list"

cases: {
	"a lane pulls a P1 bug first, then the oldest in Ready, and touches no cycle": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{cycles: [{name: "Sprint 8", issues: [3]}], issues: [
			{seq: 5, name: "fix crash", state: "Ready", module: "aprende", priority: "high", bug: true, ready: "2026-11-16T10:00:00Z"},
			{seq: 3, name: "old", state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z"},
			{seq: 2, name: "newer", state: "Ready", module: "aprende", ready: "2026-11-12T10:00:00Z"},
		]}, "engineer", 3]}, {pick: ["started", "writes"], expect: [
			["ACME-5", "ACME-3", "ACME-2"],
			["moveIssue ACME-5 Implementing", "comment i-acme-5", "moveIssue ACME-3 Implementing", "comment i-acme-3", "moveIssue ACME-2 Implementing", "comment i-acme-2"],
		], why: "an open Sprint 8 holds #3 and cycles() says so, but no verb reads or writes a cycle: the writes are the moves and their comments"},
	]}
	"priority and number do not order the queue: a later Ready issue never comes before an earlier one": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{issues: [
			{seq: 1, state: "Ready", module: "aprende", priority: "urgent", ready: "2026-11-15T10:00:00Z"},
			{seq: 9, state: "Ready", module: "aprende", priority: "low", ready: "2026-11-14T10:00:00Z"},
		]}, "engineer", 2]}, {pick: ["started"], expect: [["ACME-9", "ACME-1"]], why: "a P0 feature, and a P1 one, wait their turn; only a bug jumps"},
		{call: "queue.pulls", args: [{issues: [
			{seq: 1, state: "Ready", module: "aprende", priority: "high", ready: "2026-11-15T10:00:00Z"},
			{seq: 9, state: "Ready", module: "aprende", priority: "none", bug: true, ready: "2026-11-14T10:00:00Z"},
			{seq: 4, state: "Ready", module: "aprende", priority: "high", bug: true, ready: "2026-11-16T10:00:00Z"},
		]}, "engineer", 3]}, {pick: ["started"], expect: [["ACME-4", "ACME-9", "ACME-1"]], why: "a bug that is not P1 does not jump either"},
	]}
	"an issue is as old as its latest move into Ready, else as when it was made": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{issues: [
			{seq: 7, state: "Ready", module: "aprende", created: "2026-11-14T10:00:00Z"},
			{seq: 4, state: "Ready", module: "aprende", created: "2026-11-13T10:00:00Z"},
			{seq: 6, state: "Ready", module: "aprende", created: "2026-11-01T10:00:00Z", ready: "2026-11-13T12:00:00Z"},
			{seq: 8, state: "Ready", module: "aprende", created: "2026-11-01T10:00:00Z", ready: "2026-11-02T10:00:00Z", moves: [{state: "Ready", at: "2026-11-15T10:00:00Z"}]},
		]}, "engineer", 4]}, {pick: ["started"], expect: [["ACME-4", "ACME-6", "ACME-7", "ACME-8"]], why: "7 and 4 were made in Ready; 8 went back to Ready on the 15th, and queues from there"},
	]}
	"a lane pulls its own issues only, and none when its slots are busy": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{modules: ["aprende", "infra"], issues: [{seq: 1, state: "Ready", module: "infra", ready: "2026-11-10T10:00:00Z"}]}, "engineer", 1]}, {pick: ["started", "writes"], expect: [["empty"], []], why: "an infra issue is an SRE's"},
		{call: "queue.pulls", args: [{modules: ["aprende", "infra"], issues: [{seq: 1, state: "Ready", module: "infra", ready: "2026-11-10T10:00:00Z"}]}, "SRE", 1]}, {pick: ["started"], expect: [["ACME-1"]]},
		{call: "queue.pulls", args: [{team: {engineers: 1, sre: 1, architect: 1, product: 1}, issues: [
			{seq: 1, state: "Implementing", module: "aprende"},
			{seq: 2, state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z"},
		]}, "engineer", 1]}, {pick: ["started", "writes"], expect: [["waits"], []], why: "the one engineer slot is busy"},
	]}
	"status lists each lane's queue in pull order with ages, and flags what starves": {suite: "devflow", steps: [
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", starvingDays: 3, issues: [
			{seq: 1, name: "busy", state: "Implementing", module: "aprende"},
			{seq: 3, name: "old thing", state: "Ready", module: "aprende", ready: "2026-11-13T12:00:00Z"},
			{seq: 8, name: "new thing", state: "Ready", module: "aprende", ready: "2026-11-17T12:00:00Z"},
			{seq: 5, name: "fix crash", state: "Ready", module: "aprende", priority: "high", bug: true, ready: "2026-11-16T15:00:00Z"},
			{seq: 10, name: "refine me", state: "Refine", module: "aprende"},
			{seq: 11, name: "parked", state: "Backlog"},
		]}]}, {pick: ["queue.engineer.0.key", "queue.engineer.1.key", "queue.engineer.2.key", "starving", "slotsLine", "lines"], expect: [
			"ACME-5", "ACME-3", "ACME-8",
			[{key: "ACME-3", age: "4d"}],
			"1 of 6 engineer slots busy (ACME-1), 0 of 1 SRE slots busy, 0 of 1 architect slots busy",
			[
				"  ready to pull, engineer: ACME-5 fix crash (P1 bug, 1d); ACME-3 old thing (4d); ACME-8 new thing (3h)",
				"  ready to pull, SRE: none",
				"  ready to pull, architect: none",
				"starving: ACME-3 Ready 4d (over 3d)",
				"merged: 0 today, 0 in 7 days; days before today by completed_at",
				"  open, Refine: ACME-10 refine me",
				"  open, Implementing: ACME-1 busy",
				"backlog: 1",
			],
		]},
	]}
	"nothing starves while every Ready issue is younger than starvingDays": {suite: "devflow", steps: [
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", starvingDays: 5, issues: [{seq: 3, state: "Ready", module: "aprende", ready: "2026-11-13T12:00:00Z"}]}]}, {pick: ["starving"], expect: [[]]},
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", starvingDays: 3, issues: [{seq: 3, state: "Ready", module: "aprende", ready: "2026-11-14T15:00:00Z"}]}]}, {pick: ["starving"], expect: [[]], why: "exactly 3 days is not over 3"},
	]}
	"status counts merges by the day each merged, not by completed_at, which a later flip rewrites": {suite: "devflow", steps: [
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", issues: [
			{seq: 1, state: "Merged", module: "aprende", completed: "2026-11-17T12:00:00Z"},
			{seq: 2, state: "Merged", module: "aprende", completed: "2026-11-16T20:00:00Z"},
			{seq: 3, state: "Live", module: "aprende", completed: "2026-11-12T12:00:00Z"},
			{seq: 4, state: "Done", module: "aprende", completed: "2026-11-17T14:00:00Z", moves: [{state: "Merged", at: "2026-11-10T10:00:00Z"}, {state: "Done", at: "2026-11-17T14:00:00Z"}]},
			{seq: 5, state: "Done", module: "aprende", completed: "2026-11-05T14:00:00Z"},
			{seq: 6, state: "Done", module: "aprende", completed: "2026-11-17T13:00:00Z", moves: [{state: "Merged", at: "2026-11-10T10:00:00Z"}, {state: "Review", at: "2026-11-14T10:00:00Z"}, {state: "Merged", at: "2026-11-15T10:00:00Z"}, {state: "Done", at: "2026-11-17T13:00:00Z"}]},
		]}]}, {pick: ["merged", "writes"], expect: [{today: 1, week: 4, byDay: [{day: "2026-11-17", count: 1}, {day: "2026-11-16", count: 1}, {day: "2026-11-15", count: 1}, {day: "2026-11-12", count: 1}]}, []], why: "4 merged on the 10th and was flipped Done today: not this week's; 6 was sent back and merged again on the 15th; 5 is older than a week"},
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", issues: [{seq: 1, state: "Merged", module: "aprende", completed: "2026-11-17T12:00:00Z"}]}]}, {pick: ["lines.3"], expect: ["merged: 1 today, 1 in 7 days (2026-11-17 1); days before today by completed_at"], why: "the line names the window queue.mergedDays sets"},
	]}
	"a Ready issue the board cannot date, or whose moves cannot be read, is an error and nothing is written": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{issues: [{seq: 1, state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z"}], failMoves: true}, "engineer", 1]}, {pick: ["started", "error", "writes"], expect: [[], "plane GET activities: 500", []]},
		{call: "queue.pulls", args: [{issues: [{seq: 1, state: "Ready", module: "aprende"}]}, "engineer", 1]}, {pick: ["error", "writes"], expect: ["ACME-1 is Ready but the board gives neither a move into Ready nor a creation time", []], why: "no silent place in the queue"},
	]}
	"a P0 starts past a full lane, a P0 bug before a P1 bug, and a claim another session made first is passed over": {suite: "devflow", steps: [
		{call: "queue.pulls", args: [{team: {engineers: 1, sre: 1, architect: 1, product: 1}, issues: [
			{seq: 1, state: "Implementing", module: "aprende"},
			{seq: 2, name: "p1 bug", state: "Ready", module: "aprende", priority: "high", bug: true, ready: "2026-11-10T10:00:00Z"},
			{seq: 3, name: "p0 feature", state: "Ready", module: "aprende", priority: "urgent", ready: "2026-11-16T10:00:00Z"},
			{seq: 4, name: "p3", state: "Ready", module: "aprende", priority: "low", ready: "2026-11-11T10:00:00Z"},
		]}, "engineer", 1]}, {pick: ["started", "writes"], expect: [["ACME-3"], ["moveIssue ACME-3 Implementing", "comment i-acme-3"]], why: "the lane is full: the P1 bug waits, the P3 is not tried, the P0 feature starts past the slots"},
		{call: "queue.pulls", args: [{team: {engineers: 1, sre: 1, architect: 1, product: 1}, issues: [
			{seq: 1, state: "Implementing", module: "aprende"},
			{seq: 2, name: "p1 bug", state: "Ready", module: "aprende", priority: "high", bug: true, ready: "2026-11-10T10:00:00Z"},
			{seq: 3, name: "p0 bug", state: "Ready", module: "aprende", priority: "urgent", bug: true, ready: "2026-11-16T10:00:00Z"},
		]}, "engineer", 1]}, {pick: ["started"], expect: [["ACME-3"]], why: "a P0 bug that became Ready after a P1 bug still goes first, and past the full lane"},
		{call: "queue.pulls", args: [{issues: [
			{seq: 2, name: "head", state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z", comments: [{html: "<p>claim aaaaaaaa-other</p>", at: "2026-11-17T14:59:00Z"}]},
			{seq: 3, name: "next", state: "Ready", module: "aprende", ready: "2026-11-11T10:00:00Z"},
		]}, "engineer", 1]}, {pick: ["started"], expect: [["ACME-3"]], why: "another session's claim on the head issue is earlier than ours: it keeps it, and the pull starts the next"},
		{call: "queue.pulls", args: [{issues: [
			{seq: 6, state: "Ready", module: "aprende", ready: "2026-11-13T12:00:00Z"},
			{seq: 4, state: "Ready", module: "aprende", ready: "2026-11-13T12:00:00Z"},
		]}, "engineer", 2]}, {pick: ["started"], expect: [["ACME-4", "ACME-6"]], why: "the same Ready time: the number decides"},
	]}
	"status reads merges from completed_at, and the history only of what was completed today": {suite: "devflow", steps: [
		{call: "queue.queueState", args: [{now: "2026-11-17T15:00:00Z", issues: [
			{seq: 1, state: "Done", module: "aprende", completed: "2026-11-14T10:00:00Z", moves: [{state: "Merged", at: "2026-11-10T10:00:00Z"}, {state: "Done", at: "2026-11-14T10:00:00Z"}]},
		]}]}, {pick: ["merged"], expect: [{today: 0, week: 1, byDay: [{day: "2026-11-14", count: 1}]}], why: "before today the flip's day is the one counted: a day or days late, said on the line, and no history read"},
	]}
	"status stays within a few requests whatever the number of issues: its history reads are kept, and only today's are made": {suite: "devflow", steps: [
		{call: "queue.statusRequests", args: [{issues: list.FlattenN([
			[for n in list.Range(1, 6, 1) {seq: n, state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z"}],
			[for n in list.Range(100, 140, 1) {seq: n, state: "Done", module: "aprende", completed: "2026-11-15T10:00:00Z"}],
			[{seq: 200, state: "Done", module: "aprende", completed: "2026-11-17T12:00:00Z", moves: [{state: "Merged", at: "2026-11-17T11:00:00Z"}, {state: "Done", at: "2026-11-17T12:00:00Z"}]}],
		], 1)}]}, {pick: ["0.requests", "0.activity", "1.requests", "1.activity", "1.merged.week"], expect: [10, 6, 4, 0, 41], why: "cold: the issue list, states, modules, labels, 5 Ready issues' activity and today's one Done issue's; warm: the same 4 requests and no activity read"},
		{call: "queue.statusRequests", args: [{issues: list.FlattenN([
			[for n in list.Range(1, 61, 1) {seq: n, state: "Ready", module: "aprende", ready: "2026-11-10T10:00:00Z"}],
			[for n in list.Range(100, 400, 1) {seq: n, state: "Done", module: "aprende", completed: "2026-11-15T10:00:00Z"}],
		], 1)}]}, {pick: ["1.requests", "1.activity", "1.merged.week"], expect: [4, 0, 300], why: "60 Ready and 300 merged issues: a warm status makes the same 4 requests"},
	]}
	"file puts a bug where its priority says and joins no cycle": {suite: "devflow", steps: [
		{call: "queue.filed", args: [{}, {title: "crash", app: "aprende", bug: true, priority: "P1"}]}, {pick: ["key", "state", "module", "madeState", "priority", "labels.length", "writes"], expect: [
			"ACME-100", "Refine", "aprende", "Refine", "high", 1,
			["createLabel bug", "createIssue crash", "addToModule aprende"],
		], why: "no cycles, cycleIssues, addToCycle or createCycle call, though a Sprint cycle may be open"},
		{call: "queue.filed", args: [{}, {title: "ui", app: "aprende", bug: true, priority: "P3"}]}, {pick: ["state", "priority"], expect: ["Backlog", "low"]},
		{call: "queue.filed", args: [{}, {title: "idea", app: "aprende"}]}, {pick: ["state", "priority", "labels.length", "writes"], expect: ["Backlog", "none", 0, ["createIssue idea", "addToModule aprende"]]},
		{call: "queue.filed", args: [{}, {title: "idea", app: "nope"}]}, {pick: ["module", "writes"], expect: [null, ["createIssue idea"]]},
	]}
}
