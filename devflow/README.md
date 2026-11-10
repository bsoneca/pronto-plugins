# devflow

The dev flow of a repository of pronto apps ([dev-flow.md](dev-flow.md)): sprints in an endless loop on a [Plane](https://github.com/makeplane/plane) board, self-hosted or hosted (each ends when its issues merge, the next already planned, so no engineer waits), every piece of work an issue, one Claude session per issue, an issue Done only when it is in production: its flag is on for everyone, or, with no flag, when it is released (infra and plugins issues: when merged).

## What it adds

No files in an app. A repository opts in with one file, `devflow/devflow.cue`: its board (kind, host and project), where its token is kept, the node Plane runs on if it installs one, its team (engineers, SREs, product managers) and a sprint's size; and, if it wants them, its own states, the role each plays, and its priorities' words. The rest of the flow is here:

- [`dev-flow.md`](dev-flow.md): how the flow works, for any repository: the rules, the board, the states and their roles, P0..P3, the team, the hooks.
- [`schema.cue`](schema.cue): the flow as data, every default in it: the board and its kind, the token's source, the states (in order and in the board's groups) and the role each plays, what P0..P3 do. Its checks are [`tests.cue`](tests.cue) (`cue vet -c=false ./devflow`).
- [`board/board.ts`](board/board.ts): the `Board` interface everything else talks to, and [`plane.ts`](plane.ts), the adapter for `board.kind: "plane"` (`spec.ts`'s `boardOf` picks the adapter; `github-projects` is in the schema and refused until its adapter exists, PRONTO-207).
- [`plane.cue`](plane.cue): Plane on the node: the plane-ce chart's values, its CloudNativePG database, and its route on the node's Envoy Gateway.
- [`flow.js`](flow.js): the rules, in roles rather than a repository's state names: an issue's key from a pull request, where an event moves an issue, an issue's flag, whose slot an issue takes (an engineer's or an SRE's), what a sprint may plan per lane (`sprint.perPerson` for each person) and which Ready issue a lane pulls next, where the loop of sprints stands (the current, the next, the finished). Its cases are [`tests/unit/devflow.cue`](../tests/unit/devflow.cue).
- [`connect.ts`](connect.ts): the `connect plane` intent ([docs/intents.md](../docs/intents.md)): Plane installed on the node (when the repository names a `cluster`), its hostname, then the board set up from the spec. With no `cluster` it installs nothing: it checks the board's host answers and the token signs in, then sets the board up.
- [`hook.ts`](hook.ts): what GitHub, release-cron and pronto-flags tell the board.
- [`board.ts`](board.ts): the board as the skills use it: [`pronto-sprint-plan`](../skills/pronto-sprint-plan/SKILL.md), [`pronto-issue`](../skills/pronto-issue/SKILL.md), [`pronto-bug`](../skills/pronto-bug/SKILL.md), [`pronto-design`](../skills/pronto-design/SKILL.md) (the product managers').

## Use

```sh
bin/pronto plan plane .          # what is set up, what is next; changes nothing
bin/pronto connect plane .       # sets up what it can, stops where a person must act
```

It stops three times the first time, each saying what to do: the hostname's DNS record (`cloudflared tunnel route dns`), Plane's instance admin, and the workspace and its API token, kept where `token.kind` says (Secret Manager by default, or an environment variable); with no `cluster`, only the last. Run again, it goes on from there.

The hooks, which run without a person:

| Who | When | Hook | The board |
| --- | --- | --- | --- |
| the repository's `plane` workflow | a pull request opens, merges or closes | `pronto-devflow pr` | its issue to Review, Merged, or back to Implementing; a pull request with no key fails the check unless labelled `chore` |
| release-cron | a run confirmed a release | `pronto-devflow released` | the app's Merged issues the release holds go Live |
| `pronto-flags push` | a flag went on, or off, for everyone | `pronto-devflow flipped` / `rolledback` | the issues naming it are Done, or Live again |

### When an issue is Done

`flow.js` `doneAt` decides, from the issue's `Flag:` line and its modules:

| the issue | Done when | path |
| --- | --- | --- |
| names a flag | the flag is on for everyone (`flipped`); `rolledback` puts it back to Live | Merged → Live (released) → Done (flipped) |
| names none (a bug fix) | it is released (`released`) | Merged → Done |
| names none, in an infra module (`infra`) or the `plugins` module | its pull request merges (`merged`) | Review → Done: nothing release-cron ships |

A flagless issue is never left in Live: the release that holds its pull request finishes it. `pronto-flags rollback` tells the board too (`rolledback` for each flag it turned off).

Another repository whose pull requests carry the same board's keys (bsoneca/ume's, on bsoneca/pronto's board) gets the same `plane` workflow and its own `PLANE_TOKEN` secret, and a `devflow/devflow.cue` that names the board (`board`, or its earlier name `plane`) and its token (`token`) alone, with no `cluster`: the board is set up from one repository; `connect plane` there installs nothing and checks the board answers.

A hook never fails a release or a flip: without a token or a board it says so and goes on.

## Tests

The `devflow` suite: `deno test --allow-read --allow-env --allow-run tests/unit.ts -- devflow`. [`tests.cue`](tests.cue) holds the schema to what a repository may write (`cue vet -c=false ./devflow`): an existing board with no cluster, an env token, custom states and roles (a role naming a missing state refused), the earlier `plane` and token shapes, and bsoneca/pronto's own `devflow.cue` under the new fields.
