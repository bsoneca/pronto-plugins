// The intents' runner (intents/run.ts): a step applied is not done until its check says so, and a
// check that throws is a failed step; either stops the run there.
package unit

cases: {
	"a run waiting on a person's link ends with the link alone on its line": {suite: "runner", steps: [
		{call: "run.waitingOn", args: [[{step: "payouts set up at Stripe", state: "gate", note: "open https://connect.stripe.com/setup/e/a/b and finish Stripe's form, then run this again"}]],
			matches: "\n  https://connect\\.stripe\\.com/setup/e/a/b\n", why: "the address alone, nothing after it to copy by mistake"},
		{call: "run.waitingOn", args: [[{step: "something to sell", state: "gate", note: "say what to sell: --plan <id>"}]], matches: "Run the same command again", why: "no link: what to do is the step's own line"},
	]}
	"a step that applied and is still to do failed, and nothing after it runs": {suite: "runner", steps: [
		{call: "shop.stubborn"}, {pick: ["states", "after"], expect: [["failed"], false]},
	]}
	"a check that throws is a failed step, with why, and the run stops there": {suite: "runner", steps: [
		{call: "shop.throwing", args: ["connect"]}, {pick: ["states", "notes"], expect: [["failed"], ["gcloud: no login"]]},
		{call: "shop.throwing", args: ["plan"]}, {get: "states", expect: ["failed", "done"], why: "a plan goes on, saying it"},
	]}
	"an intent's flags: each with its value, and a switch alone, before another flag or at the end": {suite: "runner", steps: [
		{call: "shell.flagsOf", args: [["--plan", "pro", "--studio", "--usd", "299", "--json"]], expect: {plan: "pro", studio: "true", usd: "299", json: "true"}},
	]}
}
