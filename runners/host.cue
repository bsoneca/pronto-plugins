// The runners host: a setup (schema.cue) rendered into what runners.ts applies, in order: the VM (a
// Colima setup's), the controller's chart, BuildKit's objects, then each scale set's chart values;
// or, for a host setup, each host runner's download, registration and service (a launchd agent on
// macOS, a systemd unit on Linux).
// Nothing here is written by hand anywhere else: runners.ts exports a plan and applies it as it is.
package runners

import (
	"list"
	"strings"
	shalib "crypto/sha256"
	"encoding/hex"
)

// Where every hook lives, in a folder only root writes, and what an XML plist escapes.
_hookRoot: "/Library/Application Support/pronto-runners"
#Esc: {
	s:   string
	out: strings.Replace(strings.Replace(strings.Replace(s, "&", "&amp;", -1), "<", "&lt;", -1), ">", "&gt;", -1)
}

// Every setup's plan, for the checks (tests.cue gives them a home); runners.ts exports one through
// export/, with the person's.
plans: {for name, s in setups {(name): #Plan & {setup: s}}}

#Plan: P={
	setup: #Setup
	// The person's home directory: a host runner's folder, logs and agent are under it.
	home: =~"^/"
	// The person's login, which a systemd unit runs as (a launchd agent is theirs already).
	user: *"" | =~"^[a-z_][a-z0-9_.-]*$"
	// The accounts the apply creates, and the root-owned files it writes (a runner with a `user`).
	accounts?: [...{login: string, role: string, home: string, mode: string, hidden: bool, group: string, password: bool}]
	files?: [...{path: string, owner: string, mode: string, what: string, runner: string}]
	// Where the setup's amd64 images build (schema.cue's amd64), as every runner's jobs read it.
	env: PRONTO_AMD64: setup.amd64

	if setup.cluster.host == _|_ {
		// The kubeconfig context every kubectl and helm call names, never the current one.
		context: string
		if setup.cluster.colima != _|_ {
			colima:  setup.cluster.colima
			context: "colima-\(setup.cluster.colima.profile)"
		}
		if setup.cluster.context != _|_ {
			context: setup.cluster.context
		}

		charts: {
			repo:    "oci://ghcr.io/actions/actions-runner-controller-charts"
			version: setup.versions.charts
		}
		controller: {namespace: "arc-systems", release: "arc"}
		runnerNamespace: "arc-runners"
		secret:          setup.secret

		_b: {
			namespace: "buildkit"
			name:      "buildkitd"
			port:      1234
		}
		// What a runner hands to `docker buildx create --driver remote` ($BUILDKIT_HOST in its pod).
		endpoint: "tcp://\(_b.name).\(_b.namespace).svc.cluster.local:\(_b.port)"

		buildkit: [{
			apiVersion: "v1"
			kind:       "Namespace"
			metadata: name: _b.namespace
		}, {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {name: _b.name, namespace: _b.namespace}
			// mirror.gcr.io: dodge Docker Hub's anonymous pull cap.
			data: "buildkitd.toml": """
				[worker.oci]
				  gc = true
				  [[worker.oci.gcpolicy]]
				    keepBytes = \(setup.buildkit.keep*1024*1024*1024)
				[registry."docker.io"]
				  mirrors = ["mirror.gcr.io"]

				"""
		}, {
			apiVersion: "v1"
			kind:       "PersistentVolumeClaim"
			metadata: {name: _b.name, namespace: _b.namespace}
			spec: {
				accessModes: ["ReadWriteOnce"]
				resources: requests: storage: "\(setup.buildkit.cache)Gi"
			}
		}, {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata: {name: _b.name, namespace: _b.namespace}
			spec: {
				replicas: 1
				// One BuildKit owns the cache volume: the old one stops before the new one starts.
				strategy: type: "Recreate"
				selector: matchLabels: app: _b.name
				template: {
					metadata: labels: app: _b.name
					spec: {
						if len(setup.buildkit.emulate) > 0 {
							// binfmt is the kernel's: registered before BuildKit starts, so it sees the platforms.
							initContainers: [{
								name:  "binfmt"
								image: setup.versions.binfmt
								args: ["--install", strings.Join([for p in setup.buildkit.emulate {strings.TrimPrefix(p, "linux/")}], ",")]
								securityContext: privileged: true
							}]
						}
						containers: [{
							name:  "buildkitd"
							image: setup.versions.buildkit
							args: ["--addr", "unix:///run/buildkit/buildkitd.sock", "--addr", "tcp://0.0.0.0:\(_b.port)", "--config", "/etc/buildkit/buildkitd.toml"]
							securityContext: privileged: true
							ports: [{containerPort: _b.port}]
							readinessProbe: {exec: command: ["buildctl", "debug", "workers"], periodSeconds: 10}
							volumeMounts: [
								{name: "cache", mountPath: "/var/lib/buildkit"},
								{name: "config", mountPath: "/etc/buildkit"},
							]
						}]
						volumes: [
							{name: "cache", persistentVolumeClaim: claimName: _b.name},
							{name: "config", configMap: name: _b.name},
						]
					}
				}
			}
		}, {
			apiVersion: "v1"
			kind:       "Service"
			metadata: {name: _b.name, namespace: _b.namespace}
			spec: {
				selector: app: _b.name
				ports: [{port: _b.port, targetPort: _b.port}]
			}
		}]

		// Each scale set's release (its name, what runs-on says) and its chart values.
		scaleSets: {for name, s in setup.scaleSets {
			(name): {
				githubConfigUrl: "https://github.com/\(setup.github.owner)" + [if s.repo != _|_ {"/\(s.repo)"}, ""][0]
				githubConfigSecret: P.secret.name
				runnerScaleSetName: name
				minRunners:         s.min
				maxRunners:         s.max
				template: spec: {
					nodeSelector: "kubernetes.io/arch": s.arch
					containers: [{
						name:  "runner"
						image: setup.versions.runnerImage
						command: ["/home/runner/run.sh"]
						env: [{name: "BUILDKIT_HOST", value: P.endpoint}, for k, v in P.env {name: k, value: v}]
					}]
				}
			}
		}}
	}

	if setup.cluster.host != _|_ {
		_os:       setup.cluster.host.os
		_platform: "\({macos: "osx", linux: "linux"}[_os])-\(setup.cluster.host.arch)"
		// What GitHub labels the runner with besides the setup's: its OS and arch.
		runsOn: ["self-hosted", {macos: "macOS", linux: "Linux"}[_os], {arm64: "ARM64", x64: "X64"}[setup.cluster.host.arch]]
		service: setup.hostService
		if service == "systemd" {user: !=""}

		// What the apply creates for the setup's accounts, and the files that are root's, with their
		// owner and mode (only a setup that has accounts and runners that use them has either).
		_accounts: [for l, a in setup.accounts if !a.existing {login: l, role: a.role, home: a.home, mode: "700", hidden: true, group: a.group, password: false}]
		if len(_accounts) > 0 {accounts: _accounts}
		_files: [for n, r in setup.hostRunners if r.user != "" || len(r.admits) > 0 for f in host[n].files {f & {runner: n}}]
		if len(_files) > 0 {files: _files}

		// Each host runner: its download, what config.sh registers, and its service.
		host: {for name, r in setup.hostRunners {
			(name): {
				_repo: [if r.repo != _|_ {"\(setup.github.owner)/\(r.repo)"}, setup.github.owner][0]
				url: "https://github.com/\(_repo)"
				// Where gh asks for the short-lived registration and removal tokens.
				api: [if r.repo != _|_ {"repos/\(_repo)/actions/runners"}, "orgs/\(setup.github.owner)/actions/runners"][0]
				labels: r.labels
				// The folder is under the runner's account's home, or the applier's.
				_home:  [if r.user != "" {setup.accounts[r.user].home}, P.home][0]
				// An account's runner lives outside its home, where its parent is root's and it can neither
				// rename nor replace the folder.
				dir: [if r.user != "" {l: "\(_hookRoot)/\(name)/runner"}, {l: "\(_home)/\(r.dir)"}][0].l
				work:   r.work
				path: strings.Join([for p in r.path {[if strings.HasPrefix(p, "~/") {_home + strings.TrimPrefix(p, "~")}, p][0]}], ":")
				download: {
					url:    "https://github.com/actions/runner/releases/download/v\(setup.versions.hostRunner.version)/actions-runner-\(P._platform)-\(setup.versions.hostRunner.version).tar.gz"
					sha256: setup.versions.hostRunner.sha256[P._platform]
				}
				// The service actions/runner's own svc.sh would write, at a lower CPU priority.
				_label: "actions.runner.\(strings.Replace(_repo, "/", "-", -1)).\(name)"
				service: label: _label
				if P.service == "launchd" && r.user == "" {service: {
					label: string
					path:  "\(P.home)/Library/LaunchAgents/\(label).plist"
					plist: {
						Label: label
						ProgramArguments: ["/bin/bash", "\(dir)/bin/runsvc.sh"]
						WorkingDirectory:  dir
						RunAtLoad:         true
						StandardOutPath:   "\(P.home)/Library/Logs/\(label)/stdout.log"
						StandardErrorPath: "\(P.home)/Library/Logs/\(label)/stderr.log"
						EnvironmentVariables: {ACTIONS_RUNNER_SVC: "1", P.env, if len(r.admits) > 0 {ACTIONS_RUNNER_HOOK_JOB_STARTED: _hookPath}}
						ProcessType:   "Interactive"
						SessionCreate: true
						Nice:          r.nice
					}
				}}

				// What a hook is, for a runner with an account or one of the applier's that admits workflows:
				// root's file in a folder no account can write, named by the service's environment, which the
				// account cannot edit either, so its jobs cannot drop it.
				_hookDir:  "\(_hookRoot)/\(name)"
				_hookPath: "\(_hookDir)/job-started.sh"
				_toolsDir: "/usr/local/\(r.user)/bin"
				_role: [if r.user != "" {setup.accounts[r.user].role}, "agent"][0]
				// The account the hook insists on: the runner's, or the applier's own.
				_want: [if r.user != "" {r.user}, P.user][0]
				if r.user != "" || len(r.admits) > 0 {
					_wantSet: _want & !=""
					hook: {
						path:  _hookPath
						owner: "root:wheel"
						mode:  "755"
						text:  strings.Join([
							"#!/bin/bash",
							"# Generated from the setup (pronto-plugins runners/host.cue), root:wheel 755: do not edit.",
							"set -u",
							"want='\(_want)'",
							"fail() { echo \"runner \(name) refuses: $*\" >&2; exit 1; }",
							"[ \"$(id -un)\" = \"$want\" ] || fail \"wrong account\"",
							if _role == "pr" {_probe},
							if _role != "pr" {_admits},
							"exit 0",
							"",
						], "\n")
						sha256: hex.Encode(shalib.Sum256(text))
					}
				}
				// What an admits hook takes: not a pull request's event, one of the (workflow at its ref,
				// event) pairs the runner admits, a home that is mode 700 and, for an account's runner, tools
				// that are root's wherever its PATH finds them.
				_admits: strings.Join([
					"case \"${GITHUB_EVENT_NAME:-}\" in pull_request*) fail \"event $GITHUB_EVENT_NAME\";; esac",
					"case \"${GITHUB_WORKFLOW_REF:-}|${GITHUB_EVENT_NAME:-}\" in",
					for a in r.admits for e in a.events {"  \"\(_repo)/\(a.workflow)@\(a.ref)|\(e)\") ;;"},
					"  *) fail \"${GITHUB_WORKFLOW_REF:-} (${GITHUB_EVENT_NAME:-})\";;",
					"esac",
					"[ \"$(ls -ld \"$HOME\" | cut -c1-10)\" = \"drwx------\" ] || fail \"home is not mode 700\"",
					if r.user != "" {
						strings.Join([
							"rootuid=0",
							"for t in \(strings.Join(setup.trustedTools, " "))",
							"do",
							"  p=$(command -v \"$t\") || fail \"$t not found\"",
							"  [ \"$(ls -lnL \"$p\" | awk '{print $3}')\" = \"$rootuid\" ] || fail \"$t is not root's: $p\"",
							"done",
						], "\n")
					},
				], "\n")
				// What a pull request's runner proves of its account on every job, before any step: the
				// other accounts' homes, the credentials, the paths other accounts execute, the token-like
				// environment. The lists are the setup's, not written here.
				_others: [for l, a in setup.accounts if l != r.user {a.home}]
				_protected: list.Concat([setup.protectedPaths, [_hookRoot]])
				_probe: strings.Join([
					"for g in $(id -Gn); do",
					"  case \"$g\" in",
					"    \(strings.Join(setup.forbiddenGroups, "|"))) fail \"in group $g\";;",
					"  esac",
					"done",
					for h in _others {"ls \"\(h)\" >/dev/null 2>&1 && fail \"can list \(h)\""},
					"security find-generic-password -s gh:github.com >/dev/null 2>&1 && fail \"the keychain holds gh:github.com\"",
					"for f in \"$HOME/.config/gh/hosts.yml\" \"$HOME/.config/gcloud/credentials.db\" \"$HOME/.git-credentials\" \"$HOME/.codex/auth.json\" \"$HOME/.codex\" \"$HOME\"/.ssh/id_*; do",
					"  [ -e \"$f\" ] && fail \"$f exists\"",
					"done",
					for p in _protected {"[ -w \"\(p)\" ] && fail \"\(p) is writable\""},
					"for v in $(compgen -e); do",
					"  case \"$v\" in GITHUB_TOKEN|ACTIONS_*) continue;; esac",
					"  case \"$v\" in",
					"    \(strings.Join(setup.tokenPatterns, "|"))) fail \"$v looks like a token\";;",
					"  esac",
					"done",
				], "\n")

				// An applier's runner behind a hook keeps its agent: only the hook is root's.
				if r.user == "" && len(r.admits) > 0 {
					files: [
						{path: _hookDir, owner: "root:wheel", mode: "755", what: "the hook's folder"},
						{path: _hookPath, owner: "root:wheel", mode: "755", what: "the job-started hook"},
					]
				}

				// A runner with an account is a LaunchDaemon of the system's (root's plist, under
				// /Library/LaunchDaemons) run as that account, from its home.
				if P.service == "launchd" && r.user != "" {
					user:  r.user
					group: setup.accounts[r.user].group
					home:  _home
					// Where the applier's own agent for this runner was, folder and service: the runner
					// moves from there, and its folder is kept.
					previous: {
						dir: "\(P.home)/\(r.dir)"
						service: {label: _label, path: "\(P.home)/Library/LaunchAgents/\(_label).plist"}
					}
					_logs: "/Library/Logs/pronto-runners/\(service.label)"
					// What a trusted account's PATH finds first: root's copies of the tools its jobs may run.
					if _role == "trusted" {
						tools: {
							dir: _toolsDir
							gh:  setup.versions.gh[P._platform]
						}
					}
					service: {
						label: string
						path:  "/Library/LaunchDaemons/\(label).plist"
						plist: {
							Label: label
							ProgramArguments: ["/bin/bash", "\(dir)/bin/runsvc.sh"]
							WorkingDirectory:  dir
							RunAtLoad:         true
							StandardOutPath:   "\(_logs)/stdout.log"
							StandardErrorPath: "\(_logs)/stderr.log"
							EnvironmentVariables: {ACTIONS_RUNNER_SVC: "1", ACTIONS_RUNNER_HOOK_JOB_STARTED: _hookPath, HOME: _home, P.env, r.env}
							UserName:  r.user
							GroupName: group
							Nice:      r.nice
						}
						// The plist as launchd reads it, the text whose sha256 is checked before root installs it.
						xml: strings.Join([
							"<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
							"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
							"<plist version=\"1.0\">",
							"<dict>",
							"\t<key>Label</key><string>\((#Esc & {s: plist.Label}).out)</string>",
							"\t<key>ProgramArguments</key>",
							"\t<array>",
							for a in plist.ProgramArguments {"\t\t<string>\((#Esc & {s: a}).out)</string>"},
							"\t</array>",
							"\t<key>WorkingDirectory</key><string>\((#Esc & {s: plist.WorkingDirectory}).out)</string>",
							"\t<key>RunAtLoad</key><true/>",
							"\t<key>StandardOutPath</key><string>\((#Esc & {s: plist.StandardOutPath}).out)</string>",
							"\t<key>StandardErrorPath</key><string>\((#Esc & {s: plist.StandardErrorPath}).out)</string>",
							"\t<key>EnvironmentVariables</key>",
							"\t<dict>",
							for k, v in plist.EnvironmentVariables {"\t\t<key>\(k)</key><string>\((#Esc & {s: v}).out)</string>"},
							"\t</dict>",
							"\t<key>UserName</key><string>\((#Esc & {s: plist.UserName}).out)</string>",
							"\t<key>GroupName</key><string>\((#Esc & {s: plist.GroupName}).out)</string>",
							"\t<key>Nice</key><integer>\(plist.Nice)</integer>",
							"</dict>",
							"</plist>",
							"",
						], "\n")
						sha256: hex.Encode(shalib.Sum256(xml))
					}
					// What the apply puts in root's hands or the account's, with its owner and mode. The runner's
					// folder is root's but for the folders its jobs write, so its account cannot edit .env, .path
					// or bin/ to drop the hook; its listener only writes _work and _diag.
					files: [
						{path: _hookDir, owner: "root:wheel", mode: "755", what: "the hook's folder"},
						{path: _hookPath, owner: "root:wheel", mode: "755", what: "the job-started hook"},
						{path: service.path, owner: "root:wheel", mode: "644", what: "the LaunchDaemon"},
						{path: _logs, owner: "root:wheel", mode: "755", what: "the daemon's logs (launchd makes the files)"},
						{path: dir, owner: "root:\(setup.accounts[r.user].group)", mode: "750", what: "the runner's folder, readable by its account's group alone"},
						{path: "\(dir)/\(work)", owner: "\(r.user):\(setup.accounts[r.user].group)", mode: "700", what: "the jobs' checkouts"},
						{path: "\(dir)/_diag", owner: "\(r.user):\(setup.accounts[r.user].group)", mode: "700", what: "the runner's logs"},
						if _role == "trusted" {
							{path: _toolsDir, owner: "root:wheel", mode: "755", what: "the trusted PATH: \(strings.Join(setup.trustedTools, ", ")); gh pinned (versions.gh), the rest the system's"}
						},
					]
				}

				// svc.sh's unit (its actions.runner.service.template): the system's, run as the person,
				// stopped gently so a job may finish.
				if P.service == "systemd" {service: {
					label: string
					path:  "/etc/systemd/system/\(label).service"
					unit: strings.Join([
						"[Unit]",
						"Description=GitHub Actions Runner (\(_repo).\(name))",
						"After=network.target",
						"",
						"[Service]",
						"ExecStart=/bin/bash \(dir)/bin/runsvc.sh",
						"User=\(P.user)",
						"WorkingDirectory=\(dir)",
						"KillMode=process",
						"KillSignal=SIGTERM",
						"TimeoutStopSec=5min",
						"Nice=\(r.nice)",
						"Environment=ACTIONS_RUNNER_SVC=1",
						for k, v in P.env {"Environment=\(k)=\(v)"},
						"",
						"[Install]",
						"WantedBy=multi-user.target",
						"",
					], "\n")
				}}
			}
		}}
	}
}
