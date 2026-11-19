package tests

// A reduced copy of what upstream pronto v1.5.1's #BuildManifests renders for an app named "app"
// with its default (non-preview) host "app.example.com": one of each kind the engine treats
// differently. The contract test compares the real render.
_fixture: {
	ns:   string
	host: string
	reg:  string
	objects: [
		{apiVersion: "v1", kind: "Namespace", metadata: name: ns},
		{apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: {name: "app-auth-secrets", namespace: ns}},
		{
			apiVersion: "postgresql.cnpg.io/v1"
			kind:       "Cluster"
			metadata:   {name: "app-db", namespace: ns}
			spec:       {instances: 1, imageName: "\(reg)/app-database:17@sha256:\(_d)"}
		},
		{
			apiVersion: "batch/v1"
			kind:       "Job"
			metadata:   {name: "app-initdb", namespace: ns}
			spec: template: spec: containers: [{name: "initdb", image: "\(reg)/app-database:17@sha256:\(_d)"}]
		},
		{
			apiVersion: "batch/v1"
			kind:       "Job"
			metadata:   {name: "app-migrate", namespace: ns}
			spec: template: spec: containers: [{name: "migrate", image: "\(reg)/app-migrate:latest"}]
		},
		{
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "app-crud", namespace: ns}
			spec: template: spec: {
				initContainers: [{name: "wait", image: "\(reg)/app-crud:latest"}]
				containers:     [{name: "crud", image: "\(reg)/app-crud:latest"}]
			}
		},
		{apiVersion: "v1", kind: "Service", metadata: {name: "crud", namespace: ns}},
		{
			apiVersion: "gateway.networking.k8s.io/v1"
			kind:       "Gateway"
			metadata:   {name: "app-gateway", namespace: ns}
			spec: listeners: [{name: "http", protocol: "HTTP", hostname: host}]
		},
	]
}
_d: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
