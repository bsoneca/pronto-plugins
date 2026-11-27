package tests

import (
	"list"
	"strings"

	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// A tenant's release (PRONTO-740 S2): the one a namespace's publisher makes, in the namespace its provisioner made, at the one
// host the namespace was given. `cue vet -c ./node/engine/tests` holds each case; node/engine/schema_test.nu holds what it refuses
// (tests/refused) and release_test.nu what the flow does.

_tenantNs:   "studio-owner-game-1a2b3c4d"
_tenantHost: "game-game.example.com"
_tenantBase: {
	name:    "app"
	context: "contabo2"
	api: ssh:          "deploy@node.example"
	hosts: production: _tenantHost
	tenant: {namespace: _tenantNs, host: _tenantHost}
}

// What upstream renders besides the fixture's kinds: its NetworkPolicies, and the Configuration the door's own is copied from.
_tenantExtra: [
	{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: "app-default-netpol", namespace: _tenantNs}},
	{apiVersion: "dapr.io/v1alpha1", kind: "Configuration", metadata: {name: "app-dapr-config", namespace: _tenantNs}, spec: api: allowed: [{name: "invoke", version: "v1.0", protocol: "http"}]},
]

_tenant: schema.#Manifests & {
	release:  schema.#Release & _tenantBase
	app: {name: "app", namespace: _tenantNs, image: pushed: "database-base": {tag: "18", digest: "sha256:\(_d)"}}
	upstream: list.Concat([(_fixture & {ns: _tenantNs, host: _tenantHost, reg: release.environment.registry}).objects, _tenantExtra])
}

cases: {
	"a tenant release lives in its namespace, at its host, under its own path of the registry": {
		_got: {
			ns:       _tenant.release.namespace
			host:     _tenant.release.host
			origin:   _tenant.release.origin
			registry: _tenant.release.environment.registry
		}
		_want: {ns: _tenantNs, host: _tenantHost, origin: "https://\(_tenantHost)", registry: "127.0.0.1:5000/\(_tenantNs)"}
	}
	"a tenant release writes no Namespace and no NetworkPolicy of upstream's": {
		_got:  [for o in _tenant.objects if o.kind == "Namespace" || o.kind == "NetworkPolicy" {o.kind}]
		_want: []
	}
	"every kind a tenant release writes is a publisher's kind, and it is refused for nothing": {
		_got: {
			outside:    [for o in _tenant.objects if !list.Contains(schema.#PublisherKinds, "\(o.apiVersion)/\(o.kind)") {o.kind}]
			violations: _tenant.violations
		}
		_want: {outside: [], violations: []}
	}
	"a tenant's images are under its namespace's path of the registry": {
		_got:  [for o in _tenant.objects if o.kind == "Deployment" for c in o.spec.template.spec.containers if !strings.HasPrefix(c.image, "127.0.0.1:5000/\(_tenantNs)/app-") {c.image}]
		_want: []
	}
	"the door's invoke-only Configuration is written for a tenant too": {
		_got: [for o in _tenant.objects if o.kind == "Configuration" {o.metadata.name}]
		_want: ["app-dapr-config", "app-caddy-invoke-only"]
	}
	"a tenant's quota, limit range and egress are its provisioner's: none is written": {
		_t: schema.#Manifests & {
			release:  schema.#Release & _tenantBase & {tenant: quota: pods: 12}
			upstream: list.Concat([(_fixture & {ns: _tenantNs, host: _tenantHost, reg: release.environment.registry}).objects, _tenantExtra])
			app: {name: "app", namespace: _tenantNs, image: pushed: "database-base": {tag: "18", digest: "sha256:\(_d)"}}
		}
		_got:  [for o in _t.objects if o.kind == "ResourceQuota" || o.kind == "LimitRange" || o.kind == "NetworkPolicy" {o.kind}]
		_want: []
	}
	"an operator's tenant ceiling, which names no namespace, still gets its quota": {
		_t: schema.#Manifests & {
			release:  schema.#Release & _base & {tenant: quota: pods: 12}
			upstream: (_fixture & {ns: "app", host: "app.example.com", reg: release.environment.registry}).objects
		}
		_got:  {ns: _t.release.namespace, quota: [for o in _t.objects if o.kind == "ResourceQuota" {o.metadata.name}]}
		_want: {ns: "app", quota: ["app-quota"]}
	}
	"a tenant keeps its own services' Deployment and Service and writes no NetworkPolicy for them": {
		_t: schema.#Manifests & {
			release: schema.#Release & _tenantBase & {services: flagd: {port: 8693}}
			upstream: list.Concat([(_fixture & {ns: _tenantNs, host: _tenantHost, reg: release.environment.registry}).objects, _tenantExtra, [
				{apiVersion: "v1", kind: "Service", metadata: {name: "crud", namespace: _tenantNs}},
			]])
			app: {name: "app", namespace: _tenantNs, image: pushed: {flagd: {tag: "release", digest: "sha256:\(_d)"}, "database-base": {tag: "18", digest: "sha256:\(_d)"}}}
		}
		_got: {
			deployment: [for o in _t.objects if o.kind == "Deployment" && o.metadata.name == "app-flagd" {o.metadata.name}]
			policies:   [for o in _t.objects if o.kind == "NetworkPolicy" {o.metadata.name}]
		}
		_want: {deployment: ["app-flagd"], policies: []}
	}
	"a tenant's Cluster runs the approved database base it was pushed, under its own registry path": {
		_t: schema.#Manifests & {
			release:  schema.#Release & _tenantBase
			upstream: list.Concat([(_fixture & {ns: _tenantNs, host: _tenantHost, reg: release.environment.registry}).objects, _tenantExtra])
			app: {name: "app", namespace: _tenantNs, image: pushed: "database-base": {tag: "17", digest: "sha256:\(_d)"}}
		}
		_got:  [for o in _t.objects if o.kind == "Cluster" {strings.Contains(o.spec.imageName, "\(_tenantNs)/") && strings.Contains(o.spec.imageName, "-database-base") }]
		_want: [true]
	}
	"a tenant's build is the tenants' buildkitd by default": {
		_got:  _tenant.release.tenant.buildkit
		_want: "tcp://buildkitd.pronto-buildkit-tenants.svc:1234"
	}
}
