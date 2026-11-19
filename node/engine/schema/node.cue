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
#Release: R={
	// The app's name: its compose project's, and the release's own Kubernetes names.
	name: =~"^[a-z]([-a-z0-9]{0,28}[a-z0-9])?$"
	// A pull request's or the rc's own copy of the app, in a namespace of its own beside the
	// release's (`--preview=rc`, the engine passes `-t preview=<name>`).
	preview: *"" | =~"^[a-z0-9]([-a-z0-9]{0,14}[a-z0-9])?$"
	// The kubectl context of the node, and how its API is reached: an ssh tunnel from the
	// Mac, 127.0.0.1:<port> to the node's own 127.0.0.1:<remotePort>.
	context: string & !=""
	api: {
		ssh:        string & !=""
		port:       *26444 | int & >0 & <65536
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
	// Public hosts: production's, and each preview's that has one. A preview without one is served
	// at <namespace>.<domainSuffix>, which nothing routes to.
	hosts: {
		production: string & !=""
		[string]:   string
	}
	namespace: [if R.preview == "" {R.name}, "\(R.name)-\(R.preview)"][0]
	host: [
		if R.preview == "" {R.hosts.production},
		if R.hosts[R.preview] != _|_ {R.hosts[R.preview]},
		"\(R.namespace).\(R.environment.domainSuffix)",
	][0]
	environment: #Environment & {registry: R.registry.url}

	// Seconds each wait takes: the primary database on its image, a Job, a rollout.
	waits: {
		primary: *300 | int & >0
		rollout: *180 | int & >0
		job:     *600 | int & >0
	}
	operators: #Operators
	backups?:  #Backups & {_name: R.name}
	tenant?:   #Tenant
	// The SOPS file applied into the namespace; absent, `secrets.metal.enc.yaml` when it exists.
	secrets?: string
	// The order the schema Jobs run in. A rendered Job not named here refuses the release: a new
	// upstream Job is noticed, never skipped.
	jobOrder: *["initdb", "migrate", "restate"] | [...string]
	// Named deletions after a release that left them behind, never a Cluster, a volume claim, a Secret.
	retire: *[] | [...{kind: !~"^(Cluster|PersistentVolumeClaim|Secret|Namespace)$", name: string}]
	hooks: afterJobs: *[] | [...[...string]]
}

// #Manifests: what the engine applies. `upstream` is upstream's own render of the app; `objects`
// is that, patched and added to as the tables below say, and refused (the field is an error) when
// `violations` is not empty.
#Manifests: M={
	app:      {name: string, namespace: string, ...}
	release:  #Release
	upstream: [...{apiVersion: string, kind: string, metadata: {name: string, namespace?: string, ...}, ...}]

	let production = M.release.preview == ""
	let withBackups = M.release.backups != _|_ && production
	let backupName = "\(M.release.name)-backup"

	// What the engine changes in upstream's objects, and nothing else.
	_patched: [for o in M.upstream {
		o
		if o.kind == "Namespace" {
			metadata: labels: "pronto.dev/release": M.release.name
			if !production {metadata: labels: "pronto.dev/preview": M.release.preview}
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
		[if M.release.tenant != _|_ {
			apiVersion: "v1"
			kind:       "ResourceQuota"
			metadata:   {name: "\(M.release.name)-quota", namespace: M.release.namespace}
			spec: hard: {
				"requests.cpu":         M.release.tenant.quota.requestsCPU
				"requests.memory":      M.release.tenant.quota.requestsMemory
				"limits.cpu":           M.release.tenant.quota.limitsCPU
				"limits.memory":        M.release.tenant.quota.limitsMemory
				pods:                   M.release.tenant.quota.pods
				persistentvolumeclaims: M.release.tenant.quota.pvcs
				"requests.storage":     M.release.tenant.quota.storage
			}
		}],
		[if M.release.tenant != _|_ {
			apiVersion: "v1"
			kind:       "LimitRange"
			metadata:   {name: "\(M.release.name)-quota", namespace: M.release.namespace}
			spec: limits: [{
				type:           "Container"
				default:        {cpu: M.release.tenant.limitRange.defaultCPU, memory: M.release.tenant.limitRange.defaultMemory}
				defaultRequest: {cpu: M.release.tenant.limitRange.defaultRequestCPU, memory: M.release.tenant.limitRange.defaultRequestMemory}
				max:            {cpu: M.release.tenant.limitRange.maxCPU, memory: M.release.tenant.limitRange.maxMemory}
			}]
		}],
		[if M.release.tenant != _|_ if len(M.release.tenant.egress) > 0 {
			apiVersion: "networking.k8s.io/v1"
			kind:       "NetworkPolicy"
			metadata:   {name: "\(M.release.name)-tenant-egress", namespace: M.release.namespace}
			spec: {
				podSelector: {}
				policyTypes: ["Egress"]
				egress:      M.release.tenant.egress
			}
		}],
		[if withBackups {
			apiVersion: "barmancloud.cnpg.io/v1"
			kind:       "ObjectStore"
			metadata:   {name: backupName, namespace: M.release.namespace}
			spec: {
				configuration: {
					destinationPath: "s3://\(M.release.backups.bucket)/\(M.release.backups.path)"
					endpointURL:     M.release.backups.endpoint
					s3Credentials: {
						accessKeyId:     {name: M.release.backups.credentials, key: M.release.backups.keys.accessKeyId}
						secretAccessKey: {name: M.release.backups.credentials, key: M.release.backups.keys.secretAccessKey}
					}
				}
				retentionPolicy: M.release.backups.retention
			}
		}],
		[if withBackups {
			apiVersion: "postgresql.cnpg.io/v1"
			kind:       "ScheduledBackup"
			metadata:   {name: "\(M.release.name)-nightly", namespace: M.release.namespace}
			spec: {
				schedule:             M.release.backups.schedule
				backupOwnerReference: "self"
				method:               "plugin"
				cluster: name:             "\(M.release.name)-db"
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
		[if M.app.name != _|_ if M.app.name != M.release.name {"the app is named \(M.app.name), the release \(M.release.name)"}],
		[if M.app.namespace != _|_ if M.app.namespace != M.release.namespace {"the app's namespace is \(M.app.namespace), the release's \(M.release.namespace)"}],
		[if M.app.name != _|_ if M.app.name != M.release.name {"the app is named \(M.app.name), the release \(M.release.name)"}],
		[if M.app.namespace != _|_ if M.app.namespace != M.release.namespace {"the app's namespace is \(M.app.namespace), the release's \(M.release.namespace)"}],
		[for o in _all if o.kind != "Namespace" if o.metadata.namespace == _|_ {"\(o.kind)/\(o.metadata.name) has no namespace"}],
		[for o in _all if o.kind != "Namespace" if o.metadata.namespace != _|_ if o.metadata.namespace != M.release.namespace {
			"\(o.kind)/\(o.metadata.name) is in namespace \(o.metadata.namespace), not \(M.release.namespace)"
		}],
		[for o in _all if o.kind == "Namespace" if o.metadata.name != M.release.namespace {
			"Namespace/\(o.metadata.name) is not the release's namespace \(M.release.namespace)"
		}],
		[for o in _all if list.Contains(#ClusterScoped, o.kind) {"\(o.kind)/\(o.metadata.name) is cluster scoped"}],
		[for o in _all if !list.Contains(M.release.operators.served, "\(o.apiVersion)/\(o.kind)") {
			"\(o.apiVersion) \(o.kind)/\(o.metadata.name) is not served by the node's operators (\(M.release.operators.dapr) dapr, \(M.release.operators.cnpg) cnpg, \(M.release.operators.externalSecrets) external-secrets, \(M.release.operators.envoyGateway) envoy-gateway)"
		}],
		[for o in _all if o.kind == "Job" if !list.Contains(M.release.jobOrder, strings.TrimPrefix(o.metadata.name, "\(M.release.name)-")) {
			"Job/\(o.metadata.name) is not in jobOrder (\(strings.Join(M.release.jobOrder, ", ")))"
		}],
		[for o in _all if o.kind == "Gateway" for l in o.spec.listeners if l.hostname != M.release.host {
			"Gateway/\(o.metadata.name) listens for \(l.hostname), not the release's host \(M.release.host)"
		}],
		[for i in _images if !strings.HasPrefix(i, M.release.environment.registry + "/") if !strings.Contains(i, "@sha256:") {
			"image \(i) is neither in \(M.release.environment.registry) nor pinned by digest"
		}],
	])

	// The objects: refused whole while `violations` is not empty.
	_gate:   "" & strings.Join(violations, "; ")
	objects: [for o in _all {o, if len(_gate) >= 0 {}}]
	// The Jobs, in the order they run.
	jobs: [for j in M.release.jobOrder for o in _all if o.kind == "Job" if o.metadata.name == "\(M.release.name)-\(j)" {o.metadata.name}]
}
