# restore.nu: the node's database backups, proved and used (README.md, "The node release engine",
# Backups). Moved from pronto's tools/metal/restore-drill.sh, parametrized by the app: the Cluster is
# `<app>-db`, the ObjectStore `<app>-backup`, both in the app's namespace (what node.#Backups emits).
#
#   nu node/restore.nu drill [--app <dir>] [--keep]
#       a base backup now, restored into the namespace restore-drill, every table's rows compared with
#       the live database's at the backup; the namespace is deleted at the end (--keep leaves it)
#   nu node/restore.nu restore --to <namespace> [--app <dir>] [--target-time <timestamp>]
#       a recovery Cluster `<app>-restore` in <namespace> from the store, for a real incident; switching
#       the app to it stays a human step

use runtime.nu
use render.nu
use tunnel.nu

def --wrapped k [...args: string]: any -> string {
	let input = $in
	let r = ($input | ^kubectl ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl ($args | first 4 | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}

def --wrapped kj [...args: string]: nothing -> any { k ...$args -o json | from json }

# Every table's rows, one `schema.table count` a line, sorted: what a restore must have back.
def counts [namespace: string, pod: string, db: string]: nothing -> table<table: string, rows: int> {
	let sql = "SELECT format('%I.%I', table_schema, table_name), (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema') AND table_schema NOT LIKE 'pgroll%' ORDER BY 1"
	k -n $namespace exec -i $pod -c postgres -- psql -U postgres -d $db -XAtF ' ' -c $sql
		| lines | where {|l| $l | str trim | is-not-empty }
		| each {|l| let p = ($l | split row " "); {table: $p.0, rows: ($p.1 | into int)} }
		| sort-by table
}

# The tables with fewer rows after the restore than at the backup (one the app wrote to since may have more).
export def shortfall [before: table, after: table]: nothing -> list<string> {
	$before | each {|b|
		let a = ($after | where table == $b.table | get -o 0.rows | default 0)
		if $a < $b.rows { $"($b.table): ($b.rows) at the backup, ($a) restored" }
	} | compact
}

# The recovery Cluster: the source's image, ids and storage; bootstrapped from the store's latest state
# (that backup and the WAL after it) or the moment `target_time` names; it writes no archive.
export def recovery-cluster [source: record, name: string, origin: string, store: string, --target-time: string = ""]: nothing -> record {
	let recovery = ({source: "origin"} | merge (if ($target_time | is-empty) { {} } else { {recoveryTarget: {targetTime: $target_time}} }))
	{
		apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster", metadata: {name: $name}
		spec: {
			imageName: $source.spec.imageName
			postgresUID: $source.spec.postgresUID
			postgresGID: $source.spec.postgresGID
			storage: {size: $source.spec.storage.size, storageClass: $source.spec.storage.storageClass}
			instances: 1
			bootstrap: {recovery: $recovery}
			externalClusters: [{name: "origin", plugin: {name: "barman-cloud.cloudnative-pg.io", parameters: {barmanObjectName: $store, serverName: $origin}}}]
		}
	}
}

# The store and its credentials' Secret copied into `namespace`, a restore reading them there.
def copy-store [from: string, to: string, store: string] {
	let obj = (kj -n $from get objectstore $store)
	let secret = $obj.spec.configuration.s3Credentials.accessKeyId.name
	let s = (kj -n $from get secret $secret)
	{apiVersion: $s.apiVersion, kind: $s.kind, type: $s.type, data: $s.data, metadata: {name: $s.metadata.name}} | to json | k -n $to apply -f - | ignore
	# no retentionPolicy: a store another namespace reads must never prune the one it copies
	{apiVersion: $obj.apiVersion, kind: $obj.kind, spec: ($obj.spec | reject -o retentionPolicy), metadata: {name: $obj.metadata.name}} | to json | k -n $to apply -f - | ignore
}

# The drill: how long a backup and a restore take, and whether every table's rows came back.
export def drill [app: string, namespace: string, --scratch: string = "restore-drill", --keep] {
	let cluster = $"($app)-db"
	let store = $"($app)-backup"
	k -n $namespace get objectstore $store | ignore
	let db = (k -n $namespace get cluster $cluster -o jsonpath='{.spec.bootstrap.initdb.database}')
	let primary = (k -n $namespace get cluster $cluster -o jsonpath='{.status.currentPrimary}')
	if (^kubectl get namespace $scratch | complete).exit_code == 0 {
		error make {msg: $"namespace ($scratch) exists: a drill is running, or --keep left one"}
	}
	# 1. A base backup now, so the drill restores today's data.
	let name = $"drill-(date now | format date '%Y%m%d%H%M%S')"
	let t0 = (date now)
	{apiVersion: "postgresql.cnpg.io/v1", kind: "Backup", metadata: {name: $name, namespace: $namespace}, spec: {cluster: {name: $cluster}, method: "plugin", pluginConfiguration: {name: "barman-cloud.cloudnative-pg.io"}}}
		| to json | k apply -f - | ignore
	loop {
		let phase = (k -n $namespace get backup $name -o jsonpath='{.status.phase}')
		if $phase == "completed" { break }
		if $phase == "failed" { error make {msg: (k -n $namespace get backup $name -o jsonpath='{.status.error}')} }
		sleep 5sec
	}
	let backup_s = (((date now) - $t0) / 1sec | math round)
	# The WAL that closes the backup, archived, so the restore reaches it.
	k -n $namespace exec $primary -c postgres -- psql -U postgres -XAtc "SELECT pg_switch_wal()" | ignore
	let before = (counts $namespace $primary $db)
	# 2. The restore, into a scratch Cluster that reads the store and writes none.
	k create namespace $scratch | ignore
	try {
		copy-store $namespace $scratch $store
		let source = (kj -n $namespace get cluster $cluster)
		recovery-cluster $source "drill-db" $cluster $store | to json | k -n $scratch apply -f - | ignore
		let t1 = (date now)
		loop {
			if (k -n $scratch get cluster drill-db -o jsonpath='{.status.readyInstances}' | str trim) == "1" { break }
			if ((date now) - $t1) > 1hr { error make {msg: "the restore was not ready in an hour"} }
			sleep 5sec
		}
		let restore_s = (((date now) - $t1) / 1sec | math round)
		let after = (counts $scratch "drill-db-1" $db)
		# 3. What came back.
		let size = (k -n $scratch exec drill-db-1 -c postgres -- psql -U postgres -XAtc $"SELECT pg_size_pretty\(pg_database_size\('($db)'\)\)" | str trim)
		print $"backup ($name): ($backup_s)s; restore of ($db) \(($size)\): ($restore_s)s; tables: ($before | length)"
		let short = (shortfall $before $after)
		if ($short | is-not-empty) { error make {msg: $"rows missing after the restore:\n($short | str join "\n")"} }
		print "every table has at least the rows it had at the backup"
	} finally {
		if not $keep {
			# checked: a scratch namespace that is not deleted holds a restored database, and says so
			let d = (^kubectl delete namespace $scratch --wait=false | complete)
			if $d.exit_code != 0 { error make {msg: $"deleting the scratch namespace ($scratch) failed, so a restored database is still there: ($d.stderr | str trim)"} }
		}
	}
}

# A recovery Cluster for a real incident, in `to`.
export def restore-to [app: string, from: string, to: string, --target-time: string = ""] {
	if $to == $from { error make {msg: $"--to is the namespace the database lives in (($from)): restore into another"} }
	let cluster = $"($app)-db"
	let store = $"($app)-backup"
	k get namespace $to | ignore
	copy-store $from $to $store
	let source = (kj -n $from get cluster $cluster)
	recovery-cluster $source $"($app)-restore" $cluster $store --target-time $target_time | to json | k -n $to apply -f - | ignore
	print $"cluster/($app)-restore in ($to) is recovering from ($store)(if ($target_time | is-not-empty) { $' up to ($target_time)' }); switching ($app) to it is a human step"
}

# Both verbs run against the node, over its tunnel, for the app in the folder (or `--app`) at production's namespace.
def main [
	verb: string               # drill | restore
	--app: string
	--to: string = ""          # restore: the namespace for the recovery Cluster
	--target-time: string = "" # restore: recover up to this moment (RFC 3339)
	--keep                     # drill: leave the scratch namespace
] {
	let app_info = (runtime resolve-app $app)
	let node = (render node-config $app_info.cue_path "")
	if ($node.backups? | default null) == null { error make {msg: $"($app_info.name) declares no Node.backups"} }
	if $verb not-in [drill restore] { error make {msg: $"unknown verb ($verb): drill | restore"} }
	if $verb == "restore" and ($to | is-empty) { error make {msg: "restore needs --to <namespace>"} }
	tunnel with-tunnel $node.api $node.build {|fwd|
		let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
		try {
			with-env {KUBECONFIG: $kubeconfig} {
				if $verb == "drill" { drill $node.name $node.namespace --keep=$keep } else { restore-to $node.name $node.namespace $to --target-time $target_time }
			}
		} finally { rm -f $kubeconfig }
	}
}
