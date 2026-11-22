# A flag flip runs its flag's cases

**Status:** the plugin side was built and merged on 2026-11-04 (#65). On 2026-11-11 the owner
dropped the tester (PRONTO-284: "drop the requirement of testers for flag flips"): a flip now
writes the flag for everyone at once, then runs the cases that need no tester. Decisions 2 and 4
below record the shape it had before, and what replaced it.

**How to use it:** the [root README](../README.md#a-flip-runs-its-cases) explains the commands.
This page records why the mechanism has this shape and what was decided.

## Why

A deploy never changes behaviour; only a flag does (pronto's AGENTS.md). That rule makes the flip
the risky step. A `pronto-flags push` changes what production does with no release, so none of a
release's checks run for it: no rehearsal, no rc preview, no scenarios. On 2026-11-04, Bonk Chess's
`birosca_army` went on at 22:43 BRT, and the shop stopped taking clicks. The flag was rolled back at
22:47. Its scenarios had passed at hand with the flag `local: true`. Production still broke. Until
this change, the only check of a flip was the owner clicking around by hand.

A flip therefore needs a test of its own, and it must be:

- the same for every pronto app, not only Bonk Chess;
- run against production's real shape, before everyone gets the flag.

## What was decided

1. **A flag's cases are declared once, in CUE, on the tests.**
   - A scenario (`tests/scenarios/*.cue`) or a unit case (`tests/unit/*.cue`) names the flags it
     exercises in `flags: [...]`.
   - A scenario step's `flag: "<name>"` also counts, so the mapping is partly derived.
   - The flag itself lists nothing. A test knows what it exercises, and a list on the flag would be
     a second place to keep in step.
   - `pronto-flags cases <app-dir> [flag]` prints the mapping.
2. **No tester, no canary (since 2026-11-11).** Until PRONTO-284 a flip was first on only for
   `flagsLive.testers`, production accounts only tests signed in as, and the flag's `production`
   scenarios ran signed in as the first tester before everyone got it. Bonk Chess's tester
   account never came to exist in time, every flip waited on it, and the owner flipped with
   `--no-canary` instead (pronto-plugins#184). Now every push is that push:
   - it writes the flags as the spec says them, for everyone, in one version (`stage=all`);
   - it then runs the flag's `production` scenarios that need no tester (no `signIn` step)
     against the live site; one that signs in is listed and not run;
   - `flagsLive.testers`, `runAs` and `alert` are no longer read, and nothing is snoozed.
   The cost: a broken flag meets real players for the length of its cases (seconds) before it is
   rolled back, where the canary kept it to the tester.
3. **Nothing runs at hand.** A flip builds and launches no stack and runs no local case (the
   user, 2026-11-07: "flips must not rebuild the stack"). The pull request that set the flag's
   value passed its gate with the flag on, since every flag reads its `local` value at hand; the
   flip's own test is production. Until 2026-11-07 a flip ran `flagsCases.local`, a whole slowed
   `integrate@local`: 30+ minutes for a 12 s scenario.
4. **A push stops if any check fails, and rolls back on its own.**
   - A flag with `production` scenarios whose app lacks `flagsLive.url` or `flagsCases.live` is
     refused before anything is written.
   - A live failure, or an OFREP that never answers the new value within 90 s, writes the version
     read before the push again as the newest. The push then prints the report and exits non-zero.
   - The rollback is an ordinary version, so `history` shows it and `rollback` can undo it.
5. **No cases means no flip.** A changed flag without cases is refused.
   - `--untested "<why>"` pushes it anyway, with a loud warning.
   - Both reasons are kept on the version's metadata, so history records each untested flip.
6. **One mechanism, reused.** The push writes the same versioned object as before. The stages are
   recorded in version metadata (`stage=all|rolled-back`, `cases=…`; older versions may say `stage=testers`), which `history`
   shows. Each app's own runner (its scenario driver, `tests/unit.ts`) runs the cases. The plugin
   only selects them (`ONLY`, `UNIT_ONLY`) and sets the environment.
7. **`rollback` stays the fast way out.** It runs no cases, since turning a broken feature off must
   not wait on tests.
8. **A push is a merge, and a flip is named (PRONTO-680).** `pronto-flags push` once wrote main's spec whole
   over the live object, so a flag retired from main disappeared from production while the release
   serving it still read it, and a default changed on main landed with no one flipping it.
   - A repo pins the pronto-flags that may write (`.github/flags.pin`, PRONTO-718) and runs it through
     its pinned entry point (in pronto: `tools/flags/pronto-flags`); a write from a checkout older than the pin is
     refused, since an old one drops retired flags the release still reads. Each version records the
     plugin commit that wrote it.
   - A flip is named: `--flip a,b` (decision 10 says what it sets). A flag whose default differs and is not named
     keeps its live entry, said on stderr; a bare push flips nothing live. What `--flip` meant until decision 10
     (write the spec's whole reach: default, accounts, targeting; PRONTO-1191) is now `--sync a,b`.
   - A retirement waits for a release. A live flag the spec drops stays while the release being
     served reads it; `released.json` beside the live object (`pronto-flags released`, run by
     release-cron once production serves a release) says what it reads. With no record every flag
     counts as read, so nothing is removed before a release writes one. `--drop a,b` forces it.
   - Refusing instead would block every push from main while a retirement or an unflipped default
     awaits a release, which for a release-cron app is always.
   - `rollback` still writes an old version whole.
9. **A pass must have shown the flag at work.** A runner skips a step behind a flag
   that is off at the door, so a flip whose live site still evaluated the flag false could run
   green having exercised nothing.
   - Before the production cases, the push waits until the node's flagd answers each changed
     flag's new value for the anonymous context (OFREP, no targetingKey), flipped to true or
     not; if it never does, the push rolls back and runs no case (tested: stale flagd).
   - After each flag's cases, the output is read (`vacuous` in `flags/live.nu`). It is refused,
     and rolled back like a failed case, when it holds no `✓ <scenario>` verdict, when a verdict
     names the flipped flag in `steps behind <flags> skipped, off here` (Bonk Chess's runner
     prints it), or when a verdict counts `0 steps run`. The skipped-flag check applies only to a flag whose
     new anonymous value is true: with accounts only, or turned off, the runner skips its steps
     legitimately. The armies' push (rows, not the flag's value) gets the verdict checks alone.
   - No runner prints how many steps ran: proposed, one more clause on
     each `✓` line, `; <n> steps run, <m> skipped`, a separate pronto change. Until then the
     guard rests on the skipped-flag clause and on the missing verdict.
   - There is still no tester stage (decision 2).

10. **A flip needs no spec PR: record-back (the owner: "flag flips must not need a pronto PR").** Live is the truth
    and the spec is its record, so a flip changes production first and the spec follows.
    - `--flip X` turns X on and `--flip X=<value>` sets a bool, a string or a number, the value checked against
      the kind of the spec's default. The value comes from the command line; the spec still supplies the flag's shape
      (its `local` value, hosts and accounts), and the cases, the rollback on failure and the journal work as before.
      A bare name on a non-bool is refused, and so is a bare name where the spec says false and live says true
      (say `X=true` or `X=false`). `--flip X=false` turns it off and runs no case (decision 3). `--sync X` is the old
      meaning of `--flip`; `--drop X` stays for a live flag the spec no longer names and points a spec flag to
      `--flip X=false`.
    - After the final successful write (cases passed, a write with no production case, an off flip, a `rollback`; never
      the automatic restore after a failure; not under a dry run) `record` writes what is live into the app's
      `flags_spec.cue` through a pull request the tool opens: in a scratch worktree from a fresh `origin/main`
      (never the operator's checkout), only the literal of each such flag's
      depth-1 `default:`, and only for the flags that push wrote (`--flip`/`--sync` names; for a rollback the flags it moved), with the values of the version it wrote, kept only while live still holds them; anything else is `drift`'s. It is accepted only if `cue export -e flagd.document` moves nowhere but
      `flags.<name>.variants.default` and `cue vet` passes; then the app's generate runs, and a diff that touches
      anything outside the app (or `.github/`) is refused. One branch per app, `fix/flags-record-<app>`, rebuilt from
      main and live each time, with auto-merge armed; an open pull request gets the new head (force with lease, once
      more after a lost lease) and its body edited; where there is nothing to record or the record fails, an open record pull request naming the flags is closed. A rebuilt branch carries this push's flags plus the flags the open pull request already changes (its `Records:` line) while live still holds their values, so flipping Y before X's pull request merges records both. Only this repository's pull request by the current gh user counts.
    - A record that cannot be made (a default that is a reference or appears twice, a refused diff, no network) is
      said loudly, noted with `record: failed` in the journal, and never fails the push or reverts live. A closed
      record pull request reverts nothing either. `pronto-flags drift <app>` is the read-only check: it compares the
      reach of every flag both hold, lists the differences and the open record pull request, and exits 1 when they
      differ.
    - A plain push after an unrecorded flip leaves the flag live as it is (decision 8: a default the spec differs on is kept).

## The production guarantee

Scenarios that run on production must never touch real players, real money, or what players see:

- **The schema.** Only scenarios marked `production: true` run on production. The app's scenario
  schema limits such a scenario to one actor who never signs up. The schema allows no `pay` step,
  no other player, no table, move or game, and only GET requests, plus an anonymous POST to
  `/ofrep/v1/evaluate/flags/<name>` with only its evaluation context (it reads a flag, so a flip can hold the flag to
  answering `"value": true`). Since nothing pays, Stripe
  (live) charges nothing.
- **No sign-in.** A flip runs only the `production` scenarios with no `signIn` step, so no
  account is used at all; one that signs in (written for the tester's stage) is listed, not run.
- **The runner.** The runner refuses any scenario not marked `production` against the host that
  `flagsLive.url` names.

The plugin's own tests run every step against stand-ins for gcloud and OFREP (`fake_gcloud.py`,
`fake_ofrep.py`). No production flag was flipped while this was built.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Run the flag's cases on the rc preview | The preview reads production's flags object and has its own database. It shows the image, but not production's data or the accounts a flag actually meets. It also exists only during a release. |
| A tagged Cloud Run URL, with the flag on by host | Every actor on that host gets the flag, so scenarios would sign up fresh accounts in production's database and show up in the lobby. |
| A list of cases on each flag | It is a second place to keep in step with the tests. The test already knows which flags it exercises. |
| Warn instead of refusing | A warning is easy to miss at 22:43. Refusing, with an explicit `--untested` reason kept in history, leaves a record. |

## Open

- **At hand, a flag reads its `local` value.** The pull request's gate tests that value; the flip's
  live cases test the one production reads, for everyone.
- **Turning a flag off also runs its cases.** In an emergency, use `rollback`, not an edited spec
  and a push.
- **Release notes.** A flip's report is printed and kept on the version. It does not yet appear on
  the app's GitHub Releases (release-notes) the way a release does.

What published practice adds (staged rollout, guardrails, prerequisites), and where this falls short of it: [docs/flag-release-practices.md](flag-release-practices.md).

A flip that breaks a journey anyway is caught and undone as [docs/flag-rollback-drill.md](flag-rollback-drill.md) shows: pronto-probe alerts, naming the flip from the flags journal, and `pronto-flags rollback` restores the version before it.
