# flags

Feature flags for a pronto app, on [OpenFeature](https://openfeature.dev) and [flagd](https://flagd.dev).

## What it adds

- The app says its flags in CUE (`flags_spec.cue`); generate turns them into flagd's definitions in `flags/flags.json`.
- flagd runs beside the door, as a container or a Cloud Run sidecar, and answers OpenFeature's remote protocol (OFREP) at `/ofrep/` on the app's own origin.
- Live flags: where the app is released, flagd reads one object in a versioned Cloud Storage bucket. `pronto-flags push` changes a flag with no deploy, and `rollback` restores an earlier version.
- Files in the app: `flags_plugin.cue`, `pronto/flags.cue`, `flags/flags.nu`, and `flags_spec.cue` (written once, then the app's).

```cue
flags: premium: {default: false, local: true}
```

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-flags <app-dir>
# say the flags in flags_spec.cue
./saytw generate && ./saytw lint
```

Live flags, run as the operator's own gcloud login:

```sh
<this repo>/bin/pronto-flags setup|push|history|rollback|show|cases <app-dir>
```

A `push` that changes a flag's default value (or adds a flag) is a flip, and a flip runs the flag's cases before it reaches everyone: at hand, then on production for the testers alone. See [A flip runs its cases](../README.md#a-flip-runs-its-cases). In the spec: `flagsLive: {url, testers, runAs, alert}` (a tester is targeted only during the run and may not be in any flag's `accounts`; the live cases run impersonating `runAs`, the release identity that reads the tester's credential; `alert` is snoozed for the live stage) and `flagsCases: {local, live}`; in the app's scenarios and unit cases, `flags: ["<flag>"]` (and `production: true` on the scenarios safe to run on production).

Live flags need `flagsLive: {project, bucket}` in the spec and a flagd sidecar in `release.cue`. The page reads flags with OpenFeature's web SDK and the OFREP provider. Details in the [root README](../README.md#pronto-flags); why a flip runs its flag's cases, in [docs/flag-flips.md](../docs/flag-flips.md). There is no skill for this plugin.

## Tests

- [`install_test.ts`](install_test.ts): the installer: flags in the app's own package, its spec kept, a program with no package refused.
- [`live_test.ts`](live_test.ts) and [`test/live_test.nu`](test/live_test.nu): the live commands against a stand-in for gcloud ([`fake_gcloud.py`](test/fake_gcloud.py)) and for flagd's OFREP answer ([`fake_ofrep.py`](test/fake_ofrep.py)), with the app's cases as tiny `sh` commands: a flip refused with no cases, `--untested` and `--skip-live` with their reasons kept, the happy path (canary, then final), a local failure (nothing written), a live failure and an OFREP timeout (rolled back).

```sh
deno lint --no-config flags && FLAGD=$(mise where http:flagd)/flagd deno test --no-config --allow-read --allow-write --allow-run --allow-env --allow-net flags
./saytw --script tools.nu nu flags/test/live_test.nu
```
