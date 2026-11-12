# Releasing flags safely: practice, and where pronto-flags falls short

**Why this page:** a release engineer turns flags on in production, one at a time, and removes them once
they are on (the owner, 2026-11-12). This page collects the published practice for that job and compares
it with what [`pronto-flags push`](flag-flips.md) does today. Each gap is a filed issue (PRONTO-411's
research; the gaps are PRONTO-412 to PRONTO-418). Claims are paraphrased; each names its source.

Evidence: the flagd, OpenFeature, Fowler/Hodgson, Google SRE and LaunchDarkly/Unleash pages are primary.
Dwell times per stage and "when to flip" come from vendor blogs or are our own policy, and say so.

## 1. Progressive rollout

- **Canary, then widen.** Turn the feature on for a small, consistent, randomly chosen share of users,
  compare their metrics with everyone else's, then widen ([Fowler/Hodgson, Canary releasing][fowler]).
  A chosen group (staff, one tenant) first is the "champagne brunch" variant of the same idea.
- **A ladder with exit criteria.** The common ladder is 1–5%, 25%, 50%, 100%, or rings (developers,
  staff, everyone) ([LaunchDarkly, release management][ld-release]). Each stage moves on when criteria
  written beforehand hold, not when a timer ends. Dwell times are not standardised: vendor blogs suggest
  1–2 days for staff, days for a small canary, and 48–72 h of watching at 100% ([ConfigCat][configcat]).
- **Small and long enough.** A canary is small so a bad change spends little error budget, and lasts long
  enough to see a representative sample, peak hours included ([Google SRE Workbook, Canarying releases][sre]).
- **Sticky buckets.** A user keeps their variant: Unleash hashes the user id ([Unleash, activation
  strategies][ul-strategies]), Flagsmith hashes identity and segment and only adds users as the percentage
  rises ([Flagsmith, rollout by percentage][fs-pct]), and LaunchDarkly switches each context once
  ([LaunchDarkly, progressive rollouts][ld-progressive]).
- **One mechanism per flag at a time.** LaunchDarkly refuses a guarded rollout, a progressive rollout and
  an experiment together on one flag ([LaunchDarkly, guarded rollouts][ld-guarded]).

## 2. Guardrails and automatic rollback

- **User-facing signals, few of them.** Prefer error rate and latency over CPU or memory, keep the set
  small, and pick metrics attributable to the change whose interval fits inside the watch window ([SRE][sre]).
- **Exposed against unexposed, at the same time.** Before/after alone is weak, since time moves metrics;
  compare the canary with a concurrent control, per population, and also against absolute SLO limits ([SRE][sre]).
- **Business metrics too.** Conversions belong beside errors and latency, watched before, during and
  after ([LaunchDarkly, release management][ld-release]).
- **Automatic rollback with statistics.** LaunchDarkly's guarded rollouts attach metrics to a rollout, test
  sequentially, call a regression only when the whole interval is on the harmful side, and roll back
  ([LaunchDarkly, guarded rollouts][ld-guarded]).
- **Low traffic proves little.** Each step needs a minimum sample; LaunchDarkly rolls back a step that lacks
  it. With little traffic, extend the stage or widen the cohort, or add synthetic probes ([SRE][sre], [LaunchDarkly][ld-guarded]).

## 3. Kill switches

- Ops toggles let operators turn a feature off without a release; a few stay for good as kill switches
  ([Fowler/Hodgson, ops toggles][fowler]). Unleash lists a kill switch as permanent and an operational flag
  as 7 days ([Unleash, feature flags][ul-flags]).
- The code's own default must be the safe, old behaviour, so a flag service that is down changes nothing
  ([Unleash, best practices][ul-best]); flagd answers a `DISABLED` flag with no value and the code default
  ([flagd, flag definitions][fd-defs]).
- A release flag is the emergency off switch while it exists ([LaunchDarkly, release management][ld-release]).

## 4. Flag types and lifetimes

- Release, experiment, ops and permission toggles differ in how long they live and how dynamic they are
  ([Fowler/Hodgson, categories][fowler]). A release toggle lives a week or two ([Fowler/Hodgson][fowler]);
  Unleash expects 40 days ([Unleash, feature flags][ul-flags]).
- Configuration that never changes at run time is not a flag ([Unleash, at scale][ul-scale]).

## 5. Flag debt and removal

- File the removal when the flag is made, give it an expiry, and fail a test once it is past
  ([Fowler/Hodgson, carrying cost][fowler]).
- Detect staleness: LaunchDarkly marks a flag *launched* when it served one variation to all for 7 days
  and *ready to archive* when inactive, 30+ days old, unreferenced and no one's prerequisite
  ([LaunchDarkly, flag status][ld-status]); Unleash marks flags past their expected life as stale
  ([Unleash, technical debt][ul-debt]).
- Remove the code first, confirm with a code-reference scan, then archive; never reuse a key
  ([LaunchDarkly, technical debt][ld-debt], [Unleash, at scale][ul-scale]).

## 6. Dependencies, and one flag at a time

- A prerequisite gates a dependent: while it is off, the dependent serves its off variation, and a flag with
  dependents cannot be archived ([LaunchDarkly, prerequisites][ld-prereq]). Unleash warns that hierarchies
  add complexity and prefers independent flags ([Unleash, at scale][ul-scale]).
- n flags make 2^n states, but most never meet: test production's mix, all off, and sometimes all on
  ([Fowler/Hodgson, validation][fowler]).
- Run one canary at a time so signals are not confounded ([SRE][sre]).

## 7. When to flip

No primary source sets a window. Our policy: flip on a weekday in daytime with someone watching, outside
the app's peak and outside a release run (release-cron's), and count a flip as done only once its watch
window has passed. Sourced in part: a canary window should include peak load ([SRE][sre]), and Unleash
advises approvals for sensitive changes ([Unleash, at scale][ul-scale]).

## 8. Before and after

- Keep an audit trail of who changed what and when ([Unleash, at scale][ul-scale]).
- Mark each flip on the dashboards it may move, as an annotation ([Grafana, annotations][grafana]).
- Tag telemetry with the flag's variant: flagd returns OpenTelemetry-shaped details with each evaluation
  ([flagd, feature flagging][fd-concepts]) and exports `feature_flag.flagd.impression` and
  `feature_flag.flagd.result.reason` ([flagd, monitoring][fd-monitoring]); OpenFeature's `after` hooks and
  `PROVIDER_STALE`/`PROVIDER_ERROR` events serve the same end ([OpenFeature, hooks][of-hooks], [events][of-events]).

## 9. flagd and OFREP

- **`fractional`** splits by relative weights: `["on", 5], ["off", 95]` is 5% on. Its default bucketing
  key is the flag's key plus `targetingKey`, so a flag's buckets differ from another's; renaming the flag,
  reordering variants or upgrading flagd across v0.18.0 reshuffles users. Raising the `on` weight only
  moves users from off to on ([flagd, fractional][fd-fractional]).
- **`targetingKey`** is the context's `targetingKey`; a rule reads it as `{"var": "targetingKey"}`
  ([flagd, flag definitions][fd-defs]). A fractional rule with no key answers an error path
  (`TARGETING_KEY_MISSING` in OFREP).
- **OFREP**: `POST /ofrep/v1/evaluate/flags/{key}` for one flag, `POST /ofrep/v1/evaluate/flags` in bulk
  with ETags; reasons `STATIC`, `TARGETING_MATCH`, `SPLIT`, `DISABLED`; `FLAG_NOT_FOUND` is a 404
  ([OpenFeature, OFREP OpenAPI][ofrep]).

## Where pronto-flags stands

What a push does today ([flag-flips.md](flag-flips.md)): it writes the spec's flags for everyone in one
versioned object (`stage=all`), waits for OFREP to answer the new value, runs the flag's `production`
scenarios that sign in as no one, and writes the version before back if one fails. It refuses a flag
without cases unless `--untested`, and `rollback` restores any version without running cases.

| Practice | pronto-flags today | Gap |
| --- | --- | --- |
| A small sticky cohort first | Everyone at once since PRONTO-284 (the tester canary was dropped) | PRONTO-412: `--stages` through flagd `fractional` on `targetingKey` |
| Guardrails over a watch window, rollback on breach | Only the production scenarios, for seconds | PRONTO-413: errors, probe journeys and one business metric watched after each stage |
| One flag per push | A habit: push writes whatever the spec says | PRONTO-415: refuse a push where two flags' values move; `show` prints the per-flag diff |
| Prerequisites | Written in notes (save_progress_ask after keep_guest and google_adopts_guest) | PRONTO-416: `after: [...]` in flags_spec, enforced by push |
| Before/after marks | The flags journal and version metadata | PRONTO-417: dashboard annotations and each guardrail's reading in the report |
| A written procedure | AGENTS.md's flag rules and this repo's README | PRONTO-414: the `pronto-flip` skill, the release engineer's checklist |
| Every app can flip | Studio lacks `flagsCases.live`; Prontoweeper has no `flagsLive` | PRONTO-418 |
| Kill switch without a deploy | `pronto-flags rollback`, no cases | None |
| Removal after the flip | A removal issue a week after each flip (PRONTO-283, PRONTO-287) | None |
| Audit trail | Versioned object, journal, `history` | None |
| Live check per flip | A flag with no production scenario is pushed with `cases=none on production` | Each flip issue's readiness names it; the flip's PR adds one where a read-only check exists |

## The release engineer's checklist

**Before:**
1. The flip issue says the flag's readiness:
   - its cases and production scenarios (`pronto-flags cases`);
   - that its merge is in the released commit (live OFREP answers it);
   - its prerequisite flags, secrets and migrations;
   - its hazards and its rollback.
2. The owner's go, in so many words.
3. A pull request with `default: true` and `generate`'s files committed, merged by automerge.
4. From a clean main, run `pronto-flags show` and diff it against the live object: only the intended flag moves.
5. A weekday daytime window, outside release-cron's run.

**During:**
1. `pronto-flags push`.
2. Watch errors, probe journeys and the business dashboard for the window.
3. On any regression, `pronto-flags rollback` first and investigate after.

**After:**
1. Record the readings on the flip issue.
2. The removal issue a week on: remove the code, then the flag, and never reuse its name.

[fowler]: https://martinfowler.com/articles/feature-toggles.html
[sre]: https://sre.google/workbook/canarying-releases/
[ld-release]: https://launchdarkly.com/blog/release-management-flags-best-practices/
[ld-progressive]: https://launchdarkly.com/docs/home/releases/progressive-rollouts
[ld-guarded]: https://launchdarkly.com/docs/home/releases/guarded-rollouts
[ld-status]: https://launchdarkly.com/docs/home/flags/flag-status
[ld-debt]: https://launchdarkly.com/docs/guides/flags/technical-debt
[ld-prereq]: https://launchdarkly.com/docs/home/flags/prerequisites
[ul-strategies]: https://docs.getunleash.io/concepts/activation-strategies
[ul-flags]: https://docs.getunleash.io/concepts/feature-flags
[ul-best]: https://docs.getunleash.io/topics/feature-flags/feature-flag-best-practices
[ul-scale]: https://docs.getunleash.io/topics/feature-flags/best-practices-using-feature-flags-at-scale
[ul-debt]: https://docs.getunleash.io/concepts/technical-debt
[fs-pct]: https://docs.flagsmith.com/managing-flags/rollout/rollout-by-percentage
[configcat]: https://configcat.com/blog/feature-flag-best-practices/
[fd-fractional]: https://flagd.dev/reference/custom-operations/fractional-operation/
[fd-defs]: https://flagd.dev/reference/flag-definitions/
[fd-concepts]: https://flagd.dev/concepts/feature-flagging/
[fd-monitoring]: https://flagd.dev/reference/monitoring/
[of-hooks]: https://openfeature.dev/specification/sections/hooks
[of-events]: https://openfeature.dev/specification/sections/events
[ofrep]: https://github.com/open-feature/protocol/blob/main/service/openapi.yaml
[grafana]: https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/annotate-visualizations/
