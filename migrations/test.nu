# The installer and the driver against a fresh example app: `./saytw --script tools.nu nu
# migrations/test.nu` from the repository's root (cue, nu and deno on the PATH). Installs into an app
# with an emitted proto and pronto's facts, takes the snapshot, then changes the model the way an app
# does (a column retired, a machine's state gone) and makes the migration: the lint refuses the moved
# model, make names the carry it needs, writes the migration once it is declared, and the program reads
# it. Then a migration edited by hand is refused; an index the migration dropped is refused until the
# migration is folded; a rename is refused; and two branches that each made a migration are merged,
# rebase making the side's again after main's.
def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"migrations/test.nu: ($what)"} }
	print $"ok  ($what)"
}

def migrate [app: path, ...args: string] {
	cd $app
	^deno run --no-config --allow-read --allow-write --allow-run --allow-env migrations/migrate.ts ...$args | complete
}

def --wrapped g [...args] {
	^git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c core.autocrlf=false ...$args | complete
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
	check "the installer refuses an argument it does not know" ((do { ^sh bin/pronto-migrations $app nope=1 } | complete).exit_code == 2)
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

	# Two branches each make a migration. main's (status made optional) is released first; the side
	# branch's (status's default changed) has main's count and a name that sorts before it, so pgroll's
	# runner would refuse it. Merging main in conflicts on the snapshot, the sum and the ledger; rebase
	# takes main's and makes the side's changes again, named after main's.
	let status_open = (field status 2 string true {default: "'open'"})
	emitted $app $proto2 $retired [{name: orders_ref, cols: [id]}] [open closed]
	check "the model is the snapshot again" ((migrate $app check).exit_code == 0)
	cd $app
	g init -q
	g add -A
	g commit -q -m base
	g checkout -q -b side
	emitted $app $proto2 [$id $status_open ((field ref 3 uuid false) | merge {retired: true})] [{name: orders_ref, cols: [id]}] [open closed]
	check "the side branch makes its migration" ((migrate $app make status_default).exit_code == 0)
	cd $app
	g add -A
	g commit -q -m side
	g checkout -q main
	emitted $app $proto2 [$id (field status 2 string false {default: "'draft'"}) ((field ref 3 uuid false) | merge {retired: true})] [{name: orders_ref, cols: [id]}] [open closed]
	check "main makes its migration" ((migrate $app make status_optional).exit_code == 0)
	cd $app
	g add -A
	g commit -q -m main
	let theirs = (ls migrations | where name =~ '_status_optional\.json$' | get name.0 | path basename | str replace '.json' '')
	let ours = $"($day)_0002_status_default"
	check "the side's migration sorts before main's, as pgroll would refuse" ($ours < $theirs)
	g checkout -q side
	check "merging main conflicts on what make wrote" ((g merge -q main).exit_code != 0)
	# generate settles the emitted files: the model is both branches' changes.
	emitted $app $proto2 [$id (field status 2 string false {default: "'open'"}) ((field ref 3 uuid false) | merge {retired: true})] [{name: orders_ref, cols: [id]}] [open closed]
	check "the lint refuses the merged tree" ((migrate $app check).exit_code == 1)
	let rebased = (migrate $app rebase main)
	let names = (ls ($app | path join migrations) | get name | path basename | where {|n| $n =~ '^\d{8}_\d{4}_.*\.json$' } | sort)
	check "rebase keeps main's migration and makes the side's again, named after it" ($rebased.exit_code == 0 and ($names | length) == 2 and ($names.0 == $"($theirs).json") and ($names.1 | str ends-with "_status_default.json") and ($names.1 > $names.0) and not ($"($ours).json" in $names))
	check "the rebased migration holds only the side's change" ((open ($app | path join $"migrations/($names.1)") | get operations.0.sql.up) =~ "SET DEFAULT 'open'" and not ((open ($app | path join $"migrations/($names.1)") | get operations.0.sql.up) =~ "DROP NOT NULL"))
	check "the lint passes after rebase" ((migrate $app check).exit_code == 0)
	cd $root
	rm -r $dir
}
