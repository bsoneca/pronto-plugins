// runners' rules (../../runners/plan.js) on the plans they were written for.
package unit

_runnersPlan: {
	context:         *"colima-arc" | string
	runnerNamespace: "arc-runners"
	secret: {name: "gha-token", kind: *"pat" | "app"}
	colima?: {profile: "arc"}
	scaleSets: [string]: {githubConfigUrl: string}
}
_mac: _runnersPlan & {
	colima: profile: "arc"
	scaleSets: {
		"pronto-arc": githubConfigUrl: "https://github.com/bsoneca/pronto"
		"ume-arc": githubConfigUrl:    "https://github.com/bsoneca/ume-verify"
	}
}
_remote: _runnersPlan & {context: "k3s-hetzner", scaleSets: "all": githubConfigUrl: "https://github.com/acme-org"}
_host: host: {
	"pronto-mac": {url: "https://github.com/bsoneca/pronto", api: "repos/bsoneca/pronto/actions/runners", dir: "/Users/check/actions-runners/pronto-mac", labels: ["pronto-mac"], work: "_work", path: "/Users/check/.deno/bin:/usr/bin:/bin"}
	"ume-mac": {url: "https://github.com/bsoneca/ume-verify", api: "repos/bsoneca/ume-verify/actions/runners", dir: "/Users/check/actions-runners/ume-mac", labels: ["ume-mac", "xcode"], work: "_work", path: "/Users/check/.deno/bin:/usr/bin:/bin"}
}
_ready: {installed: true, registration: *"current" | string, agent: true}
_found: {runner: {agentName: "pronto-mac", gitHubUrl: "https://github.com/bsoneca/pronto", workFolder: "_work", agentId: 7}, path: "/Users/check/.deno/bin:/usr/bin:/bin\n", labels: ["self-hosted", "macOS", "ARM64", "pronto-mac"]}

cases: {
	"a Colima setup starts its VM first, only when it is not running": {suite: "runners", steps: [
		{call: "runners.steps", args: [_mac, {vm: false, releases: [], secret: true}]},
		{map: {get: "do"}, expect: ["start-vm", "controller", "buildkit", "namespace", "scale-set", "scale-set"]},
		{call: "runners.steps", args: [_mac, {vm: true, releases: [], secret: true}]},
		{map: {get: "do"}, expect: ["controller", "buildkit", "namespace", "scale-set", "scale-set"]},
	]}
	"a setup on a cluster it reaches starts nothing": {suite: "runners", steps: [
		{call: "runners.steps", args: [_remote, {vm: false, releases: [], secret: true}]},
		{map: {get: "do"}, expect: ["controller", "buildkit", "namespace", "scale-set"]},
	]}
	"without the secret an apply stops after BuildKit, before any scale set": {suite: "runners", steps: [
		{call: "runners.steps", args: [_mac, {vm: true, releases: ["pronto-arc"], secret: false}]},
		{map: {get: "do"}, expect: ["controller", "buildkit", "namespace", "need-secret"]},
	]}
	"each scale set is applied by name, and one the setup no longer names is removed": {suite: "runners", steps: [
		{call: "runners.steps", args: [_mac, {vm: true, releases: ["old-arc", "pronto-arc"], secret: true}]},
		{filter: "name"},
		{map: {pick: ["do", "name"]}, expect: [["scale-set", "pronto-arc"], ["scale-set", "ume-arc"], ["remove", "old-arc"]]},
	]}
	"the secret's help names every repository and never holds a value": {suite: "runners", steps: [
		{call: "runners.secretHelp", args: [_mac]},
		{keep: "pat"},
		{get: "0", matches: "bsoneca/pronto, bsoneca/ume-verify"},
		{use: "pat"},
		{get: "1", matches: "^read -rs t && kubectl --context colima-arc -n arc-runners create secret generic gha-token --from-literal=github_token=\"\\$t\"; unset t$"},
		{call: "runners.secretHelp", args: [_mac & {secret: kind: "app"}]},
		{get: "1", matches: "github_app_id=<id> .*github_app_private_key=<key.pem>$"},
	]}
	"a host runner is installed, registered and its agent loaded, each only when missing": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_host, {}]},
		{map: {pick: ["do", "name"]}, expect: [["install", "pronto-mac"], ["register", "pronto-mac"], ["agent", "pronto-mac"], ["install", "ume-mac"], ["register", "ume-mac"], ["agent", "ume-mac"]]},
		{call: "runners.hostSteps", args: [_host, {"pronto-mac": _ready, "ume-mac": {installed: true, registration: "current", agent: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["agent", "ume-mac"]]},
	]}
	"a host runner registered otherwise is unregistered, registered again and its agent reloaded": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_host, {"pronto-mac": _ready & {registration: "stale"}, "ume-mac": _ready}]},
		{map: {pick: ["do", "name"]}, expect: [["unregister", "pronto-mac"], ["register", "pronto-mac"], ["agent", "pronto-mac"]]},
	]}
	"a host runner's registration is current only as the plan registers it": {suite: "runners", steps: [
		{call: "runners.registration", args: [_host, "pronto-mac", _found], expect: "current"},
		{call: "runners.registration", args: [_host, "pronto-mac", {runner: _found.runner, path: _found.path, labels: null}], expect: "current"},
		{call: "runners.registration", args: [_host, "pronto-mac", {runner: null, path: null, labels: null}], expect: "none"},
		{call: "runners.registration", args: [_host, "pronto-mac", {runner: _found.runner, path: "/usr/bin\n", labels: _found.labels}], expect: "stale"},
		{call: "runners.registration", args: [_host, "pronto-mac", {runner: _found.runner, path: _found.path, labels: ["self-hosted", "macOS"]}], expect: "stale"},
		{call: "runners.registration", args: [_host, "pronto-mac", {runner: {agentName: "pronto-mac", gitHubUrl: "https://github.com/bsoneca/pronto", workFolder: "work"}, path: _found.path, labels: null}], expect: "stale"},
	]}
	"a host runner registers with its labels and work folder, the token added only at the call": {suite: "runners", steps: [
		{call: "runners.registerArgs", args: [_host, "ume-mac"], expect: ["--unattended", "--url", "https://github.com/bsoneca/ume-verify", "--name", "ume-mac", "--labels", "ume-mac,xcode", "--work", "_work", "--replace"]},
		{call: "runners.registerHelp", args: [_host, "pronto-mac"]},
		{get: "1", matches: "^cd /Users/check/actions-runners/pronto-mac && \\./config\\.sh --unattended .* --token \"\\$\\(gh api -X POST repos/bsoneca/pronto/actions/runners/registration-token --jq \\.token\\)\"$"},
	]}
}
