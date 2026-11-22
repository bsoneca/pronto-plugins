# ledger.sh and ledger.py against a throwaway Postgres: `PG_BIN=<bin> ./saytw --script tools.nu nu
# migrations/ledger_test.nu` from the repository's root, with bash and python3 on the PATH and Postgres's
# server binaries (14 or later) in PG_BIN; CI hands it its runner's newest. The server listens on a
# socket in its own folder alone, so runs beside it and one left behind never meet it, and every file the
# test makes is in that folder, removed when it ends, failing or not.
# Each case starts a database of its own: migrations run once each, in name order, recorded by name, two
# of one day apart; one that sorts before a migration the database has had is refused, one of another
# build is not; `record` runs none; a failing one, or a name past 63 bytes, leaves nothing; a run waits
# for another that holds the lock, and stops once its own lock's session ends; a record in a schema named
# as a keyword works; and what is no migration, no record or no database stops it.

const here = path self .

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"migrations/ledger_test.nu: ($what)"} }
	print $"ok  ($what)"
}

# An external command that must succeed: its output, or an error with what it said.
def must [what: string, run: closure] {
	let r = (do $run | complete)
	if $r.exit_code != 0 { error make {msg: $"migrations/ledger_test.nu: ($what): ($r.stderr)($r.stdout)"} }
	$r.stdout
}

# The runner over `dir`, recording in `record` (app.ledger), in database `db`.
def ledger [db: string, mode: string, dir: path, record: string = "app.ledger"] {
	with-env {PGDATABASE: $db, LEDGER_RETRY_SECONDS: "0"} { ^bash ($here | path join ledger.sh) $mode $dir $record | complete }
}

def sql [db: string, query: string] {
	^psql -XtAq -v ON_ERROR_STOP=1 -d $db -c $query | str trim
}

def labels [db: string] {
	sql $db "SELECT coalesce(string_agg(enumlabel, ' ' ORDER BY enumsortorder), '') FROM pg_enum WHERE enumtypid = to_regtype('app.ledger')"
}

# A database with the app's schema, and a ledger folder of `migrations` (name → SQL).
def fixture [db: string, migrations: record] {
	must $"createdb ($db)" { ^createdb $db } | ignore
	sql $db "CREATE SCHEMA app" | ignore
	let dir = ($env.PGHOST | path join $"migrations-($db)")
	mkdir $dir
	$migrations | transpose name text | each {|m| $m.text | save --raw ($dir | path join $"($m.name).sql") } | ignore
	$dir
}

def main [] {
	let bin = ($env.PG_BIN? | default "")
	if ($bin | is-empty) or not ($bin | path join pg_ctl | path exists) {
		error make {msg: $"migrations/ledger_test.nu: PG_BIN names no Postgres server binaries: '($bin)'"}
	}
	let data = (mktemp --directory | path expand)
	$env.PATH = ($env.PATH | prepend $bin)
	$env.PGHOST = $data
	$env.PGUSER = "postgres"
	try {
		must "initdb" { ^initdb -D ($data | path join db) -U postgres --auth=trust -E UTF8 } | ignore
		must "pg_ctl start" { ^pg_ctl -D ($data | path join db) -o $"-c listen_addresses='' -c unix_socket_directories=($data)" -l ($data | path join log) start -w } | ignore
		cases
	} catch {|e|
		# A server that never started (initdb or the start failed) has nothing to stop; one that started
		# and will not stop is said too, and its folder kept for a look.
		let stop = (^pg_ctl -D ($data | path join db) stop -m immediate | complete)
		if $stop.exit_code != 0 and ($data | path join db postmaster.pid | path exists) {
			error make {msg: $"($e.msg); and the server in ($data) would not stop: ($stop.stderr)"}
		}
		rm -rf $data
		error make {msg: $e.msg}
	}
	must "pg_ctl stop" { ^pg_ctl -D ($data | path join db) stop -m fast } | ignore
	rm -rf $data
}

def cases [] {
	# A database the record holds the first of; the second runs, recorded by name.
	let dir = (fixture one {"20261113_0001_a": "SELECT 1/0; -- had: never again", "20261114_0001_c": "CREATE TABLE app.c (id int);"})
	sql one "CREATE TYPE app.ledger AS ENUM ('20261113_0001_a')" | ignore
	let run = (ledger one apply $dir)
	check "apply runs the migration the record lacks, and only it" ($run.exit_code == 0 and ($run.stdout | str contains "applying 20261114_0001_c") and (sql one "SELECT to_regclass('app.c') IS NOT NULL") == "t")
	check "and records it by its name" ((labels one) == "20261113_0001_a 20261114_0001_c")
	let again = (ledger one apply $dir)
	check "a run again applies none" ($again.exit_code == 0 and not ($again.stdout | str contains "applying"))

	# Two migrations of one day are two names: a database that had one branch's runs main's.
	let dir = (fixture two {"20261117_0001_y": "CREATE TABLE app.y (id int);"})
	sql two "CREATE TYPE app.ledger AS ENUM ('20261117_0001_x')" | ignore
	check "a migration of the same day and count as one the database had still runs" ((ledger two apply $dir).exit_code == 0 and (sql two "SELECT to_regclass('app.y') IS NOT NULL") == "t")

	# One that sorts before another of the folder's the database has had is refused, and nothing runs.
	let dir = (fixture three {"20261116_0005_late": "CREATE TABLE app.late (id int);", "20261117_0001_x": "SELECT 1/0;"})
	sql three "CREATE TYPE app.ledger AS ENUM ('20261117_0001_x')" | ignore
	let late = (ledger three apply $dir)
	check "a migration that sorts before one the database has had is refused" ($late.exit_code == 1 and ($late.stderr | str contains "20261116_0005_late sorts before 20261117_0001_x") and (sql three "SELECT to_regclass('app.late') IS NULL") == "t")

	# A migration of another build (a branch's, on a shared database) refuses nothing.
	let dir = (fixture four {"20261117_0001_y": "CREATE TABLE app.y (id int);"})
	sql four "CREATE TYPE app.ledger AS ENUM ('20261118_0001_branch')" | ignore
	check "one the database had from another build refuses nothing" ((ledger four apply $dir).exit_code == 0 and (labels four) == "20261118_0001_branch 20261117_0001_y")

	# record: a database initdb has just built records every migration and runs none.
	let dir = (fixture five {"20261113_0001_a": "SELECT 1/0;", "20261114_0001_c": "SELECT 1/0;"})
	let rec = (ledger five record $dir)
	check "record makes the record and records each migration, running none" ($rec.exit_code == 0 and (labels five) == "20261113_0001_a 20261114_0001_c")
	check "and then apply runs none" ((ledger five apply $dir).exit_code == 0)

	# A failing migration leaves neither its change nor its record.
	let dir = (fixture six {"20261113_0001_half": "CREATE TABLE app.half (id int); SELECT 1/0;"})
	let failed = (ledger six apply $dir)
	check "a migration that fails leaves neither its change nor its record" ($failed.exit_code == 1 and (sql six "SELECT to_regclass('app.half') IS NULL") == "t" and (labels six) == "")

	# A run waits for another that holds the record's lock, then runs.
	let dir = (fixture seven {"20261114_0001_c": "CREATE TABLE app.c (id int);"})
	let holder = (job spawn { ^bash -c "echo \"SELECT pg_advisory_lock(hashtext('ledger.sh app.ledger')); SELECT pg_sleep(4);\" | psql -XqtA -d seven" | complete })
	# The holder has the lock before the run starts, however late its psql starts.
	mut polls = 0
	while (sql seven "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND database = (SELECT oid FROM pg_database WHERE datname = 'seven')") != "1" {
		if $polls >= 100 { error make {msg: "migrations/ledger_test.nu: the lock's holder never took it"} }
		sleep 100ms
		$polls += 1
	}
	let t0 = (date now)
	let waited = (ledger seven apply $dir)
	let took = ((date now) - $t0)
	check "a run waits while another holds the lock, then runs" ($waited.exit_code == 0 and ($waited.stdout | str contains "waiting") and $took >= 2sec and (labels seven) == "20261114_0001_c")
	check "and leaves no lock behind" ((sql seven "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = 'seven')") == "0")

	# The lock's session ending stops the run before its next migration.
	let dir = (fixture twelve {"20261113_0001_one": "CREATE TABLE app.one (id int); SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND pid <> pg_backend_pid();", "20261113_0002_two": "CREATE TABLE app.two (id int);"})
	let lost = (ledger twelve apply $dir)
	check "the lock's session ending stops the run before the next migration" ($lost.exit_code == 1 and ($lost.stderr | str contains "the lock's session ended; stopping before 20261113_0002_two") and (sql twelve "SELECT to_regclass('app.one') IS NOT NULL AND to_regclass('app.two') IS NULL") == "t")

	# A record in a schema Postgres reserves the name of is still one: every name is quoted.
	let dir = (fixture eleven {"20261113_0001_a": "CREATE TABLE app.a (id int);"})
	sql eleven 'CREATE SCHEMA "order"' | ignore
	check "a record in a schema named as a keyword (order) works" ((ledger eleven apply $dir "order.ledger").exit_code == 0 and (sql eleven "SELECT string_agg(enumlabel, ' ') FROM pg_enum WHERE enumtypid = to_regtype('\"order\".ledger')") == "20261113_0001_a")

	# A name Postgres cannot hold as a label stops the run before any migration, one that sorts before it too.
	let long = $"20261113_0002_('x' | fill --character x --width 50)"
	let dir = (fixture ten {"20261113_0001_first": "CREATE TABLE app.first (id int);", ($long): "CREATE TABLE app.long (id int);"})
	let refused = (ledger ten apply $dir)
	check "a name past the 63 bytes a label holds stops it before any migration runs" ($refused.exit_code == 1 and ($refused.stderr | str contains "63 bytes") and (sql ten "SELECT to_regclass('app.first') IS NULL AND to_regclass('app.long') IS NULL") == "t")

	# What is no migration, no record or no database stops it.
	let dir = (fixture eight {"notes": "SELECT 1;"})
	mv ($dir | path join notes.sql) ($dir | path join "x';DROP.sql")
	let unsafe = (ledger eight apply $dir)
	check "a file whose name is not safe to splice into SQL is refused" ($unsafe.exit_code == 1 and ($unsafe.stderr | str contains "names no migration ledger.py writes"))
	check "a record that is not <schema>.<type> is refused" ((ledger eight apply $dir "ledger; DROP TABLE x").exit_code == 2)
	let ok = (fixture nine {"20261114_0001_c": "SELECT 1;"})
	let gone = (with-env {PGHOST: ($env.PGHOST | path join nowhere)} { ledger nine apply $ok })
	check "no database to reach stops it, saying so" ($gone.exit_code == 1 and ($gone.stderr | str contains "no session to hold the lock in"))

	# ledger.py writes each migration's SQL, and refuses what ledger.sh could not run.
	let src = ($env.PGHOST | path join pgroll)
	let out = ($env.PGHOST | path join sql)
	mkdir $src
	mkdir $out
	"SELECT 'renamed away';" | save --raw ($out | path join 20261113_0001_old_name.sql)
	{operations: [{sql: {up: "SELECT 1;"}}, {sql: {up: "SELECT 2;"}}]} | to json | save --raw ($src | path join 20261113_0001_two.json)
	let wrote = (^python3 ($here | path join ledger.py) $src $out | complete)
	check "ledger.py writes a migration's operations' up, in order" ($wrote.exit_code == 0 and (open --raw ($out | path join 20261113_0001_two.sql)) == "SELECT 1;\n\nSELECT 2;\n")
	check "and removes a .sql no migration wrote, which ledger.sh would run" (not ($out | path join 20261113_0001_old_name.sql | path exists))
	# One more migration, in turn each of what ledger.py refuses.
	let py = {|json: string| $json | save --raw --force ($src | path join 20261113_0002_bad.json); ^python3 ($here | path join ledger.py) $src $out | complete }
	check "and refuses one with an operation that is not raw SQL" ((do $py ({operations: [{add_column: {table: "t"}}]} | to json)).stderr | str contains "not raw SQL")
	check "and one that pgroll would run out of order (onComplete)" ((do $py ({operations: [{sql: {up: "SELECT 1;", onComplete: true}}]} | to json)).stderr | str contains "onComplete")
	check "and a file that is no migration (no operations)" ((do $py ({model: {}} | to json)).stderr | str contains "no pgroll migration")
}
