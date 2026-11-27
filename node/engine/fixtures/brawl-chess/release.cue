package brawlchess

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/brawlchess/node/schema"
)

// A Bonk Chess-shaped app on the engine, at upstream pronto v1.18.1: the renderer (render.enabled) and a
// release on the Contabo node, with the fields the engine supports: replicas (`scale`), the database's instances, volume,
// parameters and logins, containers' resources (PP2), and the app's own services (billing, analyst, flagd, collectors,
// ticker, standin, notifier, an exporter on a database login), the blob plane and the metrics export (PP3). What
// apps/brawl-chess still asks of it (PRONTO-740): TRUSTED_JWKS. The GKE half is upstream's
// own `main -e gke`, which the contract test runs for comparison.
_preview: *"" | =~"^[a-z0-9-]+$" @tag(preview)

Node: node.#Release & {
	name:    "brawl-chess"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: {production: "bonk.bsoneca.com", rc: "rc.bonk.bsoneca.com"}
	// n+1 (the stateless Deployments, by upstream's names): three pods, the rc preview two. Electric stays at one: it holds
	// a replication slot and an advisory lock per database.
	scale: {
		"brawl-chess-render": {replicas: 3, preview: 2}
		"brawl-chess-caddy":  {replicas: 3, preview: 2}
		"brawl-chess-crud":   {replicas: 3, preview: 2}
		"brawl-chess-auth":   {replicas: 3, preview: 2}
	}
	// One primary and two standbys, the volume stated, connections, a login for the exporter.
	database: {
		instances: 3
		storage:   "1Gi"
		parameters: max_connections: "200"
		logins: analytics_reader: inRoles: ["analytics_viewer"]
	}
	containerResources: {
		electric: {requests: memory: "256Mi", limits: {cpu: "1", memory: "2Gi"}}
		caddy: limits: {cpu: "1", memory: "512Mi"}
		crud: limits: memory:    "512Mi"
		postgres: requests: cpu: "250m"
		billing: limits: memory: "512Mi"
	}
	// What the compose project runs beside the cluster's own, each its own Deployment.
	services: {
		billing: {
			port: 8688
			env: {
				BILLING_BROKER:          "https://billing.example"
				BILLING_BROKER_INTERNAL: "https://billing.example"
				BILLING_FLAGS:           "origin"
			}
		}
		analyst: port: 8689
		// flagd reads the flags live from the ConfigMap a push writes, seeded once from the file generate wrote.
		flagd: {
			port: 8693
			env: FLAGD_SOURCES:        "[{\"uri\":\"/etc/flags-live/flags.json\",\"provider\":\"file\"}]"
			files: "/etc/flags-live":  "brawl-chess-flags"
			seed: "brawl-chess-flags": "flags/flags.json"
		}
		"perf-collector":     {port: 8687, metrics: port: 9599}
		"journeys-collector": {port: 8686, metrics: port: 9598}
		// mecha's ticker: one writer, poked each minute by a CronJob.
		ticker:   {port: 9998, singleWriter: true, clock: {}}
		standin:  {port: 8699, env: STANDIN_FLAGS: "origin"}
		notifier: {port: 8698, secrets: VAPID_PRIVATE_KEY: "notify-vapid-private-key"}
		exporter: {port: 9399, metrics: port: 9399, database: {login: "analytics_reader", env: "SQLEXPORTER_TARGET_DSN"}}
	}
	blobs: {
		bucket:         "brawl-chess-blobs"
		provider:       "projects/1/locations/global/workloadIdentityPools/contabo/providers/contabo-k3s"
		serviceAccount: "blobs@brawl-chess.iam.gserviceaccount.com"
		audience:       "contabo-k3s"
	}
	metricsExport: {
		project:        "brawl-chess"
		provider:       "projects/1/locations/global/workloadIdentityPools/contabo/providers/contabo-k3s"
		serviceAccount: "metrics@brawl-chess.iam.gserviceaccount.com"
		audience:       "contabo-k3s"
		cluster:        "contabo"
	}
}

App: k8s.#ReleaseSpec & {
	name:      "brawl-chess"
	namespace: Node.namespace
	render: enabled: true
	gateway: {host: Node.host, tls: enabled: false}
}

nodeManifests: (node.#Manifests & {
	app:      App
	release:  Node
	upstream: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
}).objects

// Upstream's own: `main -e gke`.
GKE: k8s.#GKE & {
	context: "contabo2"
	environment: {
		registry:     Node.environment.registry
		domainSuffix: "bsoneca.com"
		storageClass: "local-path"
	}
}
gkeManifests: (k8s.#BuildManifests & {release: App, env: GKE.environment}).manifests

// What the contract test compares: upstream's objects, as the engine's start from.
upstreamObjects: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
