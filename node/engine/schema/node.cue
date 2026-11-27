package schema

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/yaml"
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
		"apps/v1/Deployment", "batch/v1/Job", "batch/v1/CronJob", "v1/ServiceAccount", "networking.k8s.io/v1/NetworkPolicy",
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
	CronJob:              "cronjob.batch"
	ServiceAccount:       "serviceaccount"
	HTTPRoute:            "httproute.gateway.networking.k8s.io"
	NetworkPolicy:        "networkpolicy.networking.k8s.io"
	BackendTrafficPolicy: "backendtrafficpolicy.gateway.envoyproxy.io"
}

// What a tenant's release never retires, though an operator's may: a NetworkPolicy and a CronJob (its publisher may not delete them) and a
// ServiceAccount (the provisioner's publisher is one, and its RoleBinding and Role are not retirable kinds at all). Said once here; the
// violation below and the engine's own check (tenant.nu check-retire) both read it.
#TenantNoRetire: ["NetworkPolicy", "CronJob", "ServiceAccount"]

// What no object of a tenant's release may carry or be, read by the engine's own check of the rendered objects (tenant.nu check-objects):
// the metadata fields that hand an object's life to another (an ownerReference to the provisioner's publisher account, which Kubernetes then
// garbage-collects when the owner is not found; a finalizer that holds an object undeletable) -- the engine sets what it needs itself -- and the
// objects the provisioner and the engine own, which a release neither writes nor seeds: the publisher's account, the namespace's record
// of the release and the root CA bundle every namespace gets.
#TenantRefusedMetadata: ["ownerReferences", "finalizers"]

// The namespaces a service's egress may name instead of an address block: the Envoy Gateway's, whose data-plane pods a live release's door
// check dials from the pod it runs in. Another is a change here, never an app's.
#EgressNamespaces: ["envoy-gateway-system"]
#TenantReserved: [
	{kind: "ServiceAccount", name: "publisher"},
	{kind: "ConfigMap", name: "pronto-release"},
	{kind: "ConfigMap", name: "kube-root-ca.crt"},
]

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
	// A tenant's own release (PRONTO-740 S2, `release.nu --tenant <namespace> --host <host>`, which passes the tags `tenant` and
	// `tenantHost`): the release runs as the namespace's publisher, a ServiceAccount whose rights are the namespace's alone, in
	// a namespace its provisioner made (with the quota, the limit range and the policies above, which the publisher never writes).
	// Naming the namespace is what makes the release a tenant's: then the host is the one address the namespace was given, the
	// images are under the namespace's own path of the node's registry, and the build is the tenants' sandboxed buildkitd, never
	// the operator's (which has no sandbox and can overwrite any image in the registry).
	namespace?: =~"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" & !="default" & !~"^(kube|pronto)-"
	host?:      =~"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)+$"
	if namespace != _|_ {
		host:     string
		buildkit: *"tcp://buildkitd.pronto-buildkit-tenants.svc:1234" | =~"^tcp://buildkitd\\.pronto-buildkit-tenants\\.svc(\\.cluster\\.local)?:[0-9]{1,5}$"
	}
}

// The kinds a tenant's publisher may write, as `apiVersion/kind`: the subset of `operators.served` that Studio's publisher Role
// covers (apps/studio/spec/tenants.cue `rules`). A kind outside it makes a tenant's release refuse before anything is written.
#PublisherKinds: ["v1/Service", "v1/ConfigMap", "v1/Secret", "v1/ServiceAccount", "apps/v1/Deployment", "batch/v1/Job",
	"gateway.networking.k8s.io/v1/Gateway", "gateway.networking.k8s.io/v1/HTTPRoute", "postgresql.cnpg.io/v1/Cluster",
	"external-secrets.io/v1beta1/ExternalSecret", "generators.external-secrets.io/v1alpha1/Password",
	"dapr.io/v1alpha1/Configuration", "dapr.io/v1alpha1/Resiliency", "gateway.envoyproxy.io/v1alpha1/BackendTrafficPolicy"]

// The OIDC issuers a tenant's release may name (every `OIDC_*_ISSUER` and `*_INTERNAL` of its auth settings), each as the exact origin: the
// release registers its clients at the issuer from Studio's builder pod, which reaches the node's API and its pods, so a tenant's own
// choice of issuer would make the builder its proxy. Today the one sign-in broker Studio's games use (apps/studio games.cue `signIn`).
#TenantIssuers: ["https://id.bonkchess.com"]

// The database images a tenant's Cluster may run (PRONTO-740, Codex): mecha's database image, by digest, as the validated pronto runtimes' generated database stages name it
// (`FROM bonitao/mecha-database:<version>@sha256:...` plus COPYs of the app's SQL, which render.nu's database-base reads). A tenant builds its own database image from its
// own Dockerfile, so running that image in the operator-created instance pod would run tenant code there; the Cluster runs the engine's approved base instead, copied into
// the tenant's own registry path (`<registry>/<namespace>/<app>-database-base:<major>`), and the full tenant image stays with the schema and migration Jobs. `major` is the
// base's PG_MAJOR (`crane config` at the time it is added: 18 for mecha-database 0.36.1). One entry for each mecha database the validated runtimes generate: pronto 1.17 and 1.18
// both name 0.36.1, so a pin move that adds a runtime adds its mecha digest here in the same change, and keeps the previous runtime's (N and N-1).
#TenantDatabaseImages: [...{ref: string, digest: =~"^sha256:[0-9a-f]{64}$", major: =~"^[0-9]+$"}] & [
	{ref: "bonitao/mecha-database:0.36.1@sha256:5d6f9f38a065c1c001656b4e667f875145a3179c92af0bd07f6f414c75788598", digest: "sha256:5d6f9f38a065c1c001656b4e667f875145a3179c92af0bd07f6f414c75788598", major: "18"},
]

// The fields a tenant's Cluster may carry (PRONTO-740, Codex): what upstream renders and the engine patches, and nothing else, since a Cluster field is how tenant code or an
// image the tenant chose could reach the operator-created instance pod: imageCatalogRef, postgresql.extensions[].image (image-volume extensions), projectedVolumeTemplate,
// serviceAccountTemplate, plugins, env, envFrom, bootstrap.initdb's postInit*SQL*, import, recovery and externalClusters are all refused, and so is any key not listed.
#TenantClusterSpec: {
	// The first line is what upstream renders and the second what the engine's own #Tune patches in (multi-instance databases, enablePDB).
	keys: ["instances", "postgresql", "imageName", "postgresUID", "postgresGID", "enableSuperuserAccess", "managed", "bootstrap", "storage", "resources", "replicationSlots", "stopDelay", "smartShutdownTimeout",
		"primaryUpdateStrategy", "primaryUpdateMethod", "enablePDB"]
	// The uid and gid of mecha's database image (upstream's own, whose postgres user is 999, not CloudNativePG's 26): the approved base is the one image a tenant's Cluster runs.
	uid: 999
	postgresql: ["parameters", "synchronous"]
	bootstrap: ["initdb"]
	initdb: ["database", "owner", "localeProvider", "icuLocale", "secret"]
}

// The Postgres parameters a tenant's Cluster may set (PRONTO-740, Codex): tuning only, each held to a bound. Every other one is refused, among them each `*_command`
// (archive, restore, recovery_end, ssl_passphrase), `*_library` and `*_preload_libraries`, `archive_*`, `restore_*`, `recovery_*`, and the file and directory settings
// (`data_directory`, `hba_file`, `ssl_*_file`, `unix_socket_directories`), which run a program or read a file in the instance pod. `kind` says how a value reads:
// `int` a plain integer, `mem` an integer with kB, MB, GB or TB (kB when none, as Postgres reads it), `ms` an integer with ms, s, min, h or d (ms when none),
// `real` a number, `enum` one of `values`. `min` and `max` are in kB for `mem` and in ms for `ms`: the most a tenant's single database gets.
#TenantParameters: {
	max_connections:                      {kind: "int", min: 1, max: 1000}
	shared_buffers:                       {kind: "mem", min: 128, max: 4194304}
	work_mem:                             {kind: "mem", min: 64, max: 1048576}
	maintenance_work_mem:                 {kind: "mem", min: 1024, max: 2097152}
	effective_cache_size:                 {kind: "mem", min: 8, max: 16777216}
	wal_buffers:                          {kind: "mem", min: 32, max: 65536}
	max_wal_size:                         {kind: "mem", min: 32768, max: 8388608}
	min_wal_size:                         {kind: "mem", min: 32768, max: 2097152}
	max_slot_wal_keep_size:               {kind: "mem", min: 64, max: 1073741824}
	temp_file_limit:                      {kind: "mem", min: 0, max: 16777216}
	checkpoint_completion_target:         {kind: "real", min: 0, max: 1}
	random_page_cost:                     {kind: "real", min: 0, max: 100}
	seq_page_cost:                        {kind: "real", min: 0, max: 100}
	default_statistics_target:            {kind: "int", min: 1, max: 10000}
	effective_io_concurrency:             {kind: "int", min: 0, max: 1000}
	max_worker_processes:                 {kind: "int", min: 1, max: 64}
	max_parallel_workers:                 {kind: "int", min: 0, max: 64}
	max_parallel_workers_per_gather:      {kind: "int", min: 0, max: 16}
	max_parallel_maintenance_workers:     {kind: "int", min: 0, max: 16}
	max_replication_slots:                {kind: "int", min: 0, max: 256}
	max_wal_senders:                      {kind: "int", min: 0, max: 256}
	max_logical_replication_workers:      {kind: "int", min: 0, max: 64}
	max_sync_workers_per_subscription:    {kind: "int", min: 0, max: 64}
	statement_timeout:                    {kind: "ms", min: 0, max: 86400000}
	lock_timeout:                         {kind: "ms", min: 0, max: 86400000}
	idle_in_transaction_session_timeout:  {kind: "ms", min: 0, max: 86400000}
	log_min_duration_statement:           {kind: "ms", min: -1, max: 86400000}
	wal_level:                            {kind: "enum", values: ["replica", "logical"]}
	// What upstream renders, which a tenant may not weaken: durability stays on.
	fsync:                                {kind: "enum", values: ["on"]}
	full_page_writes:                     {kind: "enum", values: ["on"]}
	synchronous_commit:                   {kind: "enum", values: ["on", "local", "remote_write", "remote_apply"]}
}

// Roles a tenant's database may never be made a member of, and never given as its own attributes (superuser, createrole): through them SQL reaches the instance pod
// (COPY ... TO PROGRAM, server-side file reads and writes) or the cluster's own roles. A managed role of a tenant's Cluster and a `database.logins` entry are held to it.
#TenantRefusedRoles: ["postgres", "pg_execute_server_program", "pg_read_server_files", "pg_write_server_files"]

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
	// Set only when named or with standbys (then 0): else CloudNativePG's own stop settings stay, and nothing
	// restarts the primary for them. Setting either writes stopDelay 120 beside it.
	smartShutdown?: int & >=0 & <120
	// With standbys, quorum-based synchronous replication: a commit waits for `number` standbys, and a primary
	// that lost them keeps writing under "preferred".
	synchronous: {
		method:         *"any" | "first"
		number:         int & >=1 | *1
		dataDurability: *"preferred" | "required"
	}
	// Replication slots kept on every instance, so a standby promoted keeps the others' (with standbys, `false`
	// is written too; with one instance only `true` is).
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

// The images the engine itself emits that are not the app's: the metrics export's collector and a clock's curl, pinned by
// digest and pulled from where they are published, not built on the node's buildkitd. Nothing else may leave the registry.
#External: [
	"docker.io/otel/opentelemetry-collector-contrib:0.160.0@sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6",
	"docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777",
]

// What a pod's sidecar listens on (Dapr's HTTP and gRPC APIs, its internal gRPC, its metrics and its profiler): never a service's.
#FreePort: int & !=3500 & !=3501 & !=9090 & !=50001 & !=50002 & !=7777

// A Deployment of the app's own beside upstream's (billing, a collector, a flag server: a service of its compose project that
// upstream does not render), built and pushed as upstream's images are, in the mesh under its name. Its environment is stated
// here, whole: the compose project's is not read.
#Service: {
	port!: int & >1024 & <65536 & #FreePort
	// PORT, SERVICE_JWT and the telemetry's variables are the engine's (the port above, the service role's token from `<app>-service-token`); ORIGIN
	// is the release's public origin unless named here.
	env: {[=~"^[A-Z_][A-Z0-9_]*$" & !~"^(PORT|SERVICE_JWT|OTEL_DENO|OTEL_SERVICE_NAME|OTEL_EXPORTER_OTLP_ENDPOINT)$"]: string}
	// Variables read from a Secret of the namespace, each under its variable's name (a sender's VAPID key): from the SOPS
	// file or put there by hand, and the pod does not start until it is there.
	secrets: {[=~"^[A-Z_][A-Z0-9_]*$" & !~"^(PORT|SERVICE_JWT|ORIGIN|OTEL_DENO|OTEL_SERVICE_NAME|OTEL_EXPORTER_OTLP_ENDPOINT)$"]: =~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"}
	// Files read from a ConfigMap of the namespace, mounted read-only at each directory, its keys the file names (flagd's live
	// flags, which `pronto-flags push` writes): the pod does not start until it is there, and a change reaches the files in
	// about a minute.
	files: {[=~"^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$" & !~"(^|/)\\.\\.?(/|$)"]: =~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" & strings.MaxRunes(50)}
	// What a ConfigMap of `files` is made from when it is not there yet, by name: a file of the app, its key the file's name.
	// Once, on the release that finds it missing; a release never writes over one that exists (a push owns it after).
	seed: {[=~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"]: =~"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$" & !~"(^|/)\\.\\.(/|$)"}
	// Where it exports Prometheus metrics, scraped by the node's VictoriaMetrics and by `metricsExport`.
	metrics?: {
		port!: int & >1024 & <65536 & #FreePort
		path:  *"/metrics" | =~"^/"
	}
	// A CronJob that POSTs to `path` on its port each `schedule` (five fields, UTC) with the service role's token as its
	// bearer, as Cloud Scheduler pokes mecha's ticker on Cloud Run. A missed minute is the next one's: no retry.
	clock?: {
		schedule: *"* * * * *" | string
		path:     *"/poke" | =~"^/"
	}
	// Connects to the app's own database as one of `database.logins`, its URL in the variable `env` (an exporter's
	// SQLEXPORTER_TARGET_DSN), read from the login's Secret.
	database?: {
		login!: string
		env:    *"DATABASE_URL" | (=~"^[A-Z_][A-Z0-9_]*$" & !~"^(PORT|SERVICE_JWT|ORIGIN|OTEL_DENO|OTEL_SERVICE_NAME|OTEL_EXPORTER_OTLP_ENDPOINT)$")
	}
	// One writer: a Recreate strategy, which the release's default replicas leave at one (mecha's ticker; two would fire a
	// timer twice). Only `scale` changes its count.
	singleWriter: *false | bool
	// A service that runs others' code in a bubblewrap jail of its own (Studio's builder): its pod in a user namespace of
	// its own (hostUsers: false, its root no one on the node), a /proc the jail can mount afresh (procMount Unmasked), and
	// AppArmor and seccomp unconfined, since a node that restricts unprivileged user namespaces (Ubuntu's
	// apparmor_restrict_unprivileged_userns) and the runtime's default seccomp refuse the jail's own namespaces. Each less
	// fails bwrap.
	jail: *false | bool
	// A Google identity of the service's own, with no key, as `blobs` and `metricsExport` have: its pod runs as the service
	// account `<app>-<name>` (subject system:serviceaccount:<namespace>:<app>-<name>), whose projected token (`audience`) is
	// at /var/run/secrets/gcp/token, for the service to trade at the workload identity `provider` for `serviceAccount`'s.
	google?: {
		provider!:       =~"^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$"
		serviceAccount!: =~"^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$"
		audience:        string | *"https://iam.googleapis.com/\(provider)"
	}
	// Where the service may connect beyond the services' own policy (the mesh, and the internet on 443): each an address
	// block, what it leaves out, and a TCP port (the node's API server for a service that provisions namespaces, the
	// internet on 80 for a mirror). A NetworkPolicy of its own, which adds to the services'.
	// Or, instead of an address block, the pods of a namespace (the Envoy Gateway's data plane, which a live release's door check dials):
	// `namespace` and the labels its pods carry, as a namespaceSelector with a podSelector.
	egress: *[] | [...{
		cidr?:      =~"^[0-9.]+/[0-9]+$"
		except:     *[] | [...=~"^[0-9.]+/[0-9]+$"]
		namespace?: or([for n in #EgressNamespaces {n}])
		podLabels:  *{} | {[string]: string}
		port!:      int & >0 & <65536
		// exactly one of an address block and a namespace
		_one: true & (len([if cidr != _|_ {1}, if namespace != _|_ {1}]) == 1)
		// a namespace's rule names the pods it admits (never every pod of it), and leaves out nothing; `except` belongs to an address block
		if namespace != _|_ {
			_labelled: true & (len(podLabels) > 0)
			except:    []
		}
	}]
	// Folders of the pod's own, empty at each start, by path, with the most each may hold (a builder's workspace: clones,
	// toolchains, a game's checks): an emptyDir each.
	scratch: *{} | {[=~"^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$" & !~"(^|/)\\.\\.?(/|$)"]: =~"^[0-9]+(Mi|Gi)$"}
}

// The blob plane mecha's profile pictures live on (the door's /blobs and /img): rclone serving the Cloud Storage `bucket` as
// the S3 bucket every app names, and imgproxy over it, in the mesh as the app-ids rclone-s3 and imgproxy, built from the
// app's compose services of those names. rclone signs in with no key: the token of the service account `<app>-blobs`
// (subject system:serviceaccount:<namespace>:<app>-blobs) is traded at the workload identity `provider` for
// `serviceAccount`'s, which may read and write the bucket.
#Blobs: {
	bucket!:         =~"^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$"
	provider!:       =~"^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$"
	serviceAccount!: =~"^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$"
	audience:        string | *"https://iam.googleapis.com/\(provider)"
}

// The services' metrics (`services.<n>.metrics`) sent on to Google Cloud Monitoring's Managed Service for Prometheus, where
// Cloud Run's sidecars send theirs: an OpenTelemetry collector of the app's own scrapes them and writes them under `project`,
// `location` and `cluster`. It signs in with no key, as the blob plane does: the token of the service account
// `<app>-metrics-export` is traded at a workload identity `provider` that trusts the node's issuer for `serviceAccount`'s.
#MetricsExport: {
	project!:        =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
	provider!:       =~"^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$"
	serviceAccount!: =~"^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$"
	audience:        string | *"https://iam.googleapis.com/\(provider)"
	location:        string | *"europe-west3"
	cluster:         string | *"metal"
	interval:        =~"^[0-9]+s$" | *"30s"
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
	// A tenant's release (`tenant.namespace`): the one a namespace's publisher makes, in the namespace its provisioner made.
	_publisher: [if tenant != _|_ if tenant.namespace != _|_ {true}, false][0]
	if _publisher {
		// The node's registry as the publisher's push reaches it: pinned, so a release.cue cannot move where a tenant's images go.
		build: registry: {host: "127.0.0.1:5000", port: 5000, namespace: "pronto-registry"}
	}
	namespace: [if _publisher {tenant.namespace}, if preview == "" {name}, "\(name)-\(preview)"][0]
	host: [
		if _publisher {tenant.host},
		if preview == "" {hosts.production},
		if hosts[preview] != _|_ {hosts[preview]},
		"\(namespace).\(environment.domainSuffix)",
	][0]
	// The public origin of the release, a preview's included, always https (a passkey is bound to its origin, and a browser
	// offers one only on https): what the services' ORIGIN says and what release-cron's preview is asked at. The node's
	// cloudflared terminates TLS and dials the Gateway over plain HTTP, so the Gateway has no TLS listener of its own.
	origin:      *"https://\(host)" | =~"^https://[^/]+$"
	// A tenant's images are under its namespace's own path of the registry (`<registry>/<namespace>/<app>-<service>`), which the
	// image check below then holds every one of its images to.
	environment: #Environment & {registry: [if _publisher {"\(build.registry.host)/\(tenant.namespace)"}, build.registry.host][0]}

	// Seconds each wait takes: the primary database on its image, a Job, a rollout.
	waits: {
		primary: *300 | int & >0
		// for a database with standbys, after the primary: every instance ready on the image (its own wait)
		standbys: *300 | int & >0
		rollout:  *180 | int & >0
		job:      *600 | int & >0
	}
	operators: #Operators
	backups?:  #Backups & {_name: name}
	if database != _|_ if database.backup != _|_ {
		backups: database.backup
	}

	// How many pods each Deployment of upstream's render runs, in production and in a preview: `replicas` and
	// `previewReplicas` for every one, `scale` for the one named (its full name, `<app>-caddy`). A Deployment
	// that upstream renders with a Recreate strategy (one writer) is left at one by the defaults and scaled
	// by `scale` alone. Absent a number for the case, upstream's own count stays.
	replicas?:        int & >=1
	previewReplicas?: int & >=1
	scale:            {[=~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"]: {replicas?: int & >=1, preview?: int & >=1}}
	// Requests and limits by container name (crud, caddy, ...), and `postgres` for the database's.
	containerResources: {[string]: #ContainerResources}
	// `backup` is complete as it stands: the Secret of its keys is named for the release
	database?: #Database & {backup?: _name: name}
	tenant?:   #Tenant
	// The app's own Deployments beside upstream's, by name (`<app>-<name>`, in the mesh as `<name>`), and the blob plane and
	// the metrics export, which are emitted as services of the engine's own. `scale` and `containerResources` take their names.
	services:       {[=~"^[a-z]([-a-z0-9]{0,22}[a-z0-9])?$" & !~"-clock$"]: #Service}
	blobs?:         #Blobs
	metricsExport?: #MetricsExport
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
	let publisher = release._publisher
	// A tenant's release writes no backups (the operator's): its refusal is in `violations`.
	let withBackups = release.backups != _|_ && production && !publisher
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

	// The database's base image, where the release pushed one (render.nu's database-base): the primary runs it, and the
	// schema Jobs keep upstream's full image, which carries the app's SQL. So a change to the SQL, or to anything else the
	// full image copies, moves the Jobs' image and leaves the Cluster's: CloudNativePG recreates the instance on any change
	// to `imageName` (PRONTO-615, as PRONTO-537 for Bonk Chess).
	let dbBase = [
		if app.image != _|_ if app.image.pushed != _|_ if app.image.pushed["database-base"] != _|_ {
			"\(release.environment.registry)/\(release.name)-database-base:\(app.image.pushed["database-base"].tag)@\(app.image.pushed["database-base"].digest)"
		},
	]
	// The door reaches each of the app's own services (`services`) through its Dapr sidecar, as upstream's render does for its own
	// (PRONTO_UPSTREAM_<NAME>=localhost:3500): the door's egress admits the sidecar's port and not a service's own, so a door that
	// dials `flagd:8693` itself is refused. Upstream sets the variable only for the ids of its `doors`, which a release fills from
	// the app's cluster.json, so a service the app declares here would have none (PRONTO-1884: aprende's /ofrep answered 502).
	let serviceNames = [for n, _ in release.services {n}]
	// A tenant's namespace is its provisioner's and so are its policies: upstream's Namespace and NetworkPolicies are not written.
	_patched: [for o in upstream if !(publisher && (o.kind == "Namespace" || o.kind == "NetworkPolicy")) {
		if !(o.kind == "Deployment" && o.metadata.name == caddyName) {
			[
				if o.kind == "Cluster" if len(dbBase) > 0 {
					{
						for k, v in o if k != "spec" {(k): v}
						spec: {
							for k, v in o.spec if k != "imageName" {(k): v}
							imageName: dbBase[0]
						}
					}
				},
				o,
			][0]
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
			(#AddUpstreams & {in: (#RetargetDapr & {in: o, config: caddyConfig}).out, names: serviceNames}).out
		}
		if !retarget && o.kind == "Deployment" && o.metadata.name == caddyName {
			(#AddUpstreams & {in: o, names: serviceNames}).out
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
		[if release.tenant != _|_ if !publisher {
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
		[if release.tenant != _|_ if !publisher {
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
		[if release.tenant != _|_ if !publisher if len(release.tenant.egress) > 0 {
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
	// The app's own services, the blob plane and the metrics export: Deployments, Services, a clock's CronJob and what they read.
	_services: [for o in (#ServiceObjects & {"release": release, "app": app}).out if !(publisher && o.kind == "NetworkPolicy") {o}]

	_pre:  list.Concat([_patched, _added])
	_with: list.Concat([_pre, _services])
	_all:  list.Concat([[for o in _with {(#Tune & {in: o, "release": release}).out}], _logins])

	// The images a pod template or a database names.
	_images: list.Concat([
		[for o in _all if o.kind == "Deployment" || o.kind == "Job" for c in o.spec.template.spec.containers {c.image}],
		[for o in _all if o.kind == "Deployment" || o.kind == "Job" if o.spec.template.spec.initContainers != _|_ for c in o.spec.template.spec.initContainers {c.image}],
		[for o in _all if o.kind == "CronJob" for c in o.spec.jobTemplate.spec.template.spec.containers {c.image}],
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
		[for n, _ in release.scale if n == "\(release.name)-electric" {
			"scale names \(n), a single writer: Electric holds one replication slot and advisory lock per database, so more than one pod needs per-pod slots and sticky routing, which upstream does not render"
		}],
		[if release.database != _|_ for l, _ in release.database.logins if list.Contains(["postgres", "streaming_replica", "electric", "authenticator"], l) {
			"database.logins names \(l), a role of upstream's own"
		}],
		[for o in _logins if len([for u in _pre if u.kind == o.kind && u.metadata.name == o.metadata.name {u}]) > 0 {
			"database.logins would emit \(o.kind)/\(o.metadata.name), which the render already has"
		}],
		[for n, _ in release.scale if len([for o in _with if o.kind == "Deployment" if o.metadata.name == n {o}]) == 0 {
			"scale names \(n), which is no Deployment of the render (\(strings.Join([for o in _with if o.kind == "Deployment" {o.metadata.name}], ", ")))"
		}],
		[for n, _ in release.containerResources if n != "postgres" if len([for o in _with if o.kind == "Deployment" for c in o.spec.template.spec.containers if c.name == n {c}]) == 0 {
			"containerResources names \(n), which is no container of the render's Deployments (or postgres)"
		}],
		[if release.database == _|_ if release.containerResources["postgres"] != _|_ {
			"containerResources.postgres needs `database` to be set, even as {}"
		}],
		[if release.database != _|_ if len(release.database.logins) > 0 if app.externalSecrets != _|_ if app.externalSecrets.enabled {
			"database.logins generate their passwords in the namespace, which the app's externalSecrets store does not do yet"
		}],
		// What a tenant's release (a namespace's publisher) may not write or ask (PRONTO-740 S2).
		[if publisher if release.database != _|_ for l, v in release.database.logins for r in v.inRoles if list.Contains(#TenantRefusedRoles, r) {
			"database.logins.\(l) is a member of \(r), which a tenant's database never is (#TenantRefusedRoles)"
		}],
		[if publisher if len(dbBase) == 0 for o in _all if o.kind == "Cluster" {"Cluster/\(o.metadata.name) has no approved database base pushed: a tenant's Cluster runs the engine's approved image (#TenantDatabaseImages), copied to its own registry path"}],
		[if publisher if !production {"a tenant's release (\(release.namespace)) is never a preview"}],
		[if publisher if release.backups != _|_ {"a tenant's release writes no backups: database.backup and backups are the operator's"}],
		[if publisher if len(release.tenant.egress) > 0 {"a tenant's release writes no NetworkPolicy: tenant.egress is its namespace's provisioner's"}],
		[if publisher for n, s in release.services if s.clock != _|_ {"a tenant's service \(n) sets clock, a CronJob its publisher may not write"}],
		[if publisher if release.blobs != _|_ {"a tenant's release runs no blob plane: it signs in to Google as the operator's account"}],
		[if publisher if release.metricsExport != _|_ {"a tenant's release runs no metrics export: it signs in to Google as the operator's account"}],
		[if publisher if app.externalSecrets != _|_ if app.externalSecrets.enabled {"a tenant's release reads no ClusterSecretStore: the app's externalSecrets must be off"}],
		[if publisher for o in _all if !list.Contains(#PublisherKinds, "\(o.apiVersion)/\(o.kind)") {
			"\(o.kind)/\(o.metadata.name) is not a kind a tenant's publisher writes (#PublisherKinds)"
		}],
		[if publisher for r in release.retire if list.Contains(#TenantNoRetire, r.kind) {
			"retire names \(r.kind)/\(r.name), which a tenant's publisher may not delete"
		}],
		[if publisher for o in _all if o.kind == "Gateway" for l in o.spec.listeners if l.port != 80 || l.protocol != "HTTP" {
			"Gateway/\(o.metadata.name) listens on \(l.port)/\(l.protocol); a tenant's gateway listens on 80/HTTP alone"
		}],
		[if publisher if release.origin != "https://\(release.host)" {"a tenant's origin is https://\(release.host), not \(release.origin)"}],
		// `jail`, `google` and `egress` of a service are Studio's builder's alone (PRONTO-1882): they weaken the pod (a user namespace, an
		// unmasked /proc, AppArmor and seccomp off), hand it a Google identity and open the network past the mesh, which a tenant's app
		// must never ask. Here, with the engine's other refusals, so the objects themselves are refused, not only a whole release. A
		// tenant's release (a game named studio included) never has them.
		[for n, s in release.services if s.jail || s.google != _|_ || len(s.egress) > 0 if publisher || release.name != "studio" || n != "builder" {
			"service \(n) of \(release.name) sets jail, google or egress, which only Studio's builder (app studio, service builder) may (PRONTO-1882)"
		}],
		// what an app's services may not be
		[for i, o in _services for j, p in _services if j > i if o.kind == p.kind && o.metadata.name == p.metadata.name {
			"services, blobs and metricsExport would emit \(o.kind)/\(o.metadata.name) twice"
		}],
		[for o in _services if len([for u in _pre if u.kind == o.kind && u.metadata.name == o.metadata.name {u}]) > 0 {
			"services, blobs or metricsExport would emit \(o.kind)/\(o.metadata.name), which the render already has"
		}],
		[for n, s in release.services if s.database != _|_ if release.database == _|_ || release.database.logins[s.database.login] == _|_ {
			"services.\(n).database names the login \(s.database.login), which database.logins does not declare"
		}],
		[for n, s in release.services for cm, _ in s.seed if len([for _, c in s.files if c == cm {c}]) == 0 {
			"services.\(n).seed names the ConfigMap \(cm), which no directory of its files reads"
		}],
		[for n, s in release.services for v, _ in s.secrets if s.env[v] != _|_ {
			"services.\(n).env and secrets both name \(v)"
		}],
		[for n, s in release.services if s.database != _|_ if s.env[s.database.env] != _|_ {
			"services.\(n).env names \(s.database.env), which its database login fills"
		}],
		[for n, s in release.services if s.clock != _|_ if len("\(release.name)-\(n)-clock") > 52 {
			"services.\(n).clock would be the CronJob \(release.name)-\(n)-clock, whose name a Job's pods cannot carry past 52 characters"
		}],
		[for n, _ in release.scale if n == "\(release.name)-metrics-export" {
			"scale names \(n), a single writer: two collectors would write the same series"
		}],
		[if release.metricsExport != _|_ for n, s in release.services if s.metrics != _|_ for o in _all if o.kind == "Deployment" && o.metadata.name == "\(release.name)-\(n)" if o.spec.replicas > 1 {
			"metricsExport scrapes services.\(n) through its Service, which mixes the counters of its pods: it must run one (scale names it)"
		}],
		[for n, s in release.services for v, _ in s.secrets if s.database != _|_ if s.database.env == v {
			"services.\(n).secrets names \(v), which its database login fills"
		}],
		[for n, s in release.services for cm, _ in s.seed if cm == "pronto-release" || len([for o in _all if o.kind == "ConfigMap" && o.metadata.name == cm {o}]) > 0 {
			"services.\(n).seed names the ConfigMap \(cm), which the release writes itself"
		}],
		[if release.metricsExport != _|_ if len([for _, s in release.services if s.metrics != _|_ {s}]) == 0 {
			"metricsExport needs a service with `metrics` to scrape"
		}],
		[for i in _images if publisher || !list.Contains(#External, i) if !strings.HasPrefix(i, release.environment.registry+"/") {
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

// A door Deployment whose `caddy` container has `PRONTO_UPSTREAM_<NAME>=localhost:3500` (the Dapr sidecar) for each of `names`
// that its environment does not already name: one already there is left as it is. A Deployment with no spec, pod template or
// containers is passed on as it is, for the API server to refuse.
#AddUpstreams: {
	in:    _
	names: [...string]
	out: {
		for k, v in in if k != "spec" {(k): v}
		if in.spec != _|_ {
			spec: {
				for k, v in in.spec if k != "template" {(k): v}
				if in.spec.template != _|_ {
					template: {
						for k, v in in.spec.template if k != "spec" {(k): v}
						if in.spec.template.spec != _|_ {
							spec: {
								for k, v in in.spec.template.spec if k != "containers" {(k): v}
								if in.spec.template.spec.containers != _|_ {
									containers: [for c in in.spec.template.spec.containers {
										if c.name != "caddy" {c}
										if c.name == "caddy" {
											let have = [if c.env != _|_ for e in c.env {e.name}]
											let add = [for n in names for var in ["PRONTO_UPSTREAM_\(strings.ToUpper(strings.Replace(n, "-", "_", -1)))"] if !list.Contains(have, var) {name: var, value: "localhost:3500"}]
											for k, v in c if k != "env" {(k): v}
											if len(add) == 0 if c.env != _|_ {env: c.env}
											if len(add) > 0 {env: list.Concat([[if c.env != _|_ for e in c.env {e}], add])}
										}
									}]
								}
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

// What the release's services, blob plane and metrics export are as objects, by the shapes upstream's own Deployments have:
// in the mesh (a Dapr sidecar under the app's shared Configuration), reached by name, a policy of the services' own. `app`
// is upstream's ReleaseSpec, read for the pushed images (`image.pushed`) and the shared resources.
#ServiceObjects: {
	release: #Release
	app:     {...}
	let ns = release.namespace
	let appLabels = {"app.kubernetes.io/name": release.name, "app.kubernetes.io/instance": release.name, "app.kubernetes.io/managed-by": "cue"}
	let selects = {component: string, out: {"app.kubernetes.io/name": release.name, "app.kubernetes.io/component": component}}
	let origin = release.origin
	let netpol = [if app.networkPolicy != _|_ if app.networkPolicy.enabled != _|_ {app.networkPolicy.enabled}, true][0]
	let podResources = [if app.resources != _|_ {app.resources}, {requests: {cpu: "50m", memory: "64Mi"}, limits: {cpu: "500m", memory: "256Mi"}}][0]
	let blobsPorts = {rcloneS3: 3900, imgproxy: 8081}

	// The image the build pushed for `svc`: by digest, which the render refuses to go without.
	let imageOf = {
		svc: string
		let ref = [
			if app.image != _|_ if app.image.pushed != _|_ if app.image.pushed[svc] != _|_ {":\(app.image.pushed[svc].tag)@\(app.image.pushed[svc].digest)"},
			if app.image != _|_ if app.image.tag != _|_ {":\(app.image.tag)"},
			":latest",
		]
		out: "\(release.environment.registry)/\(release.name)-\(svc)\(ref[0])"
	}

	// Every pod joins the mesh, as upstream's do: its sidecar under the shared Configuration.
	let sidecar = {
		id:   string
		port: int
		out: {
			"dapr.io/enabled":                 "true"
			"dapr.io/app-id":                  id
			"dapr.io/app-port":                "\(port)"
			"dapr.io/config":                  "\(release.name)-dapr-config"
			"dapr.io/enable-metrics":          "true"
			"dapr.io/metrics-port":            "9090"
			"dapr.io/block-shutdown-duration": "20s"
		}
	}

	// A Google identity with no key: the projected token of the pod's service account, traded at the workload identity.
	let credentials = {
		provider:       string
		serviceAccount: string
		out: {
			type:               "external_account"
			audience:           "//iam.googleapis.com/\(provider)"
			subject_token_type: "urn:ietf:params:oauth:token-type:jwt"
			token_url:          "https://sts.googleapis.com/v1/token"
			credential_source: file: "/var/run/secrets/gcp/token"
			service_account_impersonation_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/\(serviceAccount):generateAccessToken"
		}
	}

	let serviceObjs = [for n, s in release.services for o in list.Concat([
		[{
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(release.name)-\(n)", namespace: ns, labels: appLabels & {"app.kubernetes.io/component": n}}
			spec: {
				replicas: 1
				if s.singleWriter {strategy: type: "Recreate"}
				selector: matchLabels: (selects & {component: n}).out
				template: {
					metadata: {
						labels:      appLabels & {"app.kubernetes.io/component": n}
						annotations: (sidecar & {id: n, port: s.port}).out
						if s.metrics != _|_ {
							annotations: {
								"prometheus.io/scrape": "true"
								"prometheus.io/port":   "\(s.metrics.port)"
								"prometheus.io/path":   s.metrics.path
							}
						}
					}
					spec: {
						// A Service's links would give AUTH_PORT=tcp://... to a pod that reads AUTH_PORT as its port.
						enableServiceLinks: false
						if s.google != _|_ {serviceAccountName: "\(release.name)-\(n)"}
						if s.jail {
							hostUsers: false
							securityContext: {
								appArmorProfile: type: "Unconfined"
								seccompProfile: type:  "Unconfined"
							}
						}
						containers: [{
							name: n
							if s.jail {securityContext: procMount: "Unmasked"}
							image:           (imageOf & {svc: n}).out
							imagePullPolicy: release.environment.imagePullPolicy
							// A pod going away keeps serving while the mesh learns of its successor.
							lifecycle: preStop: sleep: seconds: 15
							ports: [{name: "http", containerPort: s.port}, if s.metrics != _|_ if s.metrics.port != s.port {{name: "metrics", containerPort: s.metrics.port}}]
							env: list.Concat([
								[for k, v in s.env if k != "ORIGIN" {name: k, value: v}],
								[
									{name: "PORT", value: "\(s.port)"},
									{name: "ORIGIN", value: [if s.env["ORIGIN"] != _|_ {s.env["ORIGIN"]}, origin][0]},
									{name: "SERVICE_JWT", valueFrom: secretKeyRef: {name: "\(release.name)-service-token", key: "SERVICE_JWT"}},
									for k, v in s.secrets {name: k, valueFrom: secretKeyRef: {name: v, key: k}},
									if s.database != _|_ {{name: s.database.env, valueFrom: secretKeyRef: {name: "\(release.name)-\(strings.Replace(s.database.login, "_", "-", -1))-db", key: "url"}}},
									// Deno's spans, to the node's Jaeger.
									{name: "OTEL_DENO", value: "true"},
									{name: "OTEL_SERVICE_NAME", value: n},
									{name: "OTEL_EXPORTER_OTLP_ENDPOINT", value: "http://jaeger.observability.svc.cluster.local:4318"},
								],
							])
							startupProbe:   {tcpSocket: port: s.port, periodSeconds: 2, failureThreshold: 60}
							readinessProbe: {tcpSocket: port: s.port, periodSeconds: 5}
							"resources":    podResources
							if len(s.files) > 0 || len(s.scratch) > 0 || s.google != _|_ {
								volumeMounts: list.Concat([
									[for dir, cm in s.files {name: "files-\(cm)", mountPath: dir, readOnly: true}],
									[for dir, _ in s.scratch {name: "scratch-\(strings.SliceRunes(hex.Encode(sha256.Sum256(dir)), 0, 12))", mountPath: dir}],
									[if s.google != _|_ {{name: "google-token", mountPath: "/var/run/secrets/gcp", readOnly: true}}],
								])
							}
						}]
						if len(s.files) > 0 || len(s.scratch) > 0 || s.google != _|_ {
							volumes: list.Concat([
								// one volume a ConfigMap, whatever directories read it
								[for cm, _ in {for _, c in s.files {(c): true}} {name: "files-\(cm)", configMap: "name": cm}],
								[for dir, size in s.scratch {name: "scratch-\(strings.SliceRunes(hex.Encode(sha256.Sum256(dir)), 0, 12))", emptyDir: sizeLimit: size}],
								[if s.google != _|_ {{name: "google-token", projected: sources: [{serviceAccountToken: {path: "token", audience: s.google.audience, expirationSeconds: 3600}}]}}],
							])
						}
					}
				}
			}
		}, {
			apiVersion: "v1"
			kind:       "Service"
			metadata:   {name: n, namespace: ns, labels: appLabels & {"app.kubernetes.io/component": n}}
			spec: {
				type:     "ClusterIP"
				selector: (selects & {component: n}).out
				ports:    [{name: "http", port: s.port, targetPort: s.port, protocol: "TCP"}, if s.metrics != _|_ if s.metrics.port != s.port {{name: "metrics", port: s.metrics.port, targetPort: s.metrics.port, protocol: "TCP"}}]
			}
		}],
		// The service's own account, whose token the pod trades for its Google identity.
		[if s.google != _|_ {
			apiVersion: "v1"
			kind:       "ServiceAccount"
			metadata:   {name: "\(release.name)-\(n)", namespace: ns, labels: appLabels & {"app.kubernetes.io/component": n}}
		}],
		// The service's own egress past the services' policy: policies add up.
		[if netpol if len(s.egress) > 0 {
			apiVersion: "networking.k8s.io/v1"
			kind:       "NetworkPolicy"
			metadata:   {name: "\(release.name)-\(n)-egress", namespace: ns, labels: appLabels}
			spec: {
				podSelector: matchLabels: (selects & {component: n}).out
				policyTypes: ["Egress"]
				egress: [for e in s.egress {
					to: [
						if e.cidr != _|_ {{ipBlock: {cidr: e.cidr, if len(e.except) > 0 {except: e.except}}}},
						if e.namespace != _|_ {{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": e.namespace, podSelector: matchLabels: e.podLabels}},
					]
					ports: [{port: e.port, protocol: "TCP"}]
				}]
			}
		}],
		// The clock: each schedule, a pod that POSTs to the service's path with the service role's token.
		[if s.clock != _|_ {
			apiVersion: "batch/v1"
			kind:       "CronJob"
			metadata:   {name: "\(release.name)-\(n)-clock", namespace: ns, labels: appLabels & {"app.kubernetes.io/component": "\(n)-clock"}}
			spec: {
				schedule:                   s.clock.schedule
				timeZone:                   "Etc/UTC"
				concurrencyPolicy:          "Forbid"
				startingDeadlineSeconds:    50
				successfulJobsHistoryLimit: 1
				failedJobsHistoryLimit:     3
				jobTemplate: spec: {
					backoffLimit:            0
					activeDeadlineSeconds:   60
					ttlSecondsAfterFinished: 600
					template: {
						// It carries the app's name label, which the services' network policy admits on their ports.
						metadata: labels: appLabels & {"app.kubernetes.io/component": "\(n)-clock"}
						spec: {
							restartPolicy:      "Never"
							enableServiceLinks: false
							containers: [{
								name:  "poke"
								image: #External[1]
								env:   [{name: "SERVICE_JWT", valueFrom: secretKeyRef: {name: "\(release.name)-service-token", key: "SERVICE_JWT"}}]
								// A new pod's address reaches the network policies a few seconds after it starts (k3s's
								// kube-router refuses it until then): it waits, up to 30s, for the service to take a connection,
								// then pokes once.
								command: ["sh", "-c", """
									u=http://\(n).\(ns).svc.cluster.local:\(s.port)
									for i in $(seq 10); do [ "$(curl -s -o /dev/null -m 1 -w '%{http_code}' "$u/")" != 000 ] && break; sleep 2; done
									exec curl -fsS -m 50 -X POST -H "Authorization: Bearer $SERVICE_JWT" "$u\(s.clock.path)?caller=k8s-cronjob"
									"""]
								resources: limits: {cpu: "100m", memory: "32Mi"}
							}]
						}
					}
				}
			}
		}],
		// The service's own reach of the database: a policy of its own, since policies add up.
		[if netpol if s.database != _|_ {
			apiVersion: "networking.k8s.io/v1"
			kind:       "NetworkPolicy"
			metadata:   {name: "\(release.name)-\(n)-database-egress", namespace: ns, labels: appLabels}
			spec: {
				podSelector: matchLabels: (selects & {component: n}).out
				policyTypes: ["Egress"]
				egress: [{
					to:    [{podSelector: matchLabels: "cnpg.io/cluster": "\(release.name)-db"}]
					ports: [{port: 5432, protocol: "TCP"}]
				}]
			}
		}],
	]) {o}]

	// The blob plane: rclone over the bucket, and imgproxy over rclone (on the cluster network, not through the mesh, whose
	// invoke path would be part of what the S3 client signs).
	let blobsObjs = [if release.blobs != _|_ {
		let x = release.blobs
		let blobsName = "\(release.name)-blobs"
		let cred = (credentials & {provider: x.provider, serviceAccount: x.serviceAccount}).out
		let rcloneLabels = appLabels & {"app.kubernetes.io/component": "rclone-s3"}
		let imgproxyLabels = appLabels & {"app.kubernetes.io/component": "imgproxy"}
		[{
			apiVersion: "v1"
			kind:       "ServiceAccount"
			metadata:   {name: blobsName, namespace: ns, labels: rcloneLabels}
		}, {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata:   {name: blobsName, namespace: ns, labels: rcloneLabels}
			data: "credentials.json": json.Marshal(cred)
		}, {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(release.name)-rclone-s3", namespace: ns, labels: rcloneLabels}
			spec: {
				replicas: 1
				selector: matchLabels: (selects & {component: "rclone-s3"}).out
				template: {
					metadata: {
						labels:      rcloneLabels
						annotations: (sidecar & {id: "rclone-s3", port: blobsPorts.rcloneS3}).out
						// A changed credential rolls the pods.
						annotations: "pronto.dev/config": hex.Encode(sha256.Sum256(json.Marshal(cred)))
					}
					spec: {
						serviceAccountName: blobsName
						enableServiceLinks: false
						containers: [{
							name:            "rclone-s3"
							image:           (imageOf & {svc: "rclone-s3"}).out
							imagePullPolicy: release.environment.imagePullPolicy
							command:         ["rclone"]
							args:            ["serve", "s3", "--addr=0.0.0.0:\(blobsPorts.rcloneS3)", "--vfs-cache-mode=off", "objects:"]
							lifecycle: preStop: sleep: seconds: 15
							ports: [{name: "http", containerPort: blobsPorts.rcloneS3}]
							// mecha's blob plane over the bucket: a combine remote names its root mecha-objects, and the pod's
							// service account reaches it with no key.
							env: [
								{name: "RCLONE_CONFIG_OBJECTS_TYPE", value: "combine"},
								{name: "RCLONE_CONFIG_OBJECTS_UPSTREAMS", value: "mecha-objects=gcs:\(x.bucket)"},
								{name: "RCLONE_CONFIG_GCS_TYPE", value: "google cloud storage"},
								{name: "RCLONE_CONFIG_GCS_ENV_AUTH", value: "true"},
								{name: "RCLONE_CONFIG_GCS_BUCKET_POLICY_ONLY", value: "true"},
								{name: "GOOGLE_APPLICATION_CREDENTIALS", value: "/etc/gcp/credentials.json"},
							]
							startupProbe: {tcpSocket: port: blobsPorts.rcloneS3, periodSeconds: 2, failureThreshold: 60}
							"resources":  podResources
							volumeMounts: [
								{name: "credentials", mountPath: "/etc/gcp", readOnly: true},
								{name: "token", mountPath: "/var/run/secrets/gcp", readOnly: true},
							]
						}]
						volumes: [
							{name: "credentials", configMap: "name": blobsName},
							{name: "token", projected: sources: [{serviceAccountToken: {path: "token", audience: x.audience, expirationSeconds: 3600}}]},
						]
					}
				}
			}
		}, {
			apiVersion: "v1"
			kind:       "Service"
			metadata:   {name: "rclone-s3", namespace: ns, labels: rcloneLabels}
			spec: {
				type:     "ClusterIP"
				selector: (selects & {component: "rclone-s3"}).out
				ports:    [{name: "http", port: blobsPorts.rcloneS3, targetPort: blobsPorts.rcloneS3, protocol: "TCP"}]
			}
		}, {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: "\(release.name)-imgproxy", namespace: ns, labels: imgproxyLabels}
			spec: {
				replicas: 1
				selector: matchLabels: (selects & {component: "imgproxy"}).out
				template: {
					metadata: {
						labels:      imgproxyLabels
						annotations: (sidecar & {id: "imgproxy", port: blobsPorts.imgproxy}).out
					}
					spec: {
						enableServiceLinks: false
						containers: [{
							name:            "imgproxy"
							image:           (imageOf & {svc: "imgproxy"}).out
							imagePullPolicy: release.environment.imagePullPolicy
							lifecycle: preStop: sleep: seconds: 15
							ports: [{name: "http", containerPort: blobsPorts.imgproxy}]
							// As the app's compose: mecha's presets alone, no key signs a URL.
							env: [
								{name: "IMGPROXY_USE_S3", value: "true"},
								{name: "IMGPROXY_S3_ENDPOINT", value: "http://rclone-s3.\(ns).svc.cluster.local:\(blobsPorts.rcloneS3)"},
								// The store takes any key pair; imgproxy's S3 client insists on one.
								{name: "AWS_ACCESS_KEY_ID", value: "GK000000000000000000000000"},
								{name: "AWS_SECRET_ACCESS_KEY", value: "0000000000000000000000000000000000000000000000000000000000000000"},
								{name: "AWS_REGION", value: "rclone"},
								{name: "IMGPROXY_BIND", value: ":\(blobsPorts.imgproxy)"},
								{name: "IMGPROXY_MAX_SRC_RESOLUTION", value: "50"},
								// The store and Google's photo host, as mecha's #ImgproxySources.
								{name: "IMGPROXY_ALLOWED_SOURCES", value: "s3://mecha-objects/,https://lh3.googleusercontent.com/"},
								{name: "IMGPROXY_ONLY_PRESETS", value: "true"},
								{name: "IMGPROXY_PRESETS", value: "thumb=rs:fill:128:128/f:webp,avatar=rs:fill:256:256/f:webp,picture=rs:fit:1024:1024/f:webp"},
								{name: "IMGPROXY_MAX_RESULT_DIMENSION", value: "1024"},
								{name: "IMGPROXY_SET_CANONICAL_HEADER", value: "false"},
								{name: "IMGPROXY_CACHE_CONTROL_PASSTHROUGH", value: "true"},
							]
							startupProbe: {tcpSocket: port: blobsPorts.imgproxy, periodSeconds: 2, failureThreshold: 60}
							"resources":  podResources
						}]
					}
				}
			}
		}, {
			apiVersion: "v1"
			kind:       "Service"
			metadata:   {name: "imgproxy", namespace: ns, labels: imgproxyLabels}
			spec: {
				type:     "ClusterIP"
				selector: (selects & {component: "imgproxy"}).out
				ports:    [{name: "http", port: blobsPorts.imgproxy, targetPort: blobsPorts.imgproxy, protocol: "TCP"}]
			}
		}]
	}]

	// The metrics export: an OpenTelemetry collector scraping each service's metrics port through its Service and writing to
	// Managed Service for Prometheus, signed in through workload identity.
	let exportObjs = [if release.metricsExport != _|_ {
		let x = release.metricsExport
		let exportName = "\(release.name)-metrics-export"
		let labels = appLabels & {"app.kubernetes.io/component": "metrics-export"}
		let cred = (credentials & {provider: x.provider, serviceAccount: x.serviceAccount}).out
		let config = {
			receivers: prometheus: config: scrape_configs: [for sn, s in release.services if s.metrics != _|_ {
				job_name:        sn
				scrape_interval: x.interval
				metrics_path:    s.metrics.path
				static_configs:  [{targets: ["\(sn).\(ns).svc.cluster.local:\(s.metrics.port)"]}]
			}]
			processors: {
				resource: attributes: [
					{key: "cloud.region", value: x.location, action: "upsert"},
					{key: "k8s.cluster.name", value: x.cluster, action: "upsert"},
					{key: "k8s.namespace.name", value: ns, action: "upsert"},
				]
				batch: {}
			}
			exporters: googlemanagedprometheus: project: x.project
			service: pipelines: metrics: {
				receivers:  ["prometheus"]
				processors: ["resource", "batch"]
				exporters:  ["googlemanagedprometheus"]
			}
		}
		[{
			apiVersion: "v1"
			kind:       "ServiceAccount"
			metadata:   {name: exportName, namespace: ns, "labels": labels}
		}, {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata:   {name: exportName, namespace: ns, "labels": labels}
			data: {
				"config.yaml":      yaml.Marshal(config)
				"credentials.json": json.Marshal(cred)
			}
		}, {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata:   {name: exportName, namespace: ns, "labels": labels}
			spec: {
				// one collector: two would write the same series
				replicas: 1
				strategy: type:        "Recreate"
				selector: matchLabels: (selects & {component: "metrics-export"}).out
				template: {
					metadata: {
						"labels": labels
						// A changed config rolls the collector.
						annotations: "pronto.dev/config": hex.Encode(sha256.Sum256(yaml.Marshal(config) + json.Marshal(cred)))
					}
					spec: {
						serviceAccountName: exportName
						enableServiceLinks: false
						containers: [{
							name:        "otelcol"
							image:       #External[0]
							args:        ["--config=/etc/otelcol/config.yaml"]
							env:         [{name: "GOOGLE_APPLICATION_CREDENTIALS", value: "/etc/otelcol/credentials.json"}]
							"resources": podResources
							volumeMounts: [
								{name: "config", mountPath: "/etc/otelcol", readOnly: true},
								{name: "token", mountPath: "/var/run/secrets/gcp", readOnly: true},
							]
						}]
						volumes: [
							{name: "config", configMap: "name": exportName},
							{name: "token", projected: sources: [{serviceAccountToken: {path: "token", audience: x.audience, expirationSeconds: 3600}}]},
						]
					}
				}
			}
		}]
	}]

	// What each takes and reaches: the door's requests on its port and the mesh's, the node's metrics scrapers on the metrics
	// ports, the mesh, Jaeger, and the internet on 443 (a broker). The backends' policy of upstream's holds the cluster's own.
	let components = list.Concat([[for n, _ in release.services {n}], [if release.blobs != _|_ for c in ["rclone-s3", "imgproxy"] {c}]])
	let metricPorts = [for _, s in release.services if s.metrics != _|_ {port: s.metrics.port, protocol: "TCP"}]
	let policyObjs = [if netpol if len(components) > 0 {
		apiVersion: "networking.k8s.io/v1"
		kind:       "NetworkPolicy"
		metadata:   {name: "\(release.name)-services-netpol", namespace: ns, labels: appLabels}
		spec: {
			podSelector: matchExpressions: [{key: "app.kubernetes.io/component", operator: "In", values: components}]
			policyTypes: ["Ingress", "Egress"]
			ingress: list.Concat([
				[{
					from: [{podSelector: matchLabels: "app.kubernetes.io/name": release.name}]
					ports: list.Concat([
						[for _, s in release.services {port: s.port, protocol: "TCP"}],
						[if release.blobs != _|_ for _, p in blobsPorts {port: p, protocol: "TCP"}],
						[{port: 50002, protocol: "TCP"}, {port: 3500, protocol: "TCP"}],
					])
				}, {
					from:  [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "observability"}]
					ports: list.Concat([[{port: 9090, protocol: "TCP"}], metricPorts])
				}],
				// the metrics export's own scrape
				[if len(metricPorts) > 0 {
					from:  [{podSelector: matchLabels: (selects & {component: "metrics-export"}).out}]
					ports: metricPorts
				}],
			])
			egress: [
				{ports: [{port: 53, protocol: "UDP"}, {port: 53, protocol: "TCP"}]},
				{
					to:    [{podSelector: matchLabels: "app.kubernetes.io/name": release.name}]
					ports: list.Concat([[{port: 50002, protocol: "TCP"}, {port: 3500, protocol: "TCP"}], [if release.blobs != _|_ {{port: blobsPorts.rcloneS3, protocol: "TCP"}}]])
				},
				{
					to:    [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "observability"}]
					ports: [{port: 4317, protocol: "TCP"}, {port: 4318, protocol: "TCP"}, {port: 9411, protocol: "TCP"}]
				},
				{
					to:    [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "dapr-system"}]
					ports: [for p in [4000, 50001, 50005, 50006, 6500] {port: p, protocol: "TCP"}]
				},
				{
					to:    [{ipBlock: {cidr: "0.0.0.0/0", except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]}}]
					ports: [{port: 443, protocol: "TCP"}]
				},
			]
		}
	}]

	out: list.Concat([serviceObjs, list.Concat(blobsObjs), list.Concat(exportObjs), policyObjs])
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
		if in.kind == "Job" if in.metadata.name == "\(release.name)-initdb" {(#TuneInitdb & {"in": in}).out},
		in,
	][0]
}

// The initdb Job's pod is new, and k3s's kube-router refuses a new pod's address for a few seconds (the clock's poke below
// waits for it the same way): upstream's script ran psql at once, was refused ("Connection refused" from the database
// Service, whose primary was healthy), and the Job, which never retries, failed the release. Its script is run after a wait,
// up to a minute, for the database to take a connection; a database that never does fails it as before. The migrate Job
// connects at once too, from its image's own entrypoint: it is not tuned here.
#TuneInitdb: {
	in: _
	let wait = "for i in $(seq 30); do PGCONNECT_TIMEOUT=2 psql -XtAc 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done\n"
	out: {
		for k, v in in if k != "spec" {(k): v}
		spec: {
			for k, v in in.spec if k != "template" {(k): v}
			template: {
				for k, v in in.spec.template if k != "spec" {(k): v}
				spec: {
					for k, v in in.spec.template.spec if k != "containers" {(k): v}
					containers: [for c in in.spec.template.spec.containers {
						for k, v in c if k != "command" {(k): v}
						if c.command != _|_ {
							// ["bash", "-c", script]: the script is the one to wait before; any other shape is left alone
							if len(c.command) == 3 if c.command[1] == "-c" {command: [c.command[0], "-c", wait + c.command[2]]}
							if len(c.command) != 3 {command: c.command}
							if len(c.command) == 3 if c.command[1] != "-c" {command: c.command}
						}
					}]
				}
			}
		}
	}
}

#TuneDeployment: {
	in:      _
	release: #Release
	let production = release.preview == ""
	let n = in.metadata.name

	// single writers: a Recreate strategy, and Electric (one replication slot and advisory lock per database)
	let recreate = n == "\(release.name)-electric" || len([if in.spec.strategy != _|_ if in.spec.strategy.type == "Recreate" {true}]) > 0
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
		if len(sizeOf) > 0 {div(strconv.Atoi(sizeOf[0][1])*{Mi: 1, Gi: 1024, Ti: 1048576}[sizeOf[0][2]], 4)},
	]
	let smart = [if db.smartShutdown != _|_ {db.smartShutdown}, if db.instances > 1 {0}]
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
			if db.instances > 1 || db.haSlots {replicationSlots: highAvailability: enabled: db.haSlots}
			if db.instances > 1 || !db.enablePDB {enablePDB: db.enablePDB}

			// A stop is bounded: a smart shutdown for `smartShutdown` seconds, a fast one after, the pod killed at
			// stopDelay. Written only where named or with standbys; else CloudNativePG's defaults stay.
			if len(smart) > 0 {
				smartShutdownTimeout: smart[0]
				stopDelay:            120
			}
			if release.containerResources["postgres"] != _|_ {resources: release.containerResources["postgres"]}
		}
	}
}
