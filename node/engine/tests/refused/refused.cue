package refused

import "github.com/bsoneca/pronto-plugins/node/engine/schema"

// Renders the engine refuses: each `objects` is an error, which node/engine/schema_test.nu holds.
// Not vetted with the cases (a package of its own): they fail by design.

_base: {
	name:    "app"
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: production: "app.example.com"
}

_ns: {apiVersion: "v1", kind: "Namespace", metadata: name: "app"}

unserved: (schema.#Manifests & {
	release:  schema.#Release & _base
	upstream: [_ns, {apiVersion: "acme.io/v1", kind: "Widget", metadata: {name: "w", namespace: "app"}}]
}).objects

clean: (schema.#Manifests & {
	release:  schema.#Release & _base
	upstream: [_ns]
}).objects

// An operator version nobody looked at: no row in #Served.
unlookedOperator: (schema.#Manifests & {
	release:  schema.#Release & _base & {operators: dapr: "1.99.0"}
	upstream: [_ns]
}).objects

// An app whose own name is not the release's.
otherApp: (schema.#Manifests & {
	app:      {name: "other", namespace: "app"}
	release:  schema.#Release & _base
	upstream: [_ns]
}).objects

// Retiring what must never be: state, credentials, archives, aliases, cluster-wide kinds, option-like names.
retireCluster:        schema.#Release & _base & {retire: [{kind: "Cluster", name: "app-db"}]}
retirePVC:            schema.#Release & _base & {retire: [{kind: "PersistentVolumeClaim", name: "data"}]}
retireAlias:          schema.#Release & _base & {retire: [{kind: "pvc", name: "data"}]}
retireNamespace:      schema.#Release & _base & {retire: [{kind: "ns", name: "app"}]}
retireExternalSecret: schema.#Release & _base & {retire: [{kind: "ExternalSecret", name: "app-auth-secrets"}]}
retireObjectStore:    schema.#Release & _base & {retire: [{kind: "ObjectStore", name: "app-backup"}]}
retireScheduled:      schema.#Release & _base & {retire: [{kind: "ScheduledBackup", name: "app-nightly"}]}
retireClusterRole:    schema.#Release & _base & {retire: [{kind: "ClusterRole", name: "x"}]}
retireFlagName:       schema.#Release & _base & {retire: [{kind: "Service", name: "--all"}]}
sshOption:            schema.#Release & _base & {api: ssh: "-oProxyCommand=x@y"}
sshBareHost:          schema.#Release & _base & {api: ssh: "node.example"}
