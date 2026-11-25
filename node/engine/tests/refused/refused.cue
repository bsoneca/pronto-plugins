package refused

import "github.com/bsoneca/pronto-plugins/node/engine/schema"

// Renders the engine refuses: each `objects` is an error, which node/engine/schema_test.nu holds.
// Not vetted with the cases (a package of its own): they fail by design.

_base: {
	name:    "app"
	context: "contabo2"
	api: ssh:          "deploy@node.example"
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

// A preview must not take the live host: named `production`, or given production's own host.
previewProduction:       schema.#Release & _base & {preview: "production"}
previewOnProductionHost: schema.#Release & _base & {preview: "rc", hosts: rc: "app.example.com"}
previewOwnHost:          schema.#Release & _base & {preview: "rc", hosts: rc: "rc.app.example.com"}

// A service is only what #Service says: no field it does not know, no reserved variable, no seed out of the app.
serviceUnknownField:    schema.#Release & _base & {services: billing: {port: 8688, privileged: true}}
serviceScratchClimbs:   schema.#Release & _base & {services: billing: {port: 8688, scratch: "/a/../b": "1Gi"}}
serviceScratchSize:     schema.#Release & _base & {services: billing: {port: 8688, scratch: "/workspace": "lots"}}
serviceEgressNoPort:    schema.#Release & _base & {services: billing: {port: 8688, egress: [{cidr: "10.0.0.0/8"}]}}
serviceEgressBadCIDR:   schema.#Release & _base & {services: billing: {port: 8688, egress: [{cidr: "everywhere", port: 80}]}}
serviceGoogleProvider:  schema.#Release & _base & {services: billing: {port: 8688, google: {provider: "x", serviceAccount: "b@p.iam.gserviceaccount.com"}}}
serviceJailNotBool:     schema.#Release & _base & {services: billing: {port: 8688, jail: "yes"}}
serviceReservedEnv:     schema.#Release & _base & {services: billing: {port: 8688, env: SERVICE_JWT: "x"}}
serviceSeedClimbs:      schema.#Release & _base & {services: billing: {port: 8688, files: "/etc/f": "cm", seed: cm: "../x.json"}}
servicePrivilegedPort:  schema.#Release & _base & {services: billing: port: 80}
blobsUnknownField:      schema.#Release & _base & {blobs: {bucket: "b-blobs", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "b@p.iam.gserviceaccount.com", key: "x"}}
serviceDaprPort:        schema.#Release & _base & {services: billing: port: 3500}
serviceMetricsDaprPort: schema.#Release & _base & {services: billing: {port: 8688, metrics: port: 9090}}
serviceSecretReserved:  schema.#Release & _base & {services: billing: {port: 8688, secrets: PORT: "x"}}
serviceFilesDotDot:     schema.#Release & _base & {services: billing: {port: 8688, files: "/etc/../x": "cm"}}
serviceSeedAbsolute:    schema.#Release & _base & {services: billing: {port: 8688, files: "/etc/f": "cm", seed: cm: "/etc/passwd"}}
serviceNamedClock:      schema.#Release & _base & {services: "pulse-clock": port: 8688}
plainOrigin:            schema.#Release & _base & {origin: "http://localhost:18080"} // a passkey is bound to an https origin
metricsExportUnknown:   schema.#Release & _base & {metricsExport: {project: "my-project", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "m@p.iam.gserviceaccount.com", key: "x"}}
