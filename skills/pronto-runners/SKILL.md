---
name: pronto-runners
description: "Give a GitHub account or organization self-hosted GitHub Actions runners on a cluster it runs: an ARC (Actions Runner Controller) runner scale set per repository or organization, in a local Colima k3s VM or an existing Kubernetes cluster, whose runners all build images through one shared BuildKit with a warm layer cache. Written as a setup in CUE and applied by one idempotent command. Use when the user wants their own GitHub runners, ARC, runner scale sets, a shared BuildKit or build cache for CI, or says someone else's runner setup should be copied for them."
---

# pronto-runners

The plugin's folder is `${CLAUDE_PLUGIN_ROOT}/runners` (its README.md is the reference). A setup is
one field of `setups` in `runners/setups.cue`. You fill it in from what you find on the person's
machine and ask them for only what you can't find. Then `runners.ts <setup> apply` applies it.

## Filling in a setup

1. **Cluster.** Run `kubectl config get-contexts` and `colima list`.
   - The person names a cluster they run (a remote k3s, a cloud cluster): use `cluster: context: "<name>"`.
     Check that `kubectl --context <name> get nodes` answers, and read the nodes' `kubernetes.io/arch`
     for each scale set's `arch`.
   - On a Mac, or when they have no cluster: use `cluster: colima: {}`. That needs `colima`, `kubectl`
     and `helm` (`brew install colima kubectl helm`). The `arc` profile is new and leaves their own VM
     alone. Size it against what else the machine runs (`cpus`, `memory`, `disk`).
2. **GitHub.** Run `gh api users/<owner> --jq .type`. `User` means `kind: "user"`, and each scale set
   names one `repo`. `Organization` means `kind: "org"`, and a scale set may leave out `repo` to serve
   every repository.
3. **Scale sets.** Name each one for what `runs-on` will say (`<repo>-arc` by convention). `max` is
   bounded by what the cluster can run at once.
4. **BuildKit.** On a Colima setup, `emulate` stays empty (the schema refuses it): amd64 images,
   Cloud Run's, build in Cloud Build (`gcloud builds submit --tag`), since QEMU on a Mac takes cores
   the machine's own work needs. On a `context` cluster, `emulate: ["linux/amd64"]` is allowed if
   they must build amd64 on arm64 nodes and accept QEMU's slowness.
5. **Secret.** Ask whether they want a fine-grained token (`pat`, the default) or a GitHub App (`app`).
   Never ask for the token's value, never write it anywhere, and never create the secret yourself.
   `apply` prints the command, and the person runs it.

Then check the setup and apply it:

```sh
./saytw --script tools.nu cue vet -c ./runners
deno run -A runners/runners.ts <setup> apply
```

The first `apply` stops at the missing secret. Pass on the command it prints, wait for the person to
say the secret exists, and apply again.

## Checking it

- `runners.ts <setup> status` shows the controller, BuildKit and a listener pod per scale set running.
- Under the repository's Settings → Actions → Runners, the scale set appears by name.
- Push a branch with a workflow on `runs-on: <scale set>` that runs
  `docker buildx create --driver remote "$BUILDKIT_HOST" --use` and then builds an image twice. The
  second build reports its steps `CACHED`. Delete the branch afterwards.

## Tell them

- The runners are Linux pods (arm64 on a Mac). They can't run macOS-only steps.
- On a Mac, the runners work only while it is awake, and their jobs share its cores.
- `remove` takes the scale sets away, and `colima delete -p arc` removes the whole VM.
