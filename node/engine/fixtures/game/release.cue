package game

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/game/node/schema"
)

// A Studio game as its builder writes the release.cue it publishes (PRONTO-740 S4): the engine's tags bind the tenant's namespace and its one
// address into Node.tenant, and the game's own host is that address. Released with no tags it is an ordinary release on the node.
_preview:    *"" | =~"^[a-z0-9-]+$" @tag(preview)
_tenant:     *"" | string @tag(tenant)
_tenantHost: *"" | string @tag(tenantHost)

Node: node.#Release & {
	name:    "game"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: production: *"game.bsoneca.com" | string
	if _tenant != "" {
		tenant: {namespace: _tenant, host: _tenantHost}
		hosts: production: _tenantHost
	}
}

App: k8s.#ReleaseSpec & {
	name:      "game"
	namespace: Node.namespace
	render: enabled: false
	gateway: {host: Node.host, tls: enabled: false}
}

nodeManifests: (node.#Manifests & {
	app:      App
	release:  Node
	upstream: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
}).objects
