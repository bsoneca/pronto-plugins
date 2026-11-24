# GlitchTip's objects on a metal cluster (errors/metal.nu manifests), and its database's backups (common/db_backup.nu):
#   ./saytw --script tools.nu nu errors/test/metal_test.nu
use std/assert
use ../metal.nu

let docs = (metal manifests --domain errors.example.com | split row "---\n" | each { from yaml })
let cluster = ($docs | where kind == Cluster | first)
assert ($docs | where kind in [ObjectStore ScheduledBackup] | is-empty) "no backup unless asked"
assert equal ($cluster.spec.plugins? | default []) []

# With --backup: an ObjectStore at the bucket read with the operator's keys, a nightly base backup, 30 days kept, the plugin
# archiving the WAL; the Cluster gains the plugin alone.
let bk = (metal manifests --domain errors.example.com --backup s3://bucket/errors-db --backup-endpoint https://s3.example.com | split row "---\n" | each { from yaml })
let store = ($bk | where kind == ObjectStore | first)
assert equal $store.metadata.name errors-db-backup
assert equal [$store.spec.configuration.destinationPath $store.spec.configuration.endpointURL $store.spec.retentionPolicy] [s3://bucket/errors-db https://s3.example.com 30d]
assert equal $store.spec.configuration.s3Credentials.accessKeyId {name: errors-db-backup-s3, key: ACCESS_KEY_ID}
let sched = ($bk | where kind == ScheduledBackup | first).spec
assert equal [$sched.cluster.name $sched.method $sched.schedule] [errors-db plugin "0 0 6 * * *"]
let bcluster = ($bk | where kind == Cluster | first).spec
assert equal $bcluster.plugins [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true, parameters: {barmanObjectName: errors-db-backup}}]
assert equal ($bcluster | reject plugins) $cluster.spec "the backup adds only the plugin to the Cluster"
assert error { metal manifests --domain errors.example.com --backup s3://bucket/errors-db }

# The metrics' scrape reaches the database, which archiver and backup alerts read.
let np = ($docs | where kind == NetworkPolicy and metadata.name == errors-db | first)
assert (($np.spec.ingress | where {|r| ($r.ports | get port) == [9187] } | length) == 1) "the metrics' scrape reaches the database"
print "errors metal_test: ok"
