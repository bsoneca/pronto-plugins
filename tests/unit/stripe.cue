// `connect stripe` (billing/connect.ts, docs/intents.md) on a stand-in shop: pronto-billing
// installed, the author's secret kept and its hash published, a plan, the design document, then on
// the live origin the broker named, the plans published, Stripe's link and a verify.
package unit

_broker: {broker: "https://broker.example"}
_pro: _broker & {plan: {id: "pro", name: "Shop Pro", usd: 499, brl: 1990}}
_unbrokered: {origin: "https://shop.example", email: "author@example.com", country: "BR"}
_live: _broker & _unbrokered
_gcpRelease: "package shop\n\nGCP: schema.#Release & {\n\tname: \"shop\"\n\tproject: \"p-apps\"\n}\n"
_k8sRelease: "App: schema.#ReleaseSpec & {\n\tname: \"my-app\"\n}\n"

cases: {
	"a new app: billing installed, its secret kept and its hash published, then it asks what to sell": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker]},
		{get: "states", expect: ["done", "applied", "applied", "gate"], why: "it stops at the plan"},
		{call: "shop.kept", args: ["$shop"], matches: "^[A-Za-z0-9_-]{32,}$"}, {keep: "secret"},
		{call: "shop.file", args: ["$shop", "billing_spec.cue"]}, {keep: "spec"},
		{call: "stripe.specOwner", args: ["$spec"]}, {keep: "owner"},
		{call: "shop.keptOwner", args: ["$shop"], expect: "$owner", why: "the spec publishes the kept secret's hash"},
		{call: "probe.holdsEach", args: ["$spec", ["_billingMigration: \"04_billing\"", "_billingGrantsMigration: \"05_billing_grants\""]], expect: [true, true], why: "its migrations named after 03_orders"},
		{call: "shop.connectStripe", args: ["$shop", _pro]},
		{pick: ["states", "finished"], expect: [["done", "done", "done", "applied", "done", "done", "applied"], true], why: "again with a plan, it goes on from there and redoes nothing"},
		{call: "shop.kept", args: ["$shop"], expect: "$secret", why: "the secret is kept, never remade"},
		{call: "shop.file", args: ["$shop", "billing_spec.cue"]},
		{call: "probe.includes", args: ["$", "prices: {usd: 499, brl: 1990}"], expect: true},
		{call: "shop.connectStripe", args: ["$shop", _pro, "plan"]}, {get: "states"},
		{call: "probe.every", args: ["$", "done"], expect: true, why: "a plan after it has nothing to do"},
	]}
	"a spec naming an owner whose secret is not kept waits on its author, and changes nothing": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {call: "shop.installed", args: ["$"]}, {keep: "shop"},
		{call: "shop.file", args: ["$shop", "billing_spec.cue"]},
		{call: "probe.replaced", args: ["$", "owner:\\s*\"[^\"]*\"", "owner:  \"ooooooooooooooooooooooooooooooooooooooooooo\""]},
		{call: "shop.written", args: ["$shop", "billing_spec.cue", "$"]},
		{call: "shop.connectStripe", args: ["$shop", _broker]}, {keep: "out"},
		{get: "states", expect: ["done", "done", "gate"]},
		{use: "out"}, {get: "notes.2"},
		{call: "probe.holdsEach", args: ["$", ["pronto-billing-owner-shop", "never pasted"]], expect: [true, true], why: "where to put it, and that it is never pasted"},
	]}
	"live: the broker named in the release, the origin's plans checked, Stripe's link given, then verified": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker & {plan: {id: "pro", name: "Pro", usd: 499}}]},
		{call: "shop.written", args: ["$shop", "release.cue", _gcpRelease]},
		{call: "shop.connectStripe", args: ["$shop", _live]}, {get: "states"},
		{call: "probe.from", args: ["$", 7], expect: ["applied", "gate"], why: "not released yet: the release is told the broker, then it waits for the origin"},
		{call: "shop.file", args: ["$shop", "release.cue"]},
		{call: "probe.includes", args: ["$", "BILLING_BROKER:          \"https://broker.example\""], expect: true},
		{call: "shop.answers", args: ["$shop", {published: true}]},
		{call: "shop.connectStripe", args: ["$shop", _live]}, {keep: "out"},
		{get: "states"}, {call: "probe.from", args: ["$", 7], expect: ["done", "done", "gate"], why: "released: onboarding opens, and waits on the author"},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "https://connect\\.stripe\\.com/setup/e/acct_1/xyz"},
		{call: "shop.kept", args: ["$shop"]}, {keep: "secret"},
		{call: "shop.asked", args: ["$shop"], expect: [{tenant: "https://shop.example", owner: "$secret", email: "author@example.com", country: "BR"}], why: "the kept secret, never typed"},
		{call: "shop.answers", args: ["$shop", {onboarded: true}]},
		{call: "shop.connectStripe", args: ["$shop", _live]},
		{get: "finished", expect: true, why: "Stripe done: every step done, and verified"},
	]}
	"Stripe's link is asked for first, and the author's email only where a new account needs it": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker & {plan: {id: "pro", name: "Pro", usd: 499}}]},
		{call: "shop.written", args: ["$shop", "release.cue", _gcpRelease]},
		{call: "shop.answers", args: ["$shop", {published: true}]},
		{call: "shop.connectStripe", args: ["$shop", _broker & {origin: "https://shop.example"}]}, {keep: "out"},
		{get: "states"}, {call: "probe.last", args: ["$"], expect: "gate"},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "--email", why: "no account yet: Stripe makes it with an email"},
		{call: "shop.answers", args: ["$shop", {account: true}]},
		{call: "shop.connectStripe", args: ["$shop", _broker & {origin: "https://shop.example"}]},
		{get: "notes"}, {call: "probe.last", args: ["$"], matches: "^open https://connect\\.stripe\\.com/", why: "an account made already: the link, no email asked"},
	]}
	"a plan before anything is installed says every step is to do, the plan among them": {suite: "stripe", steps: [
		{call: "shop.stripe"},
		{call: "shop.connectStripe", args: ["$", _broker, "plan"]},
		{get: "states", expect: ["done", "todo", "todo", "todo", "done", "done", "todo"]},
	]}
	"an app whose pronto cannot run billing's service is stopped before anything is touched, with what to do": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {call: "shop.pinned", args: ["$", "0.24.1-gcp.25"]}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker]}, {keep: "out"},
		{get: "states", expect: ["gate"]},
		{use: "out"}, {get: "notes.0", matches: "0\\.24\\.1-gcp\\.26"},
		{call: "shop.file", args: ["$shop", "billing_plugin.cue"], expect: null, why: "nothing installed"},
		{call: "shop.pinned", args: ["$shop", "0.24.1-gcp.26"]},
		{call: "shop.connectStripe", args: ["$shop", _broker, "plan"]},
		{pick: ["names.0", "states.0", "notes.0"], expect: ["a pronto that runs billing's service", "done", "0.24.1-gcp.26"]},
	]}
	"migration names follow the app's own, and a plan is written in minor units": {suite: "stripe", steps: [
		{call: "stripe.migrationNames", args: [[]], expect: {billing: "billing_01", grants: "billing_02"}},
		{call: "stripe.migrationNames", args: [["migrations: \"16_analysis\": x", "migrations: \"18_rewarded_gate\": y"]], expect: {billing: "19_billing", grants: "20_billing_grants"}},
		{call: "stripe.withPlan", args: ["\tplans: {}\n", {id: "pro", name: "Pro", usd: 499, interval: "year"}], expect: "\tplans: pro: {\n\t\tname:     \"Pro\"\n\t\tinterval: \"year\"\n\t\tprices: {usd: 499}\n\t}\n"},
	]}
	"the design document is given billing's entity, with the program's type id, and its hatch": {suite: "stripe", steps: [
		{call: "stripe.subscriptionId", args: [["code: state: entities: {\n\tSubscription: {\n\t\tid: \"0xabc123\"\n\t}\n}"]], expect: "0xabc123"},
		{call: "stripe.withBillingSections", args: ["<body><main>\n</main></body>", "0xabc123"]}, {keep: "ir"},
		{call: "stripe.describesBilling", args: ["$ir", "0xabc123"], expect: true},
		{call: "stripe.describesBilling", args: ["$ir", "0xother"], expect: false, why: "another type id is not this program's"},
		{use: "ir", matches: "id=\"billing\"[\\s\\S]*</main>", why: "inside the document's main"},
		{call: "stripe.describesBilling", args: ["<body></body>", null], expect: false},
	]}
	"the type id mint stamped in pronto-billing's file is moved to the app's spec": {suite: "stripe", steps: [
		{call: "stripe.withIdInSpec", args: ["code: state: entities: {\n\tSubscription: {\n\t\tid: \"0xabc\"\n\t\ttable:      \"subscription\"\n\t}\n}\n", "code: state: entities: {\n\tSubscription: {\n\t}\n}\n"]}, {keep: "moved"},
		{get: 1, expect: "code: state: entities: {\n\tSubscription: {\n\t\tid: \"0xabc\"\n\t}\n}\n"},
		{use: "moved"}, {get: 0}, {call: "probe.holdsEach", args: ["$", ["0xabc", "table:      \"subscription\""]], expect: [false, true]},
		{call: "stripe.withIdInSpec", args: ["$moved.0", "$moved.1"], expect: null, why: "nothing left to move"},
	]}
	"host peers from 0.24.1-gcp.26 on, and the release a billing service is told the broker in": {suite: "stripe", steps: [
		{value: ["0.24.1-gcp.25", "0.24.1-gcp.26", "0.24.1-gcp.30", "0.24.1-metal.2", "0.24.1", "0.25.0", "0.16.1-gcp.23"]},
		{map: {call: "stripe.takesHostPeers", args: ["$"]}, expect: [false, true, true, false, true, true, false]},
		{call: "stripe.prontoPin", args: ["\"github.com/bonisoft3/pronto@v0\": {\n\t\tv: \"v0.24.1-gcp.24\"\n\t}"], expect: "0.24.1-gcp.24"},
		{value: [_k8sRelease, "GCP: schema.#Release & {}\n", "package x\n"]},
		{map: {call: "stripe.releasedTo", args: ["$"]}, expect: ["k8s", "gcp", null]},
		{call: "stripe.withBroker", args: [_k8sRelease, "https://broker.example"]},
		{call: "probe.holdsEach", args: ["$", ["App: services: billing: {\n\tport: 8688\n", "BILLING_BROKER:          \"https://broker.example\"", "GCP:"]], expect: [true, true, false], why: "a cluster's service of the app's own, not a Cloud Run sidecar"},
	]}
	"in a builder turn: the app's own files alone, its payout secret left to the builder's release": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _pro & {studio: true}]},
		{pick: ["states", "finished"], expect: [["done", "applied", "applied", "done", "done", "applied"], true], why: "installed, the plan, generated: no secret step"},
		{call: "shop.kept", args: ["$shop"], expect: null, why: "a turn holds no Secret Manager"},
		{call: "shop.file", args: ["$shop", "billing_spec.cue"]}, {call: "stripe.specOwner", args: ["$"], expect: "", why: "no owner published until the release makes the secret"},
		{call: "shop.connectStripe", args: ["$shop", _broker & {studio: true, release: "before"}], throws: "a release's side is the builder's own", why: "a turn never runs a side of a release, which holds the secret"},
	]}
	"before a release the builder makes: the secret kept and its hash published, the broker named, then generated": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _pro & {studio: true}]},
		{call: "shop.written", args: ["$shop", "release.cue", _gcpRelease]},
		{call: "shop.connectStripe", args: ["$shop", _broker & {release: "before"}]}, {keep: "out"},
		{get: "names"}, {call: "probe.from", args: ["$", 6], expect: ["the release names the broker", "generated and linted"], why: "generated last, once the release names the broker"},
		{use: "out"}, {pick: ["states", "finished"], expect: [["done", "done", "applied", "done", "done", "done", "applied", "done"], true]},
		{call: "shop.file", args: ["$shop", "billing_spec.cue"]}, {call: "stripe.specOwner", args: ["$"]}, {keep: "owner"},
		{call: "shop.keptOwner", args: ["$shop"], expect: "$owner", why: "the spec publishes the kept secret's hash"},
		{call: "shop.file", args: ["$shop", "release.cue"]},
		{call: "probe.includes", args: ["$", "BILLING_BROKER:          \"https://broker.example\""], expect: true},
		{call: "shop.connectStripe", args: ["$shop", _broker & {release: "before"}, "plan"]}, {get: "states"},
		{call: "probe.every", args: ["$", "done"], expect: true, why: "again, nothing to do: the next release changes nothing"},
	]}
	"after a release the builder made: the origin's plans checked, then Stripe's link, then verified": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _pro & {studio: true}]},
		{call: "shop.written", args: ["$shop", "release.cue", _gcpRelease]},
		{call: "shop.connectStripe", args: ["$shop", _broker & {release: "before"}]},
		{call: "shop.connectStripe", args: ["$shop", _live & {release: "after"}]},
		{pick: ["names", "states"], expect: [["the origin publishes its plans"], ["gate"]], why: "nothing published yet: only what is checked once out"},
		{call: "shop.answers", args: ["$shop", {published: true}]},
		{call: "shop.connectStripe", args: ["$shop", _live & {release: "after"}]}, {keep: "out"},
		{get: "states", expect: ["done", "gate"]},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "https://connect\\.stripe\\.com/setup/e/acct_1/xyz"},
		{call: "shop.answers", args: ["$shop", {onboarded: true}]},
		{call: "shop.connectStripe", args: ["$shop", _live & {release: "after"}]},
		{get: "finished", expect: true},
	]}
	"a release that names no broker, and none given, waits to be told one: there is no default": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker & {plan: {id: "pro", name: "Pro", usd: 499}}]},
		{call: "shop.written", args: ["$shop", "release.cue", _gcpRelease]},
		{call: "shop.connectStripe", args: ["$shop", _unbrokered]}, {keep: "out"},
		{get: "states"}, {call: "probe.from", args: ["$", 7], expect: ["gate"]},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "--broker https://"},
		{call: "shop.file", args: ["$shop", "release.cue"], expect: _gcpRelease, why: "unchanged"},
	]}
	"the broker the release names is the one sold through, with no --broker": {suite: "stripe", steps: [
		{call: "shop.stripe"}, {keep: "shop"},
		{call: "shop.connectStripe", args: ["$shop", _broker & {plan: {id: "pro", name: "Pro", usd: 499}}]},
		{call: "stripe.withBroker", args: [_gcpRelease, "https://broker.example"]}, {keep: "release"},
		{call: "shop.written", args: ["$shop", "release.cue", "$release"]},
		{call: "shop.answers", args: ["$shop", {published: true}]},
		{call: "shop.connectStripe", args: ["$shop", _unbrokered]}, {keep: "out"},
		{get: "states"}, {call: "probe.from", args: ["$", 7], expect: ["done", "done", "gate"]},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "https://connect\\.stripe\\.com/setup/e/acct_1/xyz"},
		{call: "stripe.brokerNamed", args: ["$release"], expect: "https://broker.example"},
		{call: "stripe.secretsProject", args: [_gcpRelease], expect: "p-apps"},
		{call: "stripe.secretsProject", args: [_k8sRelease], expect: null, why: "a cluster's release names no project, and there is no default"},
		{call: "stripe.secretsProject", args: [_k8sRelease + "\nbillingSecretsProject: \"p-secrets\"\n"], expect: "p-secrets", why: "a cluster's release says where the secret is kept"},
		{call: "stripe.secretsProject", args: [_gcpRelease + "\nbillingSecretsProject: \"p-secrets\"\n"], expect: "p-secrets", why: "said, it is the one, over the GCP release's"},
	]}
}
