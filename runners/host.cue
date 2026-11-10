// The runners host: a setup (schema.cue) rendered into what runners.ts applies, in order: the VM (a
// Colima setup's), the controller's chart, BuildKit's objects, then each scale set's chart values;
// or, for a host setup, each host runner's download, registration and service (a launchd agent on
// macOS, a systemd unit on Linux).
// Nothing here is written by hand anywhere else: runners.ts exports a plan and applies it as it is.
package runners

import "strings"

// Every setup's plan, for the checks (tests.cue gives them a home); runners.ts exports one through
// export/, with the person's.
plans: {for name, s in setups {(name): #Plan & {setup: s}}}

#Plan: P={
	setup: #Setup
	// The person's home directory: a host runner's folder, logs and agent are under it.
	home: =~"^/"
	// The person's login, which a systemd unit runs as (a launchd agent is theirs already).
	user: *"" | =~"^[a-z_][a-z0-9_.-]*$"
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

		// Each host runner: its download, what config.sh registers, and its service.
		host: {for name, r in setup.hostRunners {
			(name): {
				_repo: [if r.repo != _|_ {"\(setup.github.owner)/\(r.repo)"}, setup.github.owner][0]
				url: "https://github.com/\(_repo)"
				// Where gh asks for the short-lived registration and removal tokens.
				api: [if r.repo != _|_ {"repos/\(_repo)/actions/runners"}, "orgs/\(setup.github.owner)/actions/runners"][0]
				labels: r.labels
				dir:    "\(P.home)/\(r.dir)"
				work:   r.work
				path: strings.Join([for p in r.path {[if strings.HasPrefix(p, "~/") {P.home + strings.TrimPrefix(p, "~")}, p][0]}], ":")
				download: {
					url:    "https://github.com/actions/runner/releases/download/v\(setup.versions.hostRunner.version)/actions-runner-\(P._platform)-\(setup.versions.hostRunner.version).tar.gz"
					sha256: setup.versions.hostRunner.sha256[P._platform]
				}
				// The service actions/runner's own svc.sh would write, at a lower CPU priority.
				service: label: "actions.runner.\(strings.Replace(_repo, "/", "-", -1)).\(name)"
				if P.service == "launchd" {service: {
					label: string
					path:  "\(P.home)/Library/LaunchAgents/\(label).plist"
					plist: {
						Label: label
						ProgramArguments: ["/bin/bash", "\(dir)/bin/runsvc.sh"]
						WorkingDirectory:  dir
						RunAtLoad:         true
						StandardOutPath:   "\(P.home)/Library/Logs/\(label)/stdout.log"
						StandardErrorPath: "\(P.home)/Library/Logs/\(label)/stderr.log"
						EnvironmentVariables: {ACTIONS_RUNNER_SVC: "1", P.env}
						ProcessType:   "Interactive"
						SessionCreate: true
						Nice:          r.nice
					}
				}}

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
