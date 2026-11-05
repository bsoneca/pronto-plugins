# prod-watch: what production logged that may be a bug

Reads Cloud Logging for an app's Cloud Run services, groups what may be a bug by fingerprint and
says what is new since it last looked. An agent runs it on a loop ([the pronto-prod-watch
skill](../skills/pronto-prod-watch/SKILL.md)), triages each new fingerprint (a bug to fix in a pull
request, or noise with a reason) and checks after a release that the fingerprint stopped. It only
reads: `gcloud logging read` with the caller's credentials.

## What it adds

- `prod-watch/prod-watch.ts`, the driver (Deno), and `prod-watch/watch.js`, its rules, pure and held
  by the cases in [`tests/unit/fingerprint.cue`, `noise.cue` and `triage.cue`](../tests/unit). Both regenerated.
- `prod_watch_plugin.cue`: `#Watch` and `#Noise` in the app's package, holding `prodWatch` to them,
  with the lifecycle windows and the noise every app shares. Regenerated.
- `prod_watch.cue`, seeded once, then the app's own: the other services it answers for and its own noise.

## Turn it on for an app

```sh
bin/pronto-prod-watch apps/<app>      # from a pronto-plugins clone
```

Then edit the seeded `prod_watch.cue` (other services, the app's own noise), run the driver once
from the app's folder (below), and start the loop with the pronto-prod-watch skill. The app needs a
`release.cue` with `GCP` (project, service, and its `sidecars`).

## Run it

From the app's folder, with `cue`, `deno` and `gcloud` on `PATH` (an app's mise has the first two):

```sh
deno run -A prod-watch/prod-watch.ts brawl-chess              # since the last run (3 days on the first)
deno run -A prod-watch/prod-watch.ts brawl-chess --since 6h   # a window, the ledger and cursor untouched
deno run -A prod-watch/prod-watch.ts brawl-chess --json       # the same, as JSON
deno run -A prod-watch/prod-watch.ts brawl-chess ls open      # the ledger, by status
deno run -A prod-watch/prod-watch.ts brawl-chess mark 31db50 fixed --pr 501
deno run -A prod-watch/prod-watch.ts brawl-chess mark c254d4 noise --reason "..."
```

A report lists, in full, each fingerprint that is **new**, **regressed** (marked fixed and seen
again after the mark) or **rising** (open, 5 times or more this run and over twice its rate so far),
with its count, first and last seen, revisions and up to three samples; then the open ones a line
each; then how much was noise. A fingerprint is a prefix of the sha1 of the service and container,
the message's title with what varies taken out (timestamps, ids, addresses, query values, numbers)
and the app's own frame of a stack (`watch.js`). The header says how the app's fixes reach
production (`released`): `release-cron` when the app has a `release_cron.cue`, else `by hand`.

## What it reads

- **Which services**: the app's `release.cue` (`GCP`): its `service`, and `<service>-<name>` for each
  sidecar that runs `apart`; plus the `services` of its `prodWatch`.
- **Which entries**: a warning or worse, a 5xx, or a line with no severity that says it failed
  (error, panic, exception, traceback, fatal, refused, failed); never a request answered below 500.
  Also Cloud Run's start and shutdown lines, which open an instance's windows (below) and are
  never reported themselves.
- **Browser errors**: the journeys collector writes each page error as an `ERROR` line
  (`frontend TypeError: ...`, with its top frame, screen and revision; journeys/README.md), so they
  are read, fingerprinted and triaged like any server line, under the collector's container.
- **A traceback written a line an entry** (Python's logging to stdout, as pronto-llm does) is put
  back into one entry before it is grouped.

## Noise is a design fact

A noise rule says, in CUE, a line that is not a bug and why; a case proves it on the line it was
written for and on the line it must leave alone ([`tests/unit/noise.cue`](../tests/unit/noise.cue)).
The rules every app shares, for what pronto's release runs beside every app (Electric, the Cloud SQL
proxy, the Managed Prometheus collector), come with [`schema.cue`](schema.cue) in `prodWatch.noise`;
an app's own go beside them in its `prod_watch.cue`.

A rule may be held to an instance's **start** or **shutdown** window (`during`), as `prodWatch.lifecycle`
defines them: a container calling PostgREST before it listens, or after it stopped on SIGTERM, is how
an instance starts and stops; the same line an hour into its life is a bug.

A fingerprint judged noise one at a time, with no rule (a one-off), is marked in the ledger with its reason.

## State

The cursor (`cursor.json`, the time the last run reached) and the ledger (`ledger.json`, each
fingerprint's status: open, watching, noise with why, fixed with its PR and when) are in
`<the repository's root>/.omc/prod-watch/<app>/`, runtime state no commit carries. A watching agent
also keeps its `log.md` there, a line a pass.

Samples are redacted before they are printed (`redact` in `watch.js`): emails, phone numbers,
addresses, uuids, bearer tokens, JWTs, long tokens, and the values of keys that name a secret or a
person. Even so, a pull request quotes a sample only as far as it needs to.

## Tests

The fingerprinting, redaction, noise rules and triage are cases in `tests/unit/*.cue` (suites
`fingerprint`, `noise` and `triage`), run as every suite is:

```sh
for s in fingerprint noise triage; do deno test --allow-read --allow-env --allow-run tests/unit.ts -- $s; done
```
