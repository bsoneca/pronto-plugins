package studio

import (
	k8s "github.com/bonisoft3/pronto/k8s/schema"
	node "local.test/studio/node/schema"
)

// A Studio-shaped app on the engine, as apps/studio/release.cue of bsoneca/pronto asks of the node: the renderer, the database's
// backups, Electric's and the builder's resources, flagd reading its flags live (provider fileinfo) and the builder, a pod
// that runs others' code in a jail (a user namespace, an unmasked /proc, AppArmor and seccomp unconfined), signs in to Google
// with the token of its own service account, reaches the node's API, the internet on 80 and the cluster's gateways on
// their ports, and has a workspace of its own. The GKE half is upstream's own `main -e gke`, which the contract test runs for
// comparison.
_preview: *"" | =~"^[a-z0-9-]+$" @tag(preview)

Node: node.#Release & {
	name:    "studio"
	preview: _preview
	context: "contabo2"
	api: ssh: "deploy@node.example"
	hosts: {production: "studio.bsoneca.com", rc: "studio-rc.bsoneca.com"}
	// The database's backups to the node's object storage, in a folder of Studio's own; the keys are the Secret
	// studio-backup-s3 of the SOPS file.
	database: backup: {
		endpoint: "https://usc1.contabostorage.com"
		bucket:   "bonkchess"
		path:     "studio"
	}
	// Electric keeps a shape per app for each table: it may grow to 2Gi. The builder's turns need memory.
	containerResources: {
		electric: {requests: memory: "256Mi", limits: {cpu: "1", memory: "2Gi"}}
		builder: {requests: memory: "2Gi", limits: {cpu: "1", memory: "8Gi"}}
	}
	services: {
		// pronto-flags' flagd, reading the flags live from the ConfigMap each push writes.
		flagd: {
			port: 8693
			env: FLAGD_SOURCES:        "[{\"uri\":\"/etc/flags-live/flags.json\",\"provider\":\"fileinfo\"}]"
			files: "/etc/flags-live":  "studio-flags"
			seed: "studio-flags":      "flags/flags.json"
		}
		builder: {
			port: 8690
			jail: true
			google: {
				provider:       "projects/504479523278/locations/global/workloadIdentityPools/contabo/providers/contabo-k3s"
				serviceAccount: "studio-run@brawl-chess.iam.gserviceaccount.com"
				audience:       "contabo-k3s"
			}
			egress: [
				// the node's API, for the namespaces of the games it publishes
				{cidr: "203.0.113.7/32", port: 6443},
				// a toolchain's mirror
				{cidr: "0.0.0.0/0", except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"], port: 80},
				// the LLM gateway, the tenants' buildkitd and Studio's own flagd, by the cluster's pod network
				{cidr: "10.42.0.0/16", port: 4000},
				{cidr: "10.42.0.0/16", port: 1234},
				{cidr: "10.42.0.0/16", port: 8693},
			]
			scratch: "/workspace": "8Gi"
			env: {
				STUDIO_NODE_API: "https://kubernetes.default.svc"
				STUDIO_NODE_CA:  "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
				STUDIO_FLAGS:    "http://flagd:8693"
			}
			secrets: {
				PLAY_KEYS:        "studio-play"
				PLAY_SUB_SECRET:  "studio-play"
				PGRST_JWT_SECRET: "studio-auth-secrets"
				LLM_CHATGPT_KEY:  "studio-llm-chatgpt"
			}
		}
	}
}

App: k8s.#ReleaseSpec & {
	name:      "studio"
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
