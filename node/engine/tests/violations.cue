package tests

import (
	"list"

	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// What a render is refused for: `violations` says it, and `objects` is then an error
// (node/engine/schema_test.nu holds that half).

_refuse: {
	extra: [...]
	_m: schema.#Manifests & {
		release:  schema.#Release & _base
		upstream: list.Concat([(_fixture & {ns: "app", host: "app.example.com", reg: release.registry.url}).objects, extra])
	}
	violations: _m.violations
}

cases: {
	"a clean render is refused for nothing": {
		_got:  (_refuse & {extra: []}).violations
		_want: []
	}
	"a kind no operator serves is refused": {
		_got:  (_refuse & {extra: [{apiVersion: "acme.io/v1", kind: "Widget", metadata: {name: "w", namespace: "app"}}]}).violations
		_want: [=~"^acme.io/v1 Widget/w is not served by the node's operators"]
	}
	"a cluster-scoped object is refused, even one that is served": {
		_got:  (_refuse & {extra: [{apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRole", metadata: name: "r"}]}).violations
		_want: [=~"has no namespace$", =~"is cluster scoped$", =~"is not served"]
	}
	"an object in another namespace is refused": {
		_got:  (_refuse & {extra: [{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "c", namespace: "other"}}]}).violations
		_want: ["ConfigMap/c is in namespace other, not app"]
	}
	"a namespace that is not the release's is refused": {
		_got:  (_refuse & {extra: [{apiVersion: "v1", kind: "Namespace", metadata: name: "kube-system"}]}).violations
		_want: ["Namespace/kube-system is not the release's namespace app"]
	}
	"a job outside jobOrder is refused": {
		_got:  (_refuse & {extra: [{apiVersion: "batch/v1", kind: "Job", metadata: {name: "app-airlock-upgrade", namespace: "app"}, spec: template: spec: containers: [{image: "europe-west3-docker.pkg.dev/proj/node-images/app-x:1@sha256:\(_d)"}]}]}).violations
		_want: [=~"^Job/app-airlock-upgrade is not in jobOrder"]
	}
	"a gateway listening for another host is refused": {
		_got:  (_refuse & {extra: [{apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: {name: "g2", namespace: "app"}, spec: listeners: [{hostname: "other.example.com"}]}]}).violations
		_want: ["Gateway/g2 listens for other.example.com, not the release's host app.example.com"]
	}
	"an image from elsewhere is refused for both reasons, a digest-less one of ours for one": {
		_got: (_refuse & {
			extra: [
				{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "d1", namespace: "app"}, spec: template: spec: containers: [{image: "docker.io/library/nginx:1"}]},
				{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "d2", namespace: "app"}, spec: template: spec: containers: [{image: "docker.io/library/nginx:1@sha256:\(_d)"}]},
				{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "d3", namespace: "app"}, spec: template: spec: containers: [{image: "europe-west3-docker.pkg.dev/proj/node-images/app-x:latest"}]},
			]
		}).violations
		_want: [
			"image docker.io/library/nginx:1 is not in europe-west3-docker.pkg.dev/proj/node-images",
			"image docker.io/library/nginx:1@sha256:\(_d) is not in europe-west3-docker.pkg.dev/proj/node-images",
			"image docker.io/library/nginx:1 is not pinned by digest",
			"image europe-west3-docker.pkg.dev/proj/node-images/app-x:latest is not pinned by digest",
		]
	}
}
