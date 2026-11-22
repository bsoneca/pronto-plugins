package schema

import (
	"list"
	"regexp"
	"strconv"
	"strings"
)

// The node release engine's schema (README.md, "The node release engine"): the release of a pronto
// app onto the Contabo node's k3s, written as the app's own `node/schema/node.cue`. It imports
// nothing of upstream pronto: the app renders upstream's manifests itself,
//
//   upstream: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
//
// and hands them to #Manifests, which patches, adds to and checks them. The interface with upstream
// is its CUE (k8s.#BuildManifests, k8s.#Environment), and the contract test (node/engine/contract_test.nu)
// pins what a version of it renders.

// The versions of the operators the node runs: one place. The engine installs none of them; their
// owner is the node's own prep, and a bump there is a bump here, in a pin pull request. Each must
// have its row in #Served, or an app's generate fails.
#Operators: {
	dapr:            *"1.16.21" | string
	cnpg:            *"1.30.1" | string
	externalSecrets: *"0.10.5" | string
	envoyGateway:    *"1.2.4" | string
	gatewayAPI:      *"1.2.1" | string
	barmanCloud:     *"0.15.1" | string

	// The (apiVersion/kind) pairs the release may emit: the core ones, and each operator's at the
	// version above. A version without a row is an error (it has not been looked at).
	served: list.Concat([#Served.core, #Served.dapr[dapr], #Served.cnpg[cnpg], #Served.externalSecrets[externalSecrets],
		#Served.envoyGateway[envoyGateway], #Served.gatewayAPI[gatewayAPI], #Served.barmanCloud[barmanCloud]])
}

// What each operator version serves, as `apiVersion/Kind`, from the node's own dry run of
// 2026-11-19 (29 of 29 objects of upstream v1.5.1's aprende accepted).
#Served: {
	core: [
		"v1/Namespace", "v1/Service", "v1/ConfigMap", "v1/Secret", "v1/ResourceQuota", "v1/LimitRange",
		"apps/v1/Deployment", "batch/v1/Job", "networking.k8s.io/v1/NetworkPolicy",
	]
	dapr: "1.16.21":           ["dapr.io/v1alpha1/Configuration", "dapr.io/v1alpha1/Resiliency"]
	cnpg: "1.30.1":            ["postgresql.cnpg.io/v1/Cluster", "postgresql.cnpg.io/v1/ScheduledBackup", "postgresql.cnpg.io/v1/Backup"]
	externalSecrets: "0.10.5": ["external-secrets.io/v1beta1/ExternalSecret", "generators.external-secrets.io/v1alpha1/Password"]
	envoyGateway: "1.2.4":     ["gateway.envoyproxy.io/v1alpha1/BackendTrafficPolicy"]
	gatewayAPI: "1.2.1":       ["gateway.networking.k8s.io/v1/Gateway", "gateway.networking.k8s.io/v1/HTTPRoute"]
	barmanCloud: "0.15.1":     ["barmancloud.cnpg.io/v1/ObjectStore"]
}

// What `retire` may delete, with the resource kubectl is told (kind.group, unambiguous). Never an
// ExternalSecret, an ObjectStore or a ScheduledBackup (they carry the database's credentials and
// archive), a Cluster, a volume claim, a Secret, or anything cluster-scoped.
#RetireKinds: {
	Deployment:           "deployment.apps"
	Service:              "service"
	ConfigMap:            "configmap"
	Job:                  "job.batch"
	HTTPRoute:            "httproute.gateway.networking.k8s.io"
	NetworkPolicy:        "networkpolicy.networking.k8s.io"
	BackendTrafficPolicy: "backendtrafficpolicy.gateway.envoyproxy.io"
}

// Kinds that live outside a namespace: never rendered by the engine, an app's release has no
// right to them.
#ClusterScoped: ["ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "StorageClass", "PersistentVolume",
	"GatewayClass", "ClusterIssuer", "ClusterSecretStore", "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration",
	"ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding", "IngressClass", "PriorityClass", "Node"]

// The target upstream's #BuildManifests renders for: a #Environment of upstream's, spelled here so
// this file imports nothing. `IfNotPresent` is exact because every image is `repo:tag@digest`
// (a restart never needs the registry).
#Environment: {
	name:             "gke"
	registry:         string & !=""
	gatewayClassName: *"eg" | string
	storageClass:     *"local-path" | string
	imagePullPolicy:  *"IfNotPresent" | "Always"
	domainSuffix:     *"bsoneca.com" | string
	platform:         *"linux/amd64" | string
	policiesLate:     *false | bool
}

// The backups of a production database: Barman Cloud to an S3 bucket. Names are the ones the
// fork made for Studio, so adopting the engine keeps the archiver's timeline.
#Backups: {
	_name:       string
	endpoint:    *"https://usc1.contabostorage.com" | string
	bucket:      string & !=""
	path:        string & !=""
	retention:   *"30d" | =~"^[0-9]+[dwm]$"
	schedule:    *"0 0 3 * * *" | string
	credentials: *"\(_name)-backup-s3" | string
	keys: {
		accessKeyId:     *"ACCESS_KEY_ID" | string
		secretAccessKey: *"ACCESS_SECRET_KEY" | string
	}
}

// A tenant's ceiling: the namespace's quota and the defaults a container gets without its own.
#Tenant: {
	quota: {
		requestsCPU:    *"4" | string
		requestsMemory: *"8Gi" | string
		limitsCPU:      *"8" | string
		limitsMemory:   *"16Gi" | string
		pods:           *30 | int
		pvcs:           *6 | int
		storage:        *"20Gi" | string
	}
	limitRange: {
		defaultCPU:           *"500m" | string
		defaultMemory:        *"512Mi" | string
		defaultRequestCPU:    *"50m" | string
		defaultRequestMemory: *"64Mi" | string
		maxCPU:               *"4" | string
		maxMemory:            *"8Gi" | string
	}
	// Egress the namespace may open beyond upstream's own policies: an extra NetworkPolicy.
	egress: *[] | [...{to?: [...{...}], ports?: [...{...}]}]
}

// The database's replicas and settings, as patches over upstream's CloudNativePG Cluster (`<app>-db`). Each field
// is a patch: where `database` is not set, upstream's Cluster is applied as it renders.
#Database: {
	// One primary and instances-1 standbys; the operator keeps their PodDisruptionBudget. A preview runs as many.
	instances: int & >=1 | *1
	// The volume of each instance. Each replication slot may hold a quarter of it in WAL (max_slot_wal_keep_size,
	// below), so a hung replica gives its slot up before it fills the disk.
	storage?:       =~"^[1-9][0-9]*(Mi|Gi|Ti)$"
	slotWalKeepMB?: int & >=64
	// Postgres parameters of the app's own over upstream's.
	parameters: {[string]: string}
	// Seconds a stopping instance waits for its sessions (CloudNativePG's smartShutdownTimeout) before a fast
	// shutdown. With standbys none: no standby is promoted while the old primary waits. Below the Cluster's
	// stopDelay (120): the operator reads one at or past it as 0.
	smartShutdown: int & >=0 & <120 | *[if instances > 1 {0}, 15][0]
	// With standbys, quorum-based synchronous replication: a commit waits for `number` standbys, and a primary
	// that lost them keeps writing under "preferred".
	synchronous: {
		method:         *"any" | "first"
		number:         int & >=1 | *1
		dataDurability: *"preferred" | "required"
	}
	// Replication slots kept on every instance, so a standby promoted keeps the others'.
	haSlots: bool | *(instances > 1)
	// CloudNativePG's own PodDisruptionBudgets (on by default; with one instance a budget blocks a drain).
	enablePDB: bool | *true
	// Logins of the app's own (a service's `database.login`): each a LOGIN role, a member of the roles the app's
	// migrations made, its password generated in the namespace (Secret `<app>-<login, dashes>-db`, which
	// also carries the `url` a service reads) and set by the operator.
	logins: {[=~"^[a-z][a-z0-9_]*$"]: {inRoles: [...string]}}
	// The nightly backups: the same as `Release.backups` (set one, not both unequal).
	backup?: #Backups
}

// The requests and limits of a container, as patches over upstream's: a field named replaces upstream's, the rest stay.
#ContainerResources: {
	requests?: {[string]: string}
	limits?:   {[string]: string}
}

// #Release is an app on the node.
#Release: {
	// The app's name: its compose project's, and the release's own Kubernetes names.
	name: =~"^[a-z]([-a-z0-9]{0,28}[a-z0-9])?$"
	// A pull request's or the rc's own copy of the app, in a namespace of its own beside the
	// release's (`--preview=rc`, the engine passes `-t preview=<name>`).
	// Never `production`, and its host (below) never production's: a preview must not take the live host.
	preview: *"" | (=~"^[a-z0-9]([-a-z0-9]{0,14}[a-z0-9])?$" & !="production")
	// The kubectl context of the node, and how its API is reached: an ssh tunnel from the
	// Mac, a free local port of the release's own to the node's 127.0.0.1:<remotePort>.
	context: string & !=""
	api: {
		// user@host: never a bare host or an option (ssh would read `-oProxyCommand=...` as one).
		ssh:        =~"^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*$"
		remotePort: *6443 | int & >0 & <65536
	}
	// Where the release builds and pushes: the node's operator buildkitd and its registry, both on the
	// node's loopback alone (pronto's tools/machine/node.cue hostAccess), reached through the release's own
	// ssh tunnel (tunnel.nu). An app writes nothing here.
	build: {
		registry: {
			// as the node (containerd, buildkitd) names it: the images' manifests carry it
			host: *"127.0.0.1:5000" | string & !=""
			// the node-side port the tunnel forwards to
			port:       *5000 | int & >0 & <65536
			namespace:  *"pronto-registry" | string
			deployment: *"registry" | string
		}
		// Files git ignores that the images' Dockerfiles COPY (what the app's `generate` writes and keeps out of
		// the repository): staged though ignored, each one exact (no glob, no `..`), and a release fails when
		// one is missing, so a build that needs `generate` says so before it uploads anything.
		include: *[] | [...=~"^(\\.?[A-Za-z0-9_][A-Za-z0-9_.-]*)(/\\.?[A-Za-z0-9_][A-Za-z0-9_.-]*)*$"]
		buildkit: {
			port:       *1234 | int & >0 & <65536
			namespace:  *"pronto-buildkit" | string
			deployment: *"buildkitd" | string
		}
	}
	// Public hosts: production's, and each preview's that has one. A preview without one is served
	// at <namespace>.<domainSuffix>, which nothing routes to.
	hosts: {
		production: string & !=""
		[string]:   string
	}
	// A preview named like a host of `hosts` that is production's own is refused (the conflict is the error).
	_previewHostIsNotProduction: true & [if preview != "" if hosts[preview] != _|_ {hosts[preview] != hosts.production}, true][0]
	namespace:                   [if preview == "" {name}, "\(name)-\(preview)"][0]
	host: [
		if preview == "" {hosts.production},
		if hosts[preview] != _|_ {hosts[preview]},
		"\(namespace).\(environment.domainSuffix)",
	][0]
	environment: #Environment & {registry: build.registry.host}

	// Seconds each wait takes: the primary database on its image, a Job, a rollout.
	waits: {
		primary: *300 | int & >0
		rollout: *180 | int & >0
		job:     *600 | int & >0
	}
	operators: #Operators
	backups?:  #Backups & {_name: name}
	if database != _|_ if database.backup != _|_ {backups: database.backup}

	// How many pods each Deployment of upstream's render runs, in production and in a preview: `replicas` and
	// `previewReplicas` for every one, `scale` for the one named (its full name, `<app>-caddy`). A Deployment
	// that upstream renders with a Recreate strategy (one writer) is left at one by the defaults and scaled
	// by `scale` alone. Absent a number for the case, upstream's own count stays.
	replicas?:        int & >=1
	previewReplicas?: int & >=1
	scale:            {[=~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"]: {replicas?: int & >=1, preview?: int & >=1}}
	// Requests and limits by container name (crud, caddy, ...), and `postgres` for the database's.
	containerResources: {[string]: #ContainerResources}
	database?:          #Database
	tenant?:            #Tenant
	// The SOPS file applied into the namespace; absent, `secrets.metal.enc.yaml` when it exists.
	secrets?: string
	// The order the schema Jobs run in. A rendered Job not named here refuses the release: a new
	// upstream Job is noticed, never skipped.
	jobOrder: *["initdb", "migrate", "restate"] | [...string]
	// Named deletions after a release that left them behind, never a Cluster, a volume claim, a Secret.
	// Only what upstream's render makes and nothing that holds state or is cluster-wide: the kinds of
	// #RetireKinds, each deleted as kind.group so no alias (ns, pvc, all, clusters) can name another.
	retire: *[] | [...{
		kind:     or([for k, _ in #RetireKinds {k}])
		name:     =~"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$"
		resource: #RetireKinds[kind]
	}]
	hooks: afterJobs: *[] | [...[...string]]
}

// #Manifests: what the engine applies. `upstream` is upstream's own render of the app; `objects`
// is that, patched and added to as the tables below say, and refused (the field is an error) when
// `violations` is not empty.
#Manifests: {
	app:      {name: string, namespace: string, ...}
	release:  #Release
	upstream: [...{apiVersion: string, kind: string, metadata: {name: string, namespace?: string, ...}, ...}]

	let production = release.preview == ""
	let withBackups = release.backups != _|_ && production
	let backupName = "\(release.name)-backup"

	// What the engine changes in upstream's objects, and nothing else.
	// The door (caddy) dials its own Dapr sidecar for every upstream, and Dapr answers its own API paths (metadata, secrets,
	// state, publish, shutdown) before it routes by `dapr-app-id`, so the public door would expose the sidecar's API. Caddy gets
	// a Configuration of its own, the app's plus an allowlist of invocation alone; crud, auth and the rest keep the shared one,
	// which they need as it is.
	let caddyName = "\(release.name)-caddy"
	let caddyConfig = "\(release.name)-caddy-invoke-only"
	let sharedConfig = "\(release.name)-dapr-config"

	// Only when upstream's shared Configuration exists to copy: the door is retargeted exactly when its own is emitted.
	let retarget = len([for o in upstream if o.kind == "Configuration" && o.metadata.name == sharedConfig {o}]) > 0
	_patched: [for o in upstream {
		if !(retarget && o.kind == "Deployment" && o.metadata.name == caddyName) {
			o
			if o.kind == "Namespace" {
				metadata: labels: "pronto.dev/release": release.name
				if !production {metadata: labels: "pronto.dev/preview": release.preview}
			}
			if o.kind == "Cluster" && withBackups {
				spec: plugins: [{
					name:          "barman-cloud.cloudnative-pg.io"
					isWALArchiver: true
					parameters: barmanObjectName: backupName
				}]
			}
		}
		if retarget && o.kind == "Deployment" && o.metadata.name == caddyName {
			(#RetargetDapr & {in: o, config: caddyConfig}).out
		}
	}]

	// What it adds.
	_added: list.Concat([
		[for o in upstream if o.kind == "Configuration" && o.metadata.name == sharedConfig {
			apiVersion: o.apiVersion
			kind:       "Configuration"
			metadata: {
				name:      caddyConfig
				namespace: o.metadata.namespace
				if o.metadata.labels != _|_ {labels: o.metadata.labels}
			}
			// The app's configuration as it is, but for `api`, built here: its own other fields kept, `allowed` the door's alone.
			spec: {
				if o.spec != _|_ {
					for k, v in o.spec if k != "api" {(k): v}
				}
				api: {
					if o.spec != _|_ if o.spec.api != _|_ {
						for k, v in o.spec.api if k != "allowed" {(k): v}
					}

					// Invoke is allowed and not exploitable: every route to the sidecar sets `dapr-app-id` with `header_up` (the
					// generated Caddyfile), and Dapr resolves the target from that header before it reads a `/v1.0/invoke/<id>/`
					// path, so a client-chosen path is only the method on `crud`. The release's door probes
					// (`door-probes` in release.nu) are the proof: they ask the public door for those paths and fail the release
					// when one reaches the sidecar or another service.
					allowed: [
						{name: "invoke", version: "v1.0", protocol: "http"},
						{name: "invoke", version: "v1.0", protocol: "grpc"},
					]
				}
			}
		}],
		[if release.tenant != _|_ {
			apiVersion: "v1"
			kind:       "ResourceQuota"
			metadata:   {name: "\(release.name)-quota", namespace: release.namespace}
			spec: hard: {
				"requests.cpu":         release.tenant.quota.requestsCPU
				"requests.memory":      release.tenant.quota.requestsMemory
				"limits.cpu":           release.tenant.quota.limitsCPU
				"limits.memory":        release.tenant.quota.limitsMemory
				pods:                   release.tenant.quota.pods
				persistentvolumeclaims: release.tenant.quota.pvcs
				"requests.storage":     release.tenant.quota.storage
			}
		}],
		[if release.tenant != _|_ {
			apiVersion: "v1"
			kind:       "LimitRange"
			metadata:   {name: "\(release.name)-quota", namespace: release.namespace}
			spec: limits: [{
				type:           "Container"
				default:        {cpu: release.tenant.limitRange.defaultCPU, memory: release.tenant.limitRange.defaultMemory}
				defaultRequest: {cpu: release.tenant.limitRange.defaultRequestCPU, memory: release.tenant.limitRange.defaultRequestMemory}
				max:            {cpu: release.tenant.limitRange.maxCPU, memory: release.tenant.limitRange.maxMemory}
			}]
		}],
		[if release.tenant != _|_ if len(release.tenant.egress) > 0 {
			apiVersion: "networking.k8s.io/v1"
			kind:       "NetworkPolicy"
			metadata:   {name: "\(release.name)-tenant-egress", namespace: release.namespace}
			spec: {
				podSelector: {}
				policyTypes: ["Egress"]
				egress:      release.tenant.egress
			}
		}],
		[if withBackups {
			apiVersion: "barmancloud.cnpg.io/v1"
			kind:       "ObjectStore"
			metadata:   {name: backupName, namespace: release.namespace}
			spec: {
				configuration: {
					destinationPath: "s3://\(release.backups.bucket)/\(release.backups.path)"
					endpointURL:     release.backups.endpoint
					s3Credentials: {
						accessKeyId:     {name: release.backups.credentials, key: release.backups.keys.accessKeyId}
						secretAccessKey: {name: release.backups.credentials, key: release.backups.keys.secretAccessKey}
					}
				}
				retentionPolicy: release.backups.retention
			}
		}],
		[if withBackups {
			apiVersion: "postgresql.cnpg.io/v1"
			kind:       "ScheduledBackup"
			metadata:   {name: "\(release.name)-nightly", namespace: release.namespace}
			spec: {
				schedule:             release.backups.schedule
				backupOwnerReference: "self"
				method:               "plugin"
				cluster: name:             "\(release.name)-db"
				pluginConfiguration: name: "barman-cloud.cloudnative-pg.io"
			}
		}],
	])

	// What each of the database's logins needs: a generated password, and the Secret the operator and a service read.
	_logins: [if release.database != _|_ for l, _ in release.database.logins for o in (#LoginObjects & {"release": release, login: l}).out {o}]

	// Then the tunings of the release: replicas, the database's settings, the containers' resources, over everything
	// above (a Deployment or the Cluster, whoever added it).
	_pre: list.Concat([_patched, _added])
	_all: list.Concat([[for o in _pre {(#Tune & {in: o, "release": release}).out}], _logins])

	// The images a pod template or a database names.
	_images: list.Concat([
		[for o in _all if o.kind == "Deployment" || o.kind == "Job" for c in o.spec.template.spec.containers {c.image}],
		[for o in _all if o.kind == "Deployment" || o.kind == "Job" if o.spec.template.spec.initContainers != _|_ for c in o.spec.template.spec.initContainers {c.image}],
		[for o in _all if o.kind == "Cluster" if o.spec.imageName != _|_ {o.spec.imageName}],
	])

	// Why a render is refused: every entry says which object and what.
	violations: list.Concat([
		[if app.name != _|_ if app.name != release.name {"the app is named \(app.name), the release \(release.name)"}],
		[if app.namespace != _|_ if app.namespace != release.namespace {"the app's namespace is \(app.namespace), the release's \(release.namespace)"}],
		[for o in _all if o.kind != "Namespace" if o.metadata.namespace == _|_ {"\(o.kind)/\(o.metadata.name) has no namespace"}],
		[for o in _all if o.kind != "Namespace" if o.metadata.namespace != _|_ if o.metadata.namespace != release.namespace {
			"\(o.kind)/\(o.metadata.name) is in namespace \(o.metadata.namespace), not \(release.namespace)"
		}],
		[for o in _all if o.kind == "Namespace" if o.metadata.name != release.namespace {
			"Namespace/\(o.metadata.name) is not the release's namespace \(release.namespace)"
		}],
		[for o in _all if list.Contains(#ClusterScoped, o.kind) {"\(o.kind)/\(o.metadata.name) is cluster scoped"}],
		[for o in _all if !list.Contains(release.operators.served, "\(o.apiVersion)/\(o.kind)") {
			"\(o.apiVersion) \(o.kind)/\(o.metadata.name) is not served by the node's operators (\(release.operators.dapr) dapr, \(release.operators.cnpg) cnpg, \(release.operators.externalSecrets) external-secrets, \(release.operators.envoyGateway) envoy-gateway)"
		}],
		[for o in _all if o.kind == "Job" if !list.Contains(release.jobOrder, strings.TrimPrefix(o.metadata.name, "\(release.name)-")) {
			"Job/\(o.metadata.name) is not in jobOrder (\(strings.Join(release.jobOrder, ", ")))"
		}],
		[for o in _all if o.kind == "Gateway" for l in o.spec.listeners if l.hostname != release.host {
			"Gateway/\(o.metadata.name) listens for \(l.hostname), not the release's host \(release.host)"
		}],
		[for n, _ in release.scale if len([for o in _pre if o.kind == "Deployment" if o.metadata.name == n {o}]) == 0 {
			"scale names \(n), which is no Deployment of the render (\(strings.Join([for o in _pre if o.kind == "Deployment" {o.metadata.name}], ", ")))"
		}],
		[for n, _ in release.containerResources if n != "postgres" if len([for o in _pre if o.kind == "Deployment" for c in o.spec.template.spec.containers if c.name == n {c}]) == 0 {
			"containerResources names \(n), which is no container of the render's Deployments (or postgres)"
		}],
		[if release.database == _|_ if release.containerResources["postgres"] != _|_ {
			"containerResources.postgres needs `database` to be set, even as {}"
		}],
		[if release.database != _|_ if len(release.database.logins) > 0 if app.externalSecrets != _|_ if app.externalSecrets.enabled {
			"database.logins generate their passwords in the namespace, which the app's externalSecrets store does not do yet"
		}],
		[for i in _images if !strings.HasPrefix(i, release.environment.registry + "/") {
			"image \(i) is not in \(release.environment.registry)"
		}],
		[for i in _images if !strings.Contains(i, "@sha256:") {"image \(i) is not pinned by digest"}],
	])

	// The objects: refused whole while `violations` is not empty.
	_gate:   "" & strings.Join(violations, "; ")
	objects: [for o in _all {o, if len(_gate) >= 0 {}}]
	// The Jobs, in the order they run.
	jobs: [for j in release.jobOrder for o in _all if o.kind == "Job" if o.metadata.name == "\(release.name)-\(j)" {o.metadata.name}]
}

// A Deployment with its pod template's `dapr.io/config` annotation set to `config`, whatever it was.
#RetargetDapr: {
	in:     _
	config: string
	// missing metadata or annotations are added; a Deployment with no spec or template is passed on as it is, for the API server to refuse
	out: {
		for k, v in in if k != "spec" {(k): v}
		if in.spec != _|_ {
			spec: {
				for k, v in in.spec if k != "template" {(k): v}
				if in.spec.template != _|_ {
					template: {
						for k, v in in.spec.template if k != "metadata" {(k): v}
						metadata: {
							if in.spec.template.metadata != _|_ {
								for k, v in in.spec.template.metadata if k != "annotations" {(k): v}
							}
							annotations: {
								if in.spec.template.metadata != _|_ if in.spec.template.metadata.annotations != _|_ {
									for k, v in in.spec.template.metadata.annotations if k != "dapr.io/config" {(k): v}
								}
								"dapr.io/config": config
							}
						}
					}
				}
			}
		}
	}
}

// What a login's password and Secret are, as upstream makes the database roles' own: a Password generator and an
// ExternalSecret that renames its value into a basic-auth Secret, with the URL a service reads beside it.
#LoginObjects: {
	release: #Release
	login:   string
	let dashed = strings.Replace(login, "_", "-", -1)
	let generator = "\(release.name)-\(dashed)-password"
	let key = "\(strings.ToUpper(login))_PASSWORD"
	let labels = {"app.kubernetes.io/name": release.name, "app.kubernetes.io/instance": release.name, "app.kubernetes.io/managed-by": "cue"}
	out: [{
		apiVersion: "generators.external-secrets.io/v1alpha1"
		kind:       "Password"
		metadata:   {name: generator, namespace: release.namespace, "labels": labels}
		spec:       {length: 32, digits: 8, symbols: 0, noUpper: false, allowRepeat: true}
	}, {
		apiVersion: "external-secrets.io/v1beta1"
		kind:       "ExternalSecret"
		metadata:   {name: "\(release.name)-\(dashed)-db", namespace: release.namespace, "labels": labels}
		spec: {
			refreshInterval: "0"
			target: {
				name:           "\(release.name)-\(dashed)-db"
				creationPolicy: "Owner"
				template: {
					type: "kubernetes.io/basic-auth"
					data: {
						username: login
						password: "{{ .\(key) }}"
						url:      "postgres://\(login):{{ .\(key) }}@database:5432/\(release.name)?sslmode=disable"
					}
				}
			}
			dataFrom: [{
				sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: generator}
				rewrite: [{regexp: {source: "password", target: key}}]
			}]
		}
	}]
}

// The release's tunings of one object of the render: a Deployment's replicas and containers' resources, the
// database Cluster's replicas and settings. Anything else passes as it is. Upstream's values are concrete, so
// each field a tuning sets is rebuilt without upstream's, never unified with it.
#Tune: {
	in:      _
	release: #Release
	out: [
		if in.kind == "Deployment" {(#TuneDeployment & {"in": in, "release": release}).out},
		if in.kind == "Cluster" if release.database != _|_ {(#TuneCluster & {"in": in, "release": release}).out},
		in,
	][0]
}

#TuneDeployment: {
	in:      _
	release: #Release
	let production = release.preview == ""
	let n = in.metadata.name
	let recreate = len([if in.spec.strategy != _|_ if in.spec.strategy.type == "Recreate" {true}]) > 0
	let sc = [if release.scale[n] != _|_ {release.scale[n]}]

	// the first that applies: the Deployment's own number for the case, then the release's default for it
	let wanted = [
		if production if len(sc) > 0 if sc[0].replicas != _|_ {sc[0].replicas},
		if !production if len(sc) > 0 if sc[0].preview != _|_ {sc[0].preview},
		if production if release.replicas != _|_ if !recreate {release.replicas},
		if !production if release.previewReplicas != _|_ if !recreate {release.previewReplicas},
	]
	out: {
		for k, v in in if k != "spec" {(k): v}
		spec: {
			for k, v in in.spec if k != "replicas" && k != "template" {(k): v}
			if len(wanted) > 0 {replicas: wanted[0]}
			if len(wanted) == 0 if in.spec.replicas != _|_ {replicas: in.spec.replicas}
			template: {
				for k, v in in.spec.template if k != "spec" {(k): v}
				spec: {
					for k, v in in.spec.template.spec if k != "containers" {(k): v}
					containers: [for c in in.spec.template.spec.containers {
						for k, v in c if k != "resources" {(k): v}
						let given = release.containerResources[c.name]
						if given == _|_ {if c.resources != _|_ {resources: c.resources}}
						if given != _|_ {
							resources: {
								for sec in ["requests", "limits"] if c.resources[sec] != _|_ || given[sec] != _|_ {
									(sec): {
										if c.resources[sec] != _|_ for k, v in c.resources[sec] if given[sec] == _|_ || given[sec][k] == _|_ {(k): v}
										if given[sec] != _|_ for k, v in given[sec] {(k): v}
									}
								}
							}
						}
					}]
				}
			}
		}
	}
}

#TuneCluster: {
	in:      _
	release: #Release
	let db = release.database

	// a quarter of the volume, in MB, for each slot's WAL
	let sizeOf = [if db.storage != _|_ {regexp.FindSubmatch("^([0-9]+)(Mi|Gi|Ti)$", db.storage)}]
	let slotKeep = [
		if db.slotWalKeepMB != _|_ {db.slotWalKeepMB},
		if len(sizeOf) > 0 {div(strconv.Atoi(sizeOf[0][1]) * {Mi: 1, Gi: 1024, Ti: 1048576}[sizeOf[0][2]], 4)},
	]
	let own = {
		if len(slotKeep) > 0 {max_slot_wal_keep_size: "\(list.Max([64, slotKeep[0]]))MB"}
		db.parameters
	}
	out: {
		for k, v in in if k != "spec" {(k): v}
		spec: {
			for k, v in in.spec if !list.Contains(["instances", "storage", "postgresql", "managed"], k) {(k): v}
			instances: db.instances
			storage: {
				for k, v in in.spec.storage if k != "size" {(k): v}
				if db.storage != _|_ {size: db.storage}
				if db.storage == _|_ if in.spec.storage.size != _|_ {size: in.spec.storage.size}
			}
			postgresql: {
				for k, v in in.spec.postgresql if k != "parameters" {(k): v}
				parameters: {
					for k, v in in.spec.postgresql.parameters if own[k] == _|_ {(k): v}
					for k, v in own {(k): v}
				}
				if db.instances > 1 {synchronous: db.synchronous}
			}
			managed: {
				for k, v in in.spec.managed if k != "roles" {(k): v}
				roles: list.Concat([in.spec.managed.roles, [for l, d in db.logins {
					name:    l
					ensure:  "present"
					login:   true
					inherit: true
					inRoles: d.inRoles
					passwordSecret: name: "\(release.name)-\(strings.Replace(l, "_", "-", -1))-db"
				}]])
			}
			// A change the primary must restart for promotes a synchronised standby first and restarts the old
			// primary after it; one instance has no standby to promote.
			if db.instances > 1 {
				primaryUpdateStrategy: "unsupervised"
				primaryUpdateMethod:   "switchover"
			}
			if db.haSlots {replicationSlots: highAvailability: enabled: true}
			if db.instances > 1 || !db.enablePDB {enablePDB: db.enablePDB}

			// A stop is bounded: a smart shutdown for `smartShutdown` seconds, a fast one after, the pod killed at stopDelay.
			smartShutdownTimeout: db.smartShutdown
			stopDelay:            120
			if release.containerResources["postgres"] != _|_ {resources: release.containerResources["postgres"]}
		}
	}
}
