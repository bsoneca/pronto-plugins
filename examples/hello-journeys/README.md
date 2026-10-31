# hello-journeys

Pronto's `idioms` app — a counter, a todo list, lights-out and a timer — with
[pronto-journeys](../../README.md#pronto-journeys) added as any app would add
it: `bin/pronto-journeys .`, two journeys written into
[`journeys_spec.cue`](journeys_spec.cue), and both hatches declared in
[`ir.html`](ir.html). Pronto and omnishell are the released 0.14.0 and 0.12.1.

| Journey | Moments | SLO |
| --- | --- | --- |
| `first-task` | `todo.create-todo` | 99.5% of runs good; 95% of moments under 300 ms |
| `play` | `counter.count` → `grid.press` | 99.9% of runs good |

The gestures each screen offers are derived into
[`journeys_gestures.cue`](journeys_gestures.cue); naming one it lacks
refuses at `cue vet`.

```sh
./saytw generate && ./saytw lint && ./saytw test && ./saytw integrate
./saytw launch && ./saytw launch@journeys
```

`launch@journeys` prints the app's address, a Grafana with the journeys
dashboard, and vmalert's alerts. Open the app and Grafana side by side: add a
todo, press + on the counter then a light — each closes a good run. The
counter's **Fail** button is the failure switch: it makes `count` throw, the
screen goes to `network-error`, the `play` run closes bad, and within a few
minutes the burn rate climbs and vmalert's fast-burn alert fires. Stop it all
with `./saytw --script tools.nu nu -c 'use journeys/journeys.nu; journeys down'`.
`observability/` holds the collector's config and unit tests, the vmalert rules
and the Grafana dashboard. The [journal](journal/index.html) shows one run.
