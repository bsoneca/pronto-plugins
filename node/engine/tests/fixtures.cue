package tests

// A reduced copy of what upstream pronto v1.5.1's #BuildManifests renders for an app named "app"
// with its default (non-preview) host "app.example.com": one of each kind the engine treats
// differently. The contract test compares the real render.
_fixture: {
	// the app's name, which names every object: "app" unless a case is for another (PRONTO-1882: Studio's)
	app:  *"app" | string
	ns:   string
	host: string
	reg:  string
	objects: [
		{apiVersion: "v1", kind: "Namespace", metadata: name: ns},
		{apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: {name: "\(app)-auth-secrets", namespace: ns}},
		{
			apiVersion: "postgresql.cnpg.io/v1"
			kind:       "Cluster"
			metadata:   {name: "\(app)-db", namespace: ns}
			spec: {
				instances: 1
				postgresql: parameters: {wal_level: "logical", max_connections: "200", max_replication_slots: "128"}
				imageName: "\(reg)/\(app)-database:17@sha256:\(_d)"
				managed: roles: [{name: "electric", ensure: "present", login: true}, {name: "authenticator", ensure: "present", login: true, inRoles: ["anon"]}]
				storage: {size: "1Gi", storageClass: "local-path"}
			}
		},
		{
			apiVersion: "batch/v1"
			kind:       "Job"
			metadata:   {name: "\(app)-initdb", namespace: ns}
			spec: template: spec: containers: [{name: "initdb", image: "\(reg)/\(app)-database:17@sha256:\(_d)", command: ["bash", "-c", "set -euo pipefail\necho built"]}]
		},
		{
			apiVersion: "batch/v1"
			kind:       "Job"
			metadata:   {name: "\(app)-migrate", namespace: ns}
			spec: template: spec: containers: [{name: "migrate", image: "\(reg)/\(app)-migrate:latest@sha256:\(_d)"}]
		},
		{
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(app)-crud", namespace: ns}
			spec: {
				replicas: 1
				template: spec: {
					initContainers: [{name: "wait", image: "\(reg)/\(app)-crud:latest@sha256:\(_d)"}]
					containers:     [{name: "crud", image: "\(reg)/\(app)-crud:latest@sha256:\(_d)", resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {cpu: "500m", memory: "256Mi"}}}]
				}
			}
		},
		{
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(app)-caddy", namespace: ns}
			spec: {
				replicas: 1
				template: spec: containers: [{name: "caddy", image: "\(reg)/\(app)-caddy:latest@sha256:\(_d)", resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {cpu: "500m", memory: "256Mi"}}}]
			}
		},
		{
			// Electric: a plain Deployment upstream, one writer all the same
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(app)-electric", namespace: ns}
			spec: {
				replicas: 1
				template: spec: containers: [{name: "electric", image: "\(reg)/\(app)-electric:latest@sha256:\(_d)"}]
			}
		},
		{
			// a single-writer runtime service: the release's default replicas leave it alone
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(app)-ticker", namespace: ns}
			spec: {
				replicas: 1
				strategy: type: "Recreate"
				template: spec: containers: [{name: "ticker", image: "\(reg)/\(app)-ticker:latest@sha256:\(_d)"}]
			}
		},
		{apiVersion: "v1", kind: "Service", metadata: {name: "crud", namespace: ns}},
		{
			apiVersion: "gateway.networking.k8s.io/v1"
			kind:       "Gateway"
			metadata:   {name: "\(app)-gateway", namespace: ns}
			spec: listeners: [{name: "http", port: 80, protocol: "HTTP", hostname: host}]
		},
	]
}
_d: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
