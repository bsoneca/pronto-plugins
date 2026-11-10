// Plane on the node: the plane-ce chart's values, and what the chart does not hold, written from
// devFlow. Its database is a CloudNativePG cluster, as every database on a pronto node is; its door
// the node's Envoy Gateway, which the tunnel already reaches. The values the cluster keeps (the
// app's secret keys, the database's address) are not here: the intent reads them from the cluster
// and passes them to helm (connect.ts).
package devflow

_ns:      devFlow.cluster.namespace
_release: "plane"

planeValues: {
	planeVersion: string | *"v1.4.3"
	ingress: {
		// The node's gateway routes the host (planeObjects); the chart's ingress is Traefik's or
		// nginx's, neither of which a pronto node runs.
		enabled: false
		appHost: devFlow.board.host
	}
	// Cloudflare ends TLS: Plane's links are https.
	ssl: externalTermination: true
	postgres: local_setup: false
	redis: {local_setup: true, volumeSize: "1Gi"}
	rabbitmq: {local_setup: true, volumeSize: "1Gi"}
	minio: {local_setup: true, volumeSize: "10Gi"}
	env: {
		// Never the chart's public example keys.
		requireExplicitSecrets: true
		docstore_bucket:        "uploads"
		doc_upload_size_limit:  "20971520"
		api_key_rate_limit:     "300/minute"
	}
}

planeObjects: [
	{
		apiVersion: "postgresql.cnpg.io/v1"
		kind:       "Cluster"
		metadata: {name: "plane-db", namespace: _ns}
		spec: {
			instances: 1
			storage: size: "5Gi"
			// CloudNativePG writes plane-db-app, whose uri the intent hands Plane.
			bootstrap: initdb: {database: "plane", owner: "plane"}
		}
	},
	{
		apiVersion: "gateway.networking.k8s.io/v1"
		kind:       "Gateway"
		metadata: {name: "plane-gateway", namespace: _ns}
		spec: {
			gatewayClassName: "eg"
			listeners: [{name: "http", port: 80, protocol: "HTTP", hostname: devFlow.board.host, allowedRoutes: namespaces: from: "Same"}]
		}
	},
	{
		apiVersion: "gateway.networking.k8s.io/v1"
		kind:       "HTTPRoute"
		metadata: {name: "plane-route", namespace: _ns}
		spec: {
			hostnames: [devFlow.board.host]
			parentRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway", name: "plane-gateway"}]
			// The chart's own ingress paths (templates/ingress.yaml), one rule each.
			rules: [for r in _routes {
				matches: [{path: {type: "PathPrefix", value: r.path}}]
				backendRefs: [{group: "", kind: "Service", name: "\(_release)-\(r.to)", port: r.port, weight: 1}]
				timeouts: request: "120s"
			}]
		}
	},
]

_routes: [
	{path: "/", to: "web", port: 3000},
	{path: "/api", to: "api", port: 8000},
	{path: "/auth", to: "api", port: 8000},
	{path: "/static/", to: "api", port: 8000},
	{path: "/live/", to: "live", port: 3000},
	{path: "/spaces", to: "space", port: 3000},
	{path: "/god-mode", to: "admin", port: 3000},
	{path: "/\(planeValues.env.docstore_bucket)", to: "minio", port: 9000},
]
