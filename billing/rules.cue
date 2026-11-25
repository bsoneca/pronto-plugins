// What a tenant's billing document may say, and the words an entitlement may use: written once
// here. The plugin's broker reads it as billing/rules.ts (rules_gen.ts); install.ts copies it into
// each app as billing_rules.cue (_billingRules), which its billing_plugin.cue holds the spec to and
// its generate writes the app's billing/rules.ts from (billing.nu's rules).
package billing

rules: {
	// ownerOf the author's payout secret: its hash, base64url.
	owner: "^[A-Za-z0-9_-]{43}$"
	// A plan's id, its name (at most nameMax code points, holding a character nameText matches: one
	// that is not tab, newline, form feed, carriage return or space; spelled out because RE2's \s is
	// ASCII-only while JS's \s and trim() are Unicode), and how often it charges.
	plan: {
		id:       "^[a-z][a-z0-9-]{0,31}$"
		nameMax:  80
		nameText: "[^\\t\\n\\f\\r ]"
		interval: ["month", "year"]
	}
	// The currencies a plan may be priced in, as Stripe names them, and a price in minor units.
	currencies: ["usd", "brl", "eur", "gbp"]
	price: {min: 50, max: 1_000_000}
	// The free trial: how many months, and how many days before its first charge the app reminds
	// the account unless the document says.
	trial: {monthsMin: 1, monthsMax: 23, remindDays: 7}
	// Where a trial stands, as the broker words it in an entitlement and billing.trial keeps it.
	trialStates: ["running", "cancelled", "converted", "ended", "failed"]
	// Where a row of the broker's claim table stands: a claim in progress, or finished for good.
	claimStates: ["claimed", "done"]
	// What may happen to a Stripe event's row (store.ts claims it, one caller at a time, over every replica),
	// declared once and read by both stores: an event (claim, complete, release, remember, expire), the state it
	// finds ("absent" is no row, or none that is live), whether the caller must hold the row's current token, and
	// the state it leaves. Anything not listed is refused: a live claim is busy to every other caller; done is
	// terminal until its retention expires; a stale token completes or releases nothing.
	claimTransitions: [
		{event: "claim", from: "absent", token: "none", to: "claimed"},
		{event: "complete", from: "claimed", token: "holder", to: "done"},
		// Release by the holder: the one way a claim is given back before its lease ends. A caller that is not the
		// holder is refused.
		{event: "release", from: "claimed", token: "holder", to: "absent"},
		{event: "remember", from: "absent", token: "none", to: "done"},
		{event: "remember", from: "claimed", token: "none", to: "done"},
		{event: "remember", from: "done", token: "none", to: "done"},
		// Expiry (the sweep): a row whose time ended goes, claimed or done.
		{event: "expire", from: "claimed", token: "none", to: "absent"},
		{event: "expire", from: "done", token: "none", to: "absent"},
		// Cache invalidation (a remembered marker dropped on purpose, `forget` with no token): a finished row only,
		// never a claim in progress.
		{event: "invalidate", from: "done", token: "none", to: "absent"},
	]
	// How many rows a call may look at to sweep the ones whose time ended, in both stores.
	claimSweep: 100
	// How long a Stripe event is remembered as delivered (Stripe retries for up to three days), and how long one
	// caller's claim on it lasts before another may take it: main.ts and both stores read these, nowhere else.
	claimRetentionMs: 604800000
	claimLeaseMs:     120000
	// The anonymous route probe's own limits, apart from every checkout, trial and probe limit: calls a minute for
	// each client, and for all anonymous probes together, and the biggest body it reads.
	routeLimits: {perClient: 30, global: 120, bodyMax: 4096, windowMs: 60000}
	// The most a request body is read for, in bytes: any request the broker reads a body of, and Stripe's webhook.
	// The live/sandbox dispatcher enforces it (413) before it picks a broker.
	// The App Store's routes (appstore.ts) read more: a signed transaction or notification carries its certificate chain.
	bodyLimits: {request: 4096, webhook: 262144, appstore: 16384}
	// How long the service waits for flagd's answer on the stripe_door flag before it takes the direct route.
	doorLookupTimeoutMs: 300
	// The broker's login role and database name on its own Postgres: metal.nu creates the database with this owner, the
	// broker connects as it, and schema.sql hands the tables to it. Declared once, emitted into schema.sql, which metal.nu reads.
	brokerRole: "billing"
}

rules: {
	owner: string
	plan: {id: string, nameMax: int & >0, nameText: string, interval: [...string]}
	currencies: [...=~"^[a-z]{3}$"]
	price: {min: int & >0, max: int & >price.min}
	trial: {monthsMin: int & >=1, monthsMax: int & >=trial.monthsMin, remindDays: int & >=1}
	trialStates: [...=~"^[a-z]+$"]
	claimStates: [...=~"^[a-z]+$"]
	claimSweep: int & >0
	claimRetentionMs: int & >0
	claimLeaseMs: int & >0 & <claimRetentionMs
	routeLimits: {perClient: int & >0, global: int & >perClient, bodyMax: int & >0, windowMs: int & >0}
	bodyLimits: {request: int & >0, webhook: int & >request, appstore: int & >request}
	doorLookupTimeoutMs: int & >0
	brokerRole: =~"^[a-z_][a-z0-9_]*$"
	claimTransitions: [...{
		event: "claim" | "complete" | "release" | "remember" | "expire" | "invalidate"
		from:  "absent" | or(claimStates)
		token: "none" | "holder"
		to:    "absent" | or(claimStates)
	}]
}
