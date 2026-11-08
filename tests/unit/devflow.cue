// The dev flow's rules (devflow/flow.js): which issue a pull request is, where each event moves an
// issue, an issue's flag, the agent cap, P0..P3, and which day's sprint a moment falls in.
package unit

cases: {
	"a pull request's issue is the key in its title, else its branch, written the board's way": {suite: "devflow", steps: [
		{call: "devflow.keyOf", args: ["PRONTO", "PRONTO-123: army pick lists usable armies", "fix/x"], expect: "PRONTO-123"},
		{call: "devflow.keyOf", args: ["PRONTO", "brawl-chess: a fix", "pronto-0042/army-pick"], expect: "PRONTO-42", why: "branches are lower case; the number loses its zeros"},
		{call: "devflow.keyOf", args: ["PRONTO", "[pronto-7] fix", ""], expect: "PRONTO-7"},
		{call: "devflow.keyOf", args: ["PRONTO", "MYPRONTO-12 is another project's", "PRONTO-123x"], expect: null, why: "a key is a whole word"},
		{call: "devflow.keyOf", args: ["PRONTO", "no key", null], expect: null},
	]}
	"a pull request moves its issue forward, never back, but for a pull request closed unmerged": {suite: "devflow", steps: [
		{call: "devflow.moveFor", args: ["opened", "Implementing"], expect: "Review"},
		{call: "devflow.moveFor", args: ["opened", "Ready"], expect: "Review", why: "a session may open its pull request before the board heard it started"},
		{call: "devflow.moveFor", args: ["merged", "Review"], expect: "Merged"},
		{call: "devflow.moveFor", args: ["reopened", "Merged"], expect: null},
		{call: "devflow.moveFor", args: ["merged", "Live"], expect: null, why: "a second pull request for a released issue leaves it Live"},
		{call: "devflow.moveFor", args: ["closed", "Review"], expect: "Implementing"},
		{call: "devflow.moveFor", args: ["closed", "Merged"], expect: null},
		{call: "devflow.moveFor", args: ["merged", "Cancelled"], expect: null, why: "a cancelled issue is never moved"},
	]}
	"a release makes Merged Live; a flip makes it Done, and its rollback Live again": {suite: "devflow", steps: [
		{call: "devflow.moveFor", args: ["released", "Merged"], expect: "Live"},
		{call: "devflow.moveFor", args: ["released", "Review"], expect: null},
		{call: "devflow.moveFor", args: ["flipped", "Live"], expect: "Done"},
		{call: "devflow.moveFor", args: ["flipped", "Merged"], expect: "Done", why: "an app released outside release-cron never says released"},
		{call: "devflow.moveFor", args: ["flipped", "Implementing"], expect: null},
		{call: "devflow.moveFor", args: ["rolledback", "Done"], expect: "Live"},
		{call: "devflow.moveFor", args: ["rolledback", "Live"], expect: null},
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
	"an issue starts while an agent is free; a P0 starts regardless": {suite: "devflow", steps: [
		{call: "devflow.mayStart", args: [3, 4, "high"]}, {pick: ["ok"], expect: [true]},
		{call: "devflow.mayStart", args: [4, 4, "medium"], expect: {ok: false, why: "all 4 agents are busy"}},
		{call: "devflow.mayStart", args: [9, 4, "urgent"]}, {pick: ["ok"], expect: [true]},
	]}
	"P0..P3 are Plane's priorities, and say where a new bug goes": {suite: "devflow", steps: [
		{call: "devflow.priorityOf", args: ["p0"], expect: "urgent"},
		{call: "devflow.bugPlace", args: ["P0"], expect: {state: "Implementing", sprint: true}},
		{call: "devflow.bugPlace", args: ["P1"], expect: {state: "Refine", sprint: true}},
		{call: "devflow.bugPlace", args: ["P3"], expect: {state: "Backlog", sprint: false}},
		{call: "devflow.priorityOf", args: ["P4"], throws: "P0, P1, P2 or P3"},
	]}
	"a day's sprint ends at its hour: a moment after it is the next day's": {suite: "devflow", steps: [
		{call: "devflow.sprintOf", args: ["2026-11-08T20:59:00Z", "18:00", "America/Sao_Paulo"], expect: "2026-11-08", why: "17:59 in São Paulo"},
		{call: "devflow.sprintOf", args: ["2026-11-08T21:00:00Z", "18:00", "America/Sao_Paulo"], expect: "2026-11-09"},
		{call: "devflow.sprintOf", args: ["2026-12-31T22:00:00Z", "18:00", "America/Sao_Paulo"], expect: "2027-01-01"},
	]}
	"a pull request with no issue fails the check, but for a chore or while it only warns": {suite: "devflow", steps: [
		{call: "devflow.missingKey", args: [["chore"], "chore", false, "PRONTO"]}, {pick: ["ok"], expect: [true]},
		{call: "devflow.missingKey", args: [[], "chore", false, "PRONTO"]}, {pick: ["ok"], expect: [false]},
		{call: "devflow.missingKey", args: [[], "chore", true, "PRONTO"]}, {pick: ["ok"], expect: [true]},
	]}
}
