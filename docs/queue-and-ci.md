# The queue and ci: one Mac, many jobs

How bsoneca/pronto keeps gates, stacks, releases and `cue` from starving each other on one Mac, and
how a project built on pronto-plugins adopts it. Written 2026-11-23 from pronto's `origin/main` and
the queue work of 2026-11-05 to 2026-11-22 (PRONTO-841, 851, 870, 873, 738, 894).

Each section gives the problem, the mechanism, the knobs and how to adopt it. Where a piece lives
only in pronto, the section says so.

## Where each piece lives

| Piece | In pronto-plugins | Only in pronto |
| --- | --- | --- |
| Slots, weights, release hold (sections 1, 2) | `harness/files/tests/slot.ts` | measured weights: `apps/brawl-chess/README.md`, "Weights are measured" |
| cue budget, caches, watchdog (3) | `machine/` | the dashboard, `tools/machine/` |
| Unit selection (4) | `harness/files/tests/unit.ts`, `tests/unit/select.js` | `docs/test-selection.md` |
| Scenario selection (4) | `harness/files/tests/scenarios/select.ts` | each app's `select` declarations |
| Gate key (5) | `gcp/engine/local-gate-key.nu` | `.github/workflows/gate.yml`, `ci.yml` |
| Run folders (6) | `harness/files/tests/slot.ts` | none |
| Hung pages, throttling (7, 8) | `harness/files/tests/slow.ts`, `tests/scenarios.ts` | scenario CUE in `apps/*/tests/scenarios/` |
| Runner pools (2) | `runners/` (how to register runners) | `docs/queue.md`, `.github/workflows/` |

An app gets the harness files from `bin/pronto-harness <app-dir>`, never by hand
(`harness/README.md`). The machine is set up once per Mac with `bin/pronto-machine install`.

## 1. One machine-wide budget

**Problem.** Local stacks, gates and rehearsals each used every core they could. Load reached 64
to 131 on an 18-core Mac, renderers wedged, and a page's first request for its flags timed out
(the rehearsal of 2026-11-03, and again 2026-11-19).

**Mechanism.** `tests/slot.ts` is a static semaphore, the same file in every app. It admits by what
a job declares, not by what it measures when it starts.

- A **slot** is a stack's ports (33000 + 100 per slot) and its own copy of the app.
- A **weight** is a plain count of cores the holder keeps busy. Defaults: launch 1/2, stack 1,
  gate 3, rehearsal 6, scenarios pass 6, Premium lane 2.
- The **budget** is every core but a reserve of 3: 15 on an 18-core Mac.
- A claim is admitted when the weight held, the weight of every older ticket and its own fit the
  budget. First come, first served, so a heavy claim is never starved by light ones. The oldest
  ticket is admitted on an empty pool whatever it weighs.
- A claim inside a live holder (by process tree, `STACK_JOB` or `STACK_SLOT`) is nested: admitted
  at once, adds no weight. Waiting for its own holder would wait for ever.
- Every claim frees what dead pids left: jobs, tickets, slots, browsers, and the System V shared
  memory segments of dead postgres (macOS allows 32).

**Weights are measured, offline.** A weight is the mean of the holder's process-tree CPU over the
samples where it uses at least 0.1 core, rounded up to the next half. The pool adds declared
weights and compares the sum to cores, so the sum of busy means is the load the holders add. A mean
over the whole life lets idle stretches under-count; the p90 charges every holder its burst at
once. Measured 2026-11-05 (10 695 samples), and for gates again 2026-11-19 (about 2.9 cores). A
weight is never read off a saturated machine: each figure is a lower bound, so move a weight only
where the measure is far from it. The tables are in `apps/brawl-chess/README.md` (pronto only).

The pool sees only part of the load. On 2026-11-05 about 17 percent of the busy cores ran in a
holder's process tree; the rest was `cue` evaluations and sessions outside it. That is why
section 3 exists.

**Admission by measured load** exists in one case: beside a release (section 2), a claim is
admitted while the machine's one-minute load is under `STACK_HOLD_LOAD`.

**Knobs.**

| Name | Meaning | Default |
| --- | --- | --- |
| `STACK_POOL` | the pool directory, shared by every checkout on the machine; leave it unset on the owner's account: a second pool is invisible to the first (PRONTO-774), so `slot.ts` warns of it and `pronto-machine install` refuses a shell file that sets it, even to the default path spelled out. A pr runner's own pool (`/tmp/pronto-stacks-<user>`, read with `STACK_HOLD_POOL`) is on purpose and draws no warning | `/tmp/pronto-stacks` |
| `STACK_BUDGET` | the weight budget | cores minus `STACK_RESERVE` |
| `STACK_RESERVE` | cores kept for what runs outside the pool | 3 |
| `STACK_WEIGHT`, `--weight <n>` | a job's weight | by verb |
| `STACK_SLOT` | ask for a slot by number | none |
| `STACK_WAIT_MINUTES` | a claim fails after this long with no progress ahead of it | 120 |
| `--what <label>` | the job's name in `status` | none |

**Adopt.**

```sh
bin/pronto-harness <app-dir>                       # writes tests/slot.ts into the app
deno run -A tests/slot.ts --weight 1 --what "unit tests" -- ./saytw test
deno run -A tests/slot.ts status                   # who holds what
```

Wrap every heavy command, not only stacks: a gate step, a build, a local-model job (give a GPU job
at least `--weight 2`). Copy `slot.ts` unchanged: pronto's guard fails an app whose copy differs.

## 2. cd and ci on separate queues

**Problem.** A release waited for pull-request work and pull-request work waited for a release.
The owner (2026-11-07): "cd must not compete with ci." The causes were `slot.ts` blocking every
non-release claim while `~/.cache/pronto/release-active` was live, and cd's plan and mirror jobs
sharing runners with ci.

**Mechanism, in two layers.**

1. **Runners.** GitHub's queue is the only queue between jobs. Each kind of work has its own pool,
   so one never takes another's runner (`docs/queue.md` in pronto):

   | Runner label | Runs |
   | --- | --- |
   | `pronto-gate` | a pull request's `generate`, `lint` and unit tests, one app per runner |
   | `ci-light` | seconds of git and `gh`: `changed`, final jobs, automerge |
   | `pronto-mac` | ci's `check`, the scans and the reviews |
   | `pronto-plan` | cd's plan, mirror and release-cron ticks |
   | `pronto-release` | cd's releases, one per app |

   The lead's notes also name `pronto-gate-k8s`, a planned gate pool; no workflow on main uses it
   yet. A push cancels the pull request's older gate. Queued `release-plan` jobs collapse to one
   per trigger kind (cd.yml's concurrency group).

2. **The Mac's budget.** #809 (2026-11-07) gave `slot.ts` a release lane (`STACK_RELEASE_LANE`, 8)
   and a ci lane (`STACK_CI_LANE`, 3), so neither queue blocked the other. PRONTO-894 (2026-11-19
   and 20) replaced the lanes: both variables are now accepted and ignored. The rule today:
   - A claim made with `STACK_PRIORITY=release` and weight above 0 is a **release**. While one
     holds or waits, every other weighted claim waits ("Gates wait", 2026-11-19). The wait does
     not use up `STACK_WAIT_MINUTES`.
   - **Beside a release** (2026-11-20, "Admit while there's room"): while a release holds a slot
     and none waits for one, another claim is admitted when the one-minute load is under
     `STACK_HOLD_LOAD` (one per core) and its weight fits beside the holders and older tickets.
     A release claim waits only for room beside the holders and skips other claims' tickets.
   - A runner job (`GITHUB_ACTIONS=true`) is admitted at once on cores when no release holds,
     since its pool is its cap. Waiting here as well would queue it twice.
   - A release counts only if its process started before its record, and for
     `STACK_RELEASE_HOLD_MAX` hours (12), so a hung release stops holding.
   - Weight-0 claims (cue memory alone, watches) and nested claims are never held. So are ci's
     `security` scan and the Codex reviews, by exception (2026-11-22): a rehearsal once held all
     three `pronto-mac` runners in that wait for 40 minutes.

   The exact cases live once, in `slot.ts`'s header, "A release holds the machine".

**Knobs.** `STACK_PRIORITY=release`, `STACK_HOLD_LOAD`, `STACK_RELEASE_HOLD_MAX`. For a release run
by another account, `STACK_HOLD_POOL` and `STACK_HOLD_UID` (read-only and cooperative, no security
boundary). Runner labels are each job's `runs-on`.

**Adopt.** Put each kind of work on its own runner label; `runners/README.md` registers runners
(`hostRunners` in `runners/setups.cue`). Have the release run claim with `STACK_PRIORITY=release`.
Never design a mechanism where one queue waits on the other. Pronto only: the workflows and
`docs/queue.md`.

## 3. The cue memory budget

**Problem.** A `cue vet -c ./spec` of a large spec holds 16 to 17 GB for about a minute. On
2026-11-05 at 07:35 BRT, 21 `cue` processes held 210 GB of a 128 GB Mac and macOS ran out of
memory and swap. `GOMEMLIMIT` does not help (the memory is live data), macOS ignores `ulimit -v`,
and there are no cgroups. Specs are never slimmed to fit the machine.

**Mechanism.** `machine/cue`, a wrapper first on the PATH of every `mise exec`, `mise run` and
activated shell. A command that evaluates (`vet`, `export`, `eval`, `def`, `cmd`, `trim`) claims
memory and cores from a budget of its own through `tests/slot.ts --mem <GB> --cores-claim <n>`.

- The line is `<pool>/cue-queue`, strictly first come first served, with older tickets' room
  reserved, so a small claim never passes a large one.
- The memory claim is the last peak plus a quarter, learned per repository, folder and arguments in
  `~/.cache/pronto/cue-mem`. Never seen: the largest peak learned in its folder, else 16 GB.
- While it runs, the holder rewrites its record each second with its real resident size.
- Under 20 percent free memory, nothing is admitted but the head of an empty line.
- A top-level `--weight` beside `--mem` makes an evaluation weigh cores in the stacks' budget too.
  A nested one weighs none.
- **Only what changed is vetted and exported** (`machine/vetted.ts`). A `cue vet` is cut into
  packages, each keyed by the SHA-256 of what it reads; a package that passed anywhere on the
  machine is not evaluated again. Exports are replayed from `~/.cache/pronto/cue-exported`. In
  pronto, aprende's vet went from 20 GB and 5 minutes to a tenth of a second on an unchanged tree.
- **The watchdog** (`machine/watchdog.sh`, launchd, every 10 s) kills a `cue` above the whole
  budget, and the largest one under memory pressure. A `cue` killed under pressure is queued
  again once. A hot `cue` outside the pool is moved to background priority.

**Knobs.**

| Name | Meaning | Default |
| --- | --- | --- |
| `CUE_MEM_GB` | memory budget | half of RAM |
| `CUE_CORES` | cue core budget | cores minus `STACK_RESERVE` |
| `CUE_MIN_FREE_PCT` | free-memory floor | 20 |
| `CUE_UNKNOWN_GB` | claim for a never-seen evaluation | 16 |
| `CUE_DIRECT_GB` | under this, run at once | 1 |
| `CUE_MAX_CORES` | `GOMAXPROCS` cap | 7 |
| `CUE_WATCHDOG_MAX_GB` | kill threshold | RAM minus 32 |
| `CUE_BUDGET=off`, `CUE_VETTED=off`, `CUE_EXPORTED=off` | skip one part, for one command | on |

**Adopt.**

```sh
bin/pronto-machine install        # wrapper and watchdog; again after a change to machine/ or slot.ts
sudo bin/pronto-machine shm       # postgres shared memory, once per Mac
```

It works on any pronto runtime, upstream's included; nothing in the app fronts `cue`. A `cue` run
outside mise is not budgeted. The dashboard (`tools/machine`) is pronto only.

## 4. Test selection and caching

**Problem.** Every gate reran every suite and every scenario, for a one-line change.

**Unit suites** (`tests/unit.ts` with `tests/unit/select.js`). A suite whose inputs hash as they did
at its last green run is reported `cached` and not run, as Bazel skips a test it has seen pass. The
key is the SHA-256 of the suite's own cases, the runner, the toolchain locks, every module the
cases can reach (`deno info`), every file, directory, variable and command the run itself read, and
the Deno version. A red run leaves no record; a suite that reached another machine keeps none.
Records are `.task/unit/<suite>/<slot>.json`; ci shares `~/.cache/pronto/unit/<project>` across
runners. `UNIT_ALL=1` runs everything, and pronto's gate uses it, since the key cannot see reads
inside npm packages and similar. Measured 2026-11-01 on brawl-chess: `test` took 46 s with every
suite, 8 s with nothing changed and 14 s with one case changed.

**Scenarios** (`tests/scenarios/select.ts`). A scenario is skipped when it has a green record and
the change since main touches nothing it exercised. A green run records its steps, its
environment, the requests its pages made and the hash of every static asset it loaded. A changed
file is judged by kind: documentation and other checks' runners are inert; a client source is
judged by the bytes the live stack serves; a changed `*.sql` is attributed by the tables and
functions the scenario's requests named, to a fixpoint. Anything else fails open and runs every
scenario. Selection and throttling happen only in a by-hand run (`INTEGRATE_LOCAL_DRIVERS=all`).
`SCENARIOS_ALL=1` runs every one; `SCENARIOS_BASE=<ref>` names the base (a merge checkout at depth
2 needs `HEAD^1`). Since 2026-11-19 (PRONTO-871) a pull request's gate runs unit tests only and
the release rehearsal runs every scenario, so main is not known green: the diff-based skip is
advisory between verified revisions.

**Adopt.** An app adds only `tests/unit/suites.cue`, `registry.js`, `probes.js` and, where a suite
needs setup, one small file per suite. Tests are CUE data (`tests/unit/schema.cue`), never
hand-written code. A scenario's `select` declarations (client prefixes, derived prefixes,
`outside`) are the app's own. Pronto only: the measured tables and the app declarations in
`docs/test-selection.md`.

## 5. Gate reuse

**Problem.** The same tree was gated again and again: by the engineer, by ci, by the release.

**Mechanism.**

- **A pass key per tree.** `gcp/engine/local-gate-key.nu` hashes the app's files as git lists them
  (tracked and untracked, not ignored) and the pronto files the gate runs. A passing
  `integrate@local` with every scenario stamps `~/.cache/pronto/local-gate/<app>/<key>`, and
  `release@gcp` of the same tree skips its own local gate.
- **A deploy-shaped key.** Unless a deploy-shaped file changed since the last release that passed
  the rc preview (`release.cue`, compose files, `infra/`, pins, Dockerfiles), the release skips the
  preview too. `--rc` forces it. So run the gate on the tree you release, and do not edit between.
- **Lint skipped on a passed tree.** bayt fingerprints a target and skips one whose inputs passed.
- **Guards under `test`, not `lint`**, because `lint` is skipped on a tree it already passed.
  `guard-generated` fails when a generated file differs from the committed one; `guard-image`
  fails when a file a test reads at run time is not in the image it runs in (both
  `harness/files/tests/lint.ts`). Each once failed only at a release.
- A pull request's gate no longer stamps. The evidence before a release is the rehearsal's.

**Adopt.** Use the engine (`bin/pronto-gcp --engine`) for the keys and stamps. Pronto only: the gate
and ci workflows, which choose the projects a pull request changes.

## 6. Stacks out of `$TMPDIR`

**Problem.** macOS's `com.apple.bsd.dirhelper` runs daily at 03:35 and deletes files in `$TMPDIR`
older than 3 days. A stack's served folder lived there, and its copies kept their sources' old
times. A rehearsal running at 03:35 lost every old static file: caddy answered 404 for fonts,
sounds and pages (release-cron run 3e2b249e, 2026-11-19, PRONTO-851).

**Mechanism.** A launch's and a gate's work folders (`slot.<pid>.*`, `gate.<pid>.*`) live in
`STACK_RUNS`, default `~/.cache/pronto/stacks`. A claim removes those whose pid is dead and that
are a day old.

**Signs.** A burst of static 404s, or scenario failures that begin right after 03:35. Check the
caddy 404 rate per minute and any `work/served/srv` entry with a 03:3x mtime before tracing
anything else.

**Adopt.** Take `slot.ts` from the harness, and set `STACK_RUNS` to a durable path if the default
does not suit. Keep any other long-lived work folder out of `$TMPDIR` too.

## 7. Hung pages

**Problem.** A call to a page whose renderer crashed waits for ever, so a scenario hung and
wedged the gate (PRONTO-738).

**Mechanism** (`harness/files/tests/scenarios.ts`). A page that does not answer for a minute is
marked silent, and is never asked anything again. Then:

- Slowed, and with no JS to pause, it is a fault of the browser's CPU throttling: only this
  case, a wedged browser, is run again (`tests/slow.ts`), twice at most.
- Unthrottled, or paused with frames in the app's own code, it is the app's loop, and the
  scenario fails. A renderer that crashed is never run again either.

**Rule.** A flake is a bug in the app or the harness, fixed at its cause. A retry, a longer
timeout or a fixed sleep that makes it pass is not a fix. Find a scenario's actors by id, never by
a name an earlier run left. Read a response as it arrives, not after a reload. No rehearsal,
release or by-hand run retries an ordinary scenario failure.

## 8. Throttling

**Problem.** A page throttled to a slow phone busy-waits about a core of the laptop, so a gate that
throttled every page cost more as the game grew. A race that only a slow page loses must still be
caught before a release.

**Mechanism** (`harness/files/tests/slow.ts`). `SLOW=1` slows a page's CPU 4 times and each
request by 300 ms on a 10 Mbit/s line; `SLOW=<cpu>,<ms>` names its own. A page is throttled only
while a step drives it.

- In a by-hand gate (`INTEGRATE_LOCAL_DRIVERS=all`, `SLOW` unset), only scenarios marked
  `slow: true` in their CUE are throttled. The rest run fast. `SLOW=0` turns it off.
- The release rehearsal throttles every scenario, in two serial passes. `SCENARIOS_ALL=1` runs
  every scenario unthrottled.
- Layout and speed checks stay throttled: the visual lint, the menu budget, Premium.
- The weight follows: a gate weighs 3, 6 when every page is throttled, 1 otherwise.

**Seek scenarios share one matchmaking pool** (PRONTO-873). Scenarios run on one stack, so their
seeks queue together: a seek pairs with any other seek at its clock. A scenario that waits
therefore seeks at a clock no other scenario uses, so none can take its opponent. Bonk Chess:
`seek_race` 3+2, `seek_notify_wake` 1+0, `seek_notify` 15+10, `seek_human_first` 5+0. Say the
clock in the scenario's header, and give a new waiting scenario one of its own.

## 9. What comes next: modular design

**Problem.** One 14 MB CUE package made aprende's lint take 47 minutes. Selection and caching key
on files; a monolithic spec is one file set.

**Plan.** The plugin is in this repository (`modular-design/README.md`, `bin/pronto-modular-design`).
It splits an app's design into small independent CUE modules (one aprende subject, one Bonk army,
the Journey). Each module is vetted and exported alone and cached by content hash. A dependent
reads a module's exported JSON under a schema, not its source. ci and test selection key on the
module. What comes next is moving the large specs onto it, after the queue work above. It pays only
when the design's own `cue export` is the cost: measure first. "Smaller cues, faster builds" (the
owner, 2026-11-07). Splitting is not slimming: a spec's content is never cut to fit the machine.
Say "modules", not "chunks".

It builds on section 3's export cache and section 4's keys.
