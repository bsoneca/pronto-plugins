package aprende

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/aprende/node/schema"
)

// A copy of what an app's release.cue holds for the node engine (design section 1.1), with the
// GKE half upstream's own `main -e gke` reads, which the contract test runs for comparison.
_preview: *"" | =~"^[a-z0-9-]+$" @tag(preview)

Node: node.#Release & {
	name:    "aprende"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	registry: {project: "brawl-chess", location: "europe-west3"}
	hosts: {production: "aprende.bsoneca.com", rc: "rc.aprende.bsoneca.com"}
	hooks: afterJobs: [["echo", "restate"]]
}

App: k8s.#ReleaseSpec & {
	name:      "aprende"
	namespace: Node.namespace
	render: enabled: false
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
		registry:     Node.registry.url
		domainSuffix: "bsoneca.com"
		storageClass: "local-path"
	}
}
gkeManifests: (k8s.#BuildManifests & {release: App, env: GKE.environment}).manifests

// What the contract test compares: upstream's objects, as the engine's start from.
upstreamObjects: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
