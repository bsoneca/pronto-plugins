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
`/player/<id>` link preview and `/table/<unknown room>`. Other apps may set two fields Bonk Chess
leaves at their defaults:

- `ready: [...string]`: Cloud Run services, besides the app's own, that must be Ready in confirm
  (none by default).
- `holder: "verify@local"`: the `what` in a slot's owner line (`tests/slot.ts` writes `<pid> <ISO>
  <app dir> <what> (weight <w>)`) that marks the rehearsal's main slot. An app whose `verify@local` ends in
  `./saytw integrate@local` sets `holder: "./saytw integrate@local"` (read as
  `rehearsal.holder`, below).
- For an app with a command target, the rehearsal's env carries `REHEARSE_LIVE=<the commit that serves>` (never for Cloud Run apps), read once when the rehearsal is started, before its slot wait (20 s at most, no retries; a failed read leaves it out), and, for every app (Cloud Run included), `REHEARSE_COMMIT=<the commit it rehearses>`. Both are provided for the rehearsal's selection; nothing reads them yet.

## What an app chooses

Everything below is a field of `releaseCron` with a default that is what an app got before it
existed, so an app that names none of them runs as it did.

- `scheduler`: `{kind: "launchd"}` (the default; the LaunchAgent above), `{kind: "systemd"}` or
  `{kind: "actions"}`. `systemd`: `install` writes `~/.config/systemd/user/<label>.service` (a
  oneshot that runs the script) and `.timer` (`OnUnitActiveSec` = `poll` minutes, `OnBootSec=1min`),
  then `systemctl --user daemon-reload` and `systemctl --user enable --now <label>.timer`;
  `uninstall` disables the timer and removes both. `actions`: `install` writes nothing and says
  that the app's workflow runs `release-cron.ts <app> run` (see "Started by CD"). The units and
  the plist are rendered by pure functions of `cron.js` (`systemdUnits`, `plist`).
- `target`: `{kind: "cloud-run"}` (the default: release.cue's GCP, `./saytw release@gcp`, Cloud Run's
  traffic) or `{kind: "command", release, serving, origin, preview?}` (see "An app off Cloud Run").
  A `target` that names no `kind` is a command's, so an existing one loads unchanged.
- `rehearsal`: `{command: ["./saytw", "verify@local"], slot: true, holder: "verify@local"}`. `command`
  is the rehearsal, run in the app's folder (null: none, the release follows the schedule alone);
  `slot: false` runs it without waiting for a slot of the pool; `holder` is the `what` above, which
  the top-level `holder` still sets. `GCP.rehearsal` (the cloud's) replaces it, as before.
- `notify`: who is told of a bisect's culprit and of the scenarios that flaked or failed new:
  `{kind: "none"}` (the default: the log alone), `{kind: "github-comment"}` (a comment on the pull
  request) or `{kind: "claude-session", lead, notes}` (that comment, a notes file in the author
  session's folder when the PR body names one, else `lead`'s, under `~/<notes>`, and a macOS
  notification, on darwin only). `lead` has no default. An app that still sets `bisect.lead` or
  `bisect.notes` is read as a `claude-session` with them.
- `hooks`: `[{on: "released", command: [...]}]`. After a confirmed release, each hook runs in the
  run's worktree with `<worktree> <app> <commit>` appended to its command (a first word of `deno` is
  the deno running the script; `cue` is found as mise's newest when the PATH has none). A hook that
  fails is logged and recorded (`hooks` in runs.jsonl) and never changes the run's outcome. The dev
  flow's board, which tells the app's Merged issues whose pull request the release holds that they
  are Live, is one:

  ```cue
  releaseCron: hooks: [{on: "released", command: ["deno", "run", "-A",
  	"--reload=https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/",
  	"https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/hook.ts", "released"]}]
  ```

- `flagsReleased`: the command that records which flags the served release reads (pronto-flags'
  `released`, which writes `released.json` beside the live flags so a `pronto-flags push` keeps a
  flag the release still reads: PRONTO-680), run in the run's worktree with the app's folder
  appended, once production serves the release's commit and when a run finds main already serving.
  A failure is logged and never changes the run's outcome. Null by default.

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
   **3b. android** (optional, `releaseCron.android.command`): once the rehearsal passed, the app's phone
   scenarios on an emulator, run in the app's folder (no limit, as the rehearsal). Its exit says pass or
   fail; a failure ends the run **failed** (`the android step failed (exit N): <scenarios>: nothing
   released`) and its bisect says "not bisected", since the bisect's check (`integrate@local`) runs no
   emulator. Where release-cron does not run on a Mac the step is skipped and the log says so; the
   release goes on. `RELEASE_CRON_DRY=android` runs only this step (no rehearsal, no preview) and ends
   `dry` with its exit code, leaving `last` and the gap as they were and starting no bisect. A dry android run holds the app's lock while it runs, so a run cd starts meanwhile is skipped.
   The step runs in an allowlisted environment (`androidEnv` in cron.js, `clearEnv`): PATH, HOME, the Android SDK, Java, gradle, mise, sayt, `STACK_*` and `PRONTO_*`, never a token or a credential (`GH_TOKEN`, the Google credentials, `CLOUDFLARE_API_TOKEN`).
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

7. **source maps**: when the revision is new and the app has [pronto-errors](../errors/README.md)
   `errors/sourcemaps.ts`, its bundles are built again from the tree released, with their maps, and
   sent to GlitchTip (`errors/sourcemaps.ts upload`). The run records `maps` (`sent` or `failed (exit N)`)
   and its outcome never changes with it.

8. **hooks**: `releaseCron.hooks` on `released`, as above.

Each step's output goes to `runs/<start>.log`. Each run appends one line to `release-cron.log`
(and the same as JSON to `runs.jsonl`). Every time a person reads there (the line, the log's name,
the `paused` file) is Brasília's, with its offset (`cron.js`'s `local`):

```
2026-11-03T07:00:00-03:00 brawl-chess released 93d3ea73 bonk-chess-00065-abc: 29.4 min = prepare 0.3, slot 0.0, rehearse 17.6, release 9.4, confirm 0.4
```

## Measured, every release

The reasons release-cron itself gives a failed run are declared once, as `releaseCron.causes` (schema.cue; fixed, like `steps`, and tested in
tests.cue): `noVerdict` "the rehearsal gave no verdict", `rehearsalFailed` "the rehearsal failed", `rehearsalStopped` "the rehearsal was stopped",
`previewFailed` "the release preview failed", `previewStopped` "the preview was stopped", `endedBeforeSlot` "ended before its slot" and `signal`
"stopped by a signal". `release-cron.ts` and `cron.js` build a run's `why` from these phrases (`failureOf` in `cron.js` chooses the reason and key), importing them from `release-cron/causes.js`, which `host.cue` emits from the schema (tests.cue checks the committed file is that text; it is written into the app beside `cron.js`), so neither loads the config for them. The
record carries the key beside it as `run.cause` (`"noVerdict"`, `"rehearsalStopped"`, ...): a reader (the bisect, pronto's tools/metrics) matches
the key; a record written before `cause` existed is read by its `why` and the phrases above. `why` is unchanged, byte for byte.

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
run, stop it by hand (`kill <pid in <state>/lock>`). An app's old `minutes` in release_cron.cue is still accepted but ignored; delete it. There's no overall budget. Runs never overlap:
launchd never starts a job while it's still running, and a lock (`<state>/lock`, a file holding
the run's pid, made whole by `link(2)` as the bisect's is) skips a run started by hand while another is going.

## When the preview runs

An app with a `target.preview` chooses `when` (the field of `preview`, default `"after"`):

- `"after"` (the default): as above, once the rehearsal and the android step passed. A preview that fails has cost a full rehearsal first.
- `"first"`: before the rehearsal takes its slot. A preview that fails ends the run `failed` (a red verdict, as any preview failure) and no
  rehearsal was paid for.
- `"beside"`: the preview starts when the rehearsal starts, and the two run at the same time, the first to fail stopping the other
  (`besideOutcome` in `cron.js`):
  - the preview fails first: the rehearsal's process group is stopped (TERM, then KILL after 300 s so `rehearse.ts` and integrate@k8s tear
    down their stacks and cluster; a signal to the run gives 60 s; the rehearsal records `stopped`, which is no verdict) and the run ends
    `failed`, `the release preview failed: ...; the rehearsal was stopped: nothing released`. That is no attempt and cuts no release branch,
    and it is never bisected (it says nothing of a commit);
  - the rehearsal fails first: the preview's `up` is never cancelled (stopping it would only kill the local ssh, leaving the remote
    release running while `down` starts in the same worktree), so it runs to its end (Bonk Chess's `up` ends with the kill rehearsal, which
    is acceptable); the waits and probes after it are skipped and `down` runs. A failed `down` is logged and added to the run's reason.
    The run ends with the rehearsal's own reason, red or no verdict, bisected and branched as ever;
  - both passed: the android step, then the release, once `git rev-parse HEAD` in the run's worktree is still the commit both started from
    (else the run fails, nothing released). `"first"` makes the same check.

  The run's lock covers both, so there is still one release per app. The record has one step for the overlap, `rehearse+preview` (`releaseCron.steps.beside`, the names of every step are declared there) (their wall
  time, so `report`'s sum counts it once), and `run.beside = {slot, rehearse, preview, first}`: `slot` is the rehearsal's slot wait in seconds (from its claim to its
  admission, as the `slot` step is for a run that is not beside, which the overlap writes no step for; `besideTimes` in `cron.js`;
  when the slot was never seen, a rehearsal that passed counts its whole time as `rehearse` (every check was already green) and one that
  did not counts it as `slot`, where a run that is not beside counts both as `slot`),
  `rehearse` its run time in seconds (admission to its end), `preview` the preview's seconds to its end (from the start of both),
  and `first` which ended first. A rehearsal that ended before it had a slot is all `slot`, `rehearse: 0`; one that needed none
  (nothing to wait for, or every check already green for the tree) has `slot: 0`. `release-active` names the phase `rehearse+preview`.

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

`tests/slot.ts` holds the machine for a release too (PRONTO-894): while a release claim holds a slot or
waits, other weighted claims wait. While the release holds a slot and no release waits for one, a claim
is admitted beside it while the machine's load1 is under `STACK_HOLD_LOAD` (one per core) and its weight
fits the budget (`besideRelease`; the owner, 2026-11-20: "Admit while there's room").

## A failed run is bisected

A run that **failed** names the commit that broke it and reports it; bisect never reverts a merged
pull request (the user decided against automatic reverts). As it ends (after giving the machine back) it
starts `release-cron.ts <app> bisect` as a process of its own, one at a time (`bisect/lock`), in its
own checkout (`bisect/wt`, never the run's `wt`); `bisect [--dry] [<run's start>]` does it by hand,
`--dry` runs nothing, tells nobody and writes nothing, and `--no-notify` runs the checks and records them but tells nobody. `gh` (and the push) use the run's own login. Under launchd that is the machine owner's gh login, and bisect is detached. Under CD (`GITHUB_ACTIONS`) it is the release job's `GH_TOKEN`: a runner started with `SessionCreate` cannot reach the owner's login in the keychain, and the token dies with the job. So there bisect runs in the foreground once the run's lock is let go, and the job lasts until bisect ends.

1. The range is the first-parent merges of `main` between the newest run that released and the
   failed run's commit. The failure's signature is its kind (`release`: release@gcp or its confirm;
   else `rehearsal`) and the scenarios its output marks `✗ <name> (…s) at step`.
2. Each merge is read from the records first, as good, bad or unknown: pronto's release records
   (`~/.cache/pronto/releases/`: live is good, a failed rc test run bad) for a release failure, the
   rehearsal records (`~/.cache/pronto/rehearsals/`: passed, failed) for a rehearsal failure, a dirty
   tree none, plus the verdicts earlier bisects ran (`bisect/verdicts.v2.jsonl`, the v2 ledger: a verdict an older rule saved is never
   read, and a line that cannot be read stops the bisect unrecorded rather than dropping the verdicts before it).
3. For the middle merge the records leave unknown, `#Cron.bisect.command` (`./saytw integrate@local`)
   runs in that commit's tree with `ONLY=<the failed scenarios>`, `SCENARIOS_ALL=1` and `SLOW=1`, as a plain claim on the
   machine's slots (the app's `tests/slot.ts`): it waits for release-active like any job, never holds
   it, never carries `STACK_PRIORITY=release`. Neither a check nor the bisect has a time limit (an old `bisect.minutes` or
   `bisect.check` is accepted and ignored; the bisect log says every 5 minutes that a check is still running). Every failure first runs it on the failing commit, and only a check that fails there too is bisected. A release failure that passes there shows only in the cloud: nothing is bisected and the range is told to the lead. A rehearsal failure that passes there came from the run's conditions (a service stopped from outside the stack, as when every flagd on the machine was killed mid-rehearsal on 2026-11-06), not from a commit: no pull request is named, and the lead is told so. A cloud-only failure (the
   rc preview) is approximated by the same scenarios run locally.
   What a check is judged by:
   - The check starts clean: nothing inherited narrows or hands it off (`ONLY`, `ONLY_ABSENT`, a scenario queue, a slot or
     stack, `FLAG*`, `INTEGRATE_LOCAL_DRIVERS`), so it never stamps the tree for a release.
   - A named failure is judged by the scenarios' own verdict (`SCENARIOS_VERDICT`, a private temp dir) alone: bad when a named
     scenario failed, good only when every named scenario the tree has ran there and passed (none skipped, cached or run by another
     lane). Named scenarios the tree lacks (`ONLY_ABSENT=pass`) cannot have failed there.
   - A check that judged nothing (exit 3, 124, 126, 127, a signal or 128 and above, or an unreadable or missing verdict from a
     tree that writes verdicts) is inconclusive: it is written to `bisect/inconclusive.jsonl` and the run stays open for the next
     bisect, twice; the third inconclusive check records the bisect as stopped, no commit named.
   - A rehearsal that gave no verdict (exit 3, 124 or 128 and above) ends the run as `the rehearsal gave no verdict`: it is never
     bisected, and no release branch is cut for it.
4. The culprit is mapped to its pull request (`Merge pull request #N from …`). The pull request gets a
   comment; a notes file goes to the author session when the PR body names one (`local_<uuid>`) and
   its notes folder exists, else to `notify.lead`'s
   (`~/Library/Application Support/Claude/side-session-notes/<session>/`); a macOS notification is
   shown. That is `notify: {kind: "claude-session"}`; `github-comment` only comments and `none`
   (the default) only logs. Once per culprit.

Each bisect is a line of `bisect/bisects.jsonl` and a `bisect` line of `runs.jsonl` (`detail.bisect`),
and `report` ends with them; it never reverts, never releases and never calls `release@gcp`.

## Release branches

An app that opts in (`releaseCron: branches: enabled: true`) does not fail a release on a red rehearsal: it holds it, and the fixes
go in before the release ends, not into the next run. (The owner's ask: "we create a release branch, do the fixes there, and then
cherry pick fixes to main.") `abandonHours` (12) and `abandonAttempts` (2) are the app's to change. Off, a rehearsal that fails is
`failed` as ever.

A fix branch starts from the release branch (`git switch -c fix/... origin/release/<app>/<id>`), never from main: a tip
whose commits came from pull requests into main is refused. Turn branches on for an app only once the repository has a ruleset
on `refs/heads/release/**` (ci and gate required, a pull request for every change, no force push).

1. **Hold.** A run on main whose rehearsal (or android step, or preview) fails pushes `release/<app>/<YYYYMMDD-HHMM>` (Brasília
   time) at the run's commit and writes `<state>/open`: `{branch, base, opened, limits, attempts: [{tip, verdict, at}]}`, the
   cut's own failure the first attempt. The run's line says `held release/<app>/<id>`. The cut's failure is still bisected on main,
   which reports to the culprit PR; a failure on the branch is not.
2. **Fix.** While `open` exists the run's ref is `origin/release/<app>/<id>` and the gap is ignored: a wake runs only when the
   branch tip is a commit no attempt judged. A fix is a pull request into the branch (never a push to main for it). A red attempt
   is appended to `attempts` and the line says `held` again. Any failure of a run on the branch counts as a red attempt.
3. **Release.** A green rehearsal releases from the branch as any release does (preview, release, confirm, hooks). `open` is
   removed, a record `{branch, attempts, released commit}` (outcome `closed`) is appended to runs.jsonl, and the gap restarts from
   the release's end.
4. **Abandon.** `open` older than `abandonHours`, or `abandonAttempts` attempts in with the newest red, ends as
   `abandoned release/<app>/<id>`: `open` is removed, the record is written and the next run cuts from main again, after the gap.
   `release-cron.ts <app> abandon` does the same by hand (the lead's call), once no run is going. `status` shows the open release.

Guards, each so a branch cannot lose or smuggle a change:

- **Only red counts.** An attempt is a red verdict: the rehearsal, the android step or the preview failed. A failure of the release
  step, the confirm, an ssh read or the slot records nothing, so the same tip runs again once the gap is over (below).
- **Trusted tips.** Before a new tip is rehearsed it must descend from the commit the branch was cut at, and every commit
  past the cut, merge commits too, must have come by a merged pull request into that branch (`gh api repos/<slug>/commits/<sha>/pulls`: `merged_at` set,
  `base.ref` the branch). A tip that fails this is refused: logged and told as `held-refused`, no attempt, not run again until
  another tip is pushed (a pull-request read that fails is tried again next wake). A branch ruleset is the other half.
  The tip is judged **before it is checked out or trusted**: by the running script's own code, from git objects and GitHub's records,
  at the commit id read once (`origin/<branch>`), and the refusal's notify settings are the trusted checkout's. Only a tip that passes
  is checked out into the run's worktree (at that commit id), where its `.mise.toml` is trusted and its config read. A refused tip is
  never checked out, so the worktree the scheduler's job runs the script from stays where it was and the next wake cannot run the
  refused tip's script.
- **No migrations.** A tip whose cut..tip changes a file under the app's `services/database/migrations/` is refused the same way:
  migrations go to main only. The change is listed with `git diff --no-renames --name-only`, so a migration moved out of the folder is
  caught by its old path.
- **Nothing lost.** Every commit on a release branch must be cherry-picked to main (`git cherry-pick -x`), or an equal patch (`git patch-id --stable`) must be there, or, as bsoneca/pronto's ledger counts it, a main commit's message says
  `Backport-of: #n` for a branch commit whose subject ends `(#n)`. A merge commit on the branch counts too, by what its conflict
  resolution changed (`git show --cc`, as the ledger's script does): a resolution that changed code is a fix with no commit of its own, missing
  until it is carried to main by hand. One rule (`missingFromMain`) answers both a release's authorization and a branch's deletion, and
  both compare at commit ids (the branch's tip and the commit main is compared at), never at refs that move: a release checks against
  the commit it is about to deploy.
  After a branch releases, the next run that would release main first checks that every non-merge commit of the branch since the merge
  base has its counterpart on main; else it ends `held-backport <branch>` (no release, no gap used; told once per set of
  missing commits) and tries again next wake (a git or fetch failure in the check ends the run `skipped`, not `failed`). When all are there it deletes the branch from origin. An abandoned branch is deleted the
  same way only when everything on it past the cut is on main; otherwise it stays and the lead is told which commits need a cherry-pick.
  A branch is deleted only as the tip that was checked: the push carries `--force-with-lease=refs/heads/<branch>:<checked sha>` with a
  delete refspec. If the branch moved since (a push nothing checked), the lease fails, the branch and its `released-branch` record are
  kept, and the new tip is told.
  `abandon` with no release held but a branch waiting on main (held-backport) clears it only once every commit is on main and the branch is gone; else it logs which commits are still missing and keeps the record (`abandonPlan`). A hold whose branch already shipped is closed the same way, its record kept.  A hold whose branch shipped though its confirmation never ran (a run of it reached the release step) gets its released-branch record before the plan, from what serves (the serving command, or Cloud Run's traffic, once, the read itself 20 s at most): the tip, or a commit on the branch main lacks, is the record's tip; unread, the release attempt's commit is, said as assumed. A serving commit that is the tip or on the branch records with no release attempt needed (a run stopped before its release step's key was written); with none and serving unread, no record is written. The automatic give-up and a run's own last red attempt do the same (`shippedRecord`). `abandon --force` clears a released-branch record (a corrupt one too) and logs the commits still missing: it lets main release without them, and clears nothing a call just wrote for a hold that shipped. While a record waits, no new hold is cut (`cutPlan`).
- **A held tip already serving.** When the held branch's tip is what production serves (its release landed and its confirmation never
  did), the run resumes at confirmation, without rehearsing or releasing again; once confirmed it writes the `released-branch` record
  and closes the hold, in place of ending `skipped` with the hold left open. A held tip confirms itself by the trusted checkout's probes,
  `ready` services and serving command (`heldConfig`), never the candidate's own.
- **`RELEASE_CRON_DRY` is read first.** Any value makes the run a dry one before it decides anything: it deletes no branch, abandons or
  closes no hold, writes no marker (`refused`, `backport-told`, `flags-released`), records no flags and tells nobody; it says what it
  would have done (`RELEASE_CRON_DRY: would ...`). A held tip is judged (git objects and GitHub's records) but, dry, never checked out,
  cleaned or trusted: the run says it would check it out. These decisions are pure plans (`heldPlan`, `backportPlan`, `limitPlan`) that
  the driver executes in order, and the cases hold that a refused tip's plan has no checkout and a dry plan no mutation.
- **Ledger parity.** The cherry-pick and `Backport-of` lines are read from all of main's history at the deploying commit, not only since the merge base, and a
  branch commit with no patch id (an empty commit) is nothing to carry, as `.github/release-ledger.sh` counts both.
- **An unreadable record stops the run.** `open` and `released-branch` are absent only when the file is not there
  (`Deno.errors.NotFound`); a parse or I/O error stops the run with the error, never reading as nothing held. The run reads `released-branch` under its lock. `abandon` is how a lead gets past a corrupt `open`: it
  reports the file and why and exits 1, and `abandon --force` removes that file.
- **Branches off change nothing.** With `branches.enabled: false` there is no `open` or `released-branch`, and every rule above reduces to
  what it was (`missingFromMain` without merges is `backported`; `heldLanded` is false without a held release).
- **Fourth Codex round (PRONTO-870).** Every refusal below is in the run's log and in the run's `why`/`cause`, never a silent skip, and each
  decision is a pure function of `cron.js` with cases (`tests/unit/cron_round4.cue`).
  - The backport check's patch ids come from two git processes whose exits are both checked (`patchIdsOf`); a failure, or a commit that changes
    the tree yet has no patch id (`patchOf`), stops the check and keeps the branch and its record. A commit is empty only with no tree change.
  - The released-branch record is checked against the exact commit a run releases on every run that can deploy main, `RELEASE_CRON_REF` too (`backportCheck`).
  - The migration check reads `git diff --name-only -z` and splits on NUL (`nulPaths`), so a path git would quote is still seen.
  - `abandon` takes the run's lock (`lockStep`, the same way a run does) before it reads `open` or `released-branch`, and holds it until its changes are done;
    a live run's lock refuses it, in the log and in the error.
  - The rehearsal child starts with `clearEnv: true` (`rehearsalSpawn`), so a removed `REHEARSE_LIVE` is not inherited.
  - A `flags-released` marker that cannot be written fails the bookkeeping with its path (`run.flagsReleased`), apart from the deploy's outcome.
  - A held release resumes at confirmation only on a post-deployment marker (`servingAfterRelease: true`); otherwise it is run again even when what
    the node reads equals the tip (`servingPlan`, `run.heldRerun`).
  - **Held releases run only from a separate trusted checkout.** When the driver is loaded from the run's own worktree (the installed scheduler's
    `wt`), a held release is refused (`held-refused`): the candidate would supply the settings and script that confirm it (`heldTrusted`).
  - **Release branches stay linear.** A tip whose merges since the cut have a nonempty combined diff (a conflict resolution) is refused
    (`resolvedMerges`, `refusedTip`): rebase the branch or cherry-pick onto it. `abandon --force` stays the way out of a branch released earlier.
  - A signal while a remote preview's `up` runs does not stop it at once (that ends only the local ssh): it waits for `up` to exit, at most
    `preview.upMinutes` (120) from its start, then stops its process group (the recorded pid, never a pattern), and only then runs `down`
    (`signalStops`, `previewUpStep`, `upExtra`).
  - `releaseCron.outcomes` (schema.cue) names every outcome (`released`, `failed`, `skipped`, `dry`, `bisect`, `stopped`, `closed`, `held`, `abandoned`,
    `held-refused`, `held-backport`, `cleared`), exported in `causes.js` with the causes; the driver and `cron.js` build them from it (`branchOutcome`), and
    pronto's metrics imports it. A run whose tree moved under the rehearsal ends `failed` with `cause: treeMoved`, an infrastructure failure that gives no verdict.
  - **Review round.** No hold is cut while the scheduler runs from the run's own checkout (`cutPlan`'s trust condition, said in the failed run's `why`), and
    `install` is refused when `branches.enabled` (the job runs from `wt`); the trust refusal of a held release is told once for each branch and reason
    (`trustNotice`). A run killed during a preview's `up` leaves `<state>/lock.preview` (the `up` pgid and its `down`, kept until `down` has run clean): the
    next to take the lock over the dead holder stops that group (TERM, then KILL, the recorded pgid only) and runs the `down` first, said in `run.reaped`.
    The launchd `ExitTimeOut` and systemd `TimeoutStopSec` (with `KillMode=mixed`) are at least `upMinutes` plus the teardown (`stopSeconds`). After a signal,
    `down` gets its grace and teardown from the moment `up` is gone (`signalDone`). The run lock is a file taken with `link(2)` (the bisect's mechanism, one
    for both), so there is no gap between its making and its pid. A refused `abandon` is also appended to runs.jsonl, naming whether a run or an abandon holds
    the lock (`holderKind`). The watch diff and the retry judgement read `-z` paths too, and a failed red verdict's cause and reason are on the run's record
    before anything that can throw.
- **While a release is held, main does not release.** A fix merged to main waits until the branch closes (released or abandoned);
  the held notice says so, and `release-cron.ts <app> abandon` is how the lead lets main release again.
- **`RELEASE_CRON_REF`** is refused while a release is held, unless it names the held branch, which then runs as any held run (it
  skips only the cut: with no release held, no branch rule applies).
- **A failure outside the rehearsal waits.** A held tip that fails in the release step, the confirm, an ssh read or the slot (no
  attempt) waits the app's gap before it runs again; a new tip runs at once.

bsoneca/pronto's ledger check, coming separately, holds the cherry-picks too. A pull request into a release branch fixes only: no
features and no flag changes (a deploy never changes behaviour; a flag is flipped on main's own schedule), and no migrations. The
branch is deleted when the guards above allow it.

## New-feature scenario failures do not block a release

pronto's gcp release decides this, not release-cron: when only scenarios a release adds fail, it releases
on stable features and prints `released on stable features; new-feature scenarios failed: a, b (absent from <commit8>, live release)`
(gcp.85-87 printed `new-feature scenarios failed, released anyway: a, b ...`; both are read).
When a run's release output has that line, the run's log line and `report` name the scenarios
(`released; new-feature scenarios failing: a, b`), and the pull request that added each is told once
(`new-feature.jsonl`), through the same path as a bisect's culprit: a comment, and the notes file of
the author session its body names (`local_<uuid>`), else of `notify.lead`. That PR is the first merge
on main's first-parent history since the last released run whose tree has the scenario's file
(`tests/scenarios/<name>.cue`, else a mention of the name in `tests/scenarios/`).

## An app off Cloud Run

An app with no `release.cue`, released elsewhere, sets `releaseCron.target`: `release`, the command
that releases the checked-out tree; `serving`, the command that prints the commit production serves
(its first word is read); and `origin`, the https address the probes ask. Both commands run in the
app's folder. A run then uses them where it would use `./saytw release@gcp` and Cloud Run's traffic:
it skips when `serving` already names main's head, releases with `release`, and confirms when
`serving` names the head and the probes answer. `ready` is not read. aprende, on Cloudflare Pages,
uses it. An app without `target` is `{kind: "cloud-run"}` and runs exactly as before.

`servingAfterRelease` (default `false`) says that `serving` reads a ref the release command writes only after the
release finished. Only then is a `release` that exits 255 (ssh's own failure, PRONTO-758) read as possibly landed: the
run reads `serving` for about 15 min and goes on to confirm if it names the head. Otherwise 255 fails the release, as
before PRONTO-758. Studio's `refs/released/studio`, written after `release@k8s` succeeds, qualifies; a deployment
worktree's HEAD does not (Bonk Chess's moves before `mise install` and `release@k8s`, so a drop after the checkout would
count as released while the old pods still serve; PRONTO-870).

## Install, pause, remove

```sh
deno run -A release-cron/release-cron.ts brawl-chess install    # worktree + ~/Library/LaunchAgents/dev.pronto.release-cron.brawl-chess.plist
deno run -A release-cron/release-cron.ts brawl-chess status     # installed? paused? the last runs
deno run -A release-cron/release-cron.ts brawl-chess report     # every release measured; the newest against the rest
deno run -A release-cron/release-cron.ts brawl-chess pause      # runs skip (logged) until resume
deno run -A release-cron/release-cron.ts brawl-chess resume
deno run -A release-cron/release-cron.ts brawl-chess uninstall  # the launchd job (or systemd timer) removed
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
record. A run never goes backwards: a ref that is a strict ancestor of the commit the last run
tried (released or failed) ends as `skipped`, leaving `last` and the gap as they were. bsoneca/pronto's `cd` workflow releases Bonk Chess this way, on its Mac's own runner, so
that app has no launchd job.

## Why launchd

(The default scheduler; `systemd` and `actions` above are the same run on Linux and under CI.)

This Mac already runs its agents through launchd (`~/Library/LaunchAgents`), and launchd
already does what a scheduled release needs. It never runs two copies of a job at once. It
catches up one missed wake after sleep instead of a burst. It keeps running without a
terminal or a Claude session. It doesn't need cron's Full Disk Access. pronto has no
scheduler of its own: its GitHub workflows are off on purpose and can't reach the local
rehearsal stack.


## Tests

[`tests.cue`](tests.cue) checks the written files and #Cron's defaults (scheduler, target, rehearsal, notify, hooks) with `cue vet`; the rules'
cases are suite `cron` of the plugins' unit cases.

```sh
./saytw --script tools.nu cue vet -c ./release-cron
./saytw --script tools.nu cue vet -c -t package=check ./release-cron/export
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- cron
```

`deno run -A tests/unit.ts cron` runs the same cases (the runner starts the `deno test` itself); a suite with no cases fails with "no cases ran".
