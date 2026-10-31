package __PACKAGE__

// What this app sells, through the operator's billing broker. `owner` is the
// hash of the secret its author sets up payouts with (pronto-billing's
// billing/owner.ts new); the secret stays with the author. Prices are in
// minor units, the first the default.
billing: {
	// The broker on this machine, with a stand-in for Stripe; a release names
	// the operator's.
	broker: "http://localhost:28463"
	owner:  "__OWNER__"
	plans: {}
	// Accounts given a plan free, through the end of a day (UTC):
	// "<account>": {<plan>: "2027-01-31"}
	grants: {}
}

// The billing migration's name, among the app's own: pgroll applies them in
// name order and refuses one named before the last it applied, so name it
// after the app's latest (12_billing after 11_something).
_billingMigration: "billing_01"
// The grants' migration (billing_plugin.cue), after it.
_billingGrantsMigration: "billing_02"

// The Subscription table's identity, which pronto's mint stamps here: the
// rest of it is pronto-billing's (billing_plugin.cue).
code: state: entities: {
	Subscription: {
	}
}
