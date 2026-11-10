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
	// A Linux machine's runners, a systemd unit each, that send nothing amd64 anywhere.
	"check-linux": {
		cluster: host: {os: "linux", arch: "x64"}
		github: owner: "acme"
		amd64: "none"
		hostRunners: "shop-linux": repo: "shop"
	}
	"check-linux-arm": {
		cluster: host: os: "linux"
		github: owner: "acme"
		hostRunners: "shop-arm": repo: "shop"
	}
	// A cluster whose BuildKit emulates nothing: it builds its own platform only.
	"check-plain": {
		cluster: context: "k3s-home"
		github: owner:    "acme"
		scaleSets: "shop-plain": repo: "shop"
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

// The checks' home and login; runners.ts exports a plan with the person's.
plans: [string]: {home: "/Users/check", user: "check"}

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

// Where amd64 builds, and what every runner's jobs read of it: Cloud Build on a Mac (its VM or the
// Mac itself), emulation on a cluster whose BuildKit emulates amd64, nothing on one that does not,
// and what a setup says.
amd64: {
	mac:   _mac.setup.amd64
	org:   _org.setup.amd64
	host:  _host.setup.amd64
	plain: plans["check-plain"].setup.amd64
	linux: plans["check-linux"].setup.amd64
} & {mac: "cloud-build", org: "emulate", host: "cloud-build", plain: "none", linux: "none"}
amd64Env: {
	pod:   _org.scaleSets["web-amd"].template.spec.containers[0].env[1]
	agent: _shop.service.plist.EnvironmentVariables.PRONTO_AMD64
} & {pod: {name: "PRONTO_AMD64", value: "emulate"}, agent: "cloud-build"}

// A Linux host: GitHub's linux runner for its arch, pinned, run by the systemd unit svc.sh writes,
// as the person, with no Homebrew on its PATH.
_linux: plans["check-linux"]
_lx:    _linux.host["shop-linux"]
linux: {
	service: _linux.service
	runsOn:  _linux.runsOn
	tarball: strings.HasSuffix(_lx.download.url, "/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz")
	sha256:  _lx.download.sha256
	arm:     strings.HasSuffix(plans["check-linux-arm"].host["shop-arm"].download.url, "/actions-runner-linux-arm64-2.338.2.tar.gz")
	unit:    _lx.service.path
	plist:   _lx.service.plist == _|_
	path:    _lx.path
} & {
	service: "systemd"
	runsOn: ["self-hosted", "Linux", "X64"]
	tarball: true
	sha256:  "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
	arm:     true
	unit:    "/etc/systemd/system/actions.runner.acme-shop.shop-linux.service"
	plist:   true
	path:    "/Users/check/.deno/bin:/Users/check/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
linuxUnit: _lx.service.unit & """
	[Unit]
	Description=GitHub Actions Runner (acme/shop.shop-linux)
	After=network.target

	[Service]
	ExecStart=/bin/bash /Users/check/actions-runners/shop-linux/bin/runsvc.sh
	User=check
	WorkingDirectory=/Users/check/actions-runners/shop-linux
	KillMode=process
	KillSignal=SIGTERM
	TimeoutStopSec=5min
	Nice=10
	Environment=ACTIONS_RUNNER_SVC=1
	Environment=PRONTO_AMD64=none

	[Install]
	WantedBy=multi-user.target

	"""
// A Mac's runner says so to GitHub, as before.
macRunsOn: _host.runsOn & ["self-hosted", "macOS", "ARM64"]
