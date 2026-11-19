#!/usr/bin/env nu
# Run with: nu node/engine/restore_test.nu
#
# restore.nu's pure parts: what a restore must have back, and the recovery Cluster made from the live
# one. The drill itself needs a cluster and a bucket: it runs on adoption of each app (README.md).

use std/assert
use restore.nu [shortfall recovery-cluster restore-to]

def main [] {
	print "Running node restore tests...\n"
	test_shortfall_names_the_tables_with_fewer_rows
	test_recovery_cluster_reads_the_store_and_writes_none
	test_recovery_to_a_moment
	test_restore_refuses_the_namespace_the_database_lives_in
	print "\nAll node restore tests passed."
}

def test_shortfall_names_the_tables_with_fewer_rows [] {
	print "test a table with fewer rows after the restore is named, one with more is not..."
	let before = [{table: "public.a", rows: 10} {table: "public.b", rows: 5} {table: "public.c", rows: 0}]
	let after = [{table: "public.a", rows: 10} {table: "public.b", rows: 3}]
	assert equal (shortfall $before $after) ["public.b: 5 at the backup, 3 restored"]
	assert equal (shortfall $before ($after | append {table: "public.b", rows: 9} | where rows != 3)) []
}

def live []: nothing -> record {
	{spec: {imageName: "reg/app-database:17@sha256:aa", postgresUID: 999, postgresGID: 999, storage: {size: "1Gi", storageClass: "local-path"}, instances: 3}}
}

def test_recovery_cluster_reads_the_store_and_writes_none [] {
	print "test the recovery Cluster keeps the image and storage, starts from the store and has no archiver..."
	let c = (recovery-cluster (live) "drill-db" "app-db" "app-backup")
	assert equal $c.metadata.name "drill-db"
	assert equal $c.spec.instances 1
	assert equal $c.spec.imageName "reg/app-database:17@sha256:aa"
	assert equal $c.spec.bootstrap.recovery {source: "origin"}
	assert equal $c.spec.externalClusters.0.plugin.parameters {barmanObjectName: "app-backup", serverName: "app-db"}
	assert ($c.spec | get -o plugins | is-empty) "it archives nothing"
}

def test_recovery_to_a_moment [] {
	print "test a target time becomes the recovery target..."
	let c = (recovery-cluster (live) "app-restore" "app-db" "app-backup" --target-time "2026-11-19T10:00:00Z")
	assert equal $c.spec.bootstrap.recovery.recoveryTarget.targetTime "2026-11-19T10:00:00Z"
}

def test_restore_refuses_the_namespace_the_database_lives_in [] {
	print "test restore into the namespace of the live database is refused..."
	let msg = (try { restore-to app aprende aprende; "no error" } catch {|e| $e.msg })
	assert ($msg | str contains "restore into another") $msg
}
