# devflow

The dev flow of a repository of pronto apps (bsoneca/pronto's [docs/dev-flow.md](https://github.com/bsoneca/pronto/blob/main/docs/dev-flow.md)): one-day sprints on a self-hosted [Plane](https://github.com/makeplane/plane) board, every piece of work an issue, one Claude session per issue, an issue Done only when its flag is on in production.

## What it adds

No files in an app. A repository opts in with one file, `devflow/devflow.cue`: its board's host and project, the node Plane runs on, the agent cap and when the day's sprint ends. The rest of the flow is here:

- [`schema.cue`](schema.cue): the flow as data: its states, in order and in Plane's groups, and what P0..P3 do.
- [`plane.cue`](plane.cue): Plane on the node: the plane-ce chart's values, its CloudNativePG database, and its route on the node's Envoy Gateway.
- [`flow.js`](flow.js): the rules: an issue's key from a pull request, where an event moves an issue, an issue's flag, the agent cap, which day's sprint a moment is in. Its cases are [`tests/unit/devflow.cue`](../tests/unit/devflow.cue).
- [`connect.ts`](connect.ts): the `connect plane` intent ([docs/intents.md](../docs/intents.md)): Plane installed on the node, its hostname, then the board set up from the spec.
- [`hook.ts`](hook.ts): what GitHub, release-cron and pronto-flags tell the board.
- [`board.ts`](board.ts): the board as the skills use it: [`pronto-sprint-plan`](../skills/pronto-sprint-plan/SKILL.md), [`pronto-issue`](../skills/pronto-issue/SKILL.md), [`pronto-bug`](../skills/pronto-bug/SKILL.md).

## Use

```sh
bin/pronto plan plane .          # what is set up, what is next; changes nothing
bin/pronto connect plane .       # sets up what it can, stops where a person must act
```

It stops three times the first time, each saying what to do: the hostname's DNS record (`cloudflared tunnel route dns`), Plane's instance admin, and the workspace and its API token, kept in Secret Manager. Run again, it goes on from there.

The hooks, which run without a person:

| Who | When | Hook | The board |
| --- | --- | --- | --- |
| the repository's `plane` workflow | a pull request opens, merges or closes | `pronto-devflow pr` | its issue to Review, Merged, or back to Implementing; a pull request with no key fails the check unless labelled `chore` |
| release-cron | a run confirmed a release | `pronto-devflow released` | the app's Merged issues the release holds go Live |
| `pronto-flags push` | a flag went on, or off, for everyone | `pronto-devflow flipped` / `rolledback` | the issues naming it are Done, or Live again |

A hook never fails a release or a flip: without a token or a board it says so and goes on.

## Tests

The `devflow` suite: `deno test --allow-read --allow-env --allow-run tests/unit.ts -- devflow`.
