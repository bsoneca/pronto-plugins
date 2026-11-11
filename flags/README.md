# flags

Feature flags for a pronto app, on [OpenFeature](https://openfeature.dev) and [flagd](https://flagd.dev).

## What it adds

- The app says its flags in CUE (`flags_spec.cue`); generate turns them into flagd's definitions in `flags/flags.json`.
- flagd runs beside the door, as a container or a Cloud Run sidecar, and answers OpenFeature's remote protocol (OFREP) at `/ofrep/` on the app's own origin.
- Live flags: where the app is released, flagd reads one object in a versioned Cloud Storage bucket. `pronto-flags push` changes a flag with no deploy, and `rollback` restores an earlier version.
- Files in the app: `flags_plugin.cue`, `pronto/flags.cue`, `flags/flags.nu`, and `flags_spec.cue` (written once, then the app's).
- The flags in the app's database: generate also writes `flags/flags.sql`, which an app with a database lists among its raw migrations. It adds `pronto_flags.flag_on(flag, player)`, which answers as flagd does (default, local at hand, accounts, a push's canary), so the database can refuse a feature's writes while its flag is off. A flag the database holds no document for is off. With `flagsLive.database` (the app's command that runs SQL on its stdin in the released database), every write of the live flags (push, its canary and restore, rollback) is written there too, through `pronto_flags.put()`, with flagsLive.url's host; a write that fails there fails the push. A test database holds the flags baked into the image instead: one whose fixture inserts `pronto_flags.at_hand` and calls `pronto_flags.fill_local()` (a release's database never has the marker). To adopt it: reinstall, run `generate` twice (the first writes the rule that writes `flags/flags.sql` before pronto's writer, the second writes the file), then list it among the raw migrations, numbered before any migration that reads it.

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

Every write (`setup`, `push`, `rollback`) prints `flags: target <url>` first, and refuses, with nothing written, a target other than `--expect <url>` (or `PRONTO_FLAGS_EXPECT`). With `--dry-run` (or `PRONTO_FLAGS_DRY_RUN=1`) a write shows what it would write and stops, and a dry run never writes, whatever path it takes: each place that writes refuses under it (every gcloud call but a read, the ssh mirror, the store itself) with `flags: dry run: refused a write`. A stand-in for gcloud is no dry run: on 2026-11-07 a test that faked gcloud through `SAYT_MISE_BIN`, run under `./saytw` (which sets its own), wrote the live bucket. Each write is also appended, as one JSON line, to the flip journal (`$XDG_STATE_HOME/pronto-flags/<app>.jsonl`, `~/.local/state` by default; `PRONTO_FLAGS_JOURNAL` names another file) and printed after `flags: journal `: `at`, `event` (`flags.write`), `app`, `target`, `version`, `from` (the generation it replaced), `stage`, `flag` (the flags whose default value moved, joined by `+`), `who`, `commit`, `cases`, `note` and `changes` (`[{flag, from, to}]`). `history --json` prints the versions as JSON, each with its `changes` against the version before it.

The store can be a local directory instead of a bucket, for a drill or a laptop: `flagsLive: {dir: "flagstore"}` (relative to the app's folder, or absolute). It keeps the bucket's semantics as files: the live document at `<dir>/flags.json` (written whole by a rename, so a flagd watching it never reads half), each version at `<dir>/versions/<generation>.json` with its `<generation>.meta.json`, a write refused when the generation it read is no longer the live one. It needs no gcloud, and a flagd reads it as a file source (`flagsLive.sources`).

Live flags need `flagsLive: {project, bucket}` in the spec and a flagd sidecar in `release.cue`. The page reads flags with OpenFeature's web SDK and the OFREP provider. Details in the [root README](../README.md#pronto-flags); why a flip runs its flag's cases, in [docs/flag-flips.md](../docs/flag-flips.md). There is no skill for this plugin.

## pronto-armies

The same push, one object kind over: an app whose page reads its armies from a database shape publishes them with `bin/pronto-armies push|show|history|rollback <app-dir>` (testers first, the flag's `production` scenarios as the tester, then everyone, written back on a failure). See [pronto-armies](../README.md#pronto-armies-the-second-object-kind-of-the-push).

## Tests

- [`test/armies_test.nu`](test/armies_test.nu): the armies kind, against a stand-in for the app's SQL command ([`fake_sql.py`](test/fake_sql.py)): a local push, a live push through its testers' stage and its cases, a refusal with no cases, tester or `production` scenario, a failing case written back, the dry run, `--expect`, `history` and `rollback`.

- [`sql_test.ts`](sql_test.ts): `flags/flags.sql` on PGlite: `flag_on` with no document, a flag's default and accounts released, a test database's baked flags at hand, a push's canary then its final document, a rule it cannot read, a disabled flag, a quote in a value, and no write for an app role.
- [`install_test.ts`](install_test.ts): the installer: flags in the app's own package, its spec kept, a program with no package refused.
- [`live_test.ts`](live_test.ts) and [`test/live_test.nu`](test/live_test.nu): the live commands against a stand-in for gcloud ([`fake_gcloud.py`](test/fake_gcloud.py)) and for flagd's OFREP answer ([`fake_ofrep.py`](test/fake_ofrep.py)), with the app's cases as tiny `sh` commands: a flip refused with no cases, with no tester or with no `production` scenario (nothing written), `--untested` with its reason kept, `--no-canary` (one version for everyone, no case run), the happy path (canary, then final, nothing at hand), a live failure and an OFREP timeout (rolled back). With `flagsLive.database` (a stand-in command that keeps the SQL), a push and a rollback put the document with flagsLive.url's host, a dry run writes nothing there, and a failure there fails the push. The same cases run on a directory store (flagsLive.dir), with the journal, `history --json`, `--expect`, the dry run and a stale write; with gcloud refusing every write (`FAKE_GCLOUD_READONLY`), `--dry-run` and `PRONTO_FLAGS_DRY_RUN` on push, rollback and setup write nothing, and the store and gcloud each refuse a write under a dry run on their own.

```sh
deno lint --no-config flags && FLAGD=$(mise where http:flagd)/flagd deno test --no-config --allow-read --allow-write --allow-run --allow-env --allow-net flags
./saytw --script tools.nu nu flags/test/live_test.nu
```
