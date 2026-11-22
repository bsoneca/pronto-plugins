# machine: specs of any size, one machine

A CUE evaluation of a large spec holds tens of GB: `cue vet -c ./spec` of `apps/aprende` peaks at
16-17 GB for about a minute, and grows by about 2 GB with each ENEM edition. On 2026-11-05 at
07:35 BRT, 21 `cue` processes held 210 GB of this 128 GB Mac and macOS ran out of memory and swap
(`/Library/Logs/DiagnosticReports/JetsamEvent-2026-11-05-073538.ips`). `GOMEMLIMIT` does not help
(the memory is live data), macOS does not enforce `ulimit -v`, and there are no cgroups. Specs are
not slimmed to fit: the tooling makes room for them.

What one Mac holds so that every app's specs, stacks and gates share it (PRONTO-484, formerly
bsoneca/pronto's `tools/cue-budget` and `tools/sysv-shm`). It works on any pronto runtime, upstream
bonisoft3/pronto's too: nothing in an app or in the runtime has to front `cue`, because the
installed wrapper stands first on the PATH of every `mise exec`, `mise run` and mise-activated shell.
A mise shim (`~/.local/share/mise/shims/cue`) does not: it runs the tool's own `cue`, not the PATH's,
so the wrapper, run first by a shell that has the shims, starts it again through `mise exec` once. pronto-fork's runtime still carries
the same wrapper at its root (`cue`, with `cue-budget/slot.ts`); the two claim once between them.
`slot.ts` here is the harness's (`harness/files/tests/slot.ts`, a link), the same file as every app's.

- **The budget** (admission). `cue` here stands first on the PATH mise builds on the Mac (`mise exec`,
  `mise run`, an activated shell, not a shim): the installer puts its folder in the global mise
  config's `env._.path`, which mise puts ahead of every tool (the runtime's wrapper behind it sees
  the claim already made and passes the call through). So every `cue` an app's tooling runs through mise (bayt's generate rules,
  `tools run-cue`, `run-mise exec -- cue`, lint's `cue vet`, unit tests and drivers, the Studio
  builder, a Studio user's own repository, the CI runners on this Mac) comes through it. A command
  that evaluates (`vet`, `export`, `eval`, `def`, `cmd`, `trim`) claims its memory and cores from the
  cue memory budget of the machine-wide pool, `tests/slot.ts --mem <GB> --cores-claim <n>` (the same
  slot.ts every app has, copied beside the wrapper), and waits its turn in line when they are spoken
  for (PRONTO-870: this replaced the cue lock, one evaluation at a time, which kept a gate's generate
  in line for 44 of 92 minutes to do about one minute of work; learned peaks on the 128 GB Mac are
  p95 0.5 GB, p99 2.2 GB, largest 26.7 GB). The budget is `CUE_MEM_GB` (half the machine's memory; one evaluation at a time where that cannot be read) of memory and `CUE_CORES`
  (every core but `STACK_RESERVE`, 3) of cores, so several evaluations run at once while their claims
  fit. The line is strictly first come first served: a claim is admitted when what the live holders
  hold, what every older ticket reserves and its own fit, memory and cores alike; so a small claim never
  passes a large one that waits, and the oldest ticket is admitted on an empty pool whatever it
  claims. The memory claim is the evaluation's peak the last time, a quarter more, learned per
  repository, folder and arguments in `~/.cache/pronto/cue-mem`; an evaluation never seen claims the
  largest peak learned in its folder (`cue-mem/folder/<md5 of repository and folder>`) a quarter more,
  else 16 GB (`CUE_UNKNOWN_GB`). Its cores are what it kept busy the last time (2 when never measured),
  at most the cap below. They are counted in the cue budget's own cores, not in the stacks' weight
  budget (claiming them there, e8e3226 / PRONTO-761, was reverted in PRONTO-838: a local cue waited
  for room while runner jobs, admitted outside it, held more than all of it). One that held under
  1 GB (`CUE_DIRECT_GB`) and every command that evaluates nothing (`fmt`, `mod`, `version`) runs at
  once; one that kept 2 cores busy for 30 CPU seconds is claimed even when it held under 1 GB.
  While it runs, its holder records its resident memory every second, for its next claim and so that
  one grown past its claim counts at its real size; a holder alive whose child has been dead for a
  minute counts for nothing. While the machine's free memory (`kern.memorystatus_level`) is under 20 %
  (`CUE_MIN_FREE_PCT`) the pool admits nothing but the head of the line on a pool holding no cue memory.
  A holder record or ticket without a `mem=` (a `slot.ts` from before the budget) claims the whole
  of `CUE_MEM_GB`: it blocks as the lock did. Its parallelism is bounded, not only claimed: `GOMAXPROCS`
  is set, unless already set, to 7 (`CUE_MAX_CORES`) or the stacks' budget, whichever is smaller.
  Inside a gate, a rehearsal or a stack (a live holder above it in the process tree, or named by
  `STACK_JOB` / `STACK_SLOT`) it waits only in the cue line, never for its holder's cores.
  `CUE_BUDGET=off` skips the budget for one command.
- **Only what changed is vetted** (`vetted.ts`). Every app's lint runs `cue vet -c ./...`, and the
  same CUE used to be evaluated again in each worktree's gate, on each ci runner that checked the pull
  request, on main after the merge, and in every pull request that touched none of it: for aprende,
  20 GB and 5+ minutes each time (2026-11-07, the largest load on this Mac). CUE is declarative, so
  a vet's answer depends only on what it reads. A claimed `cue vet` is cut into its packages; each is
  keyed by the SHA-256 of the files vetting it reads (its folder's CUE and its parents' of the same
  package, every module package it imports, transitively, the files their `@embed`s name, cue.mod),
  its flags and the cue binary; a package whose key passed before, anywhere on the machine, is not
  evaluated again, and the rest are vetted in one run whose pass records their keys
  (`~/.cache/pronto/cue-vetted`, kept 30 days). So an unchanged tree vets in a tenth of a second, and
  a pull request re-vets only the packages its change reaches. A vet it can't key (stdin, `-T`, an
  `@embed` it does not read) runs as asked; `CUE_VETTED=off` vets every time.
- **Only what changed is exported** (`vetted.ts` again). Every `cue export` of one package, claimed or run at once, is
  keyed the same way, plus its `-t` tags (a file an `@if` leaves out is not read), `-e` and `--out`;
  its output is kept in `~/.cache/pronto/cue-exported` (30 days, 8 GB: `CUE_EXPORTED_GB`) and printed
  again for the same key without evaluating. Only a passing export whose inputs held still while it
  ran is kept. A hit costs a deno start (about 0.1 CPU-s), so an export run at once that took less CPU than
  `CUE_REPLAY_MIN_S` (0.3 s) the last time (learned beside its peak, `<id>.secs`) is evaluated, never looked up;
  aprende's unchanged spec build went from 11.5 to 3.6 CPU-s when its modules' exports, each under 1 GB, began to
  be replayed (PRONTO-11); `-o`, stdin and several packages run as asked; `CUE_EXPORTED=off` exports every time.
- **Its caches are measured** (PRONTO-31). Every claimed vet and every export appends a line to
  `~/.cache/pronto/cue-cache.log` (rotated at 10 MB to `cue-cache.log.1`), tab-separated: epoch seconds,
  kind (`vet`|`export`), outcome (vet: `hit` all packages skipped, `partial` some, `miss` none; export:
  `hit`, `miss`; either: `unkeyed`), the folder (the git prefix), the seconds the evaluation took (0 for a
  hit; the wait in the pool included), the seconds saved and the seconds waited in the pool before it was
  admitted (a 7th column, 0 for a hit or one run at once; readers that take the first six columns are
  unaffected). What a hit saves is stored when the entry is: an
  export's `<key>.secs` beside it, a vet's package's file under `cue-vetted` (the run's seconds over its
  packages); a partial vet saves the sum of the skipped packages'. Logging is best effort and never changes
  an exit code or output. bsoneca/pronto's machine dashboard (tools/machine) counts the log per kind and app over 24 h and 7 d.
- **The watchdog** (backstop). `watchdog.sh`, launchd job `dev.pronto.cue-watchdog`, every 10 s:
  kills a `cue` above the whole memory budget (RAM but 32 GB, 96 GB here: `CUE_WATCHDOG_MAX_GB`), which no evaluation can hold on this machine, and, when memory available
  (`kern.memorystatus_level`) is under 10 % and swap in use over 8 GB, the largest `cue`, one per
  pass. Each kill is a line in `~/Library/Logs/pronto/cue-watchdog.log` (BRT, pid, size, reason,
  level, swap, folder, command). A cue killed under pressure, not for its own size, is put in line
  again once by its holder, with its peak as its claim, so it is still evaluated. A `cue` that no
  pool holder is above, and that used over 200 % CPU (`CUE_WATCHDOG_HOT_PCT`) in two passes in a row,
  is moved to background priority (`taskpolicy -b`) and logged, never killed.

- **Shared memory** (`sysv-shm.sh`, as root). Every postgres cluster takes one System V segment and
  macOS allows 32 on the whole machine; a full machine of stacks passes that, and the next database
  exits at start. It raises the limits now and at every boot (launchd `dev.pronto.sysv-shm`).

```sh
bin/pronto-machine install           # install, or update after a change here or to the harness's slot.ts
bin/pronto-machine remove            # take it out
sudo bin/pronto-machine shm          # shared memory, once per Mac (--remove to undo)
```

## Tests

`deno test -A machine/tests/cue_test.ts`: the wrapper against a fake cue, each case with its own
PATH, HOME and pool: what passes through at once, what claims, what it learns, stdin and signals, two
wrappers on one PATH, what vet and export replay, and the budget (evaluations that overlap or wait,
strict first come first served, legacy holders, dead holders).

A `cue` run outside mise (a shell without mise, a binary called by path) is not budgeted; the
watchdog still sees it, and slows it when it keeps many cores busy.
