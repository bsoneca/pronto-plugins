package schema

import (
	"list"
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

// #Release is an app on the node.
#Release: {
	// The app's name: its compose project's, and the release's own Kubernetes names.
	name: =~"^[a-z]([-a-z0-9]{0,28}[a-z0-9])?$"
	// A pull request's or the rc's own copy of the app, in a namespace of its own beside the
	// release's (`--preview=rc`, the engine passes `-t preview=<name>`).
	preview: *"" | =~"^[a-z0-9]([-a-z0-9]{0,14}[a-z0-9])?$"
	// The kubectl context of the node, and how its API is reached: an ssh tunnel from the
	// Mac, a free local port of the release's own to the node's 127.0.0.1:<remotePort>.
	context: string & !=""
	api: {
		// user@host: never a bare host or an option (ssh would read `-oProxyCommand=...` as one).
		ssh:        =~"^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*$"
		remotePort: *6443 | int & >0 & <65536
	}
	// The Artifact Registry the images go to (Cloud Build) and the node pulls from, through its k3s
	// registries.yaml.
	registry: {
		project:    string & !=""
		location:   string & !=""
		repository: *"node-images" | string
		url:        "\(location)-docker.pkg.dev/\(project)/\(repository)"
	}
	_registryURL: registry.url
	// Public hosts: production's, and each preview's that has one. A preview without one is served
	// at <namespace>.<domainSuffix>, which nothing routes to.
	hosts: {
		production: string & !=""
		[string]:   string
	}
	namespace: [if preview == "" {name}, "\(name)-\(preview)"][0]
	host: [
		if preview == "" {hosts.production},
		if hosts[preview] != _|_ {hosts[preview]},
		"\(namespace).\(environment.domainSuffix)",
	][0]
	environment: #Environment & {registry: _registryURL}

	// Seconds each wait takes: the primary database on its image, a Job, a rollout.
	waits: {
		primary: *300 | int & >0
		rollout: *180 | int & >0
		job:     *600 | int & >0
	}
	operators: #Operators
	backups?:  #Backups & {_name: name}
	tenant?:   #Tenant
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
	_patched: [for o in upstream {
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
	}]

	// What it adds.
	_added: list.Concat([
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

	_all: list.Concat([_patched, _added])

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
