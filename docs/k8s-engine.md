# k8s engine: leaving pronto-fork for apps that release to Kubernetes (PRONTO-742)

Design, 2026-11-18. Read-only analysis. Sources: pronto-plugins `docs/forks-exit.md` (rows 36-48), `gcp/engine/`,
`bin/pronto-gcp`; pronto-fork `k8s/` at `live` and `v1.5.1`; pronto `origin/main` (`apps/*/release.cue`,
`release_cron.cue`, `cd.cue`, `.github/harness.sh`, `.github/gcp-engine.pin`, `apps/studio/tests/k8s/`).
Line numbers: `live:` / `v1.5.1:` are `git show <tag>:k8s/release.nu`.

## Decision summary

- **Upstream hook (one proposal, four small parts):** a cluster the app declares (generalised `GKE`), an open
  `#Environment.name`, a `--data` overlay on `main`, and **release steps**: argv commands a cluster lists per
  named phase that `k8s/release.nu` runs at eight fixed points (Helm hooks plus `--post-renderer`).
- **Engine:** `pronto-plugins/k8s/engine/`, written into each app as `k8s/*.nu` + `k8s/schema/k8s.cue` by
  `bin/pronto-k8s --engine`, pinned by `.github/k8s-engine.pin`, checked by a third block of `.github/harness.sh`.
  It holds the metal environment, SOPS/age secrets, node registry, buildkit, tenant/preview releases, node
  database operations and seed-fill. It carries **no** B row (the generic ones go upstream as proposals 3-7).
- **Fallback if upstream refuses the steps:** the engine's `flow.nu` runs the release itself, calling upstream's
  exported functions as a library (subprocess `nu -c "use $PRONTO_RUNTIME/k8s/release.nu [..]"`), with a
  parity test against upstream `main --dry-run`.
- **First app:** solitaire. Last: Brawl Chess.

## 1. Who releases to k8s today

All through the fork's `k8s/release.nu`, run by the runtime's say rule `release@k8s`
(`live:distribution/config.cue:233` `nu ($pronto | path join k8s release.nu)`), env `metal` (`envs.Metal`),
manifests from the app's `metalManifests: (schema.#BuildManifests & {release: App, env: Metal}).manifests`.

| App | Pin (`.mise.toml`) | Node / access | build | Extra fields in use | Driven by |
|---|---|---|---|---|---|
| brawl-chess | 1.1.4-gcp.65.2 | `_node`, its tunnel | node | services, scale, electric, blobs, metricsExport, containerResources, database (backups), render, auth, previewOrigin | release-cron (`release_cron.cue`, `cd.cue`), rc preview + kill rehearsal |
| studio | 1.1.4-gcp.64.5 | `_node`, tunnel `spec.games.node.tunnel` | node | services, containerResources, database (backups), doors, auth, previewOrigin | release-cron (`release_cron.cue`, `cd.cue`), rehearsal `integrate@k8s`, rc = `--preview rc` |
| studio games (Publish) | Studio's builder | in-cluster, publisher token | `--buildkit` sandboxed | `--tenant`, `--host`, `--push-kubeconfig` | Studio's builder (`builder/node.ts`), proved by `apps/studio/tests/k8s/integrate.ts` |
| reclaim-clone | 1.1.4-gcp.44 | the node over SSH | node | services, auth; `secrets.metal.enc.yaml` | release-cron (ssh to `a checkout on the node`) |
| solitaire | 1.1.4-gcp.44 | the node over SSH | node | none beyond Metal | by hand |
| prontoweeper | 1.1.4-gcp.44 | the node over SSH (node 1) | docker (default) | render | by hand |

Note: the fork's `live:k8s/release.nu:13` does `use ../gcp/build.nu [push-images service-jwt]`: the fork's k8s
path depends on the fork's `gcp/`. The engine must not.

## 2. The split of the fork's `k8s/`

`git diff v1.5.1 live -- k8s`: +5839/-1923 over 20 files. `live` is v1.4.1-based, so part of the diff is
upstream's newer work that `live` lacks (v1.5.1's airlock wall: `airlock-services`, `verify-wall`,
`wall-probes`, `v1.5.1:319-930`). Upstream wins there.

### (a) Upstream already at v1.5.1 (drop; use upstream's)

`release.nu`: `get-operator-cache-dir`, `fetch-verified`, `ensure-cluster`, `ensure-operators` (base),
`ensure-envoy-gateway-class` (hostPort), `ensure-observability`, `apply-sops-secrets` (kind sandbox file),
`resolve-app`, `ensure-tls-secret`, `run-job`, `render-manifests` (already has `--data`, `v1.5.1:414`),
`read-environment` (kind/eks/aks), `release-tree`, `bake-images`, `auth-provider-environment`,
`auth-provider-secret`, `runtime-services`, roles reconcile, trusted keys, bare-sidecar check, the airlock
(upstream's v1.5.1 version replaces `live`'s `airlock-*` at `live:1329-1466`; **verify** each app with an
airlock against it). Schema: `#Environment` core fields, `#ReleaseSpec` core, `#GKE`, `envs/kind|eks|aks.cue`.

### (b) Generic: owner's upstream proposals (forks-exit "pronto: the way out", proposals 3-7, rows 36-43, 47)

| Fork code (`live`) | Row | Proposal |
|---|---|---|
| `app-services-environment`, `ensure-service-jwt`, `release-plan`, `release-runtime`, `compose-config`/`compose-raw`, `crud-schemas`, `schema-facts`; schema `services`, `runtime`, `crud.schemas`; k8s.cue services/clock/jail/ConfigMap files/exporter port | 40 | 3 |
| `operators-for`, `controller-replicas`, `dapr-ha-now`, `install-operator`, `drop-args`, `set-cpu`, `immutable-statefulsets`; `rollout-sample/-floors/-breaches/-verdict`, `deployments-now`, `watch-rollout`, `kube-items`; `retire-electric-slot`, `drop-retired-electric-slot`; schema `replicas`, `scale`, `electric.pool`, `dapr.ha`, `controllers`; PDBs, spread | 37, 42 | 4 |
| `check-backup-secrets`; schema `database.backups`, `database.smartShutdown`, `containerResources.postgres`; the stopDelay-aware primary wait (`live:2122-2126`) | 36, 38, 46 (part) | 5 |
| `apply-alert-rules`; `alerting`; vmalert, per-pod scrape | 39 | 6 |
| Dapr 1.16.21, no mesh-call timeout | 41 | 7 |
| render restart after the door rolls (`live:2203-2209`), startupProbe, `/ready` | 43 | verify vs upstream #2432; omnishell proposal 2 |
| initdb replay of 010_machines + app migrations on k8s | 47 | with #10 or a k8s sibling |
| `default-environment`, `defines`, `read-environment <env> <cue_path>` (cluster declared in release.cue) | 44 (part) | **the hook, below** |

`cloud-build-images` (`build.by: "cloudbuild"`): no app uses it (all `node`; prontoweeper `docker`). Drop.
`metricsExport` (Managed Prometheus) is GCP-flavoured (row 39 note): it stays in the fork until the owner
decides B or C; it only blocks Brawl Chess.

### (c) Ours: the k8s engine (rows 44, 45, 46, 48 seed-fill)

| Module (engine) | From `live:k8s/release.nu` | Row |
|---|---|---|
| `metal.nu` | `tunnel-proxy-kubernetes`, `spread-over-nodes`, `envoy-proxy`, `tunnel-manifests`, `open-api-tunnel`, `close-api-tunnel`, `ensure-tunnel`, cloudflared pin (`:16`), the kubeconfig-to-tunnel rewrite (`:1957-1964`), the "route dns" hint (`:2224`) | 44 |
| `registry.nu` | `node-registry-manifests`, `-in-use`, `-keep-tag`, `prune-node-registry`, `ensure-node-registry`, `forward-node-registry`, `node-registry-tag`, `node-registry-pg-major`, `registry-pg-major`, `port-forward`, `stop-port-forward`, registry pin (`:21`) | 44 |
| `images.nu` | `node-buildkit-manifests`, `ensure-node-buildkit`, `buildkit-images`, docker build+push through the tunnel (`:2033-2053`), `tenant-images`, `tenant-repo`, `tenant-bake-allows`, `crane-platform`, `crane-bin`, `crane-pinned` | 44, 45 |
| `database.nu` | `database-base`, `database-base-copy` (primary on the base image, PRONTO-537), `switchover` settings (`primaryUpdateMethod: switchover`, `stopDelay`), CNPG controller sizing | 46 |
| `secrets.nu` | `sops-platform`, `sops-bin` (pinned v3.13.3), `sops-age-key` (SOPS_AGE_KEY, Keychain `pronto-sops-age`, `pronto-sops/age-key`), `apply-environment-secrets` (`secrets.<env>.enc.yaml`, field manager `pronto-sops`) | 44 |
| `tenant.nu` | `tenant-manifests`, `tenant-refusals`, `airlock-refusals`, `can-i` check (`:1987`), server dry-run (`:2109-2112`) | 45 |
| `preview.nu` | `--preview`, `--delete` (`:1966-1973`), `--schema-from`: `schema-copy-steps`, `db-primary`, `copy-schema` | 45 |
| `flags.nu` | `seed-configmaps`, `seed-fill`, `seed-off` (PRONTO-464: a release never turns a flag on) | 48 |
| `schema/k8s.cue` | `envs/metal.cue`; `#Environment.access/build/ingress`; `#ReleaseSpec.preview/id/tenant/tenantHost/ns/previewOrigin/previewReplicas` | 44, 45 |

Row 48's `PRONTO_IMAGE_REGISTRY` goes to the plugins' pins and `INTEGRATE_LOCAL_SECRETS=skip` to the harness
(not the engine).

## 3. The upstream hook

One upstream PR, "k8s: clusters an app declares, with release steps", against v1.5.x. About 120 lines in
`k8s/release.nu` and 25 in `k8s/schema/release.cue`, with tests in `k8s/release_test.nu`. No bsoneca name in it.

### H1. Open environment name (schema)

`v1.5.1:k8s/schema/release.cue:5` `name: "kind" | "eks" | "aks" | "gke"` becomes
`name: =~"^[a-z][a-z0-9-]*$"`. Without this, no plugin can define an environment: the definition is closed and
embedding cannot widen a disjunction.

### H2. A cluster the app declares (generalises `GKE`)

```cue
#Cluster: {
	context?:    string & !=""          // kube context; absent: the steps' `connect` gives KUBECONFIG
	environment: #Environment
	steps:       #Steps | *{}
}
#GKE: #Cluster & {context: string & !=""}   // unchanged meaning
// release.cue: Clusters: [Name=string]: #Cluster & {environment: name: Name}
```

`main --cluster-env X`: if `release.cue` defines `Clusters.X`, read it (as the `GKE` branch does at
`v1.5.1:980-985`). Else fall back to `envs/` (kind/eks/aks). `render-manifests` keeps reading `XManifests`,
which apps already define (`metalManifests`).

### H3. A per-run overlay

`main --data <file.json>`: unified into **every** `cue export` of `release.cue` that `main` runs: the metadata
read (`v1.5.1:960`), `Clusters.X`, both `render-manifests` calls (merge it with the pushed-images file that
`v1.5.1:1078-1080` already writes). This is how a preview or tenant name reaches the release without any
upstream field for them.

### H4. Release steps

```cue
#Phase: "connect" | "prepare" | "images" | "postRender" | "beforeApply" | "databaseReady" | "beforeRollout" | "released" | "finally"
#Steps: [#Phase]: [...[...string]]   // argv lists, run in order, cwd = the app dir
```

For each step, `release.nu` writes a context file and runs the argv with `PRONTO_RELEASE_CONTEXT=<file>`.
The context file holds `{app, appDir, cuePath, clusterEnv, namespace, name, gatewayHost, environment, imageTag,
platform, registry, build: [services], manifests?: <path>, pushed?: <path>}`. stdout is JSON, except for
`postRender`. A non-zero exit fails the release. Call points in `v1.5.1:main`, and what is read back:

| Phase | Where in `main` | Reads back |
|---|---|---|
| `connect` | replaces the context/KUBECONFIG block (`:980-1000`), before any kubectl | `{env: {KUBECONFIG?, ...}}`, which is `load-env`'d; optional `{namespace: {create: false}}` (skip `:1013` for a namespace the caller does not own) |
| `prepare` | after operators/observability, before the namespace | nothing (side effects) |
| `images` | replaces bake+tag+push (`:1028-1048`) when listed | `{pushed: {<svc>: {tag, digest}, ...}}`, merged into `App.image.pushed` |
| `postRender` | after the second `render-manifests` (`:1080`) | stdin: manifests YAML. stdout: manifests YAML (Helm's `--post-renderer`) |
| `beforeApply` | after the namespace and secrets, before `kubectl apply` (`:1113`) | nothing |
| `databaseReady` | after the primary wait, before the Jobs (`:1130`) | nothing |
| `beforeRollout` | after roles reconcile and service token, before Deployments | nothing |
| `released` | after the sidecar check, before SUCCESS | nothing |
| `finally` | always (try/finally around everything after `connect`) | nothing |

The refusal at `v1.5.1:953` (`not-in ["kind" "gke"]`) becomes: refuse unless kind, gke, or a declared
cluster.

**Why it is generic (for the PR text):** bare-metal and edge clusters reached through a bastion or tunnel
(`connect`/`finally`); CI without a Docker daemon (kaniko, buildkit, a registry inside the cluster: `images`);
policy patches and admission fixes that every Helm user does with a post-renderer (`postRender`); external
secret stores (sops, Vault: `beforeApply`); data copies and seeds (`databaseReady`, `beforeRollout`); cleanup
and notifications (`released`). It adds no field upstream must understand beyond argv lists, and it changes
nothing when no step is listed (the kind/gke tests stay green).

**Evidence for the PR (the owner's rule: measured gains):** `release_test.nu` cases with a fake kubectl that
records the call order: no steps gives exactly v1.5.1's sequence; each phase is called once, at its point;
`finally` runs after a failure; `postRender` output is what gets applied. Plus one kind e2e with
`connect`+`images` steps backed by an in-cluster registry.

### Fallback if upstream refuses

- **Refuses H4 only (accepts H1-H3):** the engine's `k8s/flow.nu` runs the release itself. It calls
  upstream's exported functions through `runtime.nu`'s `upstream <fn> <json-args>` (a subprocess
  `nu -c "use $PRONTO_RUNTIME/k8s/release.nu [<fn>]; ..."`, as `apps/studio/tests/k8s/integrate.ts:253` already
  does) for `render-manifests`, `run-job`, `ensure-operators`, `runtime-services`, `auth-provider-*`. Our code
  then holds about 300 lines of `main`'s ordering. **Guard:** `k8s/flow_test.nu` compares flow.nu's call
  order (fake kubectl) with upstream `main` on kind at every pin move, and `--dry-run` manifests must be
  byte-equal to upstream `main --dry-run --data` for the same overlay.
- **Refuses everything:** same flow.nu, plus the engine schema must not import upstream's closed
  `#Environment` for metal. `schema/k8s.cue` then defines `#Metal` by composition: `Metal: {access, build,
  ingress, environment: k8s.#Environment & {name: "kind", ...}}`. The `"kind"` name is a stand-in and must be
  named in the engine README.
- Either way, `flow.nu` is reachable only when the runtime lacks steps. `release.nu` dispatches on
  `nu $PRONTO_RUNTIME/k8s/release.nu --help` listing `--data`, so the fallback deletes itself the day the hook
  lands.

## 4. Engine layout (mirrors `gcp/engine`)

pronto-plugins:

```
k8s/README.md                 # "The release engine" section, as gcp/README.md
k8s/engine/
  release.nu       # entry: release@k8s. Flags as live main + --preview/--delete/--schema-from/--tenant/--host/
                   #   --images/--buildkit/--push-kubeconfig. Builds the --data overlay {Engine: {...}},
                   #   handles --delete itself, then runs upstream main (steps) or flow.nu
  steps.nu         # `nu k8s/steps.nu <phase>`: reads PRONTO_RELEASE_CONTEXT and dispatches to the modules below
  metal.nu registry.nu images.nu database.nu secrets.nu tenant.nu preview.nu flags.nu   # section 2(c)
  postrender.nu    # database-base imageName, switchover settings, previewReplicas, tenant strip (tenant-manifests)
  runtime.nu       # PRONTO_RUNTIME dir, resolve-app, `upstream <fn>` (as gcp/engine/runtime.nu)
  flow.nu          # fallback only (section 3)
  schema/k8s.cue   # #Metal, #Engine, metal steps wiring
  host.cue export/export.cue   # files written into an app + the .say.json rule
  *_test.nu        # fakes of kubectl, ssh, crane, sops, docker, as gcp/engine's
bin/pronto-k8s --engine <app-dir>...   # cue export ./k8s/engine/export -e files | bin/write.nu
```

In an app, written byte for byte: `k8s/{release,steps,metal,registry,images,database,secrets,tenant,preview,
flags,postrender,runtime,flow}.nu`, `k8s/schema/k8s.cue`, and a merged `.say.json` rule (no app has a `k8s/` dir
today; only `gcp/`):

```json
{"say": {"release": {"rulemap": {"k8s-engine": {"platform": "k8s", "priority": -1, "stop": true,
  "cmds": [{"do": "use tools.nu [run-mise]; $env.PRONTO_RUNTIME = (run-mise where github:bonisoft3/pronto | str trim); run-mise exec -- nu k8s/release.nu"}]}}}}}
```

This mirrors `gcp/engine/host.cue:42-48`. Release-cron's commands (`./saytw release@k8s`,
`--preview rc`) do not change.

App CUE (`release.cue`), through the engine schema. The schema composes and never embeds a closed
definition, so upstream's `#BuildManifests` only ever sees upstream shapes:

```cue
import (k8s "github.com/bonisoft3/pronto/k8s/schema"; engine "<app module>/k8s/schema")
Engine: engine.#Engine & {app: "studio"}            // preview, tenant, tenantHost come from --data
App: k8s.#ReleaseSpec & Engine.spec & { ... }        // spec: {name: Engine.id, namespace: Engine.ns,
                                                     //   if tenantHost != "" {gateway: host: tenantHost}}
Clusters: metal: engine.#Metal & {context: "<node>", access: ssh: _node, build: by: "node", ingress: id: "…", domainSuffix: "…"}
metalManifests: (k8s.#BuildManifests & {release: App, env: Clusters.metal.environment}).manifests
```

`engine.#Metal` sets `steps` to `[["nu","k8s/steps.nu","<phase>"]]` for every phase. `previewOrigin` and
`previewReplicas` live in `Engine` and are applied by `postrender.nu`.

Where each concern lives:

- **SOPS/age:** `secrets.nu` at `beforeApply`. It applies `secrets.metal.enc.yaml` server-side as `pronto-sops`
  (same field manager, so no conflict with what the fork applied). Key order: `SOPS_AGE_KEY` → Keychain
  `pronto-sops-age` → `pronto-sops/age-key`.
- **Metal env:** `metal.nu` at `connect` (SSH tunnel to the API server, KUBECONFIG rewrite, returned as `env`)
  and `finally` (close it). `prepare` runs `ensure-tunnel` (cloudflared), `ensure-node-registry`,
  `ensure-node-buildkit`. `images` builds with Docker and pushes through the tunnel (`node`), or with buildkit;
  it adds `database-base`. `released` prunes the node registry.
- **Tenant/preview:** `release.nu` turns flags into the overlay `{Engine: {preview|tenant|tenantHost}}` passed
  with `--data`. So the name, namespace and host flow through upstream's own `App.name`/`App.namespace`,
  and preview names stay `studio-rc`, `studio-rc-db` as today. `connect` returns
  `namespace.create: false` and skips the tunnel for a tenant. `images` handles `--images`/`--buildkit`.
  `beforeApply` runs can-i and a server dry-run. `postRender` strips Namespace objects. `databaseReady` runs
  `--schema-from`. `--delete` never reaches upstream.
- **Node DB ops:** `postrender.nu` sets the CNPG `imageName` to the `database-base` copy and sets
  `primaryUpdateMethod: switchover`. CNPG controller sizing sits in `prepare` (operators patch). When
  proposal 5 lands, `smartShutdown`/`stopDelay`/`containerResources.postgres` leave the engine.
- **Seed-fill:** `flags.nu` at `beforeRollout` (`seed-configmaps` with `seed-fill`/`seed-off`). Until
  proposal 3 gives upstream `services.files`, an app needing ConfigMap files waits (see section 5).

pronto side:

- `.github/k8s-engine.pin`: a pronto-plugins commit.
- `.github/harness.sh`: a third block, a copy of the gcp one (`fetch .github/k8s-engine.pin k8s/engine`). It
  compares `k8s/engine/*.nu` (not `*_test.nu`) and `schema/k8s.cue` with each `apps/*/k8s/`. "An app that holds
  the engine holds all of it" lists the 13 modules + schema.
- AGENTS.md: the harness/engine sentence gains "and the k8s engine (`k8s/engine`, `bin/pronto-k8s --engine`,
  `.github/k8s-engine.pin`)".

## 5. Migration order

An app moves when (i) every row it uses is upstream at its new pin or in an engine, and (ii) its non-k8s rows
are clear (PRONTO-748's per-app check). Each flip is one PR: engine files + `.say.json` rule + `release.cue`
imports + `.mise.toml` pin to upstream (+ CUE_REGISTRY without the bsoneca module mirror for pronto).

0. **Engine in pronto-plugins** (no app touched). Proof: `k8s/engine/*_test.nu` on fakes. The **parity
   harness** `k8s/engine/parity.nu <app>`: renders `--dry-run` with the fork (`live`) and with
   upstream+engine; it normalises digests and prints the diff. Every diff line is either "row N, proposal M"
   or a bug. That list is each app's blocking set.
1. **Studio's `integrate@k8s` gains the engine lane** (one pronto PR, gated by `integrate@k8s` because the
   publish path changes). `apps/studio/tests/k8s/integrate.ts` imports engine functions from
   `apps/studio/k8s/*.nu`, not from `${pronto}/k8s/release.nu` (lines 245-253, 331, 496, 504). On kind it
   proves `images` (buildkit + in-cluster registry), `postRender` (database-base), SOPS with a throwaway age
   key, `--preview`/`--delete`/`--schema-from`, tenant with `--buildkit`/`--push-kubeconfig`, and seed-fill.
   Not proved on kind: the SSH tunnel and cloudflared. Those are proved at step 2 on the node.
2. **solitaire first.** It sits on the same node and the same `build: node` path as Studio and Bonk, has no
   services, no SOPS file, no cron, no cd, and is released by hand. Proof: parity diff empty except accounted
   rows, then `release@k8s --preview=engine` on the node, check, `--delete`, then `release@k8s`, then
   `./saytw verify@k8s` (runtime `verifyK8s`).
3. **prontoweeper.** It is on node 1 (the node over SSH); CrowdSec bans failed SSH. Run it as the operator via
   node 2, as the memory says. It is also the forks-exit "first candidate" for the whole pin. Default `docker`
   build: this is the path that proves `images` with Docker through the tunnel.
4. **reclaim-clone** (first release-cron app; `secrets.metal.enc.yaml`; `services`). Needs proposal 3 upstream
   for `services`. Its flip merges, and its next release-cron run (rehearsal `verify@local`, then
   `release@k8s` over ssh) is the proof. A failure stops that run; production stays on the last release; fix
   forward.
5. **Studio.** Needs proposals 3, 5 (backups, containerResources), omnishell proposal 2 (`/ready`), the door
   (proposal 1). The flip PR's gate runs `integrate@k8s` with the engine (step 1). Studio's builder must write
   the engine's `k8s/schema` and `Clusters.metal` into each game at Publish. That replaces today's
   `withoutMetal` + node Metal, and repairs a game's old `github.com/bonisoft3/pronto/k8s/envs` import as
   `ensureServerSide`'s repair does. `integrate@k8s`'s republish onto the previous namespace
   (`tests/k8s/previous.txt`) is the proof that old games still publish. Release-cron then runs the rc
   (`--preview rc` into `studio-rc`, through the engine) before the release. A broken engine fails at rc, not
   in production.
6. **Brawl Chess last.** It needs proposals 3-7, an owner call on `metricsExport` (B or engine), and its `gcp/`
   path off the fork (forks-exit: "moves last"). Its rc preview and kill rehearsal run on the engine at the
   first run after the flip.

**No release-cron outage:** nothing runs `release@k8s` for Studio or Bonk by hand. The flip is a merge;
release-cron's own rc step is the first live execution, and its failure leaves production untouched (the run
fails before the release step). Before each of these two flips, the PR shows the parity diff and an
`integrate@k8s` pass. **Owner decision needed:** may a session run a hand `--preview=engine` (not `rc`) on the
node from the PR checkout as a shadow before the flip? AGENTS.md forbids only `--preview=rc`, but a Bonk
preview is a whole stack on a loaded node. Without that yes, the shadow is release-cron's rc itself.

## 6. Risks and how to check each

| # | Risk | Check |
|---|---|---|
| 1 | Upstream refuses H4: `flow.nu` becomes a second `main` that drifts (a fork by another name) | `flow_test.nu` call-order diff vs upstream `main` on kind, and `--dry-run` byte equality, run at every `.mise.toml` pin move (`guard` in `test`) |
| 2 | B rows not upstream block Studio and Bonk: `k8s.cue` +1590 lines (row 40), HA (37), backups (38). The engine could patch them in `postRender` and quietly become the fork | Parity diff per app (step 0) is the blocking list. `postrender.nu` refuses any patch not on an allowlist of C rows; adding to it needs the owner's word |
| 3 | The CNPG primary is recreated at the flip (image or `imageName` digest differs from the fork's: PRONTO-537), or a preview gets another name (`studio-rc-db` vs new) and a second database | Parity diff must show `Cluster.spec.imageName`, `metadata.name` and `namespace` unchanged for every app; `release_test` asserts preview/tenant names equal `live`'s `id`/`ns` |
| 4 | Studio games: old games import the fork's `envs.Metal`, and the builder runs the fork's release.nu as a library (`integrate.ts:245-504`). A Studio on upstream breaks Publish | `integrate@k8s` publishes the test game and replays the owner's game onto the previous namespace with the engine, before the Studio flip merges |
| 5 | v1.5.1's airlock/wall differs from `live`'s (`live:1329-1466` vs `v1.5.1:319-930`), so an app with effects behaves differently on the node (NetworkPolicy plugin on k3s, `policiesLate`) | `grep airlock` per app's release.cue/compose. For any app that has one, run the wall verdict in `integrate@k8s`; set `policiesLate` in `#Metal` from a measured probe on k3s |
| 6 | Secrets: a changed file name, field manager or key source makes the first engine release refuse (backup or airlock secret checks) or conflict | `kubectl apply --server-side --dry-run=server --field-manager=pronto-sops` from `secrets.nu` against the node in the parity step; same `secrets.<env>.enc.yaml` name |
| 7 | CUE closedness: an engine type passed into upstream's `#BuildManifests`/`#ReleaseSpec` fails `cue vet` | Composition only (section 4); `cue vet` of every k8s app's release.cue in `k8s/engine/export` tests against the pinned upstream module |
| 8 | Node access during proofs: CrowdSec bans the Mac on node 1, which breaks release-cron | prontoweeper only via node 2 as the operator; never the app user directly from the Mac |
