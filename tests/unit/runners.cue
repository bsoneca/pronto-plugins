// runners' rules (../../runners/plan.js) on the plans they were written for.
package unit

import (
	rn "github.com/bsoneca/pronto-plugins/runners"
	"crypto/sha256"
	"encoding/hex"
)

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
		"shop-arc": githubConfigUrl:    "https://github.com/acme/shop"
	}
}
_remote: _runnersPlan & {context: "k3s-hetzner", scaleSets: "all": githubConfigUrl: "https://github.com/acme-org"}
_host: host: {
	"pronto-mac": {url: "https://github.com/bsoneca/pronto", api: "repos/bsoneca/pronto/actions/runners", dir: "/Users/check/actions-runners/pronto-mac", labels: ["pronto-mac"], work: "_work", path: "/Users/check/.deno/bin:/usr/bin:/bin"}
	"shop-mac": {url: "https://github.com/acme/shop", api: "repos/acme/shop/actions/runners", dir: "/Users/check/actions-runners/shop-mac", labels: ["shop-mac", "xcode"], work: "_work", path: "/Users/check/.deno/bin:/usr/bin:/bin"}
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
		{map: {pick: ["do", "name"]}, expect: [["scale-set", "pronto-arc"], ["scale-set", "shop-arc"], ["remove", "old-arc"]]},
	]}
	"the secret's help names every repository and never holds a value": {suite: "runners", steps: [
		{call: "runners.secretHelp", args: [_mac]},
		{keep: "pat"},
		{get: "0", matches: "bsoneca/pronto, acme/shop"},
		{use: "pat"},
		{get: "1", matches: "^read -rs t && kubectl --context colima-arc -n arc-runners create secret generic gha-token --from-literal=github_token=\"\\$t\"; unset t$"},
		{call: "runners.secretHelp", args: [_mac & {secret: kind: "app"}]},
		{get: "1", matches: "github_app_id=<id> .*github_app_private_key=<key.pem>$"},
	]}
	"a host runner is installed, registered and its agent loaded, each only when missing": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_host, {}]},
		{map: {pick: ["do", "name"]}, expect: [["install", "pronto-mac"], ["register", "pronto-mac"], ["agent", "pronto-mac"], ["install", "shop-mac"], ["register", "shop-mac"], ["agent", "shop-mac"]]},
		{call: "runners.hostSteps", args: [_host, {"pronto-mac": _ready, "shop-mac": {installed: true, registration: "current", agent: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["agent", "shop-mac"]]},
	]}
	"a host runner registered otherwise is unregistered, registered again and its agent reloaded": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_host, {"pronto-mac": _ready & {registration: "stale"}, "shop-mac": _ready}]},
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
		{call: "runners.registerArgs", args: [_host, "shop-mac"], expect: ["--unattended", "--url", "https://github.com/acme/shop", "--name", "shop-mac", "--labels", "shop-mac,xcode", "--work", "_work", "--replace"]},
		{call: "runners.registerHelp", args: [_host, "pronto-mac"]},
		{get: "1", matches: "^cd /Users/check/actions-runners/pronto-mac && gh api -X POST repos/bsoneca/pronto/actions/runners/registration-token --jq \\.token \\| \\( IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN && \\./config\\.sh --unattended .* \\)$"},
		{call: "runners.configCommand", args: [["remove"]]},
		{keep: "cmd"},
		{call: "probe.includes", args: ["$cmd", "--token"], expect: false, why: "the applier's runners' token is not an argument either"},
		{use: "cmd"},
		{get: "2", matches: "^IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN && exec \\./config\\.sh \"\\$@\"$"},
		{use: "cmd"},
		{get: "4", expect: "remove"},
	]}

	// A runner without a `user` is today's. The plans of the real setups (setups.cue) carry no account
	// field, their agents are under the applier's ~/Library/LaunchAgents, and none creates an account.
	"a runner without a user has no account, hook or previous in its plan": {suite: "runners", steps: [for n, h in _rnReal.host {
		{call: "probe.lacksKeys", args: [h, ["user", "home", "previous", "hook", "tools", "files"]], expect: true}
	}]}
	"a runner without a user is a LaunchAgent of the applier's, with no hook in its environment": {suite: "runners", steps: [for n, h in _rnReal.host {
		{call: "probe.includes", args: [h.service.path, "/Users/check/Library/LaunchAgents/"], expect: true}
	}, for n, h in _rnReal.host {
		{call: "probe.lacksKeys", args: [h.service.plist.EnvironmentVariables, ["ACTIONS_RUNNER_HOOK_JOB_STARTED"]], expect: true}
	}]}
	"no runner of the real setups creates an account or hands a file to root": {suite: "runners", steps: [for n, p in {a: rn.plans["bsoneca-mac"], b: rn.plans["bsoneca-mac-studio-apps"], c: rn.plans["bsoneca-mac-pronto-fork"]} {
		{call: "probe.lacksKeys", args: [p, ["accounts", "files"]], expect: true}
	}]}
	"the real setup names the applier's own account, so the probe keeps a pr account out of it": {suite: "runners", steps: [
		{value: rn.plans["bsoneca-mac"].setup.accounts.bruno},
		{keep: "bruno"},
		{get: "role", expect: "owner"},
		{use: "bruno"},
		{get: "existing", expect: true},
	]}
	"a pr runner's daemon carries the probe hook and the setup's pr environment": {suite: "runners", steps: [
		{value: _rnAcc.host["shop-pr"].service.plist},
		{keep: "plist"},
		{get: "UserName", expect: "ci-pr"},
		{use: "plist"},
		{get: "GroupName", expect: "ci-pr"},
		{use: "plist"},
		{get: "WorkingDirectory", expect: "/Library/Application Support/pronto-runners/shop-pr/runner"},
		{use: "plist"},
		{get: "EnvironmentVariables", holds: {
			ACTIONS_RUNNER_HOOK_JOB_STARTED: "/Library/Application Support/pronto-runners/shop-pr/job-started.sh"
			STACK_POOL:                      "/tmp/pronto-stacks-ci-pr"
			STACK_HOLD_POOL:                 "/tmp/pronto-stacks"
			STACK_HOLD_UID:                  "501"
			MISE_SHARED_INSTALL_DIRS:        "/Users/Shared/pronto/mise/installs"
			HOME:                            "/Users/ci-pr"
		}},
	]}
	"a trusted account's PATH has no folder but root's, and its daemon names its admits hook": {suite: "runners", steps: [
		{value: _rnAcc.host["shop-trusted"].path, expect: "/usr/local/ci-trusted/bin:/usr/bin:/bin"},
		{value: _rnAcc.host["shop-trusted"].service.path, expect: "/Library/LaunchDaemons/actions.runner.acme-shop.shop-trusted.plist"},
		{value: _rnAcc.host["shop-trusted"].service.plist.EnvironmentVariables.ACTIONS_RUNNER_HOOK_JOB_STARTED, expect: "/Library/Application Support/pronto-runners/shop-trusted/job-started.sh"},
		{call: "probe.includes", args: [_rnAcc.host["shop-pr"].path, "/opt/homebrew/bin"], expect: true, why: "a pr account keeps the usual PATH"},
	]}
	"the probe names every other account's home, from the accounts, and the paths and groups the setup lists": {suite: "runners", steps: [
		{call: "probe.holdsEach", args: [_rnAcc.host["shop-pr"].hook.text, [
			"ls \"/Users/ci-trusted\" >/dev/null 2>&1",
			"ls \"/Users/check\" >/dev/null 2>&1",
			"[ -w \"/opt/homebrew/bin\" ]",
			"[ -w \"/Users/Shared/pronto/mise\" ]",
			"[ -w \"/Library/LaunchDaemons\" ]",
			"[ -w \"/Library/Application Support/pronto-runners\" ]",
			"admin|studio) fail",
			"security find-generic-password -s gh:github.com",
			"\"$HOME/.config/gh/hosts.yml\" \"$HOME/.config/gcloud/credentials.db\" \"$HOME/.git-credentials\" \"$HOME/.codex/auth.json\" \"$HOME/.codex\" \"$HOME\"/.ssh/id_*",
			"*TOKEN*|*SECRET*",
		]], expect: [true, true, true, true, true, true, true, true, true, true]},
		{call: "probe.includes", args: [_rnAcc.host["shop-pr"].hook.text, "ls \"/Users/ci-pr\""], expect: false, why: "its own home is not probed as another's"},
	]}
	"the generated hooks are bash, and the probe refuses any account but its own before it looks at anything": {suite: "runners", steps: [
		{call: "probe.bashSyntax", args: [_rnAcc.host["shop-pr"].hook.text], expect: 0},
		{call: "probe.bashSyntax", args: [_rnAcc.host["shop-trusted"].hook.text], expect: 0},
		{call: "probe.bashSyntax", args: [_rnAcc.host["shop-agent"].hook.text], expect: 0},
		{call: "probe.runHook", args: [_rnAcc.host["shop-pr"].hook.text]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "^runner shop-pr refuses: wrong account$"},
	]}
	"the accounts to create, and the files that are root's with their owner and mode": {suite: "runners", steps: [
		{value: _rnAcc.accounts},
		{map: {pick: ["login", "role", "home", "mode", "hidden", "password"]}, expect: [
			["ci-pr", "pr", "/Users/ci-pr", "700", true, false],
			["ci-trusted", "trusted", "/Users/ci-trusted", "700", true, false],
		]},
		{value: _rnAcc.accounts},
		{map: {pick: ["login", "group"]}, expect: [["ci-pr", "ci-pr"], ["ci-trusted", "ci-trusted"]
		]},
		{value: [for f in _rnAcc.files if f.runner == "shop-trusted" {[f.path, f.owner, f.mode]}]},
		{keep: "files"},
		{get: "1", expect: ["/Library/Application Support/pronto-runners/shop-trusted/job-started.sh", "root:wheel", "755"]},
		{use: "files"},
		{get: "2", expect: ["/Library/LaunchDaemons/actions.runner.acme-shop.shop-trusted.plist", "root:wheel", "644"]},
		{use: "files"},
		{get: "3", expect: ["/Library/Logs/pronto-runners/actions.runner.acme-shop.shop-trusted", "root:wheel", "755"]},
		{use: "files"},
		{get: "4", expect: ["/Library/Application Support/pronto-runners/shop-trusted/runner", "root:ci-trusted", "750"]},
		{use: "files"},
		{get: "5", expect: ["/Library/Application Support/pronto-runners/shop-trusted/runner/_work", "ci-trusted:ci-trusted", "700"]},
		{use: "files"},
		{get: "7", expect: ["/usr/local/ci-trusted/bin", "root:wheel", "755"]},
	]}
	"an account's uids are chosen once, in order, never twice and never one the machine has": {suite: "runners", steps: [
		{call: "runners.allocateUids", args: [[{login: "a"}, {login: "b"}, {login: "c"}], [510, 512]], expect: {a: 511, b: 513, c: 514}},
		{call: "runners.allocateUids", args: [[{login: "a"}, {login: "b"}], [510], [511, 512]], expect: {a: 513, b: 514}, why: "a gid the machine has is not taken either"},
		{call: "runners.allocateUids", args: [_rnAcc.accounts, [510]]},
		{keep: "uids"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "account", {uids: "$uids", stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "pr"},
		{get: "3", expect: "sudo dscl . -create /Groups/ci-pr PrimaryGroupID 511"},
		{use: "pr"},
		{get: "8", expect: "sudo dscl . -create /Users/ci-pr UniqueID 511"},
		{use: "pr"},
		{get: "9", expect: "sudo dscl . -create /Users/ci-pr PrimaryGroupID 511"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-trusted", "account", {uids: "$uids", stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{get: "8", expect: "sudo dscl . -create /Users/ci-trusted UniqueID 512"},
	]}

	// What an account's steps do, the commands plan.js builds, run (with sudo -n) or printed as they are.
	"an account's runner is registered with its token on stdin, never in an argument, and told not to update itself": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "register-as", {}]},
		{keep: "reg"},
		{map: {get: "argv"}},
		{keep: "argv"},
		{call: "probe.includes", args: ["$argv", "--token"], expect: false},
		{call: "probe.includes", args: ["$argv", "--disableupdate"], expect: true},
		{use: "reg"},
		{map: {get: "token"}, expect: [null, null, null, null, true]},
		{use: "reg"},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "regsh"},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true", why: "its daemon is out again right before it registers"},
		{use: "regsh"},
		{get: "1", matches: "kill -KILL -1.* ci-pr$", why: "the account is checked quiet again"},
		{use: "regsh"},
		{get: "2", matches: "launchctl print \"system/\\$0\""},
		{use: "regsh"},
		{get: "3", matches: "launchctl print \"user/\\$u\"[\\s\\S]* ci-pr$"},
		{use: "regsh"},
		{get: "4", matches: "^printf '%s\\\\n' \"\\$t\" \\| sudo -u ci-pr -H env PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c 'cd \"\\$0\" && IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN && exec \\./config\\.sh \"\\$@\"' '/Library/Application Support/pronto-runners/shop-pr/runner' --unattended .* --disableupdate$"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "unregister-as", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true", why: "and before it unregisters"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "unregister-as", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{get: "1", matches: "kill -KILL -1.* ci-pr$"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "unregister-as", {}]},
		{map: {get: "argv"}},
		{keep: "argv"},
		{call: "probe.includes", args: ["$argv", "--token"], expect: false},
		{call: "probe.includes", args: ["$argv", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"], expect: true, why: "config.sh runs with the system's PATH, never the runner's own (its home's folders are the account's)"},
		{call: "probe.includes", args: ["$argv", "PATH=" + _rnAcc.host["shop-pr"].path], expect: false},
	]}
	"an account's runner folder is root's but the folders its jobs write: the account is quiesced, nothing is granted before the tree has passed, the folder's final chown is last": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "lock"},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true"},
		{use: "lock"},
		{get: "1", expect: "sudo crontab -u ci-pr -r || true"},
		{use: "lock"},
		{get: "7", matches: "launchctl print \"user/\\$u\"[\\s\\S]* ci-pr$", why: "quiesce is 8 commands, all before any chown"},
		{use: "lock"},
		{get: "8", expect: "sudo chown -h root:wheel '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "lock"},
		{get: "9", expect: "sudo chmod 700 '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "lock"},
		{get: "10", matches: "holds a mount point[\\s\\S]*more than one link[\\s\\S]* '/Library/Application Support/pronto-runners/shop-pr/runner' _work$", why: "mounts, names and hard links are looked at before a chown could reach through one"},
		{use: "lock"},
		{get: "11", expect: "sudo chmod -N '/Library/Application Support/pronto-runners/shop-pr/runner'", why: "no ACL survives the lock"},
		{use: "lock"},
		{get: "12", expect: "sudo chflags -h 0 '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "lock"},
		{get: "13", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 '(' -path '/Library/Application Support/pronto-runners/shop-pr/runner/_work' -o -path '/Library/Application Support/pronto-runners/shop-pr/runner/_diag' ')' -prune -o -exec chmod -h -N '{}' +"},
		{use: "lock"},
		{get: "14", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 '(' -path '/Library/Application Support/pronto-runners/shop-pr/runner/_work' -o -path '/Library/Application Support/pronto-runners/shop-pr/runner/_diag' ')' -prune -o -exec chflags -h 0 '{}' +"},
		{use: "lock"},
		{get: "15", matches: "still has an ACL[\\s\\S]* '/Library/Application Support/pronto-runners/shop-pr/runner' _work$", why: "and none is left"},
		{use: "lock"},
		{get: "16", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 -maxdepth 1 '!' -name _work '!' -name _diag -exec chown -h -R root:wheel '{}' +"},
		{use: "lock"},
		{get: "17", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 -maxdepth 1 '!' -name _work '!' -name _diag -exec chmod -R go-rwx,ug-s '{}' +"},
		{use: "lock"},
		{get: "18", matches: "^sudo /bin/sh -c 'for d in .* rm -f .*_work' '.*_diag'$"},
		{use: "lock"},
		{get: "19", matches: "^sudo /bin/sh -c 'r=\\$0; w=\\$1; m=\\$2[\\s\\S]*mtree[\\s\\S]* '/Library/Application Support/pronto-runners/shop-pr/runner' _work '/Library/Application Support/pronto-runners/shop-pr/tree\\.mtree'$"},
		{use: "lock"},
		{get: "20", matches: "^sudo /bin/sh -c 'umask 077 && cd \"\\$0\" && rm -f \\.path && printf \"%s.n\" \"\\$1\" > \\.path' '/Library/Application Support/pronto-runners/shop-pr/runner' /Users/ci-pr/\\.deno/bin:\\S+$", why: "root writes .path itself"},
		{use: "lock"},
		{get: "21", matches: "^sudo /bin/sh -c 'cd \"\\$0\"[\\s\\S]*\\.env[\\s\\S]* '/Library/Application Support/pronto-runners/shop-pr/runner' /Users/ci-pr/\\.deno/bin:\\S+$"},
		{use: "lock"},
		{get: "22", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 -maxdepth 1 '!' -name _work '!' -name _diag -exec chown -h -R root:ci-pr '{}' +", why: "the group gets nothing before CLEAN has passed"},
		{use: "lock"},
		{get: "23", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 -maxdepth 1 '!' -name _work '!' -name _diag -exec chmod -R g+rX '{}' +"},
		{use: "lock"},
		{get: "24", matches: "^sudo /bin/sh -c 'u=\\$0; g=\\$1;.*mkdir -m 700 \"\\$d\".*chown -h \"\\$u:\\$g\" \"\\$d\".*' ci-pr ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner/_work' '/Library/Application Support/pronto-runners/shop-pr/runner/_diag'$", why: "_work and _diag are made by root with a plain mkdir while the folder is root's 700, then chowned"},
		{use: "lock"},
		{get: "25", expect: "sudo chmod 750 '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "lock"},
		{get: "26", expect: "sudo chown -h root:ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner'", why: "the folder's final chown is last"},
		{call: "probe.includes", args: ["$lock", "sudo chown -h ci-pr:ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner'"], expect: false, why: "the folder is never the account's in a lock"},
		{call: "probe.includes", args: ["$lock", "sudo chmod -R g+rX,go-w,o-rwx '{}' +"], expect: false},
		{call: "probe.includes", args: ["$lock", "sudo -u ci-pr -H mkdir -p -m 700 '/Library/Application Support/pronto-runners/shop-pr/runner/_work' '/Library/Application Support/pronto-runners/shop-pr/runner/_diag'"], expect: false},
	]}
	"unlocking quiesces the account, then chowns what is in the folder by name and the folder last, never into _work or _diag": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "unlock", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "unlock"},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true"},
		{use: "unlock"},
		{get: "1", expect: "sudo crontab -u ci-pr -r || true"},
		{use: "unlock"},
		{get: "5", matches: "kill -KILL -1.* ci-pr$"},
		{use: "unlock"},
		{get: "7", matches: "launchctl print \"user/\\$u\""},
		{use: "unlock"},
		{get: "8", matches: "holds a mount point", why: "mounts, names and hard links are looked at after the quiesce and before any chown"},
		{use: "unlock"},
		{get: "9", expect: "sudo chmod -N '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "unlock"},
		{get: "13", matches: "still has an ACL"},
		{use: "unlock"},
		{get: "14", expect: "sudo find '/Library/Application Support/pronto-runners/shop-pr/runner' -mindepth 1 -maxdepth 1 '!' -name _work '!' -name _diag -exec chown -h -R ci-pr:ci-pr '{}' +", why: "the first chown comes after the quiesce, and is the subtree's"},
		{use: "unlock"},
		{get: "15", expect: "sudo chown -h ci-pr:ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner'", why: "the folder last"},
	]}
	"quiesce boots out the account's user and gui domains and proves them empty, kills its processes until none is left, and the daemon must be out of launchd": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "text"},
		{get: "2", matches: "^sudo /bin/sh -c 'launchctl bootout \"\\$1/\\$\\(id -u \"\\$0\"\\)\"' ci-pr user \\|\\| true$"},
		{use: "text"},
		{get: "3", matches: "^sudo /bin/sh -c 'launchctl bootout \"\\$1/\\$\\(id -u \"\\$0\"\\)\"' ci-pr gui \\|\\| true$"},
		{use: "text"},
		{get: "4", matches: "/usr/lib/cron/jobs.* -user \"\\$0\" .* ci-pr$", why: "the account's at jobs are removed"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{keep: "lock"},
		{get: "2"},
		{keep: "boot"},
		{call: "probe.runCommand", args: ["$boot", {bin: {launchctl: "echo \"$@\" >&2", id: "echo 501"}}]},
		{get: "said", expect: "bootout user/501"},
		{use: "lock"},
		{get: "5"},
		{keep: "reap"},
		{call: "probe.runCommand", args: ["$reap", {bin: {pgrep: "exit 1", sudo: "exit 1", sleep: "exit 0"}}]},
		{get: "code", expect: 0, why: "nothing of the account running"},
		{call: "probe.runCommand", args: ["$reap", {bin: {pgrep: "[ -e \"$0.n\" ] && exit 1; : > \"$0.n\"; exit 0", sudo: "exit 0", sleep: "exit 0"}}]},
		{get: "code", expect: 0, why: "one left over: killed, and gone at the next look"},
		{call: "probe.runCommand", args: ["$reap", {bin: {pgrep: "exit 0", sudo: "exit 0", sleep: "exit 0"}}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a process that survives the third kill fails the lock"},
		{use: "ran"},
		{get: "said", expect: "ci-pr still has processes"},
		{call: "probe.runCommand", args: ["$reap", {bin: {pgrep: "exit 2", sudo: "exit 0", sleep: "exit 0"}}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a pgrep that fails is not 'nothing running'"},
		{use: "ran"},
		{get: "said", expect: "pgrep failed (2)"},
		{use: "lock"},
		{get: "6"},
		{keep: "gone"},
		{call: "probe.runCommand", args: ["$gone", {bin: launchctl: "exit 113"}]},
		{get: "code", expect: 0, why: "launchd no longer has it"},
		{call: "probe.runCommand", args: ["$gone", {bin: launchctl: "exit 0"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a bootout that did not take"},
		{use: "ran"},
		{get: "said", expect: "system/actions.runner.acme-shop.shop-pr is still loaded"},
		{use: "lock"},
		{get: "7"},
		{keep: "user"},
		{call: "probe.runCommand", args: ["$user", {bin: {id: "echo 501", launchctl: "exit 113"}}]},
		{get: "code", expect: 0, why: "no user domain"},
		{call: "probe.runCommand", args: ["$user", {bin: {id: "echo 501", launchctl: "printf 'user/501 = {\\n\\ttype = user\\n\\tservices = {\\n\\t}\\n\\tendpoints = {\\n\\t\\tcom.example.endpoint\\n\\t}\\n}\\n'"}}]},
		{get: "code", expect: 0, why: "a services block that is empty (another block's lines are not services)"},
		{call: "probe.runCommand", args: ["$user", {bin: {id: "echo 501", launchctl: "printf 'user/501 = {\\n\\ttype = user\\n\\tservices = {\\n\\t\\t     0  -9  _x\\n\\t\\t 12345  (pe)  0x2.app\\n\\t}\\n}\\n'"}}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "services of the account's that survive its bootout, as launchctl lists them (a _ label, a -9 and a (pe) status)"},
		{use: "ran"},
		{get: "said", matches: "user/501 still has services \\(2\\)"},
	]}
	"the lock holds the folder to the runner tarball's tree: a changed file, an extra file, a missing one and a re-pointed link are refused, the runner's own links and its state files are not": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{get: "19"},
		{keep: "clean"},
		{call: "probe.runCommand", args: ["$clean", _rnCl]},
		{get: "code", expect: 0, why: "the runner's own node/bin/npm link is the tarball's"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {files: {"runner/.path": "p", "runner/.env": "LANG=C", "runner/.runner": "{}", "runner/.credentials": "c", "runner/.credentials_rsaparams": "c", "runner/_work/x": "w", "runner/_diag/log": "d"}}]},
		{get: "code", expect: 0, why: "the state config.sh writes, _work and _diag are not held to the tarball"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {files: "runner/bin/x": "y"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a changed byte"},
		{use: "ran"},
		{get: "said", matches: "x changed[\\s\\S]*not the runner tarball's"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {files: "runner/bin/extra": "y"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "an extra file (mtree itself exits 0 for it)"},
		{use: "ran"},
		{get: "said", matches: "extra extra"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {links: "runner/evil": "/etc/passwd"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "an extra link"},
		{use: "ran"},
		{get: "said", matches: "evil extra"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {files: "runner/bin/x": "x", links: "runner/bin/y": "../../etc"}]},
		{get: "code", expect: 1},
		{call: "probe.runCommand", args: ["$clean", {files: {"runner/bin/x": "x", "tree.mtree": _rnSpec}, replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a missing link"},
		{use: "ran"},
		{get: "said", matches: "missing"},
		{call: "probe.runCommand", args: ["$clean", {files: "runner/bin/x": "x", links: "runner/externals/node20/bin/npm": "../../../../../etc", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "no mtree recorded at install"},
		{use: "ran"},
		{get: "said", matches: "no mtree of the runner tarball"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {links: "runner/externals/node20/bin/npm": "../../../../../etc"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a link of the tarball's re-pointed"},
		{use: "ran"},
		{get: "said", matches: "link_ref expected"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {links: "runner/.path": "/etc/hosts"}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a state file that is a link"},
		{use: "ran"},
		{get: "said", matches: "\\.path is not a plain file"},
		{call: "probe.runCommand", args: ["$clean", _rnCl & {files: "runner/.credentials/x": "c"}]},
		{get: "code", expect: 1, why: "a state file that is a folder"},
	]}
	"the lock refuses, before it changes anything, a mount point, a hard link, a tab or newline in a name or link, and a link into _work or _diag, and fails closed when find or stat fails": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{get: "10"},
		{keep: "pre"},
		{call: "probe.runCommand", args: ["$pre", _rnCl]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$pre", {files: {"runner/bin/x": "x", "runner/_work/x": "x"}, hardlinks: "runner/_work/y": "runner/_work/x", links: {"runner/_work/inside": "/etc", "runner/_diag/l": "/etc"}, replace: _rnRep}]},
		{get: "code", expect: 0, why: "_work and _diag are the account's, not looked into"},
		{call: "probe.runCommand", args: ["$pre", {files: "runner/bin/x": "x", hardlinks: "runner/bin/y": "runner/bin/x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "more than one link"},
		{call: "probe.runCommand", args: ["$pre", {bin: stat: "if [ \"$#\" -gt 3 ]; then printf '1\\n2\\n'; else echo 1; fi", files: "runner/bin/x": "x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "an entry on another device than the folder's (stat stubbed)"},
		{use: "ran"},
		{get: "said", matches: "holds a mount point"},
		{call: "probe.runCommand", args: ["$pre", {bin: stat: "case \"$3\" in */..) echo 2;; *) echo 1;; esac", files: "runner/bin/x": "x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a mount on the folder itself: its device is not its parent's"},
		{use: "ran"},
		{get: "said", matches: "is a mount point"},
		{call: "probe.runCommand", args: ["$pre", {bin: stat: "echo 7", files: "runner/bin/x": "x", replace: _rnRep}]},
		{get: "code", expect: 0, why: "every entry on the folder's device"},
		{call: "probe.runCommand", args: ["$pre", {bin: stat: "exit 1", files: "runner/bin/x": "x", replace: _rnRep}]},
		{get: "code", expect: 1, why: "a stat that fails fails the lock"},
		{call: "probe.runCommand", args: ["$pre", {files: {"runner/a\tb/x": "x"}, replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a tab in a folder name"},
		{use: "ran"},
		{get: "said", matches: "a tab or a newline"},
		{call: "probe.runCommand", args: ["$pre", {files: "runner/bin/x": "x", links: "runner/n\nl": "x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a newline in a link's name"},
		{use: "ran"},
		{get: "said", matches: "a tab or a newline"},
		{call: "probe.runCommand", args: ["$pre", {files: "runner/bin/x": "x", links: "runner/nt": "a\nb", replace: _rnRep}]},
		{get: "code", expect: 1, why: "a newline in a link's target"},
		{call: "probe.runCommand", args: ["$pre", {files: "runner/bin/x": "x", links: "runner/externals/w": "../_work/x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a link into _work"},
		{use: "ran"},
		{get: "said", matches: "reaches _work or _diag"},
		{call: "probe.runCommand", args: ["$pre", {files: "runner/bin/x": "x", links: "runner/externals/w": "../_diag/x", replace: _rnRep}]},
		{get: "code", expect: 1, why: "and into _diag"},
		{call: "probe.runCommand", args: ["$pre", {bin: find: "exit 1", files: "runner/bin/x": "x", replace: _rnRep}]},
		{get: "code", expect: 1, why: "a find that fails fails the lock"},
	]}
	"every step of a lock and an unlock that can run without root runs once on a scratch tree: the ACL and flag strip reaches the tree but not through a link, the finds are valid, the chmods land": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{keep: "lock"},
		{get: "11"},
		{keep: "s11"},
		{use: "lock"},
		{get: "12"},
		{keep: "s12"},
		{use: "lock"},
		{get: "13"},
		{keep: "s13"},
		{use: "lock"},
		{get: "14"},
		{keep: "s14"},
		{use: "lock"},
		{get: "15"},
		{keep: "s15"},
		{use: "lock"},
		{get: "8"},
		{keep: "own"},
		{use: "lock"},
		{get: "9"},
		{keep: "m700"},
		{use: "lock"},
		{get: "16"},
		{keep: "chownwheel"},
		{use: "lock"},
		{get: "17"},
		{keep: "closed"},
		{use: "lock"},
		{get: "22"},
		{keep: "chowngroup"},
		{use: "lock"},
		{get: "23"},
		{keep: "grouped"},
		{use: "lock"},
		{get: "25"},
		{keep: "m750"},
		{use: "lock"},
		{get: "26"},
		{keep: "last"},
		{call: "probe.runCommand", args: ["$s15", _rnStrip & {then: []}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "the ACLs the account may have left are there to find"},
		{call: "probe.runCommand", args: ["$s11", _rnStrip & {then: ["$s12", "$s13", "$s14", "$s15", ["/bin/sh", "-c", "ls -le \"$0\" | grep -E '^ [0-9]+: ' >&2", "OUT"], ["/bin/sh", "-c", "ls -ledO \"$0\" | cut -c1 >&2", "LNK"]]}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "then"},
		{keep: "then"},
		{get: "0.code", expect: 0},
		{use: "then"},
		{get: "1.code", expect: 0, why: "find recurses; each entry gets the non-recursive -h form"},
		{use: "then"},
		{get: "2.code", expect: 0, why: "and none is left in the tree"},
		{use: "then"},
		{get: "3.code", expect: 0},
		{use: "then"},
		{get: "4.said", matches: "0: group:everyone allow read", why: "the target of a link out of the tree keeps its ACL"},
		{use: "then"},
		{get: "5.said", expect: "l", why: "the link itself is a link, and untouched"},
		{call: "probe.runCommand", args: ["$s13", {bin: chmod: "exit 1", acls: ["runner/f"], files: "runner/f": "x", replace: _rnStrip.replace}]},
		{get: "code", expect: 1, why: "a chmod that fails fails the find, and the lock"},
		{call: "probe.runCommand", args: ["$s13", {files: {"runner/_work/w": "x", "runner/_diag/d": "x"}, acls: ["runner/_work/w", "runner/_diag/d"], then: [["/bin/sh", "-c", "ls -le \"$0\" \"$1\" | grep -E '^ [0-9]+: ' >&2", "WORK", "DIAG"]], replace: _rnStrip.replace & {WORK: "@tmp/runner/_work/w", DIAG: "@tmp/runner/_diag/d"}}]},
		{get: "then.0.said", matches: "0: group:everyone[\\s\\S]*0: group:everyone", why: "_work and _diag are the account's and are not touched"},
		{call: "probe.runCommand", args: ["$closed", {bin: chown: "exit 0", files: {"runner/bin/x": "x", "runner/_work/w": "w"}, then: [["/bin/sh", "-c", "chmod 666 \"$0\" \"$1\" && chmod 777 \"$2\"", "@tmp/runner/_work/w", "@tmp/runner/bin/x"]], replace: _rnStrip.replace}]},
		{get: "code", expect: 0, why: "find ... chmod -R go-rwx,ug-s is valid on this system"},
		{call: "probe.runCommand", args: ["$chownwheel", {bin: chown: "echo \"$@\" >&2", files: {"runner/bin/x": "x", "runner/_work/w": "w", "runner/.path": "p"}, replace: _rnStrip.replace}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", matches: "^-h -R root:wheel (\\S+/runner/(bin|\\.path) ?){2}$", why: "the chown reaches what is in the folder by name"},
		{use: "ran"},
		{get: "said", matches: "^(?![\\s\\S]*_work)"},
		{call: "probe.runCommand", args: ["$chowngroup", {bin: chown: "echo \"$@\" >&2", files: {"runner/bin/x": "x", "runner/_work/w": "w"}, replace: _rnStrip.replace}]},
		{keep: "ran"},
		{get: "said", matches: "root:ci-pr"},
		{call: "probe.runCommand", args: ["$grouped", {files: {"runner/bin/x": "x", "runner/_work/w": "w"}, replace: _rnStrip.replace}]},
		{get: "code", expect: 0, why: "find ... chmod -R g+rX is valid"},
		{call: "probe.runCommand", args: ["$own", {bin: chown: "echo \"$@\" >&2", files: "runner/x": "x", replace: _rnStrip.replace}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", matches: "-h root:wheel \\S+/runner$"},
		{call: "probe.runCommand", args: ["$m700", {files: "runner/x": "x", replace: _rnStrip.replace}]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$m750", {files: "runner/x": "x", replace: _rnStrip.replace}]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$last", {bin: chown: "echo \"$@\" >&2", files: "runner/x": "x", replace: _rnStrip.replace}]},
		{keep: "ran"},
		{get: "said", matches: "^-h root:ci-pr \\S+/runner$"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "unlock", {}]},
		{map: {get: "argv"}},
		{keep: "unlock"},
		{get: "14"},
		{keep: "uchown"},
		{call: "probe.runCommand", args: ["$uchown", {bin: chown: "echo \"$@\" >&2", files: {"runner/bin/x": "x", "runner/_work/w": "w"}, replace: _rnStrip.replace}]},
		{keep: "ran"},
		{get: "said", matches: "-h -R ci-pr:ci-pr \\S+/runner/bin"},
		{use: "unlock"},
		{get: "10"},
		{keep: "u10"},
		{call: "probe.runCommand", args: ["$u10", {files: {"runner/bin/x": "x", "runner/_work/w": "w"}, replace: _rnStrip.replace}]},
		{get: "code", expect: 0, why: "the unlock's strip is the lock's"},
	]}
	"the lock refuses a hard-linked FIFO as it does a file, and an ACL left on the tree; install-as starts by quiescing the account": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{keep: "lock"},
		{get: "10"},
		{keep: "pre"},
		{call: "probe.runCommand", args: ["$pre", {fifos: ["runner/bin/p"], hardlinks: "runner/bin/q": "runner/bin/p", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a socket or a FIFO linked twice is not a regular file"},
		{use: "ran"},
		{get: "said", matches: "more than one link"},
		{call: "probe.runCommand", args: ["$pre", {fifos: ["runner/bin/p"], replace: _rnRep}]},
		{get: "code", expect: 0, why: "a FIFO linked once is only the tarball's check to make"},
		{use: "lock"},
		{get: "15"},
		{keep: "acl"},
		{call: "probe.runCommand", args: ["$acl", {bin: ls: "printf 'drwx------  2 u  g  64 Nov 20 d\\n 0: user:x allow list\\n'", files: "runner/bin/x": "x", replace: _rnRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "an ACL entry that is still there after the strip"},
		{use: "ran"},
		{get: "said", matches: "still has an ACL"},
		{call: "probe.runCommand", args: ["$acl", {bin: ls: "echo 'drwx------  2 u  g  64 Nov 20 d'", files: "runner/bin/x": "x", replace: _rnRep}]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$acl", {bin: find: "exit 1", files: "runner/bin/x": "x", replace: _rnRep}]},
		{get: "code", expect: 1, why: "a find that fails fails the lock"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "install-as", {stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "inst"},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true"},
		{use: "inst"},
		{get: "5", matches: "kill -KILL -1"},
		{use: "inst"},
		{get: "7", matches: "launchctl print \"user/\\$u\""},
		{use: "inst"},
		{get: "8", matches: "^sudo install -d -m 755 -o root -g wheel"},
	]}
	"the lock makes a symlinked _work again and root writes .path itself over whatever is there": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{keep: "lock"},
		{get: "18"},
		{keep: "unlink"},
		{call: "probe.runCommand", args: ["$unlink", {links: "runner/_work": "/etc", replace: {"/Library/Application Support/pronto-runners/shop-pr/runner/_work": "@tmp/runner/_work", "/Library/Application Support/pronto-runners/shop-pr/runner/_diag": "@tmp/runner/_diag"}}]},
		{keep: "ran"},
		{get: "kept", expect: [false, false], why: "a symlinked _work is removed (and _diag, absent, stays absent)"},
		{use: "lock"},
		{get: "20"},
		{keep: "path"},
		{call: "probe.runCommand", args: ["$path", {files: "d/.path": "evil", replace: _rnEnvRep}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", expect: ""},
		{call: "probe.runCommand", args: ["$path", {files: "d/x": "x", links: "d/.path": "x", replace: _rnEnvRep}]},
		{get: "code", expect: 0, why: "a .path that is a link is replaced, not followed"},
		{call: "probe.runCommand", args: ["$path", {bin: rm: "exit 1", files: "d/.path": "evil", replace: _rnEnvRep}]},
		{get: "code", expect: 1, why: "and written only once the old one is gone"},
	]}
	"the lock makes _work and _diag as root with a plain mkdir and chowns them; a symlink or a file there stops it": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{get: "24"},
		{keep: "make"},
		{call: "probe.runCommand", args: ["$make", {bin: chown: "echo \"$@\" >&2", files: "runner/x": "", replace: _rnMk}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", matches: "-h ci-pr:ci-pr \\S+/runner/_work\\s+-h ci-pr:ci-pr \\S+/runner/_diag"},
		{call: "probe.runCommand", args: ["$make", {bin: chown: "exit 0", files: {"runner/_work/keep": "x"}, replace: _rnMk}]},
		{get: "code", expect: 0, why: "a folder kept from an earlier lock is only chowned"},
		{call: "probe.runCommand", args: ["$make", {bin: chown: "exit 0", files: "runner/x": "", links: "runner/_work": "/etc", replace: _rnMk}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "is a symlink"},
		{call: "probe.runCommand", args: ["$make", {bin: chown: "exit 0", files: "runner/_diag": "x", replace: _rnMk}]},
		{get: "code", expect: 1, why: "a file where the folder goes"},
	]}
	"the tree is the tarball's, recorded by root from the checked bytes as an mtree: an edited tarball, or one with a link into _work, records nothing": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "install-as", {stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{get: "11", matches: "^sudo /bin/sh -c 'set -e; t=\\$\\(mktemp\\); m=\\$\\(mktemp -d\\);[\\s\\S]*/usr/sbin/mtree -c -k type,sha256digest,link[\\s\\S]* [0-9a-f]{64} /s/runner\\.tar\\.gz '/Library/Application Support/pronto-runners/shop-pr/tree\\.mtree' _work$"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "install-as", {stage: "/s"}]},
		{map: {get: "argv"}},
		{get: "11"},
		{keep: "man"},
		{call: "probe.runCommand", args: ["$man", {bin: {tar: "mkdir -p \"$4/bin\" \"$4/externals/node20/bin\"; printf x > \"$4/bin/x\"; ln -s ../lib/npm-cli.js \"$4/externals/node20/bin/npm\"", mv: "grep -v '^#' \"$2\" >&2"}, files: staged: "TARBALL", replace: _rnManRep}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", matches: "npm\\s+type=link link=\\.\\./lib/npm-cli\\.js"},
		{use: "ran"},
		{get: "said", matches: "sha256digest=\(_rnX)"},
		{call: "probe.runCommand", args: ["$man", {bin: {tar: "mkdir -p \"$4\"; ln -s ../_work/x \"$4/w\"", mv: "grep -v '^#' \"$2\" >&2"}, files: staged: "TARBALL", replace: _rnManRep}]},
		{get: "code", expect: 1, why: "a tarball with a link into _work records nothing"},
		{call: "probe.runCommand", args: ["$man", {bin: {tar: "exit 0", mv: "grep -v '^#' \"$2\" >&2"}, files: staged: "TARBALL-EDITED", replace: _rnManRep}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "NOT match", why: "an edited tarball is refused before it is extracted"},
	]}
	"a lock holds the folder's .path to the plan's and its .env to nothing but a LANG, plain files only": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "lock", {}]},
		{map: {get: "argv"}},
		{get: "21"},
		{keep: "env"},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": _rnAcc.host["shop-pr"].path + "\n", "d/.env": ""}, replace: _rnEnvRep}]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": _rnAcc.host["shop-pr"].path + "\n", "d/.env": "LANG=en_US.UTF-8\n"}, replace: _rnEnvRep}]},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": _rnAcc.host["shop-pr"].path + "\n"}, replace: _rnEnvRep}]},
		{get: "code", expect: 0, why: "no .env is none"},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": _rnAcc.host["shop-pr"].path + "\n", "d/.env": "LANG=C\nACTIONS_RUNNER_HOOK_JOB_STARTED=/tmp/x\n"}, replace: _rnEnvRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a hook variable the account put in .env"},
		{use: "ran"},
		{get: "said", matches: "ACTIONS_RUNNER_HOOK_JOB_STARTED=/tmp/x"},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": "/tmp/evil:/usr/bin\n", "d/.env": ""}, replace: _rnEnvRep}]},
		{keep: "ran"},
		{get: "code", expect: 1, why: "a .path that is not the plan's"},
		{use: "ran"},
		{get: "said", matches: "is not the plan's PATH"},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.env": ""}, links: "d/.path": "/etc/hosts", replace: _rnEnvRep}]},
		{get: "code", expect: 1, why: "a .path that is a link"},
		{call: "probe.runCommand", args: ["$env", {files: {"d/.path": _rnAcc.host["shop-pr"].path + "\n"}, links: "d/.env": "/etc/hosts", replace: _rnEnvRep}]},
		{get: "code", expect: 1, why: "a .env that is a link"},
	]}
	"gh is installed from the pin, checked as staged and as installed, and linked to nothing outside /usr/lib and /System; git and jq are not copied": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-trusted", "tools", {stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "tools"},
		{get: "0", expect: "sudo install -d -m 755 -o root -g wheel /usr/local/ci-trusted /usr/local/ci-trusted/bin"},
		{use: "tools"},
		{get: "1", matches: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb /s/gh$"},
		{use: "tools"},
		{get: "2", expect: "sudo install -m 755 -o root -g wheel /s/gh /usr/local/ci-trusted/bin/gh.new"},
		{use: "tools"},
		{get: "5", expect: "sudo mv -f /usr/local/ci-trusted/bin/gh.new /usr/local/ci-trusted/bin/gh"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-trusted", "tools", {stage: "/s"}]},
		{map: {get: "argv"}},
		{keep: "argv"},
		{call: "probe.includes", args: ["$argv", "/opt/homebrew"], expect: false, why: "nothing is copied from a folder the applier can write"},
		{call: "probe.includes", args: ["$argv", "git"], expect: false},
	]}
	"a gh that links a library outside /usr/lib and /System is refused and removed": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-trusted", "tools", {stage: "/s"}]},
		{map: {get: "argv"}},
		{get: "4"},
		{keep: "check"},
		{call: "probe.runCommand", args: ["$check", {bin: otool: _rnOtoolOk, files: gh: "x", replace: "/usr/local/ci-trusted/bin/gh.new": "@tmp/gh"}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{call: "probe.runCommand", args: ["$check", {bin: otool: _rnOtoolOk + " && printf \"\\t/opt/homebrew/lib/libintl.8.dylib (x)\\n\"", files: gh: "x", replace: "/usr/local/ci-trusted/bin/gh.new": "@tmp/gh"}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "kept", expect: [false]},
		{use: "ran"},
		{get: "said", matches: "links /opt/homebrew/lib/libintl\\.8\\.dylib$"},
	]}
	"a file root installs is checked against the sha256 the plan renders, before and after, and an edited copy fails": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-trusted", "hook", {stage: "/s"}]},
		{map: {get: "argv"}},
		{keep: "hook"},
		{get: "1"},
		{call: "probe.verifies", args: ["$", _rnAcc.host["shop-trusted"].hook.text], expect: 0},
		{use: "hook"},
		{get: "1"},
		{call: "probe.verifies", args: ["$", _rnAcc.host["shop-trusted"].hook.text + "# edited\n"], expect: 1},
		{use: "hook"},
		{get: "3"},
		{call: "probe.includes", args: ["$", "rm -f"], expect: true, why: "a file that fails the check after the install is removed"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "daemon", {stage: "/s"}]},
		{map: {get: "argv"}},
		{keep: "daemon"},
		{get: "2"},
		{call: "probe.verifies", args: ["$", _rnAcc.host["shop-pr"].service.xml], expect: 0},
		{use: "daemon"},
		{get: "2"},
		{call: "probe.verifies", args: ["$", _rnAcc.host["shop-pr"].service.xml + "<!-- edited -->\n"], expect: 1},
	]}
	"a daemon is bootstrapped after its files are checked, installed beside their place and renamed onto it": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "daemon", {stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "daemon"},
		{get: "1", expect: "sudo install -d -m 755 -o root -g wheel /Library/Logs/pronto-runners/actions.runner.acme-shop.shop-pr"},
		{use: "daemon"},
		{get: "3", matches: "^sudo install -m 644 -o root -g wheel /s/plist /Library/LaunchDaemons/actions\\.runner\\.acme-shop\\.shop-pr\\.plist\\.new$"},
		{use: "daemon"},
		{get: "5", expect: "sudo mv -f /Library/LaunchDaemons/actions.runner.acme-shop.shop-pr.plist.new /Library/LaunchDaemons/actions.runner.acme-shop.shop-pr.plist"},
		{use: "daemon"},
		{get: "6", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-pr || true"},
		{use: "daemon"},
		{get: "7", expect: "sudo launchctl bootstrap system /Library/LaunchDaemons/actions.runner.acme-shop.shop-pr.plist"},
	]}
	"an account's tarball is copied to a root-only file, checked there, and only then extracted as the account": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "install-as", {stage: "/s"}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "install"},
		{get: "8", expect: "sudo install -d -m 755 -o root -g wheel '/Library/Application Support/pronto-runners/shop-pr'"},
		{use: "install"},
		{get: "9", expect: "sudo install -d -m 750 -o ci-pr -g ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner'"},
		{use: "install"},
		{get: "10", matches: "^sudo /bin/sh -c 'set -e; t=\\$\\(mktemp\\);.*tar xzf - -C \"\\$3\" < \"\\$t\"' [0-9a-f]{64} /s/runner\\.tar\\.gz ci-pr '/Library/Application Support/pronto-runners/shop-pr/runner'$"},
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "install-as", {stage: "/s"}]},
		{map: {get: "argv"}},
		{get: "10"},
		{keep: "tar"},
		{call: "probe.runCommand", args: ["$tar", {bin: {sudo: "shift 4; exec \"$@\"", tar: "cat >&2"}, files: staged: "TARBALL", replace: {"/s/runner.tar.gz": "@tmp/staged", (_rnAcc.host["shop-pr"].download.sha256): _rnTarSha}}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{use: "ran"},
		{get: "said", expect: "TARBALL", why: "what was checked is what the account extracts"},
		{call: "probe.runCommand", args: ["$tar", {bin: {sudo: "shift 4; exec \"$@\"", tar: "cat >&2"}, files: staged: "TARBALL-EDITED", replace: {"/s/runner.tar.gz": "@tmp/staged", (_rnAcc.host["shop-pr"].download.sha256): _rnTarSha}}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "NOT match", why: "an edited tarball is refused and nothing is extracted"},
	]}
	"an account is refused when its group already exists, and a gid the machine has is never taken": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-pr", "account", {uids: {"ci-pr": 511}, stage: "/s"}]},
		{map: {get: "argv"}},
		{get: "0"},
		{keep: "free"},
		{call: "probe.runCommand", args: ["$free", {bin: dscl: "exit 0"}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", expect: "group ci-pr exists"},
		{call: "probe.runCommand", args: ["$free", {bin: dscl: "exit 56"}]},
		{keep: "ran"},
		{get: "code", expect: 0},
	]}
	"a help that cd's into a folder with a space quotes it": {suite: "runners", steps: [
		{call: "runners.registerHelp", args: [_rnAcc, "shop-pr"]},
		{get: "1", matches: "^cd '/Library/Application Support/pronto-runners/shop-pr/runner' && gh api "},
	]}
	"a runner that is the applier's own again has its old daemon unloaded and removed": {suite: "runners", steps: [
		{call: "runners.stepCommands", args: [_rnAcc, "shop-own", "remove-daemon", {}]},
		{map: {call: "runners.shell", args: ["$"]}},
		{keep: "rm"},
		{get: "0", expect: "sudo launchctl bootout system/actions.runner.acme-shop.shop-own || true"},
		{use: "rm"},
		{get: "1", expect: "sudo rm -f /Library/LaunchDaemons/actions.runner.acme-shop.shop-own.plist"},
	]}

	// The order of an apply, by what it finds.
	"a runner that changes account drains before it is unregistered, then registers again as the account, its folder locked, its hook before its daemon": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-pr": {account: false, oldRegistered: true, installed: false, registration: "none", locked: false, hook: false, tools: false, daemon: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["account", "shop-pr"], ["drain", "shop-pr"], ["unregister-old", "shop-pr"], ["install-as", "shop-pr"], ["register-as", "shop-pr"], ["lock", "shop-pr"], ["hook", "shop-pr"], ["daemon", "shop-pr"]]},
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-trusted": {account: false, oldRegistered: true, installed: false, registration: "none", locked: false, hook: false, tools: false, daemon: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["account", "shop-trusted"], ["drain", "shop-trusted"], ["unregister-old", "shop-trusted"], ["install-as", "shop-trusted"], ["register-as", "shop-trusted"], ["lock", "shop-trusted"], ["tools", "shop-trusted"], ["hook", "shop-trusted"], ["daemon", "shop-trusted"]]},
	]}
	"an apply that finds everything as planned does nothing, and a changed hook restarts only its daemon": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen], expect: []},
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-pr": {hook: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["hook", "shop-pr"], ["daemon", "shop-pr"]]},
	]}
	"a stale registration is drained, the folder given back, unregistered and registered again, then locked": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-pr": {registration: "stale"}}]},
		{map: {pick: ["do", "name"]}, expect: [["drain", "shop-pr"], ["unlock", "shop-pr"], ["unregister-as", "shop-pr"], ["register-as", "shop-pr"], ["lock", "shop-pr"], ["daemon", "shop-pr"]]},
	]}
	"the applier's own runner behind a hook gets its hook before its agent restarts": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-agent": {hook: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["hook", "shop-agent"], ["agent", "shop-agent"]]},
		{value: _rnAcc.host["shop-agent"].service.plist.EnvironmentVariables.ACTIONS_RUNNER_HOOK_JOB_STARTED, expect: "/Library/Application Support/pronto-runners/shop-agent/job-started.sh"},
		{call: "probe.includes", args: [_rnAcc.host["shop-agent"].hook.text, "want='check'"], expect: true, why: "the account it insists on is the applier's"},
		{call: "probe.includes", args: [_rnAcc.host["shop-agent"].hook.text, "rootuid"], expect: false, why: "its PATH is the applier's, not a root-owned folder"},
		{value: _rnAcc.host["shop-agent"].service.path, expect: "/Users/check/Library/LaunchAgents/actions.runner.acme-shop.shop-agent.plist"},
	]}
	"a runner that went back to the applier's own has its daemon removed first": {suite: "runners", steps: [
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-own": {legacyDaemon: true}}]},
		{map: {pick: ["do", "name"]}, expect: [["remove-daemon", "shop-own"]]},
		{call: "runners.hostSteps", args: [_rnAcc, _rnSeen & {"shop-own": {legacyDaemon: true, agent: false}}]},
		{map: {pick: ["do", "name"]}, expect: [["remove-daemon", "shop-own"], ["agent", "shop-own"]]},
	]}
	"a step that cuts a running job waits for the runner to be idle again right before it acts": {suite: "runners", steps: [
		{value: [{do: "unregister"}, {do: "agent"}, {do: "unregister-old"}, {do: "unregister-as"}, {do: "unlock"}, {do: "daemon"}, {do: "remove-daemon"}, {do: "drain"}, {do: "hook"}, {do: "register-as"}, {do: "lock"}]},
		{map: {call: "runners.gatedByBusy", args: ["$"]}, expect: [true, true, true, true, true, true, true, false, false, false, false]},
	]}

	// Without passwordless sudo the account's folder is closed: a runner that already has its files is judged
	// by them and by GitHub, one that is not there is still to be moved, and one that cannot be told is left alone.
	"without sudo a migrated runner that GitHub shows online is current, and a second apply does nothing": {suite: "runners", steps: [
		{call: "runners.inspectAccount", args: [_rnAcc, "shop-pr", _rnFacts]},
		{keep: "seen"},
		{call: "runners.hostSteps", args: [_rnAcc, _rnRest & {"shop-pr": "$seen"}], expect: []},
	]}
	"without sudo a runner with its files that GitHub does not show online is left alone, reported unknown": {suite: "runners", steps: [
		{call: "runners.inspectAccount", args: [_rnAcc, "shop-pr", _rnFacts & {gh: {status: "offline", labels: ["shop-pr"]}}]},
		{keep: "seen"},
		{call: "runners.hostSteps", args: [_rnAcc, _rnRest & {"shop-pr": "$seen"}]},
		{map: {pick: ["do", "name"]}, expect: [["unknown", "shop-pr"]]},
		{call: "runners.inspectAccount", args: [_rnAcc, "shop-pr", _rnFacts & {gh: null}]},
		{keep: "seen"},
		{call: "runners.hostSteps", args: [_rnAcc, _rnRest & {"shop-pr": "$seen"}]},
		{map: {pick: ["do", "name"]}, expect: [["unknown", "shop-pr"]]},
	]}
	"without sudo a runner not yet moved is still planned, from the old folder it can read": {suite: "runners", steps: [
		{call: "runners.inspectAccount", args: [_rnAcc, "shop-pr", _rnFacts & {hookSame: false, daemonSame: false, oldRegistered: true, account: false, gh: {status: "online", labels: ["shop-pr"]}}]},
		{keep: "seen"},
		{call: "runners.hostSteps", args: [_rnAcc, _rnRest & {"shop-pr": "$seen"}]},
		{map: {pick: ["do"]}, expect: [["account"], ["drain"], ["unregister-old"], ["install-as"], ["register-as"], ["lock"], ["hook"], ["daemon"]]},
	]}

	// The hook, as generated, run as the runner runs it (bash -e -o pipefail) with the environment a job gives it,
	// as the account it names. One generated text, so the decision is the one the machine makes.
	"the admits hook takes the named workflow on main, on an event it admits, with root's tools": {suite: "runners", steps: [
		{call: "probe.runHook", args: [_rnTrusted, _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "workflow_run"}}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{call: "probe.runHook", args: [_rnTrusted, _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "schedule"}}]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{call: "probe.runHook", args: [_rnTrusted, _rnOk & {env: {GITHUB_WORKFLOW_REF: "acme/shop/.github/workflows/regenerate.yml@refs/heads/main", GITHUB_EVENT_NAME: "push"}}]},
		{keep: "ran"},
		{get: "code", expect: 0},
	]}
	"the admits hook refuses a pull request's event even if an arm named it": {suite: "runners", steps: [
		{call: "probe.replaced", args: [_rnTrusted, "\\|workflow_run\"\\)", "|pull_request\")"]},
		{keep: "named"},
		{call: "probe.includes", args: ["$named", "automerge.yml@refs/heads/main|pull_request\")"], expect: true, why: "the arm names a pull request"},
		{call: "probe.runHook", args: ["$named", _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "pull_request"}}]},
		{keep: "ran"},
		{get: "code", expect: 1},
		{use: "ran"},
		{get: "said", matches: "refuses: event pull_request$"},
	]}
	for n, e in _rnRefused {
		"the admits hook refuses \(n)": {suite: "runners", steps: [
			{call: "probe.runHook", args: [_rnTrusted, e]},
			{keep: "ran"},
			{get: "code", expect: 1},
			{use: "ran"},
			{get: "said", matches: "^runner shop-trusted refuses: "},
		]}
	}

	"the admits hook names the tool it did not find": {suite: "runners", steps: [
		{call: "probe.runHook", args: [_rnTrusted, _rnRefused["a tool that is not found"]]},
		{get: "said", matches: "refuses: nosuchtool not found$"},
	]}

	// The probe, run as the runner runs it, on a scratch HOME and scratch paths standing in for the ones the
	// setup lists: it passes on a clean account and each check fails it by what it checks. (A group is
	// the running user's own; a keychain item is a stand-in `security` on its PATH.)
	"the pr probe passes on a clean account, whose environment may hold the job's own tokens": {suite: "runners", steps: [
		{call: "probe.runHook", args: [_rnPrHook, _rnPr]},
		{keep: "ran"},
		{get: "code", expect: 0},
		{call: "probe.runHook", args: [_rnPrHook, _rnPr & {env: {GITHUB_TOKEN: "x", ACTIONS_RUNTIME_TOKEN: "y"}}]},
		{keep: "ran"},
		{get: "code", expect: 0},
	]}
	for n, f in _rnFaults {
		"the pr probe fails on \(n)": {suite: "runners", steps: [
			{call: "probe.runHook", args: [_rnPrHook, _rnPr & f.run]},
			{keep: "ran"},
			{get: "code", expect: 1},
			{use: "ran"},
			{get: "said", matches: f.said},
		]}
	}
}

_rnDone: {account: *true | bool, oldRegistered: *false | bool, installed: *true | bool, registration: *"current" | string, hook: *true | bool, tools: *true | bool, locked: *true | bool, daemon: *true | bool}
_rnAgent: {installed: true, registration: *"current" | string, agent: *true | bool, hook: *true | bool, legacyDaemon: *false | bool}
_rnRest: {"shop-trusted": _rnDone, "shop-agent": _rnAgent, "shop-own": _rnAgent}
_rnSeen: _rnRest & {"shop-pr": _rnDone}
_rnFacts: {sudo: false, account: *true | bool, oldRegistered: *false | bool, hookSame: *true | bool, daemonSame: *true | bool, loaded: false, gh: *{status: "online", labels: ["self-hosted", "macOS", "ARM64", "shop-pr"]} | null | {status: string, labels: [...string]}, found: {runner: null, path: null, labels: null}, installed: false, locked: false, tools: false}
_rnOtoolOk: "printf \"x:\\n\\t/usr/lib/libSystem.B.dylib (compat)\\n\\t/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation (compat)\\n\""
_rnTarSha: hex.Encode(sha256.Sum256("TARBALL"))
_rnAcc:    rn.plans["check-accounts"]
// The lock's folder, and the manifest the install recorded beside it, standing in a scratch folder.
_rnDir: "/Library/Application Support/pronto-runners/shop-pr/runner"
_rnTree: "/Library/Application Support/pronto-runners/shop-pr/tree.mtree"
_rnRep: {(_rnDir): "@tmp/runner", (_rnTree): "@tmp/tree.mtree"}
_rnManRep: {"/s/runner.tar.gz": "@tmp/staged", (_rnAcc.host["shop-pr"].download.sha256): _rnTarSha, (_rnTree): "@tmp/tree.mtree"}
_rnMk: {(_rnDir + "/_work"): "@tmp/runner/_work", (_rnDir + "/_diag"): "@tmp/runner/_diag"}
_rnEnvRep: {(_rnDir): "@tmp/d"}
// A tarball's tree as mtree records it (a file's sha256, a link's target), and a folder that is it.
_rnX: hex.Encode(sha256.Sum256("x"))
_rnSpec: "/set type=file\n.               type=dir\nbin             type=dir\n    x           sha256digest=\(_rnX)\n..\nexternals       type=dir\nnode20          type=dir\nbin             type=dir\n    npm         type=link link=../lib/npm-cli.js\n..\n..\n..\n..\n"
// A scratch folder for the strip: ACLs on the folder, a file, a nested folder and a file outside the tree that a link inside names.
_rnStrip: {acls: ["runner", "runner/f", "runner/d", "outside/f"], files: {"runner/f": "x", "runner/d/g": "y", "outside/f": "o"}, links: "runner/out": "../outside/f", replace: {(_rnDir): "@tmp/runner", (_rnDir + "/_work"): "@tmp/runner/_work", (_rnDir + "/_diag"): "@tmp/runner/_diag", OUT: "@tmp/outside/f", LNK: "@tmp/runner/out"}}
_rnCl: {files: {"runner/bin/x": *"x" | string, "tree.mtree": _rnSpec}, links: "runner/externals/node20/bin/npm": *"../lib/npm-cli.js" | string, replace: _rnRep}
_rnReal:   rn.plans["bsoneca-mac"]
_rnTrusted: _rnAcc.host["shop-trusted"].hook.text
_rnPrHook: _rnAcc.host["shop-pr"].hook.text
_rnAutomerge: {GITHUB_WORKFLOW_REF: "acme/shop/.github/workflows/automerge.yml@refs/heads/main"}
// What the admits hook runs with: the account it names is the running one, and gh, git and jq are scripts in
// its PATH that are "root's" (the user running them, standing in for uid 0).
_rnOk: {user: *"@me" | string, homeMode: *0o700 | int, bin: {gh: "exit 0", git: "exit 0", jq: "exit 0"}, sub: {"rootuid=0": *"rootuid=@uid" | string, ...}, env: {...}}
_rnRefused: {
	"a pull request's event, even of the named workflow on main": _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "pull_request"}}
	"a pull_request_target's": _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "pull_request_target"}}
	"an event the workflow does not admit": _rnOk & {env: _rnAutomerge & {GITHUB_EVENT_NAME: "push"}}
	"another workflow": _rnOk & {env: {GITHUB_WORKFLOW_REF: "acme/shop/.github/workflows/ci.yml@refs/heads/main", GITHUB_EVENT_NAME: "workflow_run"}}
	"another repository's workflow of the same name": _rnOk & {env: {GITHUB_WORKFLOW_REF: "acme/other/.github/workflows/automerge.yml@refs/heads/main", GITHUB_EVENT_NAME: "workflow_run"}}
	"another ref": _rnOk & {env: {GITHUB_WORKFLOW_REF: "acme/shop/.github/workflows/automerge.yml@refs/heads/feat/x", GITHUB_EVENT_NAME: "workflow_run"}}
	"a tag": _rnOk & {env: {GITHUB_WORKFLOW_REF: "acme/shop/.github/workflows/automerge.yml@refs/tags/v1", GITHUB_EVENT_NAME: "workflow_run"}}
	"no workflow at all": _rnOk & {env: {}}
	"the wrong account": _rnOk & {user: "someone-else", env: _rnAutomerge & {GITHUB_EVENT_NAME: "workflow_run"}}
	"a home that is not mode 700": _rnOk & {homeMode: 0o755, env: _rnAutomerge & {GITHUB_EVENT_NAME: "workflow_run"}}
	"tools that are not root's": _rnOk & {sub: {"rootuid=0": "rootuid=999999"}, env: _rnAutomerge & {GITHUB_EVENT_NAME: "workflow_run"}}
	"a tool that is not found": _rnOk & {sub: {"gh git jq": "gh git jq nosuchtool"}, env: _rnAutomerge & {GITHUB_EVENT_NAME: "workflow_run"}}
}
// The probe's paths and groups pointed at a scratch folder (nothing there, unwritable, unreadable) and a group
// nobody is in, and a `security` that finds nothing: a clean account.
_rnPr: {user: "@me", bin: {security: *"exit 44" | string}, files: {...}, env: {...}, sub: {
	"/Users/ci-trusted":                          *"@tmp/no1" | string
	"/Users/check":                               *"@tmp/no2" | string
	"/opt/homebrew/bin":                          *"@tmp/p1" | string
	"/Users/Shared/pronto/mise":                  *"@tmp/p2" | string
	"/Library/LaunchDaemons":                     *"@tmp/p3" | string
	"/Library/Application Support/pronto-runners": *"@tmp/p4" | string
	"admin|studio":                               *"nosuchg1|nosuchg2" | string
}}
_rnFaults: {
	"a gh login": {run: {files: "home/.config/gh/hosts.yml": "x"}, said: "hosts\\.yml exists$"}
	"a gcloud credential": {run: {files: "home/.config/gcloud/credentials.db": "x"}, said: "credentials\\.db exists$"}
	"a git credential": {run: {files: "home/.git-credentials": "x"}, said: "\\.git-credentials exists$"}
	"a Codex login": {run: {files: "home/.codex/auth.json": "x"}, said: "\\.codex/auth\\.json exists$"}
	"a Codex folder": {run: {files: "home/.codex/config.toml": "x"}, said: "\\.codex exists$"}
	"an ssh key": {run: {files: "home/.ssh/id_ed25519": "x"}, said: "id_ed25519 exists$"}
	"a keychain item for github.com": {run: {bin: security: "exit 0"}, said: "the keychain holds gh:github\\.com$"}
	"a writable /opt/homebrew/bin": {run: {files: "p1/x": ""}, said: "p1 is writable$"}
	"a writable shared mise store": {run: {files: "p2/x": ""}, said: "p2 is writable$"}
	"a writable /Library/LaunchDaemons": {run: {files: "p3/x": ""}, said: "p3 is writable$"}
	"a writable hooks folder": {run: {files: "p4/x": ""}, said: "p4 is writable$"}
	"a token-like variable": {run: {env: MY_API_TOKEN: "x"}, said: "MY_API_TOKEN looks like a token$"}
	"a secret-like variable": {run: {env: DEPLOY_SECRET: "x"}, said: "DEPLOY_SECRET looks like a token$"}
	"a forbidden group": {run: {sub: "admin|studio": "@group|nosuchg2"}, said: "in group "}
	"another account's home that can be listed": {run: {files: "no1/x": ""}, said: "can list "}
	"the applier's own home that can be listed": {run: {files: "no2/x": ""}, said: "can list "}
}
