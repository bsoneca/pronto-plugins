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
	"check-host": {
		cluster: host: {}
		github: owner: "acme"
		hostRunners: {
			"shop-mac": repo: "shop"
			"web-mac": {repo: "web", labels: ["web-mac", "xcode"], nice: 0}
		}
	}
}

// The checks' home; runners.ts exports a plan with the person's.
plans: [string]: home: "/Users/check"

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

// A host runner: GitHub's osx-arm64 runner under the home, registered to its repository, run by a
// launchd agent at a lower priority, with no cluster at all.
_host: plans["check-host"]
_shop: _host.host["shop-mac"]
host: {
	cluster: _host.context == _|_ && _host.scaleSets == _|_
	url:     _shop.url
	api:     _shop.api
	dir:     _shop.dir
	labels:  _host.host["web-mac"].labels
	tarball: strings.HasSuffix(_shop.download.url, "/v2.338.2/actions-runner-osx-arm64-2.338.2.tar.gz")
	agent:   _shop.service.path
	program: _shop.service.plist.ProgramArguments
	path:    strings.HasPrefix(_shop.path, "/Users/check/.deno/bin:/Users/check/.local/bin:/opt/homebrew/bin:")
	nice: {shop: _shop.service.plist.Nice, web: _host.host["web-mac"].service.plist.Nice}
} & {
	cluster: true
	url:     "https://github.com/acme/shop"
	api:     "repos/acme/shop/actions/runners"
	dir:     "/Users/check/actions-runners/shop-mac"
	labels: ["web-mac", "xcode"]
	tarball: true
	path:    true
	agent:   "/Users/check/Library/LaunchAgents/actions.runner.acme-shop.shop-mac.plist"
	program: ["/bin/bash", "/Users/check/actions-runners/shop-mac/bin/runsvc.sh"]
	nice: {shop: 10, web: 0}
}
