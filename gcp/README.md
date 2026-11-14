# gcp

Releases a pronto app's door to Google Cloud Run.

## What it adds

- `sayt release@gcp`: builds the door image for Cloud Run's linux/amd64, checks it answers on :8080, runs sayt's version ceremony, pushes it to Artifact Registry and moves the service to it by digest, scaling to zero and public.
- Plain `sayt release`: deploys the same image to `<service>-preview`, with no version.
- Files in the app: `.say.json` (rules `gcp` and `gcp-preview`), `.config/mise/conf.d/gcp.toml`, `gcp/gcp.nu`, and `.goreleaser.yaml` (written once).

Only for an app whose rows the browser keeps. An app with server rows or auth is refused: it needs services beside the door that this host does not build yet.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-gcp . <gcp-project-id> [region=us-central1] [service=…] [repository=pronto] [origin=https://…] [maxScale=3] [memory=512Mi]
./saytw --script tools.nu mise trust .config/mise/conf.d/gcp.toml
./saytw --script tools.nu mise lock
./saytw release        # the preview service
./saytw release@gcp    # a version
```

Or in a sentence, through the [`pronto-intents` skill](../skills/pronto-intents/SKILL.md): `bin/pronto deploy gcp <app>` ([`deploy.ts`](deploy.ts)), which also covers apps with a server database. The [`pronto-gcp` skill](../skills/pronto-gcp/SKILL.md) covers releasing and its limits. `bin/pronto-gcp` exports [`host.cue`](host.cue)'s files (see [`export/`](export)). Config: the Google Cloud project id; `gcloud auth login` in a terminal of your own.

## The release engine

`gcp/engine/` is the release of an app whose `release.cue` holds `GCP: schema.#Release`: Cloud Run beside Cloud SQL, its sidecars and jobs, previews, the rc preview gate, the local gate's ledger (`local-gate-key.nu`) and the record of every run (`release-record.nu`). It was the pronto fork's `gcp/`, at `v1.1.4-gcp.44`; the app now holds it, so its release no longer needs a runtime that carries it (PRONTO-494).

```sh
<this repo>/bin/pronto-gcp --engine <app-dir>...
```

writes, byte for byte as `gcp/engine/` holds them, `gcp/{release,build,verify,secrets,local-gate-key,release-record,runtime}.nu` and `gcp/schema/gcp.cue` into each app, and merges two rules into its `.say.json`: `release@gcp` and `verify@gcp` run the app's `gcp/release.nu` and `gcp/verify.nu`. sayt unifies `.say.json` with the runtime's `.say.yaml`, so these rules cannot replace the runtime's own `gcp` rule; they run before it and stop it (`priority: -1, stop: true`), as an app's `launch@local` does. The app imports the schema as its own package (`import "<its module>/gcp/schema"`); the schema still reads the runtime's `resilience` bounds.

`runtime.nu` is all the engine takes from the runtime the app pins: its directory (`PRONTO_RUNTIME`, which the rule sets from `mise where github:bonisoft3/pronto`), for the runtime's version in the release record and the local gate's files in its key, and `resolve-app`, as upstream pronto's `k8s/release.nu` has it. A release.cue with `GKE` is handed to the runtime's `k8s/release.nu`.

To change the engine: change `gcp/engine/` here and merge it, then in the app's repository move the pin to that merge and run `bin/pronto-gcp --engine` on every app that holds it, in one pull request (pronto's `.github/harness.sh` compares the copies).

## Tests

[`tests.cue`](tests.cue) checks the exported files with `cue vet`.

```sh
./saytw --script tools.nu cue vet -c ./gcp
./saytw --script tools.nu cue vet -c -t app=check -t project=check-project ./gcp/export
./saytw --script tools.nu cue vet -c ./gcp/engine/export
for t in release build verify secrets; do ./saytw --script tools.nu nu gcp/engine/${t}_test.nu; done
```

The engine's tests run against fakes of gcloud, curl and docker; the release test's preflight cases evaluate the schema in a scratch app whose module pins the runtime the apps pin (`pronto_pin`), so they need `cue` on the PATH and the CUE registry.
