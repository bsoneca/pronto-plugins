// The runners host: a setup (schema.cue) rendered into what runners.ts applies, in order: the VM (a
// Colima setup's), the controller's chart, BuildKit's objects, then each scale set's chart values.
// Nothing here is written by hand anywhere else: runners.ts exports a plan and applies it as it is.
package runners

import "strings"

plans: {for name, s in setups {(name): #Plan & {setup: s}}}

#Plan: P={
	setup: #Setup

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
					env: [{name: "BUILDKIT_HOST", value: P.endpoint}]
				}]
			}
		}
	}}
}
