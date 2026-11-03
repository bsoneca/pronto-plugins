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
}
