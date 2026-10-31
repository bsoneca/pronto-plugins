---
name: pronto-journeys
description: "Add journey monitoring to a pronto app, or refresh it: critical user journeys as gestures on its screens, with SLOs, turned into a Vector collector that assembles runs from the terminal's telemetry, multi-window burn-rate vmalert rules, and a Grafana dashboard. Use when the user wants SLOs, error budgets or user-journey monitoring (an APM's job) for a pronto app."
---

# pronto-journeys

A plugin beside pronto, not part of it: pronto 0.14.0 has no journeys, so the
app holds the host's files and its generate step re-applies the door's route
pronto's writer regenerates. The terminal is unchanged: a host-DOM hatch on
every screen reports each gesture, naming it as the markup does, and reads
its outcome from the screen's `data-state`.

## What the app gets

| Path | Owner |
| --- | --- |
| `pronto/journeys.cue` | regenerated: promtool pinned, the `generate` rule after pronto's writer |
| `journeys_plugin.cue` | regenerated: the schema (`#Journeys`, `#Journey`), in the program's package |
| `journeys_hatch.cue` | regenerated: the `journeys-telemetry` host-DOM hatch on every screen, and the `journeys-collector` container hatch with its cluster target |
| `shell/hatches/journeys/telemetry.js` | regenerated: the reporter |
| `journeys/journeys.nu` | regenerated: the generate step |
| `.say.json` | merged: `launch@journeys` |
| `journeys_spec.cue` | seeded, then the app's: `journeys: #Journeys & {gestures: _journeyGestures, spec: {…}}` |
| `journeys_gestures.cue` | seeded, then rewritten by every generate from the screens' markup |

## Adding it

From a bootstrapped pronto app whose four verbs are green, with the plugin's
toolchain installed once (`./saytw --script tools.nu mise install` in
`${CLAUDE_PLUGIN_ROOT}`):

```sh
${CLAUDE_PLUGIN_ROOT}/bin/pronto-journeys .
./saytw --script tools.nu cue cmd generate ./pronto
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw --script tools.nu mise lock
./saytw generate
```

Then:

1. Read `journeys_gestures.cue`: each screen's gestures, a handler by its
   module, a form by its id else `action-entity`. Only reader events count
   (click, dblclick, change, submit, keydown, drop); a `data-on-mutation`
   reduce or a machine transition is no gesture.
2. Write the journeys into `journeys_spec.cue` with the user: an owner, the
   ordered `screen.gesture` moments, `slo.availability` (percent of valid runs
   that reach the last moment), optionally `slo.latency: {percent, under}`,
   and `idle` (how long before a run is abandoned, default 30m). Ask which
   journeys are critical and what they promise; never invent targets.
3. Add both hatches to `ir.html`'s Decisions — `<p id="journeys-telemetry"
   data-kind="hatch">…</p>` and `<p id="journeys-collector"
   data-kind="hatch">…</p>`, saying what each is — and re-pin
   `meta.ir.sha256`. A screen that declares hatches of its own names the
   reporter among them (`hatches: ["game", "journeys-telemetry"]`) and is
   listed in `journeys_spec.cue`'s `_journeysOwnHatches: ["play"]`; vet names
   any screen left without the reporter.
4. `./saytw generate && ./saytw lint && ./saytw test`.

A moment naming no gesture refuses at `cue vet` with the gestures the screen
has, so write the spec after the first generate has derived them. Re-run `bin/pronto-journeys` to refresh; the spec is kept.

## Running it

`./saytw launch@journeys`, after `./saytw launch`, brings up the collector and
a local dashboard beside it — VictoriaMetrics scraping the collector, vmalert
with the generated rules, Grafana with the generated dashboard — and prints
the app's, Grafana's and vmalert's addresses. Use the app and watch the
journeys move; `journeys down` (in `journeys/journeys.nu`) stops it all. In a
deployed cluster the same files go to its own VictoriaMetrics, vmalert and
Grafana.

## Limits

- Outcomes are read, not reported: a handler is ok unless the screen enters
  `network-error` within 1.5 s, a form is ok on `success` or when the reader
  leaves, and a withdrawal within 5 s of a form's ok is a refusal on its trace.
- A run is good once its last moment is ok; a refusal arriving after that is
  counted on the moment, not the run.
- The collector keeps runs in memory: a restart drops runs in flight. A
  counter is born at its first run, so the rules take ratios of `increase()`,
  which VictoriaMetrics counts from a series' first sample; on Prometheus,
  whose `increase()` does not, a journey's first run of each outcome is
  missed.
- The reporter flushes every 2 s and on leaving; what a page holds when it
  goes is kept for the tab's next load, so a reload loses nothing.
- `/telemetry` is unauthenticated. The door refuses a batch past 64 KB (413);
  the collector drops a session's events past `journeys.limit` (default 600
  per 60 s) and counts them as `journey_telemetry_throttled_total`. The limit
  is per session, which a client mints itself: it bounds a misbehaving
  reader, not a determined flood, for which the door would need a rate-limit
  module stock Caddy lacks.
- A pages-only release has no door and no collector: the no-data alert fires.

## Done

The four verbs exit 0, `observability/` holds the three files, and a gesture
made in the running app moves `journey_runs_total` on the collector's
`/metrics`.
