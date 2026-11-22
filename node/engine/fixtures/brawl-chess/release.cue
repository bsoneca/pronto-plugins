package brawlchess

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/brawlchess/node/schema"
)

// A Bonk Chess-shaped app on the engine, at upstream pronto v1.10.1: the renderer (render.enabled) and a
// release on the Contabo node, with only the fields the engine supports today. What apps/brawl-chess still
// asks of it (PRONTO-740 PP2-PP4): replicas (`scale`), database.instances / backup / logins, `services`
// (billing, analyst, flagd, collectors, ticker, standin, notifier), blobs, metricsExport, preview --schema-from,
// and TRUSTED_JWKS. The GKE half is upstream's own `main -e gke`, which the contract test runs for comparison.
_preview: *"" | =~"^[a-z0-9-]+$" @tag(preview)

Node: node.#Release & {
	name:    "brawl-chess"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: {production: "bonk.bsoneca.com", rc: "rc.bonk.bsoneca.com"}
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
