package brawlchess

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/brawlchess/node/schema"
)

// A Bonk Chess-shaped app on the engine, at upstream pronto v1.10.1: the renderer (render.enabled) and a
// release on the Contabo node, with only the fields the engine supports today: replicas (`scale`), the database's
// instances, volume, parameters and logins (PP2) and containers' resources. What apps/brawl-chess still asks of it
// (PRONTO-740 PP3-PP4): `services` (billing, analyst, flagd, collectors, ticker, standin, notifier), blobs,
// metricsExport, preview --schema-from, and TRUSTED_JWKS. The GKE half is upstream's own `main -e gke`, which the contract test runs for comparison.
_preview: *"" | =~"^[a-z0-9-]+$" @tag(preview)

Node: node.#Release & {
	name:    "brawl-chess"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: {production: "bonk.bsoneca.com", rc: "rc.bonk.bsoneca.com"}
	// n+1 (the services' Deployments, by upstream's names): three pods, the rc preview two.
	scale: {
		"brawl-chess-electric": {replicas: 3, preview: 2}
		"brawl-chess-render":   {replicas: 3, preview: 2}
		"brawl-chess-caddy":    {replicas: 3, preview: 2}
		"brawl-chess-crud":     {replicas: 3, preview: 2}
		"brawl-chess-auth":     {replicas: 3, preview: 2}
	}
	// One primary and two standbys, the volume stated, connections for three Electric pods, a login for the exporter.
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
