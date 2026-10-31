# perf

Measures how a pronto app runs on its readers' devices, games first: frame times, long animation frames, interactions, the largest paint, layout shift and WebGL contexts lost, by screen, GPU family and browser.

## What it adds

- A reporter ([`perf.js`](perf.js)) as a host-DOM hatch on every screen. It measures whatever draws the page, so a game needs no code. It buckets in the browser and posts every 30 seconds.
- A collector (Vector, as a `container` hatch) that validates each report, and rules and a dashboard generated from `perf_spec.cue`'s SLOs.
- `perf report`, which prints what the collector has counted.

Only counts and the device's kind leave the page, never the renderer string or anything typed. Global Privacy Control and Do Not Track are honored. An app can add its own numbers:

```js
screen.dispatchEvent(new CustomEvent("pronto:perf", { detail: { drawCalls, gpuMs, tier } }));
```

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-perf . [endpoint=/perf]
./saytw generate && ./saytw lint
./saytw launch@local
```

The host is [`host.cue`](host.cue), the schema [`schema.cue`](schema.cue), the generate step [`perf.nu`](perf.nu). Config is `perf: #Perf & {…}` in `perf_spec.cue` (SLOs, sample, owner); declare the two hatches in `ir.html`. The [`pronto-perf` skill](../skills/pronto-perf/SKILL.md) covers the setup. Files written and limits: [root README](../README.md#pronto-perf).

## Tests

- [`tests.cue`](tests.cue): the exported files, checked with `cue vet`.
- [`test.nu`](test.nu): the generate step against a fixture app.

```sh
./saytw --script tools.nu cue vet -c ./perf
./saytw --script tools.nu cue vet -c -t package=check ./perf/export
./saytw --script tools.nu nu perf/test.nu
```
