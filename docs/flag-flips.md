# A flag flip runs its flag's cases

**Status:** the plugin side was built and merged on 2026-11-04 (#65). Bonk Chess is the first app
being wired. Its production tester account is waiting on the owner's approval.

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
2. **The test user is the canary.** Flags already target accounts (`accounts`, used for the
   operator's ad trial). A flip uses that same targeting:
   - Production first reads the new value only for the app's `flagsLive.testers`, accounts that
     only tests sign in as. Everyone else keeps the old value.
   - The flag's `production` scenarios then run against the live site, signed in as the first
     tester.
   - Only after they pass is the flag on for everyone.
   - Everything stays inside flagd's JSON logic. There is no new service, no new host, and no
     preview to keep alive.
3. **The same cases run at hand first, slowed.** `flagsCases.local` runs every case of the flag
   with `SLOW=1`, before anything is written. That catches the cheap failures without touching
   production.
4. **A push stops if any check fails, and rolls back on its own.**
   - A local failure stops the push before anything is written.
   - A live failure, or an OFREP that never answers the tester's value within 90 s, writes the
     version read before the canary again as the newest. The push then prints the report and
     exits non-zero.
   - The rollback is an ordinary version, so `history` shows it and `rollback` can undo it.
5. **No cases means no flip.** A changed flag without cases is refused.
   - `--untested "<why>"` pushes it anyway, with a loud warning.
   - `--skip-live "<why>"`, for an app that has no tester yet, stops after the local cases.
   - Both reasons are kept on the version's metadata, so history records each untested flip.
6. **One mechanism, reused.** The push writes the same versioned object as before. The stages are
   recorded in version metadata (`stage=testers|all|rolled-back`, `cases=…`), which `history`
   shows. Each app's own runner (its scenario driver, `tests/unit.ts`) runs the cases. The plugin
   only selects them (`ONLY`, `UNIT_ONLY`) and sets the environment.
7. **`rollback` stays the fast way out.** It runs no cases, since turning a broken feature off must
   not wait on tests.

## The production guarantee

Scenarios that run on production must never touch real players, real money, or what players see.
Three rules hold that, each enforced by code rather than by convention:

- **The schema.** Only scenarios marked `production: true` run on production. The app's scenario
  schema limits such a scenario to one actor. That actor signs in as the tester and never signs up.
  The schema allows no `pay` step, no other player, no table, move or game, and only GET requests.
  Since nothing pays, Stripe (live) charges nothing.
- **The runner.** The runner refuses any scenario not marked `production` when it runs as a tester
  or against the host that `flagsLive.url` names.
- **The tester's identity.** The tester signs in with a passkey whose credential is kept in Secret
  Manager. That credential is imported into the browser's virtual authenticator, so no real
  person's account is used. The tester never goes online in the lobby, so no player sees it.

The plugin's own tests run every stage against stand-ins for gcloud and OFREP (`fake_gcloud.py`,
`fake_ofrep.py`). No production flag was flipped while this was built.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Run the flag's cases on the rc preview | The preview reads production's flags object and has its own database. It shows the image, but not production's data or the accounts a flag actually meets. It also exists only during a release. |
| A tagged Cloud Run URL, with the flag on by host | Every actor on that host gets the flag, so scenarios would sign up fresh accounts in production's database and show up in the lobby. |
| A list of cases on each flag | It is a second place to keep in step with the tests. The test already knows which flags it exercises. |
| Warn instead of refusing | A warning is easy to miss at 22:43. Refusing, with an explicit `--untested` reason kept in history, leaves a record. |

## Open

- **Bonk Chess's tester.** Making the production account is an owner-approved step. Until it
  exists, Bonk Chess pushes with `--skip-live`.
- **At hand, a flag reads its `local` value.** When the new production `default` differs from
  `local`, the at-hand run does not test the value production will read. Push could warn when the
  two differ.
- **Turning a flag off also runs its cases.** In an emergency, use `rollback`, not an edited spec
  and a push.
- **Release notes.** A flip's report is printed and kept on the version. It does not yet appear on
  the app's GitHub Releases (release-notes) the way a release does.
