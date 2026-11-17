// The dev flow's rules (devflow/flow.js): which issue a pull request is, where each event moves an
// issue, an issue's flag, the agent cap, P0..P3, and the queue Ready issues are pulled from (PRONTO-658). They reason in
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
		{call: "devflow.mayStart", args: [0, 1, "high", "architect"], expect: {ok: true, why: "architect slot 1 of 1"}},
		{call: "devflow.mayStart", args: [1, 1, "medium", "architect"], expect: {ok: false, why: "all 1 architect slots are busy"}},
		{call: "devflow.mayStart", args: [9, 2, "urgent", "engineer"]}, {pick: ["ok"], expect: [true]},
	]}
	"a lane pulls a P0 bug, then a P1 bug, then the issue that became Ready first": {suite: "devflow", steps: [
		{call: "devflow.pullOrder", args: [[
			{key: "K-3", sequence: 3, jump: false, readyAt: "2026-11-12T10:00:00Z"},
			{key: "K-9", sequence: 9, jump: false, readyAt: "2026-11-10T10:00:00Z"},
			{key: "K-5", sequence: 5, jump: true, readyAt: "2026-11-16T10:00:00Z"},
			{key: "K-1", sequence: 1, jump: false, readyAt: "2026-11-12T10:00:00Z"},
		]]}, {pick: ["0.key", "1.key", "2.key", "3.key"], expect: ["K-5", "K-9", "K-1", "K-3"], why: "the jump first; then Ready time, whatever the number; a tie by number"},
		{call: "devflow.pullOrder", args: [[{key: "K-2", sequence: 2, jump: false}, {key: "K-1", sequence: 1, jump: false, readyAt: "2026-11-12T10:00:00Z"}]]}, {pick: ["0.key"], expect: ["K-1"], why: "an issue with no Ready time comes last"},
		{call: "devflow.pullOrder", args: [[
			{key: "K-2", sequence: 2, jump: true, p0: false, readyAt: "2026-11-10T10:00:00Z"},
			{key: "K-8", sequence: 8, jump: true, p0: true, readyAt: "2026-11-16T10:00:00Z"},
			{key: "K-6", sequence: 6, jump: false, readyAt: "2026-11-11T10:00:00Z"},
			{key: "K-4", sequence: 4, jump: false, readyAt: "2026-11-11T10:00:00Z"},
		]]}, {pick: ["0.key", "1.key", "2.key", "3.key"], expect: ["K-8", "K-2", "K-4", "K-6"], why: "a P0 bug before a P1 bug even if it became Ready later; equal Ready times: the number decides"},
		{call: "devflow.pullOrder", args: [[]], expect: []},
	]}
	"an issue became Ready at its latest move into Ready, else when it was made": {suite: "devflow", steps: [
		{call: "devflow.readySince", args: [[{to: "s-ready", at: "2026-11-10T10:00:00Z"}, {to: "s-impl", at: "2026-11-11T10:00:00Z"}, {to: "s-ready", at: "2026-11-13T09:00:00Z"}], "s-ready", "2026-11-01T00:00:00Z"], expect: "2026-11-13T09:00:00.000Z", why: "bounced back to Ready: the current stay counts"},
		{call: "devflow.readySince", args: [[{to: "s-refine", at: "2026-11-10T10:00:00Z"}], "s-ready", "2026-11-01T00:00:00Z"], expect: "2026-11-01T00:00:00Z", why: "made in Ready, no move into it"},
		{call: "devflow.readySince", args: [[], "s-ready", null], expect: null},
	]}
	"a bug at P0 or P1 jumps the queue, nothing else does": {suite: "devflow", steps: [
		{call: "devflow.jumps", args: ["high", true, ["urgent", "high"]], expect: true},
		{call: "devflow.jumps", args: ["urgent", true, ["urgent", "high"]], expect: true},
		{call: "devflow.jumps", args: ["high", false, ["urgent", "high"]], expect: false, why: "a P1 feature waits its turn"},
		{call: "devflow.jumps", args: ["medium", true, ["urgent", "high"]], expect: false},
		{call: "devflow.jumps", args: ["major", true, ["critical", "major"]], expect: true, why: "the repository's words"},
	]}
	"merges are counted by day in the flow's time zone, the last 7 days": {suite: "devflow", steps: [
		{call: "devflow.mergedByDay", args: [["2026-11-17T12:00:00Z", "2026-11-17T01:00:00Z", "2026-11-16T20:00:00Z", "2026-11-12T12:00:00Z", "2026-11-09T12:00:00Z", "2026-11-18T12:00:00Z"], "2026-11-17T15:00:00Z", "America/Sao_Paulo"], expect: {today: 1, week: 4, byDay: [{day: "2026-11-17", count: 1}, {day: "2026-11-16", count: 2}, {day: "2026-11-12", count: 1}]}, why: "01:00 UTC on the 17th is the 16th in BRT; a moment before 10 Nov and one after now are not counted"},
		{call: "devflow.mergedByDay", args: [[], "2026-11-17T15:00:00Z", "America/Sao_Paulo"], expect: {today: 0, week: 0, byDay: []}},
	]}
	"a design module's issue is an architect's, an infra module's an SRE's, every other an engineer's": {suite: "devflow", steps: [
		{call: "devflow.laneOf", args: [["design"], ["infra"], ["design"]], expect: "architect"},
		{call: "devflow.laneOf", args: [["infra", "design"], ["infra"], ["design"]], expect: "architect", why: "design wins: an architect's issue ends in a doc, whatever it touches"},
		{call: "devflow.laneOf", args: [["infra"], ["infra"], ["design"]], expect: "SRE"},
		{call: "devflow.laneOf", args: [["brawl-chess"], ["infra"], ["design"]], expect: "engineer"},
		{call: "devflow.laneOf", args: [["infra"], ["infra"]], expect: "SRE"},
		{call: "devflow.laneOf", args: [["brawl-chess"], ["infra"]], expect: "engineer"},
		{call: "devflow.laneOf", args: [[], ["infra"]], expect: "engineer"},
	]}
	"P0..P3 are Plane's priorities, and say where a new bug goes (P1: refined at once, queued first once Ready)": {suite: "devflow", steps: [
		{call: "devflow.priorityOf", args: ["p0"], expect: "urgent"},
		{call: "devflow.bugPlace", args: ["P0"], expect: {role: "implementing"}},
		{call: "devflow.bugPlace", args: ["P1"], expect: {role: "refine"}},
		{call: "devflow.bugPlace", args: ["P3"], expect: {role: "backlog"}},
		{call: "devflow.priorityOf", args: ["P4"], throws: "P0, P1, P2 or P3"},
	]}
	"a moment's day is the one in the flow's time zone": {suite: "devflow", steps: [
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
		{call: "devflow.bugPlace", args: ["P0", {P0: "critical", P1: "major", P2: "minor", P3: "trivial"}], expect: {role: "implementing"}},
		{call: "devflow.bugPlace", args: ["P4", {P0: "critical", P1: "major", P2: "minor", P3: "trivial"}], throws: "P0, P1, P2 or P3"},
		{call: "devflow.mayStart", args: [9, 2, "critical", "engineer", "critical"]}, {pick: ["ok"], expect: [true]},
		{call: "devflow.mayStart", args: [2, 2, "urgent", "engineer", "critical"]}, {pick: ["ok"], expect: [false], why: "urgent is not P0 where P0 is critical"},
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
	"a flag on for everyone for a week gets one removal issue, found by title and module, whatever its state": {suite: "devflow", steps: [
		{call: "devflow.removeTitle", args: ["ads", "brawl-chess"], expect: "Remove flag ads from brawl-chess"},
		{call: "devflow.removeOf", args: ["Remove flag ads from brawl-chess"], expect: "ads"},
		{call: "devflow.removeOf", args: ["Remove flag `ads` from Bonk Chess"], expect: "ads"},
		{call: "devflow.removeOf", args: ["Flip ads on in brawl-chess"], expect: null},
		{call: "devflow.removeIssueOf", args: [[{name: "Remove flag ads from brawl-chess", modules: ["brawl-chess"], state: "done"}], "ads", "brawl-chess"], expect: {name: "Remove flag ads from brawl-chess", modules: ["brawl-chess"], state: "done"}, why: "a removal issue already Done is reused, never filed again"},
		{call: "devflow.removeIssueOf", args: [[{name: "Remove flag ads from brawl-chess", modules: ["brawl-chess"]}], "ads", "studio"], expect: null, why: "another app's flag of the same name"},
	]}
	"seven days on for everyone is the line, at an injected now": {suite: "devflow", steps: [
		{call: "devflow.onForDays", args: ["2026-11-04T12:00:00Z", "2026-11-11T12:00:00Z"], expect: true, why: "exactly 7 days"},
		{call: "devflow.onForDays", args: ["2026-11-04T12:00:01Z", "2026-11-11T12:00:00Z"], expect: false, why: "a second short"},
		{call: "devflow.onForDays", args: [null, "2026-11-11T12:00:00Z"], expect: false, why: "no Done time is never old enough"},
		{call: "devflow.onForDays", args: ["not a time", "2026-11-11T12:00:00Z"], expect: false},
	]}
	"the removal issues due are the app's flip issues Done 7 days ago with none filed yet": {suite: "devflow", steps: [
		{call: "devflow.removalsDue", args: [[
			{name: "Flip ads on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"},
			{name: "Flip shop on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-09T10:00:00Z"},
			{name: "Flip menu on in brawl-chess", modules: ["brawl-chess"], state: "backlog", doneAt: ""},
			{name: "Flip trophies on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-01T10:00:00Z"},
			{name: "Remove flag trophies from brawl-chess", modules: ["brawl-chess"], state: "cancelled"},
			{name: "Flip ads on in studio", modules: ["studio"], state: "done", doneAt: "2026-10-01T10:00:00Z"},
			{name: "Flip friends on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-10-30T10:00:00Z"},
		], "brawl-chess", "2026-11-11T12:00:00Z"], expect: [
			{flag: "ads", flip: {name: "Flip ads on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"}},
			{flag: "friends", flip: {name: "Flip friends on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-10-30T10:00:00Z"}},
		], why: "shop is 2 days Done, menu waits in the Backlog, trophies has a removal issue, studio is another app"},
		{call: "devflow.removalsDue", args: [[{name: "Flip ads on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"}, {name: "Remove flag ads from brawl-chess", modules: ["brawl-chess"], state: "backlog"}], "brawl-chess", "2026-11-11T12:00:00Z"], expect: [], why: "a second run files nothing"},
	]}
	"a flip issue may name several flags, each one its own removal": {suite: "devflow", steps: [
		{call: "devflow.flipFlagsOf", args: ["Flip ads on in brawl-chess"], expect: ["ads"]},
		{call: "devflow.flipFlagsOf", args: ["Flip trial_banner and roman_army on for everyone where Bonk Chess is released"], expect: ["trial_banner", "roman_army"], why: "PRONTO-44, filed by hand"},
		{call: "devflow.flipFlagsOf", args: ["Flip `a`, b and c on in brawl-chess"], expect: ["a", "b", "c"]},
		{call: "devflow.flipFlagsOf", args: ["Flip the menu on in brawl-chess"], expect: [], why: "words that are no flag name"},
		{call: "devflow.flipFlagsOf", args: ["Remove flag ads from brawl-chess"], expect: []},
	]}
	"a flag on by default counts from when the released history turned it on": {suite: "devflow", steps: [
		{call: "devflow.onSince", args: [[
			{at: "2026-11-08T10:00:00Z", flags: {flags: {a: {variants: {on: true, off: false}, defaultVariant: "on"}, b: {variants: {on: true, off: false}, defaultVariant: "on"}, c: {variants: {on: true, off: false}, defaultVariant: "off"}, grants: {variants: {default: [1]}, defaultVariant: "default"}}}},
			{at: "2026-11-05T10:00:00Z", flags: {flags: {a: {variants: {on: true, off: false}, defaultVariant: "on"}, b: {variants: {on: true, off: false}, defaultVariant: "off"}}}},
			{at: "2026-11-01T10:00:00Z", flags: {flags: {a: {variants: {on: true, off: false}, defaultVariant: "on"}, b: {variants: {on: true, off: false}, defaultVariant: "on"}}}},
		]], expect: {a: "2026-11-01T10:00:00Z", b: "2026-11-08T10:00:00Z"}, why: "b was off on 11-05, so its run starts 11-08; c is off; an object variant is no flag"},
		{call: "devflow.onSince", args: [[]], expect: {}, why: "no history, nothing on"},
	]}
	"flags with no Done flip issue go by the released history; one with a Done flip goes by the flip": {suite: "devflow", steps: [
		{call: "devflow.removalsDue", args: [[
			{name: "Flip trial_banner and roman_army on for everyone where Bonk Chess is released", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"},
			{name: "Flip shop on in brawl-chess", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-09T10:00:00Z"},
			{name: "Flip army_fights on in brawl-chess", modules: ["brawl-chess"], state: "cancelled", doneAt: ""},
			{name: "Remove flag premium from brawl-chess", modules: ["brawl-chess"], state: "backlog"},
		], "brawl-chess", "2026-11-11T12:00:00Z", 7, {
			shop: "2026-10-01T10:00:00Z", premium: "2026-10-28T10:00:00Z", birosca_army: "2026-11-04T12:00:00Z",
			army_fights: "2026-11-01T10:00:00Z", menu_first: "2026-11-07T10:00:00Z", roman_army: "2026-11-08T10:00:00Z",
		}], expect: [
			{flag: "army_fights", since: "2026-11-01T10:00:00Z"},
			{flag: "birosca_army", since: "2026-11-04T12:00:00Z"},
			{flag: "roman_army", flip: {name: "Flip trial_banner and roman_army on for everyone where Bonk Chess is released", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"}},
			{flag: "trial_banner", flip: {name: "Flip trial_banner and roman_army on for everyone where Bonk Chess is released", modules: ["brawl-chess"], state: "done", doneAt: "2026-11-03T10:00:00Z"}},
		], why: "shop's flip is 2 days Done, which wins over its history; premium has its removal issue; menu_first is 4 days on; a cancelled flip leaves the history to say"},
	]}

	// PRONTO-341: a board call that never answered held a verb for ever, and two pulls both took PRONTO-298.
	"a board call is asked again only where asking twice is safe": {suite: "devflow", steps: [
		{call: "devflow.askAgain", args: ["GET", "timeout", 0], expect: 2000, why: "a read that never answered is asked again"},
		{call: "devflow.askAgain", args: ["PATCH", 502, 1], expect: 4000, why: "moving an issue twice moves it once"},
		{call: "devflow.askAgain", args: ["DELETE", "network", 0], expect: 2000},
		{call: "devflow.askAgain", args: ["POST", 429, 0], expect: 2000, why: "a 429 never ran, so even a comment is asked again"},
		{call: "devflow.askAgain", args: ["POST", "timeout", 0], expect: null, why: "a comment or an issue that got no answer may have been made: asked twice, it would be two"},
		{call: "devflow.askAgain", args: ["POST", 503, 0], expect: null},
		{call: "devflow.askAgain", args: ["GET", 404, 0], expect: null, why: "an answer that says no is not asked again"},
		{call: "devflow.askAgain", args: ["GET", "timeout", 3], expect: null, why: "four calls in all, then the verb fails and says so"},
		{call: "devflow.askAgain", args: ["get", 429, 2, 4], expect: 6000, why: "the wait grows with each try"},
	]}
	"of two pulls racing for one issue, the first claim keeps it": {suite: "devflow", steps: [
		{call: "devflow.claimText", args: ["5f0c2a9e-1111-4222-8333-944455556666"], expect: "claim 5f0c2a9e-1111-4222-8333-944455556666"},
		{call: "devflow.claimWinner", args: [[
			{html: "<p>Ready → Implementing: engineer slot 3 of 6 (claim bbbbbbbb-0000)</p>", at: "2026-11-11T22:00:05Z"},
			{html: "<p>Ready → Implementing: engineer slot 3 of 6 (claim aaaaaaaa-0000)</p>", at: "2026-11-11T22:00:03Z"},
		], "2026-11-11T22:00:06Z"], expect: "aaaaaaaa-0000", why: "the one made first, whatever order the board lists them in"},
		{call: "devflow.claimWinner", args: [[
			{html: "<p>(claim bbbbbbbb-0000)</p>", at: "2026-11-11T22:00:03Z"},
			{html: "<p>(claim aaaaaaaa-0000)</p>", at: "2026-11-11T22:00:03Z"},
		], "2026-11-11T22:00:06Z"], expect: "aaaaaaaa-0000", why: "at the same moment, the smaller nonce: both pulls agree on one"},
		{call: "devflow.claimWinner", args: [[
			{html: "<p>Ready → Implementing (claim oldoldol-0000)</p>", at: "2026-11-11T20:00:00Z"},
			{html: "<p>Implementing → Ready: refined</p>", at: "2026-11-11T21:00:00Z"},
			{html: "<p>Ready → Implementing (claim newnewne-0000)</p>", at: "2026-11-11T22:00:00Z"},
		], "2026-11-11T22:00:02Z"], expect: "newnewne-0000", why: "a claim from an earlier pull, long past, does not count"},
		{call: "devflow.claimWinner", args: [[{html: "<p>Refine → Ready: refined</p>", at: "2026-11-11T22:00:00Z"}], "2026-11-11T22:00:02Z"], expect: null},
	]}

	// An issue holding a slot that no work is moving is stuck (2026-11-14: 5 of 6 slots busy for two days, every session ended).
	"an issue holding a slot is stuck when no PR and no commit moved it for hours, or its PR cannot land": {suite: "devflow", steps: [
		{call: "devflow.stuckOf", args: [{key: "PRONTO-1", state: "Implementing", since: "2026-11-14T10:00:00Z", pr: null, commit: null}, "2026-11-14T12:00:00Z"], expect: null, why: "fresh work, started two hours ago, is not stuck"},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-2", state: "Implementing", since: "2026-11-12T10:00:00Z", pr: null, commit: "2026-11-14T09:00:00Z"}, "2026-11-14T12:00:00Z"], expect: null, why: "old issue, but a commit on its branch three hours ago"},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-444", state: "Implementing", since: "2026-11-12T12:00:00Z", pr: null, commit: null}, "2026-11-14T12:00:00Z"], expect: {key: "PRONTO-444", state: "Implementing", age: "2d", why: "no PR, no commits"}, why: "two days idle"},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-5", state: "Implementing", since: "2026-11-12T12:00:00Z", pr: null, commit: "2026-11-13T12:00:00Z"}, "2026-11-14T12:00:00Z"], expect: {key: "PRONTO-5", state: "Implementing", age: "2d", why: "no PR, last commit 1d ago"}},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-6", state: "Review", since: "2026-11-14T11:00:00Z", pr: {ci: "fail", auto: true}, commit: null}, "2026-11-14T12:00:00Z"], expect: {key: "PRONTO-6", state: "Review", age: "1h", why: "PR ci failed"}, why: "a failed ci is stuck however fresh"},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-7", state: "Review", since: "2026-11-14T11:00:00Z", pr: {ci: "pending", auto: false}, commit: null}, "2026-11-14T12:00:00Z"], expect: {key: "PRONTO-7", state: "Review", age: "1h", why: "PR auto-merge not armed"}},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-8", state: "Review", since: "2026-11-10T11:00:00Z", pr: {ci: "pending", auto: true}, commit: null}, "2026-11-14T12:00:00Z"], expect: null, why: "a PR with ci running and auto-merge armed is on its way"},
		{call: "devflow.stuckOf", args: [{key: "PRONTO-9", state: "Implementing", since: "2026-11-14T08:00:00Z", pr: null, commit: null}, "2026-11-14T12:00:00Z", 3], expect: {key: "PRONTO-9", state: "Implementing", age: "4h", why: "no PR, no commits"}, why: "the hours come from devflow.cue"},
		{call: "devflow.stuckLine", args: [{key: "PRONTO-444", state: "Implementing", age: "2d", why: "no PR, no commits"}], expect: "stuck: PRONTO-444 Implementing 2d, no PR, no commits"},
	]}
}
