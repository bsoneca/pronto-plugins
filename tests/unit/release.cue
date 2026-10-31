// `release` (intents/release.ts, docs/intents.md): the app's checks and release, and, where it
// sells through pronto-billing, the broker named before it goes out and its payouts checked once it
// is out. The steps are named here, never run: what each does is the deploy and stripe suites'.
package unit

cases: {
	"an app that sells nothing is released, and answers": {suite: "release", steps: [
		{call: "shop.releaseNames", args: [false]}, {call: "probe.from", args: ["$", -2], expect: ["released", "answers"]},
	]}
	"an app that sells has the broker named before it goes out, and its payouts checked once out": {suite: "release", steps: [
		{call: "shop.releaseNames", args: [true, "https://shop.example"]},
		{call: "probe.from", args: ["$", -6], expect: ["the release names the broker", "released", "answers", "the origin publishes its plans", "payouts set up at Stripe", "verified"]},
	]}
	"before its first release, only what goes out with it": {suite: "release", steps: [
		{call: "shop.releaseNames", args: [true, null]},
		{call: "probe.from", args: ["$", -3], expect: ["the release names the broker", "released", "answers"]},
	]}
}
