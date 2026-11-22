# devflow

The dev flow of a repository of pronto apps ([dev-flow.md](dev-flow.md)): a Ready queue, pulled by the flow's `queue.order` (first in first out, or oldest filed first; a bug at P1 jumps it), on a [Plane](https://github.com/makeplane/plane) board, self-hosted or hosted, every piece of work an issue, one Claude session per issue, an issue Done only when it is in production: its flag is on for everyone, or, with no flag, when it is released (infra and plugins issues: when merged).

## What it adds

No files in an app. A repository opts in with one file, `devflow/devflow.cue`: its board (kind, host and project), where its token is kept, the node Plane runs on if it installs one, its team (engineers, SREs, architects, product managers), how long an issue may wait in Ready before it starves and its time zone; and, if it wants them, its own states, the role each plays, and its priorities' words. The rest of the flow is here:

- [`dev-flow.md`](dev-flow.md): how the flow works, for any repository: the rules, the board, the states and their roles, P0..P3, the team, the hooks.
- [`schema.cue`](schema.cue): the flow as data, every default in it: the board and its kind, the token's source, the states (in order and in the board's groups) and the role each plays, what P0..P3 do. Its checks are [`tests.cue`](tests.cue) (`cue vet -c=false ./devflow`).
- [`board/board.ts`](board/board.ts): the `Board` interface everything else talks to, and [`plane.ts`](plane.ts), the adapter for `board.kind: "plane"` and [`github-projects.ts`](github-projects.ts), the adapter for `board.kind: "github-projects"`: a GitHub Projects (v2) project whose Status, Priority, Module (multi select) and Sprint (iteration) fields hold the states, priorities, apps and sprints (the iteration is no longer read), its issues those of `board.repository` ([`board/github.js`](board/github.js) says how). `spec.ts`'s `boardOf` picks the adapter.
- [`plane.cue`](plane.cue): Plane on the node: the plane-ce chart's values, its CloudNativePG database, and its route on the node's Envoy Gateway.
- [`flow.js`](flow.js): the rules, in roles rather than a repository's state names: an issue's key from a pull request, where an event moves an issue, an issue's flag, whose slot an issue takes (an engineer's, an SRE's or an architect's), when an issue became Ready (its latest move into Ready), which Ready issues jump the queue (a bug at P1 or P0) and the order a lane pulls them (`pullOrder`, by `queue.order`; `filedPlace` for a design's children), and merges counted by day. Its cases are [`tests/unit/devflow.cue`](../tests/unit/devflow.cue).
- [`connect.ts`](connect.ts): the `connect plane` intent ([docs/intents.md](../docs/intents.md)): Plane installed on the node (when the repository names a `cluster`), its hostname, then the board set up from the spec. With no `cluster` it installs nothing: it checks the board's host answers and the token signs in, then sets the board up.
- [`suggestions.ts`](suggestions.ts): the suggestion inbox ([dev-flow.md](dev-flow.md), Suggestions), behind the `Board` interface: what `status` says of it (an excerpt of each waiting suggestion, escaped and marked untrusted), `pronto-devflow approve SUGEST-<n>` (an item the owner moved to Refine, filed as a link-only issue) and the `connect plane` steps that make it; its rules are `flow.js`'s (`excerptOf`, `submitterOf`, `staleOf`).
- [`prs.ts`](prs.ts): the hourly pull request watch: gh reads the open pull requests of `prs.repos` (schema.cue), `flow.js` `forgottenPrs` picks those nobody drives (no activity in `prs.idleHours`, or a check failed with no push since), and `status` and `pronto-devflow prs <repo>` print `forgotten PRs:`; `prs` exits 1 when there are any.
- [`queue.ts`](queue.ts): the board verbs' logic behind `board.ts`, on the `Board` interface so the cases run it on a fake Plane: each lane's Ready queue with ages and what starves (`readyQueue`), `start`, `pull`, `file` and `status`'s lines. A flip issue waiting for the release of its fix (`pronto-devflow wait . <KEY> --pr <url>`, the `waits-release` label) holds no slot until the released hook frees it. Any other issue whose fix merged under another issue's PR moves to Merged through the same verb. `Board.stateMoves` (Plane's activity) says when an issue became Ready. There are no sprints: `next` and `close` print what replaced them and exit 2.
- [`hook.ts`](hook.ts): what GitHub, release-cron and pronto-flags tell the board.
- [`board.ts`](board.ts): the board as the skills use it: [`pronto-sprint-plan`](../skills/pronto-sprint-plan/SKILL.md) (the lead's queue loop), [`pronto-issue`](../skills/pronto-issue/SKILL.md), [`pronto-bug`](../skills/pronto-bug/SKILL.md), [`pronto-design`](../skills/pronto-design/SKILL.md) (the product managers').

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
| `pronto-flags push --flip <flag>` | a flag went on, or off, for everyone | `pronto-devflow flipped` / `rolledback` | the issues naming it are Done, or Live again |

### When an issue is Done

`flow.js` `doneAt` decides, from the issue's `Flag:` line and its modules:

| the issue | Done when | path |
| --- | --- | --- |
| names a flag | the flag is on for everyone (`flipped`); `rolledback` puts it back to Live | Merged → Live (released) → Done (flipped) |
| names none (a bug fix) | it is released (`released`) | Merged → Done |
| names none, in an infra module (`infra`), a design module (`design`) or the `plugins` module | its pull request merges (`merged`) | Review → Done: nothing release-cron ships |

A flagless issue is never left in Live: the release that holds its pull request finishes it. `pronto-flags rollback` tells the board too (`rolledback` for each flag it turned off).

Another repository whose pull requests carry the same board's keys (several repositories may share one board) calls the board's one workflow, [`devflow-board.yml`](../.github/workflows/devflow-board.yml), from a short `plane.yml` of its own (its header shows the caller), with its own `PLANE_TOKEN` secret, and a `devflow/devflow.cue` that names the board (`board`, or its earlier name `plane`) and its token (`token`) alone, with no `cluster`: the board is set up from one repository; `connect plane` there installs nothing and checks the board answers.

A hook never fails a release or a flip: without a token or a board it says so and goes on.

## Tests

The `devflow` suite (the inbox's cases, [`tests/unit/devflow_inbox.cue`](../tests/unit/devflow_inbox.cue), and the queue's, [`tests/unit/devflow_queue.cue`](../tests/unit/devflow_queue.cue), run on a fake Plane, [`tests/unit/devflow.js`](../tests/unit/devflow.js)): `deno test --allow-read --allow-env --allow-run tests/unit.ts -- devflow`. [`tests.cue`](tests.cue) holds the schema to what a repository may write (`cue vet -c=false ./devflow`): an existing board with no cluster, an env token, custom states and roles (a role naming a missing state refused), the earlier `plane` and token shapes, a repository's earlier `devflow.cue` under the new fields, and the `suggestions` inbox with its defaults and refusals.
