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

A setup can instead be a **host** setup: no cluster, GitHub's own [actions/runner] on the machine
itself, each runner a launchd agent on a Mac or a systemd unit on Linux. Its jobs run on the
machine's own tools and caches, with no VM and no docker, one job at a time per runner.

[Actions Runner Controller]: https://github.com/actions/actions-runner-controller
[actions/runner]: https://github.com/actions/runner

## A setup

```cue
setups: "shop-k3s": {
	cluster: colima: profile: "arc"               // or: cluster: context: "<kubeconfig context>"
	github: {owner: "acme", kind: "user"}         // "org": a scale set without a repo serves them all
	scaleSets: "shop-arc": repo: "shop"           // runs-on: shop-arc
}
setups: "bsoneca-mac": {
	cluster: host: {}                             // this Mac: no cluster
	github: {owner: "bsoneca", kind: "user"}
	hostRunners: "pronto-mac": repo: "pronto"     // runs-on: [self-hosted, macOS, pronto-mac]
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
  `emulate` lists foreign platforms built under QEMU, on a `context` cluster only (a Colima setup
  builds amd64 in Cloud Build instead). binfmt is registered in the node's kernel by an
  init container before BuildKit starts, and the list is empty by default.
- **amd64**: where an amd64 image (Cloud Run's) builds. `cloud-build` builds it in Cloud Build
  (`gcloud builds submit`). `emulate` builds it under QEMU in the setup's BuildKit, which must list
  `linux/amd64` in `emulate`; Colima and host setups refuse it. `none` builds the setup's own platform
  only. The default is `cloud-build` for Colima and host setups, and on a cluster `emulate` when its
  BuildKit emulates amd64, else `none`. Every runner's jobs read it as `PRONTO_AMD64`: in the
  scale set's pod, the launchd agent or the systemd unit.
- **secret**: the Kubernetes secret's `name` (`gha-token`) and `kind`. A `pat` is a fine-grained token
  under the key `github_token`. An `app` is a GitHub App's id, installation id and private key. The
  values are never written in the setup. `apply` prints the command that creates the secret.
- **cluster: host**: the machine's `os` (`macos`, or `linux`) and `arch` (`arm64`, or `x64` on
  Linux), which pick the runner's tarball and what GitHub labels it with. `hostService` is
  `launchd` on macOS and `systemd` on Linux.
- **hostRunners** (a host setup's, instead of scaleSets): each runner's `repo`, its `labels` (its
  name by default; GitHub adds `self-hosted`, the OS (`macOS` or `Linux`) and the arch (`ARM64` or
  `X64`)), its folder `dir` under the home (`actions-runners/<name>`) and `work` under that
  (`_work`), the `path` its jobs run with (Homebrew's folders on a Mac only), and `nice` (10), the
  service's CPU priority, so jobs yield to the person's own work. The schema refuses a setup with
  both scale sets and host runners.
- **versions**: the ARC charts and the runner, BuildKit and binfmt images, each pinned by digest;
  the host runner's first download, by version, with a sha256 per platform (`osx-arm64`,
  `linux-x64`, `linux-arm64`); it updates itself afterwards.

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

For a host setup, `apply` downloads the runner (checked against its sha256) into its folder,
registers it, and writes and loads its launchd agent (`~/Library/LaunchAgents/actions.runner.<owner>-<repo>.<name>.plist`,
logs in `~/Library/Logs/` under the same name), each only when missing or changed. On Linux it writes
the systemd unit GitHub's `svc.sh` would (`/etc/systemd/system/actions.runner.<owner>-<repo>.<name>.service`,
run as the person who applies, `Nice=` the runner's), with `sudo -n`, then reloads, enables and
restarts it. Where sudo asks for a password, `apply` stops and says so. Registering
takes a short-lived token that `apply` fetches with `gh api` (admin on the repository) and hands to
`config.sh`, never to a file or the screen. When gh can't fetch it, `apply` prints the command for
someone who can. `status` shows the agent's state and GitHub's view of the runner (online, busy);
`remove` unloads the agent and unregisters the runner, keeping its folder.

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

A host runner's job runs on the Mac:

```yaml
jobs:
  check:
    runs-on: [self-hosted, macOS, pronto-mac]
    steps:
      - uses: actions/checkout@v4
      - run: ./saytw test
```

## On a Mac (caveats)

- **A host runner is the person's own account.** Its jobs read their home (gh's login, gcloud's,
  the keychain's), so it serves private repositories whose writers they trust, never a public one,
  where a fork's pull request would run on the Mac. A step that changes global state (`git config
  --global`, an install) changes theirs: a job keeps it in `$RUNNER_TEMP` (`GIT_CONFIG_GLOBAL`).
- **A host runner's heavy jobs claim the machine.** A stack, `integrate@local` or a rehearsal on
  a host runner runs through the repository's `tests/slot.ts` (`--weight <n> -- <command>`), so CI
  shares the stack budget with the person's own stacks and waits for a release.
- **Its agent starts at login.** A LaunchAgent runs in the person's session: after a reboot, the
  runner is back once they log in (automatic login keeps it unattended).

- **Runners are linux/arm64.** They run Linux jobs in the VM, not macOS ones. A gate that runs host
  processes on macOS (`./saytw integrate@local`) is not theirs to run. An amd64 image (Cloud Run's)
  builds in Cloud Build (`gcloud builds submit --tag`, as `billing/release.nu` does), never under
  QEMU here: a Colima setup can't `emulate`, since amd64 steps under QEMU took about 2 cores and
  10 GB on the Mac Studio and starved its release rehearsals.
- **The VM shares the Mac's cores.** Colima doesn't reserve its CPUs, but jobs use them while they
  run. bsoneca/pronto's `tests/slot.ts` budgets every core (`STACK_BUDGET`, 18 on the Mac Studio) for
  local stacks, so lower it by the VM's `cpus` (6) when runners and rehearsals run at once.
- **Runners work only while the Mac is awake and online.** Queued jobs wait until then. GitHub cancels
  a job left waiting for 24 hours.
- **Its own profile.** A Colima setup gets a profile of its own (`arc`), so the `default` VM someone
  uses for Docker is left alone. `colima delete -p arc` removes everything `apply` made.

## Tests

[`tests.cue`](tests.cue) renders a user's setup on a Mac, an organization's setup on a cluster it
reaches and a host setup, and checks the plans with `cue vet`. The apply rules' cases are suite `runners`.

```sh
./saytw --script tools.nu cue vet -c ./runners
./saytw --script tools.nu cue vet -c -t setup=bsoneca-mac ./runners/export
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- runners
```
