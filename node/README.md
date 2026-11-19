# node

The release of a pronto app onto the Contabo node's k3s: upstream pronto's manifests (the version the app
pins, bonisoft3/pronto v1.5.1 and later), patched and released by an engine that lives in this repository,
images built in Cloud Build and pulled from Artifact Registry. No kind, no second cluster.

## The node release engine

`node/engine/` is the release of an app whose `release.cue` holds `Node: node.#Release`. It runs on the
Mac (a runner, release-cron), never on the node; kubectl reaches the node's API over an ssh tunnel it opens
and closes itself (`tunnel.nu`: a free local port and a kubeconfig of each release's own, so releases running
at once share nothing; one BatchMode login, never retried, because a failed login gets the Mac banned by the
node's CrowdSec).

The app pins in its mise the tools the engine runs: `kubectl`, `docker` (compose config only), `sops` (when it
has a SOPS file), `crane` and `gcloud` (a release that builds). The preflight fails at once on a missing one,
and on a pronto runtime that is not in `validated_pins` (runtime.nu, held by contract_test.nu). An existing
namespace the release did not label (`pronto.dev/release=<app>`) is refused, `--adopt` takes it; `--delete`
never takes one.

Write it into an app, byte for byte, with:

```
<this repo>/bin/pronto-node --engine <app-dir>...
```

which writes `node/{release,render,runtime,build,tunnel,rollback,restore}.nu` and `node/schema/node.cue` into
each app and merges a `release@k8s` rule into its `.say.json` (priority -1, stop: the same mechanism as the
gcp engine, so it runs before the runtime's own `k8s` rule and stops it). `build.nu` is `gcp/engine/build.nu`
(a symlink here): one Cloud Build push, two copies to compare. To change the engine: change `node/engine/`
here, merge it, then in the app's repository move the pin to that merge and run `bin/pronto-node --engine`
on every app that holds it, in one pull request.

### What an app writes

```cue
Node: node.#Release & {
	name:    "aprende"
	preview: _preview                       // -t preview=<name>, set by the engine
	context: "contabo2"
	api: {ssh: "user@node"}                 // a tunnel of the release's own to the node's 127.0.0.1:6443
	registry: {project: "brawl-chess", location: "europe-west3"}   // repository: node-images
	hosts: production: "aprende.bsoneca.com"
	hooks: afterJobs: [["deno", "run", "node-release/restate.ts"]]
}
App: k8s.#ReleaseSpec & {name: "aprende", namespace: Node.namespace, render: enabled: false, gateway: {host: Node.host, tls: enabled: false}}
nodeManifests: (node.#Manifests & {
	app: App, release: Node
	upstream: (k8s.#BuildManifests & {release: App, env: Node.environment}).objects
}).objects
```

`node/schema/node.cue` imports nothing of upstream: the app renders upstream's objects itself and hands them to
`#Manifests`, which patches them (the Namespace's `pronto.dev/release` label, the Cluster's Barman Cloud plugin
in production), adds to them (a tenant's quota and LimitRange, backups' ObjectStore and ScheduledBackup,
production only) and refuses them, as the `violations` field and an error in `objects`: a kind no operator
serves (`#Served`, per operator version), a cluster-scoped object, another namespace, a Job outside `jobOrder`,
a Gateway for another host, an image that is neither in the registry nor pinned by digest.

### The flow (`release.nu`)

Upstream's own order (k8s/release.nu `main`), with the engine's extra steps marked: the app and the tunnel;
preflight (the operators' versions equal `#Operators`, the CRDs, GatewayClass `eg` Accepted, the backups'
Secret); build in Cloud Build (an unchanged service is not rebuilt); the release data (upstream's own helpers,
`runtime.nu`) and CUE's render; the Namespace, then a server dry run of the rest, which stops the release
on a rejection; SOPS Secrets and the OIDC Secret (extra); every object but the Deployments and Jobs; wait for
the database's primary on its image; the Jobs in `jobOrder`; `hooks.afterJobs` (extra); the database's roles
reconciled and the service token; the Deployments (crud always rolls) and their rollouts; the Dapr sidecar of
every pod; `retire` (extra); the ConfigMap `pronto-release` with `sha` (extra, what release-cron's `serving`
reads). A failure at or after the objects puts back, with `rollout undo`, only the Deployments whose revision
moved (`rollback.nu`); the database and a restated seed are not rolled back.

`--check` is the first steps with every write a server dry run and no build: an image is a placeholder digest.
Where the namespace does not exist yet, the objects are asked in `default`. `--delete` removes a preview's
namespace and refuses the release's. `--schema-from` (a preview's copy of a database) is not in this engine yet.

Not done yet, refused with a message: the airlock, `TRUSTED_JWKS`, previews' `--schema-from`, Studio's
`services` and tenant release (P3, P4).

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
kubectl, sops, ssh, nc and docker (`fixtures/fake-kubectl`); they and the contract test render the fixture
app (`fixtures/aprende`, a copy of what an app's release.cue holds) with upstream's real schema, so they need
the CUE registry, and a pronto runtime (`PRONTO_RUNTIME`, or mise's `github:bonisoft3/pronto@1.5.1`) whose six
helpers run for real. The contract test, per upstream pin (`pronto_pin`), holds that the engine's release
data, its objects and its kubectl order equal upstream `main -e gke`'s, except the engine's declared patches
and extra steps; a new pin is validated by moving `pronto_pin` and fixing the engine before an app moves its own.
