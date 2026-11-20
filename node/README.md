# node

The release of a pronto app onto the Contabo node's k3s: upstream pronto's manifests (the version the app
pins, bonisoft3/pronto's CUE module v1.5.1 and v1.7.0, and the runtime tools of `validated_pins`: an app's mise pins the tool its module's distribution config names, one release behind, so v1.7.0 runs under tool 1.6.0), patched and released by an engine that lives in this repository,
images built on the node's own buildkitd and pushed to the node's own registry, which the node pulls from.
No kind, no second cluster, no Cloud Build, no Artifact Registry, no gcloud.

## The node release engine

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
namespace the release did not label (`pronto.dev/release=<app>`) is refused, `--adopt` takes it; `--delete`
never takes one.

Write it into an app, byte for byte, with:

```
<this repo>/bin/pronto-node --engine <app-dir>...
```

which writes `node/{release,render,runtime,build,tunnel,push,registry,rollback,restore}.nu` and `node/schema/node.cue` into
each app and merges a `release@k8s` rule into its `.say.json` (verify@k8s is the runtime's own: it checks the app's public address) (priority -1, stop: the same mechanism as the
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
in production), adds to them (a tenant's quota and LimitRange, backups' ObjectStore and ScheduledBackup,
production only) and refuses them, as the `violations` field and an error in `objects`: a kind no operator
serves (`#Served`, per operator version), a cluster-scoped object, another namespace, a Job outside `jobOrder`,
a Gateway for another host, an image that is neither in the registry nor pinned by digest.

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
namespace and refuses the release's. `--schema-from` (a preview's copy of a database) is not in this engine yet.

Not done yet, refused with a message: the airlock, `TRUSTED_JWKS`, previews' `--schema-from`, Studio's
`services` and tenant release (P3, P4).

### The door's Dapr API

The door (caddy) dials its own Dapr sidecar for every upstream, and Dapr answers its own API paths (`/v1.0/metadata`,
secrets, state, publish, shutdown) before it routes by `dapr-app-id`, so `https://<host>/crud/v1.0/metadata` would answer the
sidecar's JSON. The engine gives caddy a Configuration of its own, `<app>-caddy-dapr-config` (the app's plus
`api.allowed` for invocation alone, http and grpc), points the caddy Deployment's `dapr.io/config` at it, and leaves the
shared one to crud, auth and the rest, which need other APIs. After the rollouts it asks the public door for that path and
fails the release (rolling the Deployments back) when it returns `"id":"caddy"`; a host that does not answer yet is said, not failed.

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
  descriptor cache never vouches for a collected layer.
- A release whose registry maintenance fails is live: the failure is recorded in `pronto-release` (`pruned`, `prune_error`),
  and the command ends with status 3 once its tunnel is closed. A prune stops before any deletion when a registry answers
  anything but 200 or 404 for an image the cluster names.

### Backups (`restore.nu`)

`#Backups` emits the ObjectStore `<app>-backup`, the Cluster's plugin and the ScheduledBackup `<app>-nightly`
(production only, so a preview never archives into production's path). `nu node/restore.nu drill` takes a base
backup now, restores it into the namespace `restore-drill` and compares every table's rows; `restore --to
<namespace> [--target-time <ts>]` makes a recovery Cluster for a real incident.

### Tests

```
./saytw --script tools.nu cue vet -c ./node/engine/tests
for t in schema release restore contract; do ./saytw --script tools.nu nu node/engine/${t}_test.nu; done
```

The CUE cases and `schema_test.nu` need `cue` alone. The release, restore and tunnel tests run against fakes of
kubectl, sops, ssh, nc, curl, docker (compose and buildx) and crane (`fixtures/fake-kubectl`); they and the contract test render the fixture
app (`fixtures/aprende`, a copy of what an app's release.cue holds) with upstream's real schema, so they need
the CUE registry, and a pronto runtime (`PRONTO_RUNTIME`, or mise's tool the newest validated module names, 1.6.0 for v1.7.0) whose six
helpers run for real. The contract test, per upstream pin (`pronto_pin`), holds that the engine's release
data, its objects and its kubectl order equal upstream `main -e gke`'s, except the engine's declared patches
and extra steps; a new pin is validated by moving `pronto_pin` and fixing the engine before an app moves its own.
