package tests

import (
	"list"

	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// One case per behaviour of schema.#Manifests: a release, the upstream objects, and what the
// engine makes of them. `cue vet -c ./node/engine/tests` holds each one.

_base: {
	name:    "app"
	context: "contabo2"
	api: ssh:          "deploy@node.example"
	hosts: production: "app.example.com"
}

_kinds: {[for o in _production.objects {o.kind}]}

_production: schema.#Manifests & {
	release:  schema.#Release & _base
	upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
}

cases: {
	"production: the namespace is labelled, nothing else of upstream's changes": {
		_nsLabels:  [for o in _production.objects if o.kind == "Namespace" {o.metadata.labels}][0]
		_got:       _nsLabels
		_want:      {"pronto.dev/release": "app"}
		_untouched: [for o in _production.objects if o.kind != "Namespace" {o}]
		_upstream:  [for o in _production.upstream if o.kind != "Namespace" {o}]
		same:       list.MinItems(len(_upstream)) & _untouched
		same:       _upstream
	}
	"production without backups or tenant adds nothing": {
		_got:  len(_production.objects)
		_want: len(_production.upstream)
	}
	"the release's registry and names derive from its parts": {
		_got: {
			ns:       _production.release.namespace
			host:     _production.release.host
			registry: _production.release.environment.registry
			policy:   _production.release.environment.imagePullPolicy
			class:    _production.release.environment.storageClass
		}
		_want: {ns: "app", host: "app.example.com", registry: "127.0.0.1:5000", policy: "IfNotPresent", class: "local-path"}
	}
	"an app that names its registry gets it in every image, with no violation": {
		_custom: schema.#Manifests & {
			release:  schema.#Release & _base & {build: registry: host: "10.0.0.1:5001"}
			upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
		}
		_got:  {registry: _custom.release.environment.registry, violations: _custom.violations}
		_want: {registry: "10.0.0.1:5001", violations: []}
	}
	"the jobs run in jobOrder": {
		_got:  _production.jobs
		_want: ["app-initdb", "app-migrate"]
	}
}

// A preview's namespace and host, and no backups in it.
_withBackups: _base & {backups: {bucket: "b", path: "app/db"}}
_preview: schema.#Manifests & {
	release:  schema.#Release & _withBackups & {preview: "rc", hosts: rc: "rc.example.com"}
	upstream: (_fixture & {ns: "app-rc", host: "rc.example.com", reg: release.environment.registry}).objects
}
_previewNoHost: schema.#Release & _base & {preview: "pr-3"}
_prodBackups: schema.#Manifests & {
	release:  schema.#Release & _withBackups
	upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
}

cases: {
	"a preview has its own namespace and host, and the namespace says it is one": {
		_got: {
			ns:     _preview.release.namespace
			host:   _preview.release.host
			labels: [for o in _preview.objects if o.kind == "Namespace" {o.metadata.labels}][0]
		}
		_want: {ns: "app-rc", host: "rc.example.com", labels: {"pronto.dev/release": "app", "pronto.dev/preview": "rc"}}
	}
	"a preview without a host is served at <namespace>.<domainSuffix>": {
		_got:  _previewNoHost.host
		_want: "app-pr-3.bsoneca.com"
	}
	"backups are emitted in production alone": {
		_got: {
			production: [for o in _prodBackups.objects if o.kind == "ObjectStore" || o.kind == "ScheduledBackup" {o.kind}]
			preview:    [for o in _preview.objects if o.kind == "ObjectStore" || o.kind == "ScheduledBackup" {o.kind}]
			rcPlugins:  [for o in _preview.objects if o.kind == "Cluster" {o.spec.plugins != _|_}][0]
		}
		_want: {production: ["ObjectStore", "ScheduledBackup"], preview: [], rcPlugins: false}
	}
	"backups name the store, the archiver and the credentials as the fork did": {
		_store: [for o in _prodBackups.objects if o.kind == "ObjectStore" {o}][0]
		_sched: [for o in _prodBackups.objects if o.kind == "ScheduledBackup" {o}][0]
		_db:    [for o in _prodBackups.objects if o.kind == "Cluster" {o}][0]
		_got: {
			store:    _store.metadata.name
			dest:     _store.spec.configuration.destinationPath
			secret:   _store.spec.configuration.s3Credentials.accessKeyId.name
			retain:   _store.spec.retentionPolicy
			schedule: _sched.metadata.name
			method:   _sched.spec.method
			plugin:   _db.spec.plugins[0].parameters.barmanObjectName
			wal:      _db.spec.plugins[0].isWALArchiver
		}
		_want: {store: "app-backup", dest: "s3://b/app/db", secret: "app-backup-s3", retain: "30d", schedule: "app-nightly", method: "plugin", plugin: "app-backup", wal: true}
	}
	"a tenant gets a quota, a limit range and no more": {
		_t: schema.#Manifests & {
			release:  schema.#Release & _base & {tenant: quota: pods: 12}
			upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
		}
		_got: {
			added: [for o in _t.objects if o.kind == "ResourceQuota" || o.kind == "LimitRange" {"\(o.kind)/\(o.metadata.name)"}]
			pods:  [for o in _t.objects if o.kind == "ResourceQuota" {o.spec.hard.pods}][0]
			count: len(_t.objects)
		}
		_want: {added: ["ResourceQuota/app-quota", "LimitRange/app-quota"], pods: 12, count: len(_production.upstream) + 2}
	}
	"a tenant's extra egress is one more NetworkPolicy": {
		_t: schema.#Manifests & {
			release:  schema.#Release & _base & {tenant: egress: [{ports: [{port: 443}]}]}
			upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
		}
		_got:  [for o in _t.objects if o.kind == "NetworkPolicy" {o.metadata.name}]
		_want: ["app-tenant-egress"]
	}
	"retire names a kind and a name, never a Cluster": {
		_ok:   schema.#Release & _base & {retire: [{kind: "Deployment", name: "app-old"}]}
		_got:  len(_ok.retire)
		_want: 1
	}
	"the door gets a Dapr configuration of its own, with invocation alone allowed: the shared one stays for crud and the rest": {
		_dapr: (schema.#Manifests & {
			release: schema.#Release & _base
			upstream: [
				{apiVersion: "v1", kind: "Namespace", metadata: name: "app"},
				{apiVersion: "dapr.io/v1alpha1", kind: "Configuration", metadata: {name: "app-dapr-config", namespace: "app", labels: {"app.kubernetes.io/name": "app"}}, spec: {tracing: samplingRate: "1", metric: enabled: true}},
				for n in ["caddy", "crud"] {
					apiVersion: "apps/v1"
					kind:       "Deployment"
					metadata:   {name: "app-\(n)", namespace: "app"}
					spec:       {replicas: 1, template: {metadata: {labels: component: n, annotations: {"dapr.io/enabled": "true", "dapr.io/app-id": n, "dapr.io/config": "app-dapr-config"}}, spec: containers: [{name: n, image: "127.0.0.1:5000/app-\(n):latest@sha256:\(_digest)"}]}}
				},
			]
		}).objects
		_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		_caddy:  [for o in _dapr if o.kind == "Deployment" && o.metadata.name == "app-caddy" {o}][0]
		_crud:   [for o in _dapr if o.kind == "Deployment" && o.metadata.name == "app-crud" {o}][0]
		_shared: [for o in _dapr if o.kind == "Configuration" && o.metadata.name == "app-dapr-config" {o}][0]
		_own:    [for o in _dapr if o.kind == "Configuration" && o.metadata.name == "app-caddy-invoke-only" {o}][0]
		_got: {
			caddyConfig:  _caddy.spec.template.metadata.annotations."dapr.io/config"
			caddyOtherOK: _caddy.spec.template.metadata.annotations."dapr.io/app-id"
			crudConfig:   _crud.spec.template.metadata.annotations."dapr.io/config"
			sharedHasAPI: _shared.spec.api != _|_
			allowed:      _own.spec.api.allowed
			tracing:      _own.spec.tracing.samplingRate
			count:        len(_dapr)
		}
		_want: {
			caddyConfig:  "app-caddy-invoke-only"
			caddyOtherOK: "caddy"
			crudConfig:   "app-dapr-config"
			sharedHasAPI: false
			allowed:      [{name: "invoke", version: "v1.0", protocol: "http"}, {name: "invoke", version: "v1.0", protocol: "grpc"}]
			tracing:      "1"
			count:        5
		}
	}
	"without the shared Dapr configuration upstream emits, the door is neither retargeted nor given one": {
		_none: (schema.#Manifests & {
			release: schema.#Release & _base
			upstream: [
				{apiVersion: "v1", kind: "Namespace", metadata: name: "app"},
				{
					apiVersion: "apps/v1"
					kind:       "Deployment"
					metadata:   {name: "app-caddy", namespace: "app"}
					spec:       {replicas: 1, template: {metadata: {labels: component: "caddy", annotations: {"dapr.io/config": "elsewhere"}}, spec: containers: [{name: "caddy", image: "127.0.0.1:5000/app-caddy:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}
				},
			]
		}).objects
		_got: {
			count:  len(_none)
			config: [for o in _none if o.kind == "Deployment" {o.spec.template.metadata.annotations."dapr.io/config"}][0]
		}
		_want: {count: 2, config: "elsewhere"}
	}
	"a Deployment or a Configuration with fields absent is given what the door needs, not refused": {
		_bare: (schema.#Manifests & {
			release: schema.#Release & _base
			upstream: [
				{apiVersion: "v1", kind: "Namespace", metadata: name: "app"},
				{apiVersion: "dapr.io/v1alpha1", kind: "Configuration", metadata: {name: "app-dapr-config", namespace: "app"}},
				{
					apiVersion: "apps/v1"
					kind:       "Deployment"
					metadata:   {name: "app-caddy", namespace: "app"}
					spec:       {replicas: 1, template: {metadata: labels: component: "caddy", spec: containers: [{name: "caddy", image: "127.0.0.1:5000/app-caddy:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}
				},
			]
		}).objects
		_got: {
			config: [for o in _bare if o.kind == "Deployment" {o.spec.template.metadata.annotations."dapr.io/config"}][0]
			labels: [for o in _bare if o.kind == "Deployment" {o.spec.template.metadata.labels.component}][0]
			guard:  [for o in _bare if o.kind == "Configuration" && o.metadata.name == "app-caddy-invoke-only" {o.spec.api.allowed[0].name}][0]
		}
		_want: {config: "app-caddy-invoke-only", labels: "caddy", guard: "invoke"}
	}
}

// Every case's `got` holds `want`.
_held: {for n, c in cases {(n): c._got & c._want}}
