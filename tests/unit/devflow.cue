// The dev flow's rules (devflow/flow.js): which issue a pull request is, where each event moves an
// issue, an issue's flag, the agent cap, P0..P3, and where the loop of sprints stands. They reason in
// roles (backlog, refine, ready, implementing, review, merged, live, done, cancelled); a
// repository's names for its states are mapped to roles and back (roleOf, nameOf).
package unit

cases: {
	"a pull request's issue is the key in its title, else its branch, written the board's way": {suite: "devflow", steps: [
		{call: "devflow.keyOf", args: ["PRONTO", "PRONTO-123: army pick lists usable armies", "fix/x"], expect: "PRONTO-123"},
		{call: "devflow.keyOf", args: ["PRONTO", "brawl-chess: a fix", "pronto-0042/army-pick"], expect: "PRONTO-42", why: "branches are lower case; the number loses its zeros"},
		{call: "devflow.keyOf", args: ["PRONTO", "[pronto-7] fix", ""], expect: "PRONTO-7"},
		{call: "devflow.keyOf", args: ["PRONTO", "MYPRONTO-12 is another project's", "PRONTO-123x"], expect: null, why: "a key is a whole word"},
		{call: "devflow.keyOf", args: ["PRONTO", "no key", null], expect: null},
	]}
	"a pull request moves its issue (a role) forward, never back, but for a pull request closed unmerged": {suite: "devflow", steps: [
		{call: "devflow.moveFor", args: ["opened", "implementing"], expect: "review"},
		{call: "devflow.moveFor", args: ["opened", "ready"], expect: "review", why: "a session may open its pull request before the board heard it started"},
		{call: "devflow.moveFor", args: ["merged", "review"], expect: "merged"},
		{call: "devflow.moveFor", args: ["reopened", "merged"], expect: null},
		{call: "devflow.moveFor", args: ["merged", "live"], expect: null, why: "a second pull request for a released issue leaves it Live"},
		{call: "devflow.moveFor", args: ["closed", "review"], expect: "implementing"},
		{call: "devflow.moveFor", args: ["closed", "merged"], expect: null},
		{call: "devflow.moveFor", args: ["merged", "cancelled"], expect: null, why: "a cancelled issue is never moved"},
	]}
	"a release makes Merged Live; a flip makes it Done, and its rollback Live again": {suite: "devflow", steps: [
		{call: "devflow.moveFor", args: ["released", "merged"], expect: "live"},
		{call: "devflow.moveFor", args: ["released", "review"], expect: null},
		{call: "devflow.moveFor", args: ["flipped", "live"], expect: "done"},
		{call: "devflow.moveFor", args: ["flipped", "merged"], expect: "done", why: "an app released outside release-cron never says released"},
		{call: "devflow.moveFor", args: ["flipped", "implementing"], expect: null},
		{call: "devflow.moveFor", args: ["rolledback", "done"], expect: "live"},
		{call: "devflow.moveFor", args: ["rolledback", "live"], expect: null},
	]}
	"an issue with no flag is Done when it is released (a bug fix) or merged (infra, plugins); a flagged one when its flag flips": {suite: "devflow", steps: [
		{call: "devflow.doneAt", args: ["army_pick_usable", ["brawl-chess"], ["infra"]], expect: "flip"},
		{call: "devflow.doneAt", args: [null, ["brawl-chess"], ["infra"]], expect: "release", why: "a bug fix: PRONTO-1, released 2026-11-08 11:45 BRT as c9ecd1f7"},
		{call: "devflow.doneAt", args: [null, [], ["infra"]], expect: "release"},
		{call: "devflow.doneAt", args: [null, ["infra"], ["infra"]], expect: "merge"},
		{call: "devflow.doneAt", args: [null, ["plugins"], ["infra"]], expect: "merge"},
		{call: "devflow.moveFor", args: ["released", "merged", "release"], expect: "done", why: "a flagless bug fix is finished by its release"},
		{call: "devflow.moveFor", args: ["released", "live", "release"], expect: "done"},
		{call: "devflow.moveFor", args: ["released", "review", "release"], expect: null},
		{call: "devflow.moveFor", args: ["released", "merged", "flip"], expect: "live", why: "a flagged issue waits for its flip"},
		{call: "devflow.moveFor", args: ["merged", "review", "merge"], expect: "done", why: "infra and plugins: nothing release-cron ships"},
		{call: "devflow.moveFor", args: ["merged", "review", "release"], expect: "merged"},
		{call: "devflow.moveFor", args: ["merged", "done", "merge"], expect: null},
	]}
	"a GitHub action is the flow's event: a closed pull request that merged is merged": {suite: "devflow", steps: [
		{call: "devflow.prEvent", args: ["closed", true], expect: "merged"},
		{call: "devflow.prEvent", args: ["closed", false], expect: "closed"},
		{call: "devflow.prEvent", args: ["synchronize", false], expect: null},
	]}
	"an issue's flag is its own Flag: line, in HTML or text": {suite: "devflow", steps: [
		{call: "devflow.flagOf", args: ["<p>Objective: x</p><p>Flag: army_pick_usable</p>"], expect: "army_pick_usable"},
		{call: "devflow.flagOf", args: ["Objective\nFlag: `card_chess`\n"], expect: "card_chess"},
		{call: "devflow.flagOf", args: ["<p>The Flag: line is missing</p>"], expect: null},
		{call: "devflow.flagOf", args: [null], expect: null},
	]}
	"an issue starts while its lane has a free slot; a P0 starts regardless": {suite: "devflow", steps: [
		{call: "devflow.mayStart", args: [1, 2, "high", "engineer"], expect: {ok: true, why: "engineer slot 2 of 2"}},
		{call: "devflow.mayStart", args: [2, 2, "medium", "engineer"], expect: {ok: false, why: "all 2 engineer slots are busy"}},
		{call: "devflow.mayStart", args: [0, 0, "high", "SRE"], expect: {ok: false, why: "the team has no SRE"}},
		{call: "devflow.mayStart", args: [9, 2, "urgent", "engineer"]}, {pick: ["ok"], expect: [true]},
	]}
	"a sprint commits perPerson issues to each engineer and each SRE": {suite: "devflow", steps: [
		{call: "devflow.capacity", args: [{engineers: 4, sre: 1}, 3], expect: {engineer: 12, SRE: 3}, why: "the user, 2026-11-08: 3 issues per engineer, 12 app issues and 3 infra issues"},
		{call: "devflow.capacity", args: [{engineers: 2, sre: 0}, 3], expect: {engineer: 6, SRE: 0}},
	]}
	"next plans up to a lane's capacity and refuses past it": {suite: "devflow", steps: [
		{call: "devflow.mayPlan", args: [0, 12, 12, "engineer"], expect: {ok: true, why: "engineer: 12 of 12 planned"}},
		{call: "devflow.mayPlan", args: [10, 12, 3, "engineer"], expect: {ok: false, why: "engineer: 10 of 12 planned, 3 more is 1 over"}},
		{call: "devflow.mayPlan", args: [3, 3, 1, "SRE"], expect: {ok: false, why: "SRE: 3 of 3 planned, 1 more is 1 over"}},
		{call: "devflow.mayPlan", args: [0, 0, 1, "SRE"], expect: {ok: false, why: "the team has no SRE"}},
		{call: "devflow.mayPlan", args: [3, 3, 0, "SRE"]}, {pick: ["ok"], expect: [true], why: "adding nothing is never over"},
	]}
	"a lane pulls its most urgent Ready issue, then the oldest": {suite: "devflow", steps: [
		{call: "devflow.pullNext", args: [[{key: "PRONTO-31", sequence: 31, priority: "medium"}, {key: "PRONTO-33", sequence: 33, priority: "high"}, {key: "PRONTO-30", sequence: 30, priority: "medium"}]], expect: {key: "PRONTO-33", sequence: 33, priority: "high"}},
		{call: "devflow.pullNext", args: [[{key: "PRONTO-31", sequence: 31, priority: "medium"}, {key: "PRONTO-30", sequence: 30, priority: "medium"}]], expect: {key: "PRONTO-30", sequence: 30, priority: "medium"}},
		{call: "devflow.pullNext", args: [[]], expect: null},
	]}
	"an infra module's issue is an SRE's, every other an engineer's": {suite: "devflow", steps: [
		{call: "devflow.laneOf", args: [["infra"], ["infra"]], expect: "SRE"},
		{call: "devflow.laneOf", args: [["brawl-chess"], ["infra"]], expect: "engineer"},
		{call: "devflow.laneOf", args: [[], ["infra"]], expect: "engineer"},
	]}
	"P0..P3 are Plane's priorities, and say where a new bug goes": {suite: "devflow", steps: [
		{call: "devflow.priorityOf", args: ["p0"], expect: "urgent"},
		{call: "devflow.bugPlace", args: ["P0"], expect: {role: "implementing", sprint: true}},
		{call: "devflow.bugPlace", args: ["P1"], expect: {role: "refine", sprint: true}},
		{call: "devflow.bugPlace", args: ["P3"], expect: {role: "backlog", sprint: false}},
		{call: "devflow.priorityOf", args: ["P4"], throws: "P0, P1, P2 or P3"},
	]}
	"a sprint is a cycle named Sprint <n>, its theme after a colon": {suite: "devflow", steps: [
		{call: "devflow.sprintNumber", args: ["Sprint 12: payments"], expect: 12},
		{call: "devflow.sprintNumber", args: ["Sprint 3"], expect: 3},
		{call: "devflow.sprintNumber", args: ["2026-11-09"], expect: null, why: "a day's cycle from before the loop is not a sprint"},
		{call: "devflow.sprintNumber", args: ["Sprint 12b"], expect: null},
		{call: "devflow.sprintName", args: [7, "army pick"], expect: "Sprint 7: army pick"},
		{call: "devflow.sprintName", args: [7, ""], expect: "Sprint 7"},
	]}
	"sprints loop: one ends when all its issues merge, and planning fills the next": {suite: "devflow", steps: [
		{call: "devflow.loopOf", args: [[]], expect: {current: null, next: null, finished: [], number: 1, plansInto: 1}, why: "the first planning makes Sprint 1, the current"},
		{call: "devflow.loopOf", args: [[{n: 1, groups: ["completed", "started"]}]], expect: {current: 1, next: null, finished: [], number: 2, plansInto: 2}, why: "a lane runs dry: planning makes the next sprint it pulls from"},
		{call: "devflow.loopOf", args: [[{n: 1, groups: ["started"]}, {n: 2, groups: ["unstarted"]}]], expect: {current: 1, next: 2, finished: [], number: 3, plansInto: 2}, why: "with a next sprint, planning adds to it, never a third"},
		{call: "devflow.loopOf", args: [[{n: 1, groups: ["completed", "cancelled"]}, {n: 2, groups: ["started"]}]], expect: {current: 2, next: null, finished: [1], number: 3, plansInto: 3}, why: "merged and cancelled end a sprint, at any hour"},
		{call: "devflow.loopOf", args: [[{n: 4, groups: []}, {n: 5, groups: ["completed"]}]], expect: {current: null, next: null, finished: [5], number: 6, plansInto: 6}, why: "an emptied sprint is neither open nor finished"},
	]}
	"a cycle is dated by the day in the flow's time zone": {suite: "devflow", steps: [
		{call: "devflow.dayOf", args: ["2026-11-10T02:00:00Z", "America/Sao_Paulo"], expect: "2026-11-09"},
		{call: "devflow.dayOf", args: ["2026-11-10T16:00:00Z", "America/Sao_Paulo"], expect: "2026-11-10"},
	]}
	"a pull request with no issue fails the check, but for a chore or while it only warns": {suite: "devflow", steps: [
		{call: "devflow.missingKey", args: [["chore"], "chore", false, "PRONTO"]}, {pick: ["ok"], expect: [true]},
		{call: "devflow.missingKey", args: [[], "chore", false, "PRONTO"]}, {pick: ["ok"], expect: [false]},
		{call: "devflow.missingKey", args: [[], "chore", true, "PRONTO"]}, {pick: ["ok"], expect: [true]},
	]}
	"a repository's own state names are mapped to roles and back, so the rules hold for any names": {suite: "devflow", steps: [
		{call: "devflow.roleOf", args: [{backlog: "Intake", refine: "Triage", ready: "To do", implementing: "In dev", review: "In review", merged: "Merged", live: "Shipped", done: "Closed", cancelled: "Dropped"}, "In dev"], expect: "implementing"},
		{call: "devflow.roleOf", args: [{backlog: "Intake", refine: "Triage", ready: "To do", implementing: "In dev", review: "In review", merged: "Merged", live: "Shipped", done: "Closed", cancelled: "Dropped"}, "Shipped"], expect: "live"},
		{call: "devflow.roleOf", args: [{backlog: "Intake", refine: "Triage", ready: "To do", implementing: "In dev", review: "In review", merged: "Merged", live: "Shipped", done: "Closed", cancelled: "Dropped"}, "Implementing"], expect: null, why: "a name the repository does not use plays no role: the issue is left alone"},
		{call: "devflow.nameOf", args: [{backlog: "Intake", refine: "Triage", ready: "To do", implementing: "In dev", review: "In review", merged: "Merged", live: "Shipped", done: "Closed", cancelled: "Dropped"}, "review"], expect: "In review"},
		{call: "devflow.nameOf", args: [{backlog: "Intake"}, "nope"], throws: "no such role: nope"},
		{call: "devflow.moveFor", args: ["opened", "implementing"], expect: "review", why: "the role, whatever the repository calls its state"},
		{call: "devflow.moveFor", args: ["released", "merged", "release"], expect: "done"},
		{call: "devflow.moveFor", args: ["opened", null], expect: null, why: "a state no role names is never moved"},
	]}
	"priorities are the repository's words: P0 is urgent in its own, and the order follows P0..P3": {suite: "devflow", steps: [
		{call: "devflow.priorityOf", args: ["P1", {P0: "critical", P1: "major", P2: "minor", P3: "trivial"}], expect: "major"},
		{call: "devflow.bugPlace", args: ["P0", {P0: "critical", P1: "major", P2: "minor", P3: "trivial"}], expect: {role: "implementing", sprint: true}},
		{call: "devflow.bugPlace", args: ["P4", {P0: "critical", P1: "major", P2: "minor", P3: "trivial"}], throws: "P0, P1, P2 or P3"},
		{call: "devflow.mayStart", args: [9, 2, "critical", "engineer", "critical"]}, {pick: ["ok"], expect: [true]},
		{call: "devflow.mayStart", args: [2, 2, "urgent", "engineer", "critical"]}, {pick: ["ok"], expect: [false], why: "urgent is not P0 where P0 is critical"},
		{call: "devflow.pullNext", args: [[{key: "K-1", sequence: 1, priority: "minor"}, {key: "K-2", sequence: 2, priority: "critical"}], ["critical", "major", "minor", "trivial", "none"]], expect: {key: "K-2", sequence: 2, priority: "critical"}},
	]}

	// GitHub Projects (devflow/board/github.js): a project's fields in the board's words.
	"a GitHub board's issue key is its repository's issue number": {suite: "devflow", steps: [
		{call: "ghboard.numberOf", args: ["SHOP", "SHOP-123"], expect: 123},
		{call: "ghboard.numberOf", args: ["SHOP", "shop-7"], expect: 7, why: "keys are matched as branches write them"},
		{call: "ghboard.numberOf", args: ["SHOP", "PRONTO-7"], expect: null, why: "another project's key"},
		{call: "ghboard.numberOf", args: ["SHOP", "SHOP-12x"], expect: null},
	]}
	"a Status option is a state: its group and whether new issues start there kept in its description": {suite: "devflow", steps: [
		{call: "ghboard.stateOf", args: [{id: "o1", name: "Ready", color: "BLUE", description: "group:unstarted designed: objective, acceptance"}], expect: {id: "o1", name: "Ready", group: "unstarted", color: "BLUE", default: false}},
		{call: "ghboard.stateOf", args: [{id: "o2", name: "Backlog", color: "GRAY", description: "group:backlog default on the board"}], expect: {id: "o2", name: "Backlog", group: "backlog", color: "GRAY", default: true}},
		{call: "ghboard.stateOf", args: [{id: "o3", name: "Todo", color: "GREEN", description: ""}], expect: {id: "o3", name: "Todo", group: "unstarted", color: "GREEN", default: false}, why: "GitHub's own option, which devflow did not write"},
		{call: "ghboard.describeState", args: ["completed", false, "merged into main"], expect: "group:completed merged into main"},
	]}
	"writing the Status options keeps every option by its id, so no item loses its status": {suite: "devflow", steps: [
		{call: "ghboard.optionsWith", args: [[{id: "o1", name: "Backlog", color: "GRAY", description: "group:backlog default"}], {add: {name: "Ready", group: "unstarted", color: "#3b82f6", description: "designed"}}], expect: [
			{id: "o1", name: "Backlog", color: "GRAY", description: "group:backlog default"},
			{name: "Ready", color: "BLUE", description: "group:unstarted designed"},
		]},
		{call: "ghboard.optionsWith", args: [[{id: "o1", name: "Backlog", color: "GRAY", description: "group:backlog default"}, {id: "o2", name: "Ready", color: "BLUE", description: "group:unstarted designed"}], {defaultId: "o2"}], expect: [
			{id: "o1", name: "Backlog", color: "GRAY", description: "group:backlog"},
			{id: "o2", name: "Ready", color: "BLUE", description: "group:unstarted default designed"},
		], why: "one default: the state new issues start in moves"},
		{call: "ghboard.optionsWith", args: [[{id: "o1", name: "Live", color: "GRAY", description: "group:completed in production"}], {change: {id: "o1", fields: {color: "#22c55e", group: "completed"}}}], expect: [
			{id: "o1", name: "Live", color: "GREEN", description: "group:completed in production"},
		]},
		{call: "ghboard.colorOf", args: ["#ef4444"], expect: "RED"},
		{call: "ghboard.colorOf", args: ["not a colour"], expect: "GRAY"},
	]}
	"a project item is an issue: its state, priority, apps and sprint read from the fields by name": {suite: "devflow", steps: [
		{call: "ghboard.issueOf", args: [{id: "PVTI_1", content: {id: "I_9", number: 9, title: "army pick", body: "<p>Flag: army_pick</p>", labels: {nodes: [{id: "bug"}]}}, fieldValues: {nodes: [
			{optionId: "o5", name: "Implementing", field: {name: "Status"}},
			{optionId: "p2", name: "high", field: {name: "Priority"}},
			{options: [{id: "m1", name: "brawl-chess"}, {id: "m2", name: "plugins"}], field: {name: "Module"}},
			{iterationId: "it3", title: "Sprint 3", field: {name: "Sprint"}},
			{},
		]}}], expect: {id: "I_9", item: "PVTI_1", name: "army pick", sequence_id: 9, state: "o5", priority: "high", description_html: "<p>Flag: army_pick</p>", modules: ["brawl-chess", "plugins"], cycle: "it3", labels: ["bug"]}},
		{call: "ghboard.issueOf", args: [{id: "PVTI_2", content: {id: "I_1", number: 1, title: "t"}, fieldValues: {nodes: []}}], expect: {id: "I_1", item: "PVTI_2", name: "t", sequence_id: 1, state: "", priority: "none", description_html: "", modules: [], cycle: null, labels: []}, why: "an item with no values yet: no state, no priority, no app, no sprint"},
	]}
	"a sprint is an iteration: its end the last day it covers, every iteration kept by its id when one is added": {suite: "devflow", steps: [
		{call: "ghboard.cycleOf", args: [{id: "it1", title: "Sprint 1", startDate: "2026-11-08", duration: 3}], expect: {id: "it1", name: "Sprint 1", start_date: "2026-11-08", end_date: "2026-11-10"}},
		{call: "ghboard.cycleOf", args: [{id: "it2", title: "Sprint 2", startDate: "2026-11-10", duration: 1}], expect: {id: "it2", name: "Sprint 2", start_date: "2026-11-10", end_date: "2026-11-10"}},
		{call: "ghboard.daysFrom", args: ["2026-11-10", "2026-11-10"], expect: 1, why: "a sprint the planner makes for its day lasts that day"},
		{call: "ghboard.addDays", args: ["2026-12-31", 1], expect: "2027-01-01"},
		{call: "ghboard.iterationsWith", args: [[{id: "it1", title: "Sprint 1", startDate: "2026-11-08", duration: 3, extra: true}], {name: "Sprint 2", start: "2026-11-10", end: "2026-11-10"}], expect: [
			{id: "it1", title: "Sprint 1", startDate: "2026-11-08", duration: 3},
			{title: "Sprint 2", startDate: "2026-11-10", duration: 1},
		]},
	]}
	"a link is a comment carrying its address, read back once each": {suite: "devflow", steps: [
		{call: "ghboard.linkComment", args: ["https://github.com/a/b/pull/4", "#4 a <fix>"], expect: "<!-- devflow:link https://github.com/a/b/pull/4 -->\n<p>Linked: <a href=\"https://github.com/a/b/pull/4\">#4 a &lt;fix></a></p>"},
		{call: "ghboard.linksOf", args: [[{body: "<!-- devflow:link https://github.com/a/b/pull/4 -->\nLinked"}, {body: "a comment"}, {body: "<!-- devflow:link https://github.com/a/b/pull/4 -->"}, {body: "<!-- devflow:link https://github.com/a/b/pull/9 -->"}]], expect: [{url: "https://github.com/a/b/pull/4"}, {url: "https://github.com/a/b/pull/9"}]},
	]}
}

// A flag merged off gets its flip issue (PRONTO-265): the flags a merge added off, their notes, the
// flip issue's title, and the one a flip finishes.
cases: {
	"a merge's added flags are those new in its flagd file whose default is off": {suite: "devflow", steps: [
		{call: "devflow.addedFlags", args: [
			{flags: {ads: {variants: {default: false, local: true}, defaultVariant: "default"}}},
			{flags: {
				ads: {variants: {default: false, local: true}, defaultVariant: "default"}
				shop: {variants: {default: false, local: true}, defaultVariant: "default"}
				premium: {variants: {default: true}, defaultVariant: "default"}
				grants: {variants: {default: "[]"}, defaultVariant: "default"}
			}}], expect: ["shop"], why: "ads was there; premium is on where released; grants is no switch"},
		{call: "devflow.addedFlags", args: [null, {flags: {b: {variants: {default: false}, defaultVariant: "default"}, a: {variants: {default: false}, defaultVariant: "default"}}}], expect: ["a", "b"], why: "a new flagd file: all its off flags, sorted"},
		{call: "devflow.addedFlags", args: [{flags: {a: {variants: {default: false}, defaultVariant: "default"}}}, {flags: {}}], expect: [], why: "a flag removed is no flip"},
	]}
	"a flag's note is read from flags_spec.cue, in either way a flag is written": {suite: "devflow", steps: [
		{call: "devflow.flagNote", args: ["flags: {\n\tpremium: {\n\t\tnote: \"\"\"\n\t\t\tPlus and Premium:\n\t\t\tthe offer.\n\t\t\t\"\"\"\n\t\tdefault: true\n\t}\n}\n", "premium"], expect: "Plus and Premium: the offer."},
		{call: "devflow.flagNote", args: ["flags: ads: {\n\tnote: \"\"\"\n\t\tRewarded ads.\n\t\t\"\"\"\n\tdefault: false\n}\n", "ads"], expect: "Rewarded ads."},
		{call: "devflow.flagNote", args: ["flags: a: {\n\tdefault: false\n}\nflags: b: {\n\tnote: \"\"\"\n\t\tB's.\n\t\t\"\"\"\n}\n", "a"], expect: null, why: "a flag without a note never takes the next flag's"},
		{call: "devflow.flagNote", args: ["flags: {}\n", "ads"], expect: null},
	]}
	"a flip issue is titled for its flag and app, and found by title and module, whatever its state": {suite: "devflow", steps: [
		{call: "devflow.flipTitle", args: ["ads", "brawl-chess"], expect: "Flip ads on in brawl-chess"},
		{call: "devflow.flipOf", args: ["Flip ads on in Bonk Chess"], expect: "ads", why: "PRONTO-225, filed by hand"},
		{call: "devflow.flipOf", args: ["Flip `ads` on in Bonk Chess"], expect: "ads"},
		{call: "devflow.flipOf", args: ["Ads: rewarded ads for reviews"], expect: null},
		{call: "devflow.flipIssueOf", args: [[{name: "Flip ads on in Bonk Chess", modules: ["brawl-chess"], key: 225}], "ads", "brawl-chess"], expect: {name: "Flip ads on in Bonk Chess", modules: ["brawl-chess"], key: 225}, why: "the one filed by hand is reused, not filed twice"},
		{call: "devflow.flipIssueOf", args: [[{name: "Flip ads on in Bonk Chess", modules: ["brawl-chess"]}], "ads", "studio"], expect: null, why: "another app's flag of the same name"},
		{call: "devflow.flipIssueOf", args: [[{name: "Ads in the shop", modules: ["brawl-chess"]}], "ads", "brawl-chess"], expect: null},
	]}
	"a flip finishes the flag's flip issue from wherever it waits": {suite: "devflow", steps: [
		{call: "devflow.flipIssueMove", args: ["backlog"], expect: "done", why: "it waits in the Backlog for the owner's go"},
		{call: "devflow.flipIssueMove", args: ["implementing"], expect: "done"},
		{call: "devflow.flipIssueMove", args: ["done"], expect: null},
		{call: "devflow.flipIssueMove", args: ["cancelled"], expect: null, why: "a flag the owner said stays off"},
	]}
}
