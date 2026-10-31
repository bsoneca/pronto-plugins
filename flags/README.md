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
<this repo>/bin/pronto-flags setup|push|history|rollback|show <app-dir>
```

Live flags need `flagsLive: {project, bucket}` in the spec and a flagd sidecar in `release.cue`. The page reads flags with OpenFeature's web SDK and the OFREP provider. Details in the [root README](../README.md#pronto-flags). There is no skill for this plugin.

## Tests

- [`install_test.ts`](install_test.ts): the installer: flags in the app's own package, its spec kept, a program with no package refused.
- [`live_test.ts`](live_test.ts) and [`test/live_test.nu`](test/live_test.nu): the live commands against a stand-in for gcloud ([`fake_gcloud.py`](test/fake_gcloud.py)).

```sh
deno lint --no-config flags && FLAGD=$(mise where http:flagd)/flagd deno test --no-config --allow-read --allow-write --allow-run --allow-env --allow-net flags
./saytw --script tools.nu nu flags/test/live_test.nu
```
