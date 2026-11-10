// What pronto-migrations (README.md) reads besides what pronto's generate writes: the values a change
// needs that the model cannot say, and the check the app's lint runs. bin/pronto-migrations writes
// it into the app's own package (migrations_plugin.cue), where the app's migrations_spec.cue gives
// schemaMigrations its values. make and plan read them; a declaration serves the migration it is
// written for, and goes in the same change: make refuses one no change reads, and so does the lint
// once the model is the snapshot.
package migrations

schemaMigrations: #Migrations & {names: [for k, _ in *code.state.migrations | {} {k}]}

// pronto's own field (code.state.migrations, typed there by pgroll's grammar), named here only so the
// names above can be read in an app that declares no migration yet.
code: state: migrations?: _

#Migrations: {
	// The Postgres schema the app's tables are in.
	schema: *"public" | string & =~"^[a-z_][a-z0-9_]*$"
	// Rows holding a value their column no longer admits (a value gone from its enum, or from its
	// machine's states), by entity and column, carried to one it does. `values` maps each value gone to
	// an admitted one. `set` gives the row's columns SQL expressions of the old row instead, or besides,
	// for a carry that also fills another column. `triggers` are turned off while the rows move, those
	// on put back in their mode: the trigger of any other machine's column `set` moves
	// (trg_<table>_<column>_machine), whose chart the rows never walked, and any of the app's own the
	// move would trip (one that refuses to change a final row, say).
	carry: [Entity=string]: [Column=string]: {
		values?: [string]: string
		set?: [string]: string
		triggers: *[] | [...string]
	}
	// The SQL expression of the row a column's rows take, alone or with the `triggers` the fill
	// would trip, turned off around it as a carry's are. On a column made required, its NULL rows take
	// it first (needed when it has no default a migration can compute). On a column added, the rows
	// that still hold what the replay gave them take it: another column's value, as a rename spelled
	// as a retirement beside an addition keeps its data. Beside a retirement in the same change it is
	// needed; DEFAULT keeps the replay's default instead.
	backfill: [Entity=string]: [Column=string]: string | {value!: string, triggers: *[] | [...string]}
	// Computed, not declared: the names of all the app's pgroll migrations, its own and any written by
	// hand, so make numbers the next after them.
	names: [...string]

	// The app's lint, unified as `loop: surface: checks: schemaMigrations.checks`.
	checks: {
		"migrations": {
			verb: "lint"
			cmds: ["deno run --no-config --allow-read --allow-run --allow-env migrations/migrate.ts check"]
			note: "the snapshot is the model (schema/entities.proto, pronto's facts and its emitted schema), every migration is as make wrote it, migrations/ holds no other .json the ledger would embed, and no declaration is left once its migration is made"
		}
	}
}
