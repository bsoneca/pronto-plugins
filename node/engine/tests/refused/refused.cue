package refused

import (
	"list"

	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// Renders the engine refuses: each `objects` is an error, which node/engine/schema_test.nu holds.
// Not vetted with the cases (a package of its own): they fail by design.

_base: {
	name:    "app"
	context: "contabo2"
	api: ssh:          "deploy@node.example"
	hosts: production: "app.example.com"
}

_studio: {
	name:    "studio"
	context: "contabo2"
	api: ssh:          "deploy@node.example"
	hosts: production: "studio.example.com"
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
serviceEgressBoth:         schema.#Release & _base & {services: billing: {port: 8688, egress: [{cidr: "10.0.0.0/8", namespace: "envoy-gateway-system", podLabels: {a: "b"}, port: 80}]}}
serviceEgressNeither:      schema.#Release & _base & {services: billing: {port: 8688, egress: [{port: 80}]}}
serviceEgressNamespace:    schema.#Release & _base & {services: billing: {port: 8688, egress: [{namespace: "kube-system", podLabels: {a: "b"}, port: 80}]}}
serviceEgressNoLabels:     schema.#Release & _base & {services: billing: {port: 8688, egress: [{namespace: "envoy-gateway-system", port: 80}]}}
serviceEgressExceptNs:     schema.#Release & _base & {services: billing: {port: 8688, egress: [{namespace: "envoy-gateway-system", podLabels: {a: "b"}, except: ["10.0.0.0/8"], port: 80}]}}
serviceGoogleProvider:schema.#Release & _base & {services: billing: {port: 8688, google: {provider: "x", serviceAccount: "b@p.iam.gserviceaccount.com"}}}
// PRONTO-1882: jail, google and egress are Studio's builder's alone, refused through #Manifests (the objects themselves).
_google: {provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "b@p.iam.gserviceaccount.com"}
_egress: [{cidr: "10.0.0.0/8", port: 80}]
_nsStudio: {apiVersion: "v1", kind: "Namespace", metadata: name: "studio"}
tenantJail:   (schema.#Manifests & {release: schema.#Release & _base & {services: builder: {port: 8690, jail: true}}, upstream: [_ns]}).objects
tenantGoogle: (schema.#Manifests & {release: schema.#Release & _base & {services: builder: {port: 8690, google: _google}}, upstream: [_ns]}).objects
tenantEgress: (schema.#Manifests & {release: schema.#Release & _base & {services: builder: {port: 8690, egress: _egress}}, upstream: [_ns]}).objects
studioOtherServiceJail:   (schema.#Manifests & {release: schema.#Release & _studio & {services: billing: {port: 8688, jail: true}}, upstream: [_nsStudio]}).objects
studioOtherServiceGoogle: (schema.#Manifests & {release: schema.#Release & _studio & {services: billing: {port: 8688, google: _google}}, upstream: [_nsStudio]}).objects
studioOtherServiceEgress: (schema.#Manifests & {release: schema.#Release & _studio & {services: billing: {port: 8688, egress: _egress}}, upstream: [_nsStudio]}).objects
studioBuilder: (schema.#Manifests & {release: schema.#Release & _studio & {services: builder: {port: 8690, jail: true, google: _google, egress: _egress}}, upstream: [_nsStudio]}).objects
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

// A tenant's release (PRONTO-740 S2): the one a namespace's publisher makes, in the namespace its provisioner made. What it may not
// write or ask is refused (the text of each is held by schema_test.nu); a clean one is `tenantClean`.
_tns:  "studio-owner-game-1a2b3c4d"
_thost: "game-game.example.com"
_tbase: {
	name:    *"app" | string
	context: "contabo2"
	api: ssh:          "deploy@node.example"
	hosts: production: _thost
	tenant: {namespace: _tns, host: _thost}
}
_d: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_tdeploy: {apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "app-crud", namespace: _tns}, spec: template: spec: containers: [{name: "crud", image: "127.0.0.1:5000/\(_tns)/app-crud:release@sha256:\(_d)"}]}
_tgateway: {apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: {name: "app-gateway", namespace: _tns}, spec: listeners: [{name: "http", port: 80, protocol: "HTTP", hostname: _thost}]}
_tm: {
	extra: [...]
	rel: {...}
	_m: schema.#Manifests & {
		release:  schema.#Release & _tbase & rel
		upstream: list.Concat([[_tdeploy, _tgateway], extra])
	}
	objects: _m.objects
}

tenantClean: (_tm & {extra: [], rel: {}}).objects
tenantPreview: (_tm & {extra: [], rel: {preview: "rc", hosts: rc: "rc.example.com"}}).objects
tenantBackups: (_tm & {extra: [], rel: {backups: {bucket: "b", path: "p"}}}).objects
tenantCeilingEgress: (_tm & {extra: [], rel: {tenant: egress: [{ports: [{port: 443}]}]}}).objects
tenantStudioBuilderJail: (schema.#Manifests & {
	release:  schema.#Release & _tbase & {name: "studio", services: builder: {port: 8690, jail: true}}
	app:      {name: "studio", namespace: _tns}
	upstream: [{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "studio-crud", namespace: _tns}, spec: template: spec: containers: [{name: "crud", image: "127.0.0.1:5000/\(_tns)/studio-crud:release@sha256:\(_d)"}]}]
}).objects
tenantClock: (_tm & {extra: [], rel: {services: tick: {port: 9990, clock: {}}}}).objects
tenantBlobs: (_tm & {extra: [], rel: {blobs: {bucket: "bkt-blobs", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "b@p.iam.gserviceaccount.com"}}}).objects
tenantRetireNetworkPolicy: (_tm & {extra: [], rel: {retire: [{kind: "NetworkPolicy", name: "old"}]}}).objects
tenantRetireServiceAccount: (_tm & {extra: [], rel: {retire: [{kind: "ServiceAccount", name: "publisher"}]}}).objects
tenantGatewayHTTPS: (_tm & {extra: [{apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: {name: "other", namespace: _tns}, spec: listeners: [{name: "https", port: 443, protocol: "HTTPS", hostname: _thost}]}], rel: {}}).objects
tenantUnservedKind: (_tm & {extra: [{apiVersion: "v1", kind: "ResourceQuota", metadata: {name: "q", namespace: _tns}}], rel: {}}).objects
tenantExternalImage: (_tm & {extra: [{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "app-x", namespace: _tns}, spec: template: spec: containers: [{name: "x", image: "docker.io/library/nginx:1@sha256:\(_d)"}]}], rel: {}}).objects
tenantOrigin: (_tm & {extra: [], rel: {origin: "https://other.example.com"}}).objects
// What the schema itself refuses: the buildkitd that is not the tenants', a registry moved, a namespace that is the system's, a namespace with no host.
tenantBuildkitOperator:    schema.#Release & _tbase & {tenant: buildkit: "tcp://127.0.0.1:1234"}
tenantBuildkitOperatorSvc: schema.#Release & _tbase & {tenant: buildkit: "tcp://buildkitd.pronto-buildkit.svc:1234"}
tenantRegistryMoved:       schema.#Release & _tbase & {build: registry: host: "evil.example:5000"}
tenantNamespaceKube:       schema.#Release & _tbase & {tenant: namespace: "kube-system"}
tenantNamespaceRegistry:   schema.#Release & _tbase & {tenant: namespace: "pronto-registry"}
tenantNamespaceDefault:    schema.#Release & _tbase & {tenant: namespace: "default"}
tenantHostMissing:         schema.#Release & {name: "app", context: "contabo2", api: ssh: "deploy@node.example", hosts: production: _thost, tenant: namespace: _tns}
