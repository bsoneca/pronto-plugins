package __PACKAGE__

// What this app sells, through the operator's billing broker. `owner` is the
// hash of the secret its author sets up payouts with (pronto-billing's
// billing/owner.ts new); the secret stays with the author. Prices are in
// minor units, the first the default.
billing: {
	// The broker on this machine, with a stand-in for Stripe, on a port of
	// this app's own (billing_plugin.cue); a release names the operator's.
	broker: "http://localhost:28463"
	owner:  "__OWNER__"
	plans: {}
	// Accounts given a plan free, through the end of a day (UTC):
	// "<account>": {<plan>: "2027-01-31"}
	grants: {}
	// An opt-in free trial of some plans, charged from the day it ends unless cancelled before.
	// An account chooses it and consents on a screen that says the price and the date; one trial
	// an account, and none for one that has ever held a plan. Add `_billingTrialFlag` (below) so
	// the app turns it on with a flag, not a deploy:
	// trial: {months: 3, plans: ["analysis"], remindDays: 7}
}

// The billing migration's name, among the app's own: pgroll applies them in
// name order and refuses one named before the last it applied, so name it
// after the app's latest (12_billing after 11_something).
_billingMigration: "billing_01"
// The grants' migration (billing_plugin.cue), after it.
_billingGrantsMigration: "billing_02"
// The free trial's migration (billing_plugin.cue), after those. It only adds a table and
// functions, so an app that offers no trial carries it unused.
_billingTrialMigration: "billing_03"
// The flag the trial is behind, off or on per account by pronto-flags (needs _billingFlags);
// empty, the trial is on wherever `billing.trial` is set:
// _billingTrialFlag: "free_trial"

// The Subscription table's identity, which pronto's mint stamps here: the
// rest of it is pronto-billing's (billing_plugin.cue).
code: state: entities: {
	Subscription: {}
}
