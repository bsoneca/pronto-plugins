// What a tenant's billing document may say, and the words an entitlement may use: written once
// here, read by the broker and the service (rules.ts, which rules_gen.ts writes from this) and by
// every app's billing_plugin.cue (billing_rules.cue, which install.ts writes from rules.ts).
package billing

rules: {
	// ownerOf the author's payout secret: its hash, base64url.
	owner: "^[A-Za-z0-9_-]{43}$"
	// A plan's id, its name's length, and how often it charges.
	plan: {
		id:       "^[a-z][a-z0-9-]{0,31}$"
		nameMax:  80
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
}

rules: {
	owner: string
	plan: {id: string, nameMax: int & >0, interval: [...string]}
	currencies: [...=~"^[a-z]{3}$"]
	price: {min: int & >0, max: int & >price.min}
	trial: {monthsMin: int & >=1, monthsMax: int & >=trial.monthsMin, remindDays: int & >=1}
	trialStates: [...=~"^[a-z]+$"]
}
