package runners

import "strings"

// A user's setup on a Mac, and an organization's on a cluster someone already runs.
setups: {
	"check-mac": {
		cluster: colima: {}
		github: owner: "acme"
		scaleSets: "shop-arc": repo: "shop"
	}
	"check-org": {
		cluster: context: "k3s-hetzner"
		github: {owner: "acme-org", kind: "org"}
		secret: kind: "app"
		scaleSets: {
			"all-arm": {max: 8}
			"web-amd": {repo: "web", arch: "amd64", min: 1}
		}
		buildkit: emulate: ["linux/amd64", "linux/riscv64"]
	}
}

_mac: plans["check-mac"]
_org: plans["check-org"]

// A Colima setup starts its VM and is reached at its context; a context setup starts nothing.
mac: {context: _mac.context, colima: _mac.colima} & {context: "colima-arc", colima: {profile: "arc", cpus: 6, memory: 12, disk: 100}}
org: {context: _org.context, hasVM: _org.colima != _|_} & {context: "k3s-hetzner", hasVM: false}

// A user's scale set is its repository's; an organization's without one is the organization's.
urls: {
	mac: _mac.scaleSets["shop-arc"].githubConfigUrl
	all: _org.scaleSets["all-arm"].githubConfigUrl
	web: _org.scaleSets["web-amd"].githubConfigUrl
} & {mac: "https://github.com/acme/shop", all: "https://github.com/acme-org", web: "https://github.com/acme-org/web"}

// Every runner reaches the BuildKit the plan declares, at its Service.
_svc: [for o in _mac.buildkit if o.kind == "Service" {o}][0]
endpoint: _mac.scaleSets["shop-arc"].template.spec.containers[0].env[0].value & "tcp://\(_svc.metadata.name).\(_svc.metadata.namespace).svc.cluster.local:\(_svc.spec.ports[0].port)"

// The runners land on their arch's nodes, and register with the setup's secret.
arch: {mac: _mac.scaleSets["shop-arc"].template.spec.nodeSelector["kubernetes.io/arch"], web: _org.scaleSets["web-amd"].template.spec.nodeSelector["kubernetes.io/arch"]} & {mac: "arm64", web: "amd64"}
secret: {mac: _mac.scaleSets["shop-arc"].githubConfigSecret, org: _org.secret.kind} & {mac: "gha-token", org: "app"}

// QEMU only when a platform is emulated: binfmt registers the setup's, before BuildKit starts.
_deploy: {mac: [for o in _mac.buildkit if o.kind == "Deployment" {o}][0], org: [for o in _org.buildkit if o.kind == "Deployment" {o}][0]}
emulation: {mac: _deploy.mac.spec.template.spec.initContainers == _|_, org: _deploy.org.spec.template.spec.initContainers[0].args} & {mac: true, org: ["--install", "amd64,riscv64"]}

// The cache BuildKit keeps is what the setup says, in bytes.
keep: strings.Contains([for o in _mac.buildkit if o.kind == "ConfigMap" {o}][0].data["buildkitd.toml"], "keepBytes = 42949672960") & true
