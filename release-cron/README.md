# release-cron

Releases a pronto app to production from `main` on the operator's Mac, so nobody has to ask for a
release: it releases, waits an hour, then releases again. launchd wakes it every 10 minutes
(`poll`), and a wake starts a run once `gap` (60 min by default; an app sets its own in
release_cron.cue) has passed since the end of the last run that released or failed. A skipped run leaves no gap, so a new merge doesn't wait an hour. Nor does one after a
failure: once main has moved past the commit a run failed on, the next wake starts a run; a
retry of the same commit waits the gap.

## What it adds

- `release-cron/release-cron.ts`, the driver (Deno), and `release-cron/cron.js`, its rules, pure and
  held by the cases in [`tests/unit/cron.cue`](../tests/unit/cron.cue). Both regenerated.
- `release_cron_plugin.cue`: `#Cron` and `#Probe` in the app's package, holding `releaseCron` to
  them with their defaults. Regenerated.
- `release_cron.cue`, seeded once, then the app's own: what it watches and what production must
  answer.

The app needs what a run calls: `./saytw verify@local` (its rehearsal) and `./saytw release@gcp`
([gcp](../gcp/README.md)), with `GCP` (project, region, service, name, and domain when one is mapped: without it the probes ask the service's run.app address) in its `release.cue`.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-release-cron .
deno run -A release-cron/release-cron.ts <app> install
```

Bonk Chess (bsoneca/pronto's `apps/brawl-chess`) is the first: its `release_cron.cue` probes `/`, a
`/player/<id>` link preview and `/table/<unknown room>`. bsoneca/ume's two apps, `pronto-verify` and
`ume-rental`, use it too, with two fields Bonk Chess leaves at their defaults:

- `ready: [...string]`: Cloud Run services, besides the app's own, that must be Ready in confirm
  (none by default).
- `holder: "verify@local"`: the `what` in a slot's owner line (`tests/slot.ts` writes `<pid> <ISO>
  <app dir> <what> (weight <w>)`) that marks the rehearsal's main slot. Ume's `verify@local` ends in
  `./saytw integrate@local`, so its apps set `holder: "./saytw integrate@local"`.

## A run

1. **prepare**: main is fetched into the run's own worktree (`~/.cache/pronto/release-cron/<app>/wt`,
   never a checkout a person or session works in), reset to `origin/main` and cleaned. Main
   is compared with the commit of the newest run that **released** (`runs.jsonl`), while the
   revision it confirmed still takes 100% of the traffic. When nothing under the app's `watch`
   paths (the app's folder by default) changed since that commit, the run **skips**. A failed
   run is never that commit, even when its release went live: its change is released again. With
   no such run, or another revision serving (a rollback, a release from elsewhere), it releases.
2. **slot**: `./saytw verify@local` waits for its slot in the machine's pool (`tests/slot.ts`),
   with `STACK_PRIORITY=release`: its claim goes to the head of the line, ahead of every waiting
   gate or launch (an app's `slot.ts` without priorities keeps it first come, first served).
   It waits for the slot as long as it takes (no limit); the run's lock keeps another run from
   starting meanwhile, and the log says it is still waiting every 5 minutes.
3. **rehearse**: the rehearsal, to its verdict (no limit). A failed scenario gets the
   rehearsal's own retry, once (Bonk Chess's `tests/rehearse.ts` runs it again beside the rest of
   its pass).
   A failed rehearsal never releases: the run is **failed**. The next run on the same tree
   reruns only the checks that failed, because the rehearsal keeps the ones that passed per tree.
   **Cloud rehearsal**: when the app's `release.cue` names `GCP.rehearsal` (a Cloud Run job, see
   pronto's docs/release-targets.md#gcp), steps 2 and 3 are one: nothing heavy runs here, no slot is
   taken, and `release@gcp` runs the rehearsal in the cloud against the rc preview. The run's
   record then carries the job's minutes and its cost (vCPU- and GiB-seconds at Cloud Run's
   prices), shown in the log line and by `report`, which prices it per run and per month at 16
   releases a day.
4. **release**: `./saytw release@gcp` on the same tree, which reuses the rehearsal's local-gate
   pass and skips the rc preview unless a deploy-shaped file changed.
5. **confirm**: the new revision takes 100% of the traffic and its live record is this tree's,
   each service in `ready` (Bonk Chess: `<service>-render`) is Ready, and the app's `probes` answer as expected (Bonk Chess: `/`, a
   `/player/<id>` link preview with `WhatsApp/2.23`, and `/table/<unknown room>`, which the
   renderer answers with 404). Retried until it is confirmed (no limit); every 5 minutes the log says what is still wrong. A release that changed
   nothing Cloud Run runs (tests, config) keeps the revision, and the log says so: `same image,
   nothing served changed`.

6. **notes**: when the revision is new and the app has [release-notes](../release-notes/README.md),
   its GitHub Release is made (`release-notes/release-notes.ts <app> publish <revision>`). The run
   records `notes` (`published` or `failed (exit N)`) and its outcome never changes with it.

Each step's output goes to `runs/<start>.log`. Each run appends one line to `release-cron.log`
(and the same as JSON to `runs.jsonl`). Every time a person reads there (the line, the log's name,
the `paused` file) is Brasília's, with its offset (`cron.js`'s `local`):

```
2026-11-03T07:00:00-03:00 brawl-chess released 93d3ea73 bonk-chess-00065-abc: 29.4 min = prepare 0.3, slot 0.0, rehearse 17.6, release 9.4, confirm 0.4
```

## Measured, every release

Each run records its steps, and inside them where the time went: the rehearsal's queue wait
and each check (`~/.cache/pronto/rehearsals/<app>.jsonl`), and the release's phases
(lock, rc, stage, schema, deploy, from `~/.cache/pronto/releases/<name>.jsonl`), as
`detail` in `runs.jsonl`, plus the scenarios that flaked. `report` lists every release and
compares the newest's phases with the median of the ones before, slowest first. The next
change to the release goes where the time is, and the next run's report shows whether it
helped.

No step has a time limit, and none is ever killed for its time: a stuck step must be seen, not
stopped. While a step runs, the run's log (`<state>/runs/<start>.log`) gets a line every 5 minutes
saying it is still running and how long into the run it is (confirm says what is still wrong), and
each step's minutes stay in `runs.jsonl` and `report`, so the slowest phase still shows. Only the
short calls inside prepare (`git fetch`, `gcloud describe`) keep their own hang guards of a few
minutes; a signal (launchd's, `kill`) still stops the run's children. Because nothing ends a stuck
run, stop it by hand (`kill <pid in <state>/lock/pid>`). An app's old `minutes` in release_cron.cue is still accepted but ignored; delete it. There's no overall budget. Runs never overlap:
launchd never starts a job while it's still running, and a lock (`<state>/lock`, with the
run's pid) skips a run started by hand while another is going.

## The release holds the machine

While a run works it keeps `~/.cache/pronto/release-active` (`RELEASE_ACTIVE` names another), one
line of JSON: `{"app":"<app>","pid":<the run's pid>,"started":"<ISO>","phase":"slot|rehearse|release|confirm"}`.
The run writes it (to a temporary file, then renamed) as it enters `slot`, updates `phase` at each
step and removes it when it ends, on every outcome and on a signal. A file whose pid is not alive
(`kill -0`) is stale: a reader ignores it and may delete it.

A job on this Mac checks the file before it starts heavy work and between units of work, and while
it is live starts nothing new: it waits, polling every 30 s. An app's `tests/slot.ts` does this for
every claim without `STACK_PRIORITY=release`; the run's own rehearsal and release carry it, so they
are admitted as before. Work already running keeps its slots. There is one file for the machine: when
releases of two apps overlap, the first run keeps it and the other takes it at its next phase.

## Install, pause, remove

```sh
deno run -A release-cron/release-cron.ts brawl-chess install    # worktree + ~/Library/LaunchAgents/dev.pronto.release-cron.brawl-chess.plist
deno run -A release-cron/release-cron.ts brawl-chess status     # installed? paused? the last runs
deno run -A release-cron/release-cron.ts brawl-chess report     # every release measured; the newest against the rest
deno run -A release-cron/release-cron.ts brawl-chess pause      # runs skip (logged) until resume
deno run -A release-cron/release-cron.ts brawl-chess resume
deno run -A release-cron/release-cron.ts brawl-chess uninstall  # the launchd job removed
```

Run these from the app's folder (`apps/brawl-chess`), where mise supplies deno and cue.
Pausing is a file, `~/.cache/pronto/release-cron/<app>/paused`, so `touch` and `rm` work too.
`launchctl bootout gui/$(id -u)/dev.pronto.release-cron.brawl-chess` stops the job until the
next `install`. A run whose script changed on the main it just fetched hands over to main's, so a
merged change to the plugin's files applies from the next run.

To try a change before it merges: `RELEASE_CRON_REF=origin/<branch> RELEASE_CRON_DRY=1 … run`
stops once it knows whether it would rehearse.

## Started by CD instead of launchd

A CI/CD job can start the run itself, for the commit its push carried, in place of the launchd job:
`RELEASE_CRON_REF=<commit> RELEASE_CRON_NOW=1 deno run -A release-cron/release-cron.ts <app> run`.
`RELEASE_CRON_NOW` skips the gap (the push is the schedule). Everything else is the same run:
the pause, the lock, the skip when nothing watched changed, the release, confirm and the measured
record. bsoneca/pronto's `cd` workflow releases Bonk Chess this way, on its Mac's own runner, so
that app has no launchd job.

## Why launchd

This Mac already runs its agents through launchd (`~/Library/LaunchAgents`), and launchd
already does what a scheduled release needs. It never runs two copies of a job at once. It
catches up one missed wake after sleep instead of a burst. It keeps running without a
terminal or a Claude session. It doesn't need cron's Full Disk Access. pronto has no
scheduler of its own: its GitHub workflows are off on purpose and can't reach the local
rehearsal stack.


## Tests

[`tests.cue`](tests.cue) checks the written files and #Cron's defaults with `cue vet`; the rules'
cases are suite `cron` of the plugins' unit cases.

```sh
./saytw --script tools.nu cue vet -c ./release-cron
./saytw --script tools.nu cue vet -c -t package=check ./release-cron/export
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- cron
```
