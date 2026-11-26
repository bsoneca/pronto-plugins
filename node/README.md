# node

The release of a pronto app onto the Contabo node's k3s: upstream pronto's manifests (the version the app
pins, bonisoft3/pronto's CUE module v1.5.1, v1.7.0, v1.10.1, v1.11.1, v1.14.1, v1.15.1 and v1.16.1, and the runtime tools of `validated_pins`: an app's mise pins the tool its module's distribution config names, one release behind, so v1.7.0 runs under tool 1.6.0, v1.10.1 under 1.10.0, v1.11.1 under 1.11.0, v1.14.1 under 1.14.0 and v1.15.1 under 1.15.0; module v1.15.0 names 1.14.0, the previous runtime, so it can never match its own and apps pin v1.15.1), patched and released by an engine that lives in this repository,
images built on the node's own buildkitd and pushed to the node's own registry, which the node pulls from.
No kind, no second cluster, no Cloud Build, no Artifact Registry, no gcloud.

## The node release engine

The Cluster's image does not move with the app's database files (PRONTO-615, as PRONTO-537 for Bonk Chess's gcp
path): CloudNativePG recreates an instance for any change to `imageName`, and the database image carries the app's
SQL (and the `.bayt` files its stage copies) for the schema Jobs to replay, so its digest moves with most releases.
Where the database's Dockerfile stage only copies files onto a base pinned by digest (`database-base` in
`render.nu`: no RUN, no ADD, no copy from another stage), the build copies that base into the node's registry as
`<app>-database-base:<postgres major>` (`crane copy`, digest unchanged) and `#Manifests` points the Cluster at it;
the Jobs keep the full image. A stage that adds anything, or a base not pinned, keeps the Cluster on the full
image. The first release after an app moves onto the base restarts the primary once.

`node/engine/` is the release of an app whose `release.cue` holds `Node: node.#Release`. It runs on the
Mac (a runner, release-cron), never on the node; kubectl reaches the node's API over an ssh tunnel it opens
and closes itself (`tunnel.nu`: a free local port and a kubeconfig of each release's own, so releases running
at once share nothing; one BatchMode login, never retried, because a failed login gets the Mac banned by the
node's CrowdSec). The same ssh process carries two more forwards, to the node's operator buildkitd
(`127.0.0.1:1234`) and its registry (`127.0.0.1:5000`), each to a free local port, never to 5000, which macOS's
AirPlay receiver holds.

The app pins in its mise the tools the engine runs: `kubectl`, `docker` (the CLI, never a
daemon) with its compose plugin (`aqua:docker/compose`, linked into a docker config of the call's own), `buildx` (`aqua:docker/buildx@0.39.1`, whose binary aqua names `docker-cli-plugin-docker-buildx`; run against the node's buildkit v0.29 it loads aprende's 7,933-path context and builds database, crud, electric and auth with the digests 0.33.0 gave. Not older than 0.39.1 once Go 1.27 builds it: buildx sends a Dockerfile's COPY sources as gRPC header values, one per path, and Go 1.27's net/http refuses more than 500 of them, fixed in 0.39.1, so Homebrew's 0.38.0 and the official 0.39.0 lose the session with `PROTOCOL_ERROR` or `431`; 0.33.0, built with Go 1.25, also works; the engine takes the buildx whose folder is first on the PATH, so the pin wins over Homebrew's), `sops` (when it has a SOPS file) and
`crane` (a release that builds, or `--check --build`). The preflight fails at once on a missing one,
and on a pronto runtime that is not in `validated_pins` (runtime.nu, held by contract_test.nu). An existing
namespace the release did not label (`pronto.dev/release=<app>`) is refused, `--adopt` takes it (and then applies every object
server-side with `--force-conflicts`, as field manager `pronto-release`, so the fields another manager set, the old engine's or a
hand's, are the release's; without `--adopt` the apply is the plain one); `--delete` never takes one.

Write it into an app, byte for byte, with:

```
<this repo>/bin/pronto-node --engine [--release-rule] <app-dir>...
```

which writes `node/{release,render,runtime,build,tunnel,push,registry,rollback,restore}.nu` and `node/schema/node.cue` into
each app and, with `--release-rule` only (PRONTO-1891: the rule takes over `./saytw release@k8s`, so an app that releases to the node
another way, as Bonk Chess does through release-cron until P5-H, must not get it from a regeneration), merges a `release@k8s` rule into its
`.say.json`. Without the flag `.say.json` is not touched, so an app that holds the rule keeps it (verify@k8s is the runtime's own: it checks the app's public address) (priority -1, stop: the same mechanism as the
gcp engine, so it runs before the runtime's own `k8s` rule and stops it). `build.nu` is `gcp/engine/build.nu`
(a symlink here; the node engine reads only its `stamp`), two copies to compare. To change the engine: change `node/engine/`
here, merge it, then in the app's repository move the pin to that merge and run `bin/pronto-node --engine`
on every app that holds it, in one pull request.

### What an app writes

```cue
Node: node.#Release & {
	name:    "aprende"
	preview: _preview                       // -t preview=<name>, set by the engine
	context: "contabo2"
	api: {ssh: "user@node"}                 // a tunnel of the release's own to the node's 127.0.0.1:6443
	hosts: production: "aprende.bsoneca.com"
	hooks: afterJobs: [["deno", "run", "node-release/restate.ts"]]
}
App: k8s.#ReleaseSpec & {name: "aprende", namespace: Node.namespace, render: enabled: false, gateway: {host: Node.host, tls: enabled: false}}
nodeManifests: (node.#Manifests & {
	app: App, release: Node
	upstream: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
}).objects
```

An app writes no registry: `build` in the schema defaults to the node's (`127.0.0.1:5000`, as the node's k3s and
buildkitd name it, which `registries.yaml` already mirrors), so every image is `127.0.0.1:5000/<app>-<svc>:<tag>@sha256:...`.

`node/schema/node.cue` imports nothing of upstream: the app renders upstream's objects itself and hands them to
`#Manifests`, which patches them (the Namespace's `pronto.dev/release` label, the Cluster's Barman Cloud plugin
in production, and its `imageName`: the database's base image where the release pushed one, below), adds to them (a tenant's quota and LimitRange, backups' ObjectStore and ScheduledBackup,
production only) and refuses them, as the `violations` field and an error in `objects`: a kind no operator
serves (`#Served`, per operator version), a cluster-scoped object, another namespace, a Job outside `jobOrder`,
a Gateway for another host, an image that is neither in the registry nor pinned by digest.

Replicas and the database are patches over upstream's objects, each present only where the app sets the field (an app
that sets none gets upstream's render as it is, which the contract test holds):

- `replicas` / `previewReplicas`: the pod count of every Deployment but a single writer's (upstream's `Recreate`
  strategy, and Electric, which holds one replication slot and advisory lock per database); `scale: "<app>-caddy":
  {replicas, preview}` for the one named (upstream's full name; an unknown name, and `<app>-electric`, are refused). A preview without a number keeps upstream's one pod.
- `containerResources: <container>: {requests, limits}`: the fields named replace upstream's in that container, in
  every Deployment that has one; `postgres` is the database's own (and needs `database`, even `{}`).
- `database: {instances, storage, parameters, synchronous, smartShutdown, enablePDB, haSlots, logins, backup}`:
  the CloudNativePG Cluster's instances, volume (with a WAL cap per slot of a quarter of it), Postgres parameters,
  synchronous replication, PodDisruptionBudget and slots; with standbys a switchover, not a restart, moves the
  primary. The stop settings (`smartShutdown`, with `stopDelay` 120) are written only where named or with standbys, so
  a bare `database: {}` leaves CloudNativePG's defaults and restarts nothing; `haSlots: false` is written with standbys.
  A login named for one of upstream's roles (postgres, streaming_replica, electric, authenticator) is refused. A `logins` entry is a managed role with a generated password in a Secret of its own
  (`<app>-<login>-db`, which also carries the `url` a service reads). `backup` is `backups` (one emitter, `#Backups`).
  The release waits for the primary (`waits.primary`; a failure puts the old image back), then for every instance
  ready on the image (`waits.standbys`; a failure stops the release but leaves the image: the primary is serving).

The app's own services, the blob plane and the metrics export are Deployments the engine adds beside upstream's (PRONTO-740 PP3):

- `services: <name>: {port, env, secrets, files, seed, metrics, clock, database, singleWriter, jail, google, egress, scratch}`: a compose service of the app that
  upstream does not render (billing, a collector, a flag server), built and pushed with the cluster's images, a Deployment
  `<app>-<name>` and a Service `<name>` in the mesh (Dapr app-id `<name>`, the shared Configuration, probes on its port). Its
  environment is the `env` stated, whole (compose's is not read), plus `PORT`, `SERVICE_JWT` (the service role's token, from
  `<app>-service-token`, which the release signs when any service is declared) and `ORIGIN` (the release's public origin unless
  `env` names it). `secrets: {VAR: <Secret>}` reads each variable from that Secret under its own name (it must be in the SOPS file
  or already in the namespace: the preflight refuses the release when it is neither). `files: {<dir>: <ConfigMap>}` mounts a
  ConfigMap read-only; `seed: {<ConfigMap>: <file of the app>}` makes a missing one from that file, once, on the release that
  finds it missing (a release never writes over one that exists). `metrics: {port, path}` is scraped by the node's
  VictoriaMetrics and the metrics export; `clock: {schedule, path}` is a CronJob POSTing to the service with the token (the
  pinned curl image); `database: {login, env}` reads the URL of one of `database.logins` into `env` and opens the database to
  it; `singleWriter` is a `Recreate` Deployment that the default replicas leave at one. A policy of the services' own admits the
  door and the mesh on their ports, the node's scrapers on the metrics ports, and the internet on 443 (a broker).
  `scale: "<app>-<name>"` and `containerResources: <name>` take their names. A name that upstream's render has (a Deployment or a
  Service), or two services emitting one object, is refused, and so is a login the app does not declare. For a pod like Studio's
  builder: `jail` runs it in a user namespace of its own (`hostUsers: false`) with an unmasked `/proc` and AppArmor and seccomp
  unconfined, which bubblewrap needs on a node that restricts user namespaces; `google: {provider, serviceAccount, audience}` runs
  it as the service account `<app>-<name>`, its token projected for the audience at `/var/run/secrets/gcp/token`, to trade at the
  workload identity with no key; `egress: [{cidr, except, port}]` is a NetworkPolicy `<app>-<name>-egress` beside the services'
  (TCP, one rule each); `scratch: {<dir>: <size>}` is an `emptyDir` mounted at each directory, capped at its size.
- `blobs: {bucket, provider, serviceAccount}`: rclone serving the Cloud Storage bucket as S3 and imgproxy over it (the compose
  services `rclone-s3` and `imgproxy`, built), signed in through workload identity with no key (the token of the service account
  `<app>-blobs`, traded at the pool's `provider`).
- `metricsExport: {project, provider, serviceAccount}`: an OpenTelemetry collector scraping each service's `metrics` port into
  Managed Service for Prometheus, signed in the same way (`<app>-metrics-export`). The collector's and the clock's images are
  the engine's own constants, pinned by digest and pulled from where they are published (`#External`); every other image is
  the registry's and pinned.

After the Deployments the release waits for each of the services' rollouts and checks their sidecars. A service that leaves
`Node.services` leaves its objects behind until `retire` names them (a Deployment, Service, CronJob, ConfigMap, ServiceAccount or
NetworkPolicy). The metrics export scrapes through each Service, so a service with `metrics` runs one pod while it is set, and the
collector is a single writer (`scale` refuses it); a service's port is never one of its sidecar's (3500, 3501, 9090, 50001, 50002, 7777).

### The flow (`release.nu`)

Upstream's own order (k8s/release.nu `main`), with the engine's extra steps marked: the app and the tunnel;
preflight (the operators' versions equal `#Operators`, the CRDs, GatewayClass `eg` Accepted, the backups'
Secret; the node's builder and registry running and answering through the tunnel); build (`push.nu`, below); the release data (upstream's own helpers,
`runtime.nu`) and CUE's render; the Namespace, then a server dry run of the rest, which stops the release
on a rejection; SOPS Secrets and the OIDC Secret (extra); every object but the Deployments and Jobs; wait for
the database's primary on its image; the Jobs in `jobOrder`; `hooks.afterJobs` (extra); the database's roles
reconciled and the service token; the Deployments (crud always rolls) and their rollouts; the Dapr sidecar of
every pod; `retire` (extra); the ConfigMap `pronto-release` with `sha` (extra, what release-cron's `serving`
reads). A failure at or after the objects puts back, with `rollout undo`, only the Deployments whose revision
moved (`rollback.nu`); the database and a restated seed are not rolled back. The last step prunes the node's
registry (`registry.nu`: the digests the cluster names are kept, the rest garbage-collected); a failure of it is
a warning, never a failed release, and its outcome is recorded in the ConfigMap `pronto-release` (`pruned`, and
`prune_error` when it failed).

### The build (`push.nu`)

`docker buildx bake --push` through a buildx `remote` builder at the node's operator buildkitd
(`pronto-buildkit/buildkitd`, rootless, on the node's loopback), which pushes to the node's registry from the
node: no Docker daemon runs on the Mac, and the builder, its docker config and the staged context belong to the
one release and go with it. The context is the app as git sees it (`git ls-files -co --exclude-standard`, no
`.certs/`, and no untracked file that looks like a secret: `*.dec.*`, `.env*`, `secrets*.yaml` that is not
`.enc.yaml`, `*.pem`, `*.key`), copied to a scratch folder, so ignored files and keys are never uploaded, but for the exact files the app's
`Node.build.include` names (what its `generate` writes and git ignores, and its Dockerfiles COPY: it fails when one is missing
or looks like a secret). Every image is tagged
`release` (a preview's name for a preview), and an unchanged service is a cache hit in the buildkitd, which
reproduces the same digest. Never the tenants' buildkitd (`pronto-buildkit-tenants`): that one is for untrusted
Dockerfiles and cannot reach the registry. The node's builder and registry are pronto's services, which a
release never creates or changes; the preflight refuses when either is down.

`--check` is the first steps with every write a server dry run and no build: an image is a placeholder digest.
`--check --build` builds and pushes for real under the tag `check` (registry writes only, never the cluster),
then dry-runs with the real digests: a builder's way to prove an app builds without releasing it. `--build`
alone is refused.
Where the namespace does not exist yet, the objects are asked in `default`. `--serving` prints `serving <sha> verified <sha> maintenance <ok|failed|pending|unknown>` from the namespace's `pronto-release` ConfigMap (the commit built, which is empty for a tree that was not a clean commit; the one cd marked verified with `--verified <sha>`, refused when the node now serves another; the last registry maintenance). `--prune` runs only the registry maintenance and records its outcome, the retry of a release whose own failed (exit 0 done, exit 4 deferred and recorded `pending`, which is not a failure and is retried by the next run; a failure is an error), which an app's cd reads before it releases. `--delete` removes a preview's
namespace and refuses the release's.

`--schema-from <namespace>` (with `--preview`) starts the preview's database as the live one's schema without its rows. The
namespace must exist, not be a preview, and hold `<app>-db` with a primary (its release label is not asked: Bonk's never had one).
After the preview's primary is up and before the schema Jobs, the engine reads the live primary (roles beyond CloudNativePG's own,
`pg_dump --schema-only --no-publications --no-subscriptions` with owners and privileges, and the rows of the `pgroll` schema, so
`migrate` applies only what is new) and applies all of it to the preview in one transaction, then annotates the preview's Cluster
`pronto.dev/schema-from`. A release that finds the annotation copies nothing; a database that has tables and no annotation is refused
(delete the preview first). The live namespace is only read.

A release's `origin` (`Node.origin`, `https://<host>` unless set; an `http` one is refused) is what its services' `ORIGIN` says: a
preview with a host of its own (`hosts.<preview>`, routed by the node's cloudflared, which terminates TLS) has an https origin, which a
passkey is bound to.

Not done yet, refused with a message: the airlock, `TRUSTED_JWKS`. A tenant's release is below.

### The door's Dapr API

The door (caddy) dials its own Dapr sidecar for every upstream, and Dapr answers its own API paths (`/v1.0/metadata`,
secrets, state, publish, shutdown) before it routes by `dapr-app-id`, so `https://<host>/crud/v1.0/metadata` would answer the
sidecar's JSON. The engine gives caddy a Configuration of its own, `<app>-caddy-invoke-only` (the app's plus
`api.allowed` for invocation alone, http and grpc), points the caddy Deployment's `dapr.io/config` at it, and leaves the
shared one to crud, auth and the rest, which need other APIs. After the rollouts the door check (`check-door`, eleven probes:
`door-probes` in `release.nu`) asks the door for the Dapr API paths and fails the release (rolling the Deployments back) when
one reaches the sidecar or a service (a 200 with its metadata or a bare `ok`), when a `/crud` probe does not answer a 404 (the doorguard's own, or
PostgREST's `PGRST125`), and when a probe cannot be asked: a curl failure, a timeout or any 5xx is a failure, never a warning. It does not
depend on DNS: it finds the Envoy Gateway data-plane Service of the release's Gateway (namespace `envoy-gateway-system`, labels
`gateway.envoyproxy.io/owning-gateway-name` and `-namespace`), runs `kubectl port-forward` to it on a free local port and asks
over plain HTTP with the public `Host`, the way the node's cloudflared dials it (the Gateway has no HTTPS listener). The
port-forward's pid is recorded and killed on every exit path. Only a preview with no public host of its own is skipped.

No public prefix reaches a Dapr API path at all (PRONTO-1307). The door's `/img` and `/blobs` handlers strip the prefix and proxy
the rest to the sidecar with a `dapr-app-id`, so `/img/v1.0/metadata` was a 500 from Dapr where the app runs no imgproxy. The
[doorguard](../doorguard/README.md) plugin splices a block into the app's `docker/Caddyfile` at generate time that answers 404 for
`/(crud|img|blobs|electric)/v1.0…` and `/v1.0-alpha1…` before any handler. The build only verifies it: a `docker/Caddyfile` without the
block fails the build (`verify-door-guard` in `push.nu`), naming the plugin. The door check asks `/img` and `/blobs` (and
`-alpha1`) and fails on anything but the door's own 404, a 5xx included.

### Known risks

- A `RUN` step of a Dockerfile built on the operator's buildkitd runs without a process sandbox on the node's
  network, so it can reach the node's loopback, including the registry, which has no authentication: it could
  overwrite any image in it, other apps' included. Only trusted Dockerfiles (this repository's apps, reviewed by
  ci) are built there; untrusted ones belong to the tenants' buildkitd, which cannot reach the registry. Base
  images pinned by digest keep a compromised upstream out of it.
- Registry garbage collection runs while the registry serves (it is not put in read-only mode), so it is serialized with
  releases by leases: a release takes a coordination.k8s.io Lease in the registry's namespace before its push, renews it after the push and each long phase, and holds it to its end,
  and the collector takes the Lease `registry-gc-lock` (a stale one is replaced against its resourceVersion, and only its own holder deletes it), then looks for other fresh leases and collects only when there are
  none (a release takes its lease and then looks for the lock, so one of them always sees the other; a release waits out a
  collection for 3 min, then fails). A lease or lock older than an hour is a dead release's. A push outside the engine (no
  lease) is still seen only as an open upload. The registry is restarted after each collection, so its in-memory blob
  descriptor cache never vouches for a collected layer. A release also asks the registry for each pushed manifest right after
  the push, with its config and every layer (index children too), each asked for its first byte, where a layer that answers 206 with no body (curl exit 18, as distribution up to 3.1.2 does for a layer its cache lists and the collector deleted) counts as lost (PRONTO-1868: a collection by something
  else, such as an older fork's release, leaves the cache stale and a reproducible push writes only links). A 404 restarts the registry once,
  under the collector's lock, only while it caches blob descriptors, no other release holds a lease and no upload is open, and bakes again; a second miss, a
  restart that may not run, or any other answer (a 5xx, a cut-off body, a timeout) fails the release before any rollout.
  The engine does not own the registry's Deployment (it only reads its env), so it cannot set `REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR`.
- A release whose registry maintenance fails is live: the failure is recorded in `pronto-release` (`pruned`, `prune_error`),
  and the command ends with status 3 once its tunnel is closed. A prune stops before any deletion when a registry answers
  anything but 200 or 404 for an image the cluster names.

### Backups (`restore.nu`)

`#Backups` emits the ObjectStore `<app>-backup`, the Cluster's plugin and the ScheduledBackup `<app>-nightly`
(production only, so a preview never archives into production's path). `nu node/restore.nu drill` takes a base
backup now, restores it into the namespace `restore-drill` and compares every table's rows; `restore --to
<namespace> [--target-time <ts>]` makes a recovery Cluster for a real incident.

### A tenant's release

`release.nu --tenant <namespace> --host <host> [--push-kubeconfig <file>] [--check [--build]]` releases an app that is not the operator's
(a game Studio publishes) into a namespace its provisioner made, at the one address the namespace was given (PRONTO-740 S2). It has two actors
and no tunnel: the **publisher**, the `KUBECONFIG` it is given (a ServiceAccount with rights in the namespace alone), and the **push
identity** (`--push-kubeconfig`, or with none the pod's own account, which the environment must say is a pod), which alone may reach the
node's registry pod, the registry's lease and the Envoy Gateway data plane.

- **The tags.** The engine passes `-t tenant=<namespace> -t tenantHost=<host>` to every `cue export`; the app's `release.cue` declares them
  (`@tag(tenant)`, `@tag(tenantHost)`) and binds them into `Node.tenant.{namespace,host}` (and `hosts.production`), which the engine checks
  came out as named. Naming a namespace is what makes `Node.tenant` a publisher's (without one it is the operator's ceiling, `quota` and
  `limitRange`, as before): the namespace, host and origin are the tenant's, the images are `127.0.0.1:5000/<namespace>/<app>-<service>`
  (the image check holds each one to that path), `build.registry` is pinned, and `tenant.buildkit` can only be the tenants' sandboxed buildkitd
  (`tcp://buildkitd.pronto-buildkit-tenants.svc:1234`).
- **The build.** Untrusted Dockerfiles never reach the operator's buildkitd, which has no sandbox and could overwrite any image of the registry:
  the images are built on the tenants' buildkitd as OCI archives (`output=type=oci`, nothing pushed), and pushed with `crane push` by the push
  identity through a port-forward to the registry pod, then read back (`lost-images`). A lost image fails the release: a tenant's release cannot
  restart the registry. The registry's lease and the door check run as the push identity too.
- **What is written.** Only kinds in `#PublisherKinds`, the subset of `#Served` the publisher's Role covers, all in the namespace: no Namespace and
  no NetworkPolicy of upstream's (the provisioner's own isolate it), no quota, LimitRange or egress policy (`tenant.quota` and friends are
  ignored), no backups, no CronJob, no database base image. A service with `jail`, `google`, `egress` or `clock`, a blob plane, a metrics
  export, a Gateway that is not 80/HTTP, an image outside the tenant's path and an origin that is not the host are refused (schema `violations`).
- **What the game's author cannot bypass.** The game's own `release.cue` defines `nodeManifests`, and `node/schema/node.cue` is a file of its
  repository, so the CUE refusals are only as good as what it loaded. In nushell the release therefore (before reading the game's CUE) requires the namespace
  to be `^studio-[a-z0-9-]{1,55}$` and the app's `node/schema/node.cue` to be the engine's own copy byte for byte (`#PublisherKinds` is read from
  the engine's copy, the one list), and (after the render, before anything is applied or asked of the server) checks every object again: a
  publisher's kind, in the tenant's namespace; a Service that is a ClusterIP with no `externalIPs`; in a pod, no `publisher`, `studio-builder`
  or `studio-provisioner` service account, no `hostUsers: false`, host namespace, `hostPath` or privilege, no `procMount` but `Default`, no
  Unconfined seccomp or AppArmor profile, and every container's and initContainer's image under `127.0.0.1:5000/<namespace>/`. The
  tenants' buildkitd and the registry are pinned again there. Every issuer its auth names (a `*_ISSUER` or `*_INTERNAL` setting of the auth provider environment or the compose auth service) must be exactly
  one of `#TenantIssuers` in the engine's schema (`https://id.bonkchess.com`, Studio's sign-in broker), an https name with no credentials, port or
  IP address: the release registers its clients at the issuer from Studio's builder pod, so one the game chose would be a request the pod makes
  for it. Refused, naming the key, before anything is built or any issuer is fetched. `build.include` names only files under the app's real folder (no absolute
  path, `..` or link out of it), and a tenant stages regular files only.
- **What is skipped.** The operators' versions, CRDs and nodes, the namespace's label, the prune and the collection, the registry restart, the
  tunnel and every `exec`. `--preview`, `--delete`, `--schema-from`, `--adopt`, `--serving`, `--verified` and `--prune` are refused with `--tenant`,
  as are a SOPS file (the cluster's key is the operator's), `hooks.afterJobs` and `TRUSTED_JWKS`.
- **The namespace.** A publisher cannot read a namespace, so it is asked what it may do instead: it must be able to create Deployments in it and
  must not be able to create namespaces (an operator's kubeconfig is refused); the ConfigMap `pronto-release` must be absent or say this app
  (`data.app`, which only a tenant's release writes): one app per tenant namespace.
- **The door check** reaches the Envoy Gateway data plane as the push identity. In the builder pod (no `--push-kubeconfig`) it dials the
  Service's ClusterIP, so no right to forward into the gateway's namespace is needed; with a kubeconfig (off the cluster) it forwards to it.
- **Compose is checked before it is resolved.** `docker compose config` reads env_file, secrets' and configs' files and extends files with the release
  process's own rights, so `tenant.nu check-compose-sources` reads the compose files (and `.env`) first and refuses an `include`, ssh forwarding, a
  `COMPOSE_` variable, and any path that is a variable, a URL or outside the app's folder (as it resolves after links). The staged copy is what bake may
  read, so the project's paths inside the app's folder are rebased onto it (`push.nu rebase-paths`) before the build. An ExternalSecret whose target
  template is a service account token, or any Secret or ExternalSecret naming a service account in a `kubernetes.io/service-account.*` annotation, is refused.
  A dry run with no build holds no lease and asks for no push identity.
- **Rights to add on the node, before Studio publishes through it:** the push identity (`studio-builder`, `studio-rc-builder`) needs `leases`
  (coordination.k8s.io: get, list, create, update, patch, delete) and pods/portforward in `pronto-registry`, and get/list on `services` in
  `envoy-gateway-system` (`services/buildkit-tenants/metal.nu` in bsoneca/pronto; with a kubeconfig also pods/portforward there). The preflight names the Role it misses.

### Tests

```
./saytw --script tools.nu cue vet -c ./node/engine/tests
for t in schema release restore contract; do ./saytw --script tools.nu nu node/engine/${t}_test.nu; done
```

The CUE cases and `schema_test.nu` need `cue` alone. The release, restore and tunnel tests run against fakes of
kubectl, sops, ssh, nc, curl, docker (compose and buildx) and crane (`fixtures/fake-kubectl`); they and the contract test render the fixture
app (`fixtures/aprende`, a copy of what an app's release.cue holds; `fixtures/studio` and `fixtures/brawl-chess` are the shapes of those apps) with upstream's real schema, so they need
the CUE registry, and a pronto runtime (`PRONTO_RUNTIME`, or mise's tool the newest validated module names, 1.16.0 for v1.16.1; its upstream release_test.nu also needs `cue` and `nu` on the PATH) whose seven
helpers run for real (register-clients, which runs deno and writes to an issuer, is faked there and never called by a `--check`). The contract test, per upstream pin (`pronto_pin`), holds that the engine's release
data, its objects and its kubectl order equal upstream `main -e gke`'s, except the engine's declared patches
and extra steps; a new pin is validated by moving `pronto_pin` and fixing the engine before an app moves its own.
