# The installer and the driver against a fresh example app: `./saytw --script tools.nu nu
# migrations/test.nu` from the repository's root (cue, nu and deno on the PATH). Installs into an app
# with an emitted proto and pronto's facts, takes the snapshot, then changes the model the way an app
# does (a column retired, a machine's state gone) and makes the migration: the lint refuses the moved
# model, make names the carry it needs, writes the migration once it is declared, and the program reads
# it. Then a migration edited by hand is refused; an index the migration dropped is refused until the
# migration is folded; and a rename is refused.
def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"migrations/test.nu: ($what)"} }
	print $"ok  ($what)"
}

def migrate [app: path, ...args: string] {
	cd $app
	^deno run --no-config --allow-read --allow-write --allow-run --allow-env migrations/migrate.ts ...$args | complete
}

def field [name: string, ordinal: int, type: string, required: bool, more: record = {}] {
	{name: $name, ordinal: $ordinal, retired: false, type: $type, pk: ($ordinal == 1), required: $required} | merge $more
}

# The files pronto's generate writes, as the example app's model has them.
def emitted [app: path, proto: string, fields: list, uniques: list, states: list] {
	$"syntax = \"proto3\";\npackage pronto.entities;\n\nmessage Order {\n($proto)}\n" | save --force --raw ($app | path join schema/entities.proto)
	{version: 1, entities: {Order: {server: true, table: "orders", id: "0x01", fields: $fields, cel: {enums: {}, checks: {}}, uniques: $uniques}}} | to json | save --force --raw ($app | path join .pronto/check-inputs.json)
	let list = ($states | each {|s| $"'($s)'"} | str join ", ")
	$"ALTER TABLE \"orders\" DROP CONSTRAINT IF EXISTS \"orders_status_check\";\nALTER TABLE \"orders\" ADD CONSTRAINT \"orders_status_check\" CHECK \(\"status\" IN \(($list)\)\) NOT VALID;\n" | save --force --raw ($app | path join services/database/migrations/010_machines.sql)
}

def main [] {
	# make names a migration by the day it is made: YYYYMMDD_NNNN_<what it does>.
	let day = (date now | format date "%Y%m%d")
	let first = $"($day)_0001_retire_ref"
	let root = ($env.CURRENT_FILE | path dirname | path dirname)
	let dir = (mktemp --directory | path expand)
	let app = ($dir | path join app)
	for d in [cue.mod schema .pronto services/database/migrations] { mkdir ($app | path join $d) }
	"package demo\n" | save --raw ($app | path join program.cue)
	"module: \"demo.example/app@v0\"\nlanguage: {\n\tversion: \"v0.16.1\"\n}\n" | save --raw ($app | path join cue.mod/module.cue)
	let id = (field id 1 uuid true)
	let status = (field status 2 string true {default: "'draft'"})
	emitted $app "  optional string id = 1 [json_name = \"id\"];\n  optional string status = 2 [json_name = \"status\"];\n  optional string ref = 3 [json_name = \"ref\"];\n" [$id $status (field ref 3 uuid true)] [{name: orders_ref, cols: [ref]}] [draft open closed]

	cd $root
	^sh bin/pronto-migrations $app
	for f in ["migrations/migrate.ts" "migrations/plan.js" "migrations_plugin.cue" "migrations_spec.cue"] {
		check $"the installer writes ($f)" (($app | path join $f) | path exists)
	}
	check "the lint asks for the snapshot first" ((migrate $app check).stderr | str contains "run init")

	let init = (migrate $app init)
	check "init takes the snapshot" ($init.exit_code == 0 and (($app | path join migrations/snapshot.json) | path exists))
	check "the lint passes on the model it took" ((migrate $app check).exit_code == 0)

	# A rerun keeps the app's own spec and regenerates the rest.
	"// the app's own\n" | save --append --raw ($app | path join migrations_spec.cue)
	cd $root
	^sh bin/pronto-migrations $app
	check "a rerun keeps migrations_spec.cue" ((open --raw ($app | path join migrations_spec.cue)) | str ends-with "// the app's own\n")

	# The app retires ref and drops the state draft from its machine.
	emitted $app "  optional string id = 1 [json_name = \"id\"];\n  optional string status = 2 [json_name = \"status\"];\n  reserved 3;\n  reserved \"ref\";\n" [$id $status ((field ref 3 uuid false) | merge {retired: true})] [] [open closed]
	let moved = (migrate $app check)
	check "the lint refuses a model that moved since the snapshot" ($moved.exit_code == 1 and ($moved.stderr | str contains "run `deno run --no-config -A migrations/migrate.ts make <name>`"))
	let wanting = (migrate $app make retire_ref)
	check "make names the carry it needs, and writes nothing" ($wanting.exit_code == 1 and ($wanting.stderr | str contains "declare schemaMigrations.carry.Order.status") and not (($app | path join $"migrations/($first).json") | path exists))

	"package demo\n\nschemaMigrations: carry: Order: status: values: draft: \"open\"\n\nloop: surface: checks: schemaMigrations.checks\n" | save --force --raw ($app | path join migrations_spec.cue)
	let made = (migrate $app make retire_ref)
	check "make writes the migration once the carry is declared" ($made.exit_code == 0 and (($app | path join $"migrations/($first).json") | path exists))
	let ops = (open ($app | path join $"migrations/($first).json") | get operations)
	let up = ($ops.0.sql.up)
	let at = {|s| $up | str index-of $s}
	check "it is one pgroll operation, as pgroll runs a raw SQL operation alone" (($ops | length) == 1)
	check "it relaxes the retired column and drops its index, then carries the rows" ((do $at "\"ref\" DROP NOT NULL") >= 0 and (do $at "DROP INDEX IF EXISTS \"public\".\"orders_ref\"") >= 0 and (do $at "WHEN 'draft' THEN 'open'") > (do $at "DROP INDEX IF EXISTS"))
	check "the lint passes once the migration is made" ((migrate $app check).exit_code == 0)
	cd $app
	let program = (^cue export . -e code.state.migrations --out json | from json)
	check "the program takes it as a pgroll migration, named by its day" (($program | columns) == [$first] and (($program | get $first | get operations | length) == 1))

	# A migration edited by hand no longer sums.
	let kept = (open --raw ($app | path join $"migrations/($first).json"))
	$kept | str replace "'open'" "'closed'" | save --force --raw ($app | path join $"migrations/($first).json")
	check "the lint refuses a migration edited by hand" ((migrate $app check).stderr | str contains $"($first).json: edited since make wrote it")
	$kept | save --force --raw ($app | path join $"migrations/($first).json")

	# The index the first migration dropped, built again by the replay, would be dropped again on every
	# fresh database that still runs it: refused until it is folded, once every database has run it.
	let retired = [$id $status ((field ref 3 uuid false) | merge {retired: true})]
	let proto2 = "  optional string id = 1 [json_name = \"id\"];\n  optional string status = 2 [json_name = \"status\"];\n  reserved 3;\n  reserved \"ref\";\n"
	emitted $app $proto2 $retired [{name: orders_ref, cols: [id]}] [open closed]
	let rebuilt = (migrate $app make unique_id)
	check "make refuses an index a migration dropped, until it is folded" ($rebuilt.exit_code == 1 and ($rebuilt.stderr | str contains $"orders_ref was dropped by ($first)") and ($rebuilt.stderr | str contains $"fold ($first)"))
	let fold = (migrate $app fold $first)
	check "fold deletes the migration and keeps its number" ($fold.exit_code == 0 and not (($app | path join $"migrations/($first).json") | path exists) and ((open --raw ($app | path join migrations/migrations.sum)) | str contains $"folded ($first)"))
	check "and the ledger lists nothing" (not ((open --raw ($app | path join migrations_ledger.cue)) | str contains "code: state"))
	let readded = (migrate $app make unique_id)
	check "then the index is the replay's, and only the snapshot moves" ($readded.exit_code == 0 and ($readded.stdout | str contains "nothing for the ledger"))
	check "the lint passes after the fold" ((migrate $app check).exit_code == 0)

	# A rename is refused, and nothing is written.
	let snapshot = (open --raw ($app | path join migrations/snapshot.json))
	emitted $app "  optional string id = 1 [json_name = \"id\"];\n  optional string state = 2 [json_name = \"state\"];\n  reserved 3;\n  reserved \"ref\";\n" [$id (field state 2 string true {default: "'draft'"}) ((field ref 3 uuid false) | merge {retired: true})] [{name: orders_ref, cols: [id]}] [open closed]
	let renamed = (migrate $app make rename_status)
	check "make refuses a rename" ($renamed.exit_code == 1 and ($renamed.stderr | str contains "refused  Order.status: renamed to state"))
	check "and writes nothing" ((open --raw ($app | path join migrations/snapshot.json)) == $snapshot)
	check "the lint refuses it too" ((migrate $app check).stderr | str contains "Order.status: renamed to state")
	cd $root
	rm -r $dir
}
