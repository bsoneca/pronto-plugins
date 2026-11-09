package migrations

import "strings"

_t: #Host & {package: "myapp"}

// An opt-in writes the driver, its rules and the schema, and seeds the app's own migrations_spec.cue.
written: [for p, f in _t.files if !f.seed {p}] & ["migrations/migrate.ts", "migrations/plan.js", "migrations/.gitattributes", "migrations_plugin.cue"]
seeded: [for p, f in _t.files if f.seed {p}] & ["migrations_spec.cue"]

// The schema and the opt-in join the app's package; the schema holds schemaMigrations to
// #Migrations, and the opt-in puts the check in the app's lint.
inPackage:   strings.Contains(_t.files["migrations_plugin.cue"].text, "\npackage myapp\n") & true
heldToSpec:  strings.Contains(_t.files["migrations_plugin.cue"].text, "\nschemaMigrations: #Migrations & {names: ") & true
seedPackage: strings.HasPrefix(_t.files["migrations_spec.cue"].text, "package myapp\n") & true
optedIn:     strings.Contains(_t.files["migrations_spec.cue"].text, "\nloop: surface: checks: schemaMigrations.checks\n") & true

// The defaults: the public schema, nothing to carry or fill, and the check on lint.
_defaults: #Migrations & {}
defaults: {schema: _defaults.schema, carry: _defaults.carry, backfill: _defaults.backfill, verb: _defaults.checks.migrations.verb} & {schema: "public", carry: {}, backfill: {}, verb: "lint"}

// A carry by values, and one by set with the trigger of the other machine it moves.
_carry: #Migrations & {carry: Order: {
	status: values: {draft: "open"}
	stage: {set: {step: "stage", stage: "'open'"}, triggers: ["trg_order_step_machine"]}
}}
carry: {values: _carry.carry.Order.status.values, triggers: _carry.carry.Order.status.triggers, set: _carry.carry.Order.stage.set, setTriggers: _carry.carry.Order.stage.triggers} & {values: {draft: "open"}, triggers: [], set: {step: "stage", stage: "'open'"}, setTriggers: ["trg_order_step_machine"]}

// A schema that is not an identifier is refused.
badSchema: [if (#Migrations & {schema: "Bad-Name"}) == _|_ {"refused"}, "accepted"][0] & "refused"
