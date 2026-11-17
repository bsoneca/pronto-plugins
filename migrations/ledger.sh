#!/usr/bin/env bash
# The ledger where pgroll cannot run (README.md, "Where pgroll cannot run"): each migration of <dir>, one
# `<name>.sql` per migration as ledger.py writes them, run once, in name order, in one transaction with its
# record. The record is an enum type of the target's own, one label per migration the database has had,
# by its whole name, as pgroll's ledger keys one.
#
#   ledger.sh apply  <dir> <schema>.<type>   after the replay: runs each migration the record lacks
#   ledger.sh record <dir> <schema>.<type>   on a database initdb has just built: records each, runs none
#
# libpq's variables (PGHOST, PGDATABASE, PGUSER, ...) name the database, a Postgres 14 or later; the login
# needs USAGE and CREATE on the record's schema, and owns the record. Each migration's SQL goes through
# psql, which reads its `\` commands and `:name` variables outside quotes. A migration that sorts before
# another of <dir>'s the database has had is refused, as pgroll's runner refuses it: it was made without
# that one's change. Of <dir>'s alone, so a migration of another build (a branch's, on a database several
# builds share) refuses nothing. One run at a time, by an advisory lock a session of its own holds until
# the run ends. Exits non-zero on anything short of all that.
# LEDGER_RETRY_SECONDS is the wait before a failed migration's next try (10).
set -euo pipefail
usage() { echo "usage: ledger.sh apply|record <dir> <schema>.<type>" >&2; exit 2; }
[ $# -eq 3 ] || usage
mode=$1 dir=$2 record=$3
case $mode in apply | record) ;; *) usage ;; esac
[[ $record =~ ^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$ ]] || { echo "ledger: $record is not <schema>.<type>" >&2; exit 2; }
# Quoted wherever SQL names it, so a schema or type Postgres reserves (`order`) is still a name.
quoted="\"${record%%.*}\".\"${record#*.}\""
[ -d "$dir" ] || { echo "ledger: no directory $dir" >&2; exit 2; }
# Byte order, which pgroll's runner reads a ledger in and compares its names by.
export LC_ALL=C

# The migrations' names, each checked safe to splice into SQL before any is: lowercase letters, digits and
# _, and at most the 63 bytes a label holds: Postgres compares a longer one by its first 63 bytes alone, so
# it would read as had. What a name is otherwise (plan.js isName) is the lint's to hold.
names=()
for f in "$dir"/*.sql; do
	[ -f "$f" ] || continue
	name=$(basename "$f" .sql)
	if ! [[ $name =~ ^[a-z0-9_]+$ ]]; then
		echo "ledger: $f names no migration ledger.py writes" >&2
		exit 1
	fi
	if [ ${#name} -gt 63 ]; then
		echo "ledger: $name is longer than the 63 bytes a label holds (plan.js NAME_BYTES)" >&2
		exit 1
	fi
	names+=("$name")
done

# The lock, held by a session fed through a pipe this script keeps open until it ends (so no bare `wait`
# below: it would wait on that session), which no timeout of the role's ends, nor its wait, first.
# A write to the session once it has gone fails (EPIPE) rather than kill the run unsaid (SIGPIPE).
trap '' PIPE
lock=$(mktemp -d)
mkfifo "$lock/in" "$lock/out"
psql -v ON_ERROR_STOP=1 -XqtA <"$lock/in" >"$lock/out" &
exec 3>"$lock/in" 4<"$lock/out"
# Both ends are open: the pipes' names are no longer needed.
rm -rf "$lock"
echo "SET idle_session_timeout = 0; SET statement_timeout = 0; SET lock_timeout = 0; SELECT pg_try_advisory_lock(hashtext('ledger.sh $record'));" >&3 &&
	read -r held <&4 || { echo "ledger: no session to hold the lock in" >&2; exit 1; }
if [ "$held" != t ]; then
	echo "ledger: another run holds $record; waiting for it to end"
	echo "SELECT 1 FROM (SELECT pg_advisory_lock(hashtext('ledger.sh $record'))) l;" >&3 &&
		read -r held <&4 && [ "$held" = 1 ] || { echo "ledger: the lock's session ended" >&2; exit 1; }
fi

# The lock lasts while its session does: one that ended (a reset, a failover, a kill) stops the run before
# its next migration, rather than let another run start beside it.
held() {
	if echo "SELECT 1;" >&3 && read -r alive <&4 && [ "$alive" = 1 ]; then return 0; fi
	echo "ledger: the lock's session ended; stopping before $1" >&2
	exit 1
}

# The record, made where it is not.
psql -v ON_ERROR_STOP=1 -Xq -c "DO \$\$ BEGIN IF to_regtype('$quoted') IS NULL THEN CREATE TYPE $quoted AS ENUM (); END IF; END \$\$" -c "REVOKE ALL ON TYPE $quoted FROM PUBLIC"
# Whether the record holds a migration. One that cannot be read stops the run, never reads as had.
had() {
	local n
	n=$(psql -v ON_ERROR_STOP=1 -XtAc "SELECT count(*) FROM pg_enum WHERE enumtypid = to_regtype('$quoted') AND enumlabel = '$1'") || exit 1
	case $n in 0) return 1 ;; [1-9]*) return 0 ;; *) echo "ledger: the record of $1 reads '$n'" >&2; exit 1 ;; esac
}

if [ "$mode" = record ]; then
	for name in ${names[@]+"${names[@]}"}; do
		psql -v ON_ERROR_STOP=1 -Xq -c "ALTER TYPE $quoted ADD VALUE IF NOT EXISTS '$name'"
	done
	exit 0
fi

# The last of <dir>'s migrations the record holds; '' leads the list, so an empty one still makes a list,
# and no label is empty.
list=""
for name in ${names[@]+"${names[@]}"}; do list="$list,'$name'"; done
latest=$(psql -v ON_ERROR_STOP=1 -XtAc "SELECT coalesce(max(enumlabel COLLATE \"C\"), '') FROM pg_enum WHERE enumtypid = to_regtype('$quoted') AND enumlabel = ANY (ARRAY[''$list])")
for name in ${names[@]+"${names[@]}"}; do
	if had "$name"; then continue; fi
	held "$name"
	if [[ $name < $latest ]]; then
		echo "ledger: $name sorts before $latest, which this database has had; rename it to sort after (migrations/migrate.ts rebase)" >&2
		exit 1
	fi
	echo "ledger: applying $name"
	for try in 1 2 3; do
		# A try whose commit went through but whose answer was lost is recorded: not run again.
		if [ "$try" != 1 ] && had "$name"; then break; fi
		# Live traffic can hold a table a migration alters: a short lock timeout, and the whole migration again.
		if psql -v ON_ERROR_STOP=1 -Xq --single-transaction -c "SET LOCAL lock_timeout = '5s'" -f "$dir/$name.sql" -c "ALTER TYPE $quoted ADD VALUE '$name'"; then break; fi
		if [ "$try" = 3 ]; then exit 1; fi
		echo "ledger: $name failed, again in ${LEDGER_RETRY_SECONDS:-10}s"
		sleep "${LEDGER_RETRY_SECONDS:-10}"
	done
	latest=$name
done
