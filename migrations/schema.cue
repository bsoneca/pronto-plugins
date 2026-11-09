// What pronto-migrations (README.md) reads besides what pronto's generate writes: the values a change
// needs that the model cannot say, and the check the app's lint runs. bin/pronto-migrations writes
// it into the app's own package (migrations_plugin.cue), where the app's migrations_spec.cue gives
// schemaMigrations its values. Only make and plan read them; a declaration is for the next migration,
// and can go once make has written it.
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
	// for a carry that also fills another column. `triggers` are disabled while the rows move: the
	// trigger of any other machine's column `set` moves (trg_<table>_<column>_machine), whose chart the
	// rows never walked.
	carry: [Entity=string]: [Column=string]: {
		values?: [string]: string
		set?: [string]: string
		triggers: *[] | [...string]
	}
	// A column made required, with no default: the SQL expression its NULL rows take first.
	backfill: [Entity=string]: [Column=string]: string
	// Computed, not declared: the names of all the app's pgroll migrations, its own and any written by
	// hand, so make numbers the next after them.
	names: [...string]

	// The app's lint, unified as `loop: surface: checks: schemaMigrations.checks`.
	checks: {
		"migrations": {
			verb: "lint"
			cmds: ["deno run --no-config --allow-read migrations/migrate.ts check"]
			note: "the snapshot is the model (schema/entities.proto and pronto's facts), every migration is as make wrote it, and the ledger lists them"
		}
	}
}
