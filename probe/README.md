# probe: is the released app answering, and what changed just before it stopped

Runs an app's journeys (a customer opening the shop, filling the cart, checking out) against its
address every few seconds. When a run fails twice in a row it says so loudly, and names the flag
writes ([pronto-flags](../flags/README.md)) made in the quarter hour before the first failure,
newest first, each with the command that undoes it. When a run passes again it says RESOLVED and
for how long the app was down. It only reads: HTTP requests to the address the app says, and the
flags journal on this machine.

## What it adds

- `probe/probe.ts`, the driver (Deno), and `probe/probe.js`, its rules, pure and held by the cases in
  [`tests/unit/probe.cue`](../tests/unit/probe.cue). Both regenerated.
- `probes_plugin.cue`: `#Probe`, `#Step` and `#Target` in the app's package, holding `probes` and
  `probeTarget` to them. Regenerated.
- `probes_spec.cue`, seeded once, then the app's own: its address and its journeys.

## Turn it on for an app

```sh
bin/pronto-probe apps/<app>      # from a pronto-plugins clone
```

Then say the journeys in `probes_spec.cue`:

```cue
probeTarget: url: "https://app.example.com"
probes: checkout: {
	every: "15s"       // timeout "5s" a step; alert: {after: 2, suspectWindow: "15m"}
	journey: [
		{name: "home", path: "/"},
		{name: "cart", method: "POST", path: "/cart", body: {item: "tea"}},
		{name: "checkout", method: "POST", path: "/checkout", expect: contains: "order"},
	]
}
```

A step fails on a status other than `expect.status` (200), on a body without `expect.contains`, on
a timeout or on a network error; the first failed step ends the run.

## Run it

```sh
bin/pronto-probe run apps/<app> [--once] [--probe name]
```

- One JSON line a run to stdout and to `${XDG_STATE_HOME:-~/.local/state}/pronto-probe/<app>.jsonl`:
  `{at, event: "probe.run", probe, ok, step, status, ms, error}`. `--once` runs each journey once
  and exits 1 if it failed.
- At the second failure in a row: an `ALERT` block, a `probe.alert` line with its `suspects`, and a
  macOS notification (`PROBE_NOTIFY=0` turns it off; there is no sound). `PROBE_WEBHOOK=<url>` also
  posts the alert's JSON there. A third failure does not alert again.
- At the first pass after an alert: a `RESOLVED` line and a `probe.resolved` line with `downFor`.
- The suspects come from the flags journal pronto-flags writes at
  `${XDG_STATE_HOME:-~/.local/state}/pronto-flags/<app>.jsonl` (`probeTarget.flagsJournal` names
  another), the writes that changed a flag between `suspectWindow` before the first failure and it.

`cue` comes from `PATH` or `$CUE`. The [hello-flags-drill](../examples/hello-flags-drill/README.md)
example is a whole drill: break a flag, see the alert, roll back, see RESOLVED.
