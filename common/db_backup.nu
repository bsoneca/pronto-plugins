# The off-node backup of a CloudNativePG cluster on a metal node, one definition for every plugin that makes one
# (analytics, errors and the two brokers' databases): an ObjectStore at `s3://bucket/folder` on the S3 endpoint, its
# keys the Secret `<db>-backup-s3` (ACCESS_KEY_ID, ACCESS_SECRET_KEY) that the operator puts in the namespace, a base
# backup nightly at 06:00 UTC (none at once: one taken while the archiver's sidecar restarts the instance fails) and
# the WAL archived as it fills by the barman-cloud plugin, kept 30 days: the node's other databases' backups
# (pronto's database.backup).
#
# A cluster that is applied without it loses it, so each plugin's `main` takes the backup as a required pair of
# flags (`require`), or an explicit --no-backup, and checks after the apply that the cluster holds it (`verify`).

export const plugin = "barman-cloud.cloudnative-pg.io"

# `--backup` and `--backup-endpoint` together, or a --no-backup that says so: never neither, which is how a
# cluster applied by an older command line silently stopped being backed up.
export def require [backup: string, endpoint: string, no_backup: bool, db: string] {
	if $no_backup {
		if ($backup | is-not-empty) or ($endpoint | is-not-empty) { error make {msg: "--no-backup is for a run with no --backup"} }
		print $"WARNING: ($db) is applied with no off-node backup: WAL stays on the node, and a cluster that had one loses it"
		return
	}
	if ($backup | is-empty) or ($endpoint | is-empty) {
		error make {msg: $"($db) has no backup: pass --backup s3://bucket/folder and --backup-endpoint https://…, or --no-backup to say it has none"}
	}
}

# The objects of the backup of `db`, and what its Cluster's spec gains: `{secret, cluster, objects}`.
export def objects [
	--db: string
	--bucket: string      # s3://bucket/folder
	--endpoint: string    # https://…
	--namespace: string
	--part-of: string     # The plugin, as its labels name it: pronto-analytics
]: nothing -> record {
	let store = $"($db)-backup"
	let secret = $"($db)-backup-s3"
	let meta = {|name: string| {name: $name, namespace: $namespace, labels: {"app.kubernetes.io/part-of": $part_of, "app.kubernetes.io/name": $name}} }
	{
		secret: $secret
		cluster: {plugins: [{name: $plugin, isWALArchiver: true, parameters: {barmanObjectName: $store}}]}
		objects: [
			{
				apiVersion: "barmancloud.cnpg.io/v1", kind: "ObjectStore", metadata: (do $meta $store)
				spec: {
					retentionPolicy: "30d"
					configuration: {
						destinationPath: $bucket
						endpointURL: $endpoint
						s3Credentials: {
							accessKeyId: {name: $secret, key: "ACCESS_KEY_ID"}
							secretAccessKey: {name: $secret, key: "ACCESS_SECRET_KEY"}
						}
						data: {compression: "gzip"}
						wal: {compression: "gzip"}
					}
				}
			}
			{
				apiVersion: "postgresql.cnpg.io/v1", kind: "ScheduledBackup", metadata: (do $meta $db)
				spec: {schedule: "0 0 6 * * *", immediate: false, backupOwnerReference: "self", cluster: {name: $db}, method: "plugin", pluginConfiguration: {name: $plugin}}
			}
		]
	}
}

# The backups' keys must be in the namespace before the WAL archiver starts, or every WAL fails to archive.
export def keys-present [remote: closure, kubectl: string, namespace: string, secret: string] {
	let keys = ("" | do $remote $"($kubectl) get secret ($secret) -n ($namespace) --ignore-not-found -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}'" | split row " " | where {|k| $k != ""})
	if not ("ACCESS_KEY_ID" in $keys and "ACCESS_SECRET_KEY" in $keys) {
		error make {msg: $"($secret) in ($namespace) lacks ACCESS_KEY_ID and ACCESS_SECRET_KEY: put the bucket's keys there first"}
	}
}

# After the apply: the live Cluster archives through the plugin, and its ScheduledBackup and ObjectStore are there.
# Fails otherwise, so a run that dropped the backup says so instead of finishing green.
export def verify [remote: closure, kubectl: string, namespace: string, db: string] {
	let plugins = ("" | do $remote $"($kubectl) get cluster.postgresql.cnpg.io/($db) -n ($namespace) -o jsonpath='{.spec.plugins[*].name}'" | str trim)
	if $plugin not-in ($plugins | split row " ") { error make {msg: $"($db) in ($namespace) has no ($plugin) in spec.plugins after the apply: its WAL is not archived off the node"} }
	let sched = ("" | do $remote $"($kubectl) get scheduledbackup.postgresql.cnpg.io/($db) -n ($namespace) -o jsonpath='{.spec.cluster.name}'" | str trim)
	if $sched != $db { error make {msg: $"($db) in ($namespace) has no ScheduledBackup after the apply"} }
	let store = ("" | do $remote $"($kubectl) get objectstore.barmancloud.cnpg.io/($db)-backup -n ($namespace) -o jsonpath='{.metadata.name}'" | str trim)
	if $store != $"($db)-backup" { error make {msg: $"($db) in ($namespace) has no ObjectStore ($db)-backup after the apply"} }
	print $"($db): backup configured \(plugin, ScheduledBackup, ObjectStore)"
}
