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

## The production guarantee

Scenarios that run on production must never touch real players, real money, or what players see:

- **The schema.** Only scenarios marked `production: true` run on production. The app's scenario
  schema limits such a scenario to one actor who never signs up. The schema allows no `pay` step,
  no other player, no table, move or game, and only GET requests. Since nothing pays, Stripe
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
