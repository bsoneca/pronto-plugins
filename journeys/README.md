# journeys

Monitors a pronto app's critical user journeys against SLOs, from the terminal's own telemetry.

## What it adds

A journey is an ordered list of the gestures a reader makes on the app's screens. From one spec the host derives:

- the collector that assembles runs (Vector, as a `container` hatch);
- vmalert rules that burn the error budget (multi-window burn rates, plus a no-data alert per journey);
- a Grafana dashboard.

A host-DOM hatch on every screen ([`telemetry.js`](telemetry.js)) reports each gesture and the outcome the screen's `data-state` shows. It works on the released terminal, which is not changed.

It also reports the page's errors (`error`, `unhandledrejection`): the name, a message cut to 200 characters, the top stack frame and the screen. The collector redacts them (emails, urls, token-like strings, long digit runs), caps them (5 per session and 20 per error, per minute) and writes each as one JSON `ERROR` line on stdout (`frontend <Name>: <message>`, `stack_trace`, `screen`, `revision`), which Cloud Logging keeps and [prod-watch](../prod-watch/README.md) fingerprints like a server's error. A bundle's build hash is taken off the frame so one bug stays one fingerprint across releases.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-journeys . [endpoint=/telemetry]
./saytw generate        # derives each screen's gestures into journeys_gestures.cue
# write the journeys and SLOs into journeys_spec.cue; declare the two hatches in ir.html
./saytw generate && ./saytw lint
./saytw launch@journeys # the collector, and a local dashboard to watch it in
```

The host is [`host.cue`](host.cue), the schema [`schema.cue`](schema.cue), the generate step [`journeys.nu`](journeys.nu). The [`pronto-journeys` skill](../skills/pronto-journeys/SKILL.md) writes the journeys. Files written and limits: [root README](../README.md#pronto-journeys). Example: [`examples/hello-journeys`](../examples/hello-journeys).

## Tests

- [`tests.cue`](tests.cue): the exported files, checked with `cue vet`.
- [`test.nu`](test.nu): the generate step against a fixture app.

```sh
./saytw --script tools.nu cue vet -c ./journeys
./saytw --script tools.nu cue vet -c -t package=check ./journeys/export
./saytw --script tools.nu nu journeys/test.nu
```
