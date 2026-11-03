# runners

GitHub Actions runners on a cluster you run: GitHub's [Actions Runner Controller] with one runner
scale set per repository (or per organization), whose runners all build through one shared BuildKit.
Each job gets a fresh runner pod and the pod goes away afterwards. BuildKit stays, so its layer cache
is warm for the next job, and runners need no Docker daemon and no privileges of their own.

A setup is data: one field of `setups` in [`setups.cue`](setups.cue), held to `#Setup`
([`schema.cue`](schema.cue)). [`host.cue`](host.cue) renders it into a plan: the controller's
chart, BuildKit's Namespace, ConfigMap, PersistentVolumeClaim, Deployment and Service, and each scale
set's chart values. [`runners.ts`](runners.ts) applies the plan as it is, so nothing it applies is
written by hand. What an apply does, given what it finds, is [`plan.js`](plan.js)'s, held by the
cases in [`tests/unit/runners.cue`](../tests/unit/runners.cue).

[Actions Runner Controller]: https://github.com/actions/actions-runner-controller

## A setup

```cue
setups: "bsoneca-mac": {
	cluster: colima: profile: "arc"               // or: cluster: context: "<kubeconfig context>"
	github: {owner: "bsoneca", kind: "user"}      // "org": a scale set without a repo serves them all
	scaleSets: "pronto-arc": repo: "pronto"       // runs-on: pronto-arc
}
```

The rest have defaults:

- **cluster**: either `colima` (a k3s VM of its own, 6 CPUs, 12 GiB of memory and a 100 GiB disk by
  default), or `context`, a cluster your kubeconfig already reaches. `apply` starts nothing for a
  context.
- **github**: for a **user** account, every scale set names one `repo`. GitHub registers a personal
  account's runners per repository, never for the whole account. For an **org**, a scale set without
  a repo serves all of the organization's repositories.
- **scaleSets**: each one's `min` (0) and `max` (3) runner pods, and its `arch` (`arm64`, the
  `kubernetes.io/arch` its pods land on).
- **buildkit**: the `cache` volume (60 GiB) and what BuildKit prunes it down to, `keep` (40 GiB).
  `emulate` lists foreign platforms built under QEMU. binfmt is registered in the node's kernel by an
  init container before BuildKit starts, and the list is empty by default.
- **secret**: the Kubernetes secret's `name` (`gha-token`) and `kind`. A `pat` is a fine-grained token
  under the key `github_token`. An `app` is a GitHub App's id, installation id and private key. The
  values are never written in the setup. `apply` prints the command that creates the secret.
- **versions**: the ARC charts and the runner, BuildKit and binfmt images, each pinned by digest.

## Use

From this repository's root:

```sh
deno run -A runners/runners.ts bsoneca-mac apply    # VM, controller, BuildKit, then the scale sets
deno run -A runners/runners.ts bsoneca-mac status   # releases and pods
deno run -A runners/runners.ts bsoneca-mac remove   # the scale sets (the VM, controller and BuildKit stay)
```

`apply` can be run again at any time and changes only what differs. Every step is a
`helm upgrade --install` or a `kubectl apply`. A scale set the setup no longer names is uninstalled.
On its first run, `apply` stops after BuildKit because the secret is missing, and prints what to
create. Starting Colima makes its VM the current kubectl and docker context, so `apply` switches both
back afterwards. Every kubectl and helm call names the plan's context and never uses the current one.

## In a workflow

```yaml
jobs:
  image:
    runs-on: pronto-arc
    steps:
      - uses: actions/checkout@v4
      - run: docker buildx create --name shared --driver remote "$BUILDKIT_HOST" --use
      - run: docker buildx build --platform linux/arm64 -t app:ci .
```

Each runner pod has `$BUILDKIT_HOST`, the address of the shared BuildKit
(`tcp://buildkitd.buildkit.svc.cluster.local:1234`). `docker/setup-buildx-action` works too, with
`driver: remote` and `endpoint` set to that address. To get the image out of BuildKit, push it
(`--push`) or export it (`--output`). No local daemon holds it.

## On a Mac (caveats)

- **Runners are linux/arm64.** They run Linux jobs in the VM, not macOS ones. A gate that runs host
  processes on macOS (`./saytw integrate@local`) is not theirs to run. An amd64 image needs
  `buildkit: emulate: ["linux/amd64"]` (bsoneca-mac has it) and `--platform linux/amd64`. Its `RUN`
  steps run under QEMU, several times slower than native, so a Dockerfile that cross-compiles
  (`FROM --platform=$BUILDPLATFORM`) is faster when the toolchain allows it.
- **The VM shares the Mac's cores.** Colima doesn't reserve its CPUs, but jobs use them while they
  run. bsoneca/pronto's `tests/slot.ts` budgets every core (`STACK_BUDGET`, 18 on the Mac Studio) for
  local stacks, so lower it by the VM's `cpus` (6) when runners and rehearsals run at once.
- **Runners work only while the Mac is awake and online.** Queued jobs wait until then. GitHub cancels
  a job left waiting for 24 hours.
- **Its own profile.** A Colima setup gets a profile of its own (`arc`), so the `default` VM someone
  uses for Docker is left alone. `colima delete -p arc` removes everything `apply` made.

## Tests

[`tests.cue`](tests.cue) renders a user's setup on a Mac and an organization's setup on a cluster it
reaches, and checks the plans with `cue vet`. The apply rules' cases are suite `runners`.

```sh
./saytw --script tools.nu cue vet -c ./runners
./saytw --script tools.nu cue vet -c -t setup=bsoneca-mac ./runners/export
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- runners
```
