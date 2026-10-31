# journeys

Monitors a pronto app's critical user journeys against SLOs, from the terminal's own telemetry.

## What it adds

A journey is an ordered list of the gestures a reader makes on the app's screens. From one spec the host derives:

- the collector that assembles runs (Vector, as a `container` hatch);
- vmalert rules that burn the error budget (multi-window burn rates, plus a no-data alert per journey);
- a Grafana dashboard.

A host-DOM hatch on every screen ([`telemetry.js`](telemetry.js)) reports each gesture and the outcome the screen's `data-state` shows. It works on the released terminal, which is not changed.

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
