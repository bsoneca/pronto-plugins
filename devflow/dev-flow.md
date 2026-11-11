# Dev flow: sprints, issues and releases

The flow is this plugin's [devflow](README.md), and a repository opts in with one file,
`devflow/devflow.cue`: its board, its team and the sprint's size. This document says how the flow
works; the values it gives (the project `PRONTO`, the host `plane.bsoneca.com`, four engineers) are
bsoneca/pronto's, and stand as examples of what a repository writes. `bin/pronto connect plane .`
sets the board up and says what waits on a person.

| piece | where |
| --- | --- |
| the flow's states, their roles, P0–P3, Plane's chart values, database and route | `devflow/schema.cue`, `devflow/plane.cue` |
| the rules (an issue's key, where an event moves it, its flag, whose slot it takes) | `devflow/flow.js`, cases in `tests/unit/devflow.cue` |
| the board, as an interface and its adapter | `devflow/board/board.ts`, `devflow/plane.ts` |
| the board set up | `bin/pronto connect plane .` (`devflow/connect.ts`) |
| pull requests → the board | a workflow in the repository that runs `pronto-devflow pr` (its `plane.yml`) |
| releases and flips → the board | release-cron's run and `pronto-flags push`, through `pronto-devflow` |
| the skills | `pronto-sprint-plan`, `pronto-issue`, `pronto-bug`, `pronto-design` |
| Claude Code reading the board | the repository's `.mcp.json`: the Plane MCP server, started by `pronto-devflow mcp .` |

Without a flow, work is pull requests and nothing else. Hundreds merge, the issue tracker holds a
single issue, and nobody can say what the current goal is, what is waiting, or which merged change is
actually live. This document sets one flow for every app in a repository: work happens in sprints
that always end, every piece of work is an issue on a board before it is built, every issue is one
Claude session, and a task is only finished when it is in production behind a flag that was switched
on.

## The rules

1. **Always sprints.** Each sprint has a team ([below](#the-team)): engineers and an SRE who build,
   each driving Claude sessions, and a product manager who designs what later sprints build. The
   sessions building at once are capped, one per builder, because what limits us is people's review
   and CPU, not ideas.
2. **Sprints always end, one after another, for ever.** A sprint is named `Sprint <n>: <theme>` and
   ends when every one of its issues is merged (or further along) or cancelled: no hour closes it,
   and nothing holds it open (an issue parked with a question for the owner moves to the Backlog and
   leaves the sprint). The code is written by Claude, so a sprint is short; every task in one has an
   objective a session can meet, and one that cannot is split at refinement.
3. **New features are never built on request.** Every request becomes an issue on the board first.
   This holds for every app and every kind of change.
4. **The lead plans the next sprint without asking.** Everything on the board is wanted, so no list
   waits for approval: the lead picks the next sprint's theme (P1s first, then what just got
   unblocked, one app or feature, then value and age), unless the owner names one, and fills it.
   `pronto-devflow status` says when the next sprint must be planned (`plan: true`), and an engineer
   whose sprint has nothing Ready pulls from the next one.
5. **One issue, one Claude session.** An issue goes refine → implement → review → merge. Anything new
   learned along the way becomes a new issue; the session judges whether it belongs in this sprint.
6. **Bugs carry a priority**, P0 to P3 (below), which decides whether they wait for a sprint.
7. **Releases run on the release cron, independent of sprints.** Every task ships behind a flag.
8. **A sprint ends when its tasks are merged. A task ends when it is in production and its flag was
   flipped on successfully.** The two are different on purpose: a sprint never waits on production.

## The board

The flow needs a board with these things, and the plugin reads and writes them through one
interface (`devflow/board/board.ts`), so a repository's board is a choice, not an assumption:

| the flow | on the board |
| --- | --- |
| a sprint | a **cycle** named `Sprint <n>: <theme>`, with no fixed length; day-named cycles from before the loop are ignored |
| the same rules for every app | **one project** (identifier `PRONTO`) with a **module per app** (`brawl-chess`, `giselle`, `guestbook`, …) and one for `plugins`; a sprint is one cycle across all of them |
| the issue's state | a **state** in one of the board's groups |
| P0–P3 | the board's priorities |

`board.kind` in `devflow/devflow.cue` picks the adapter. **`plane`** is the one implemented: a
[Plane](https://github.com/makeplane/plane) board, self-hosted (Community Edition, AGPL) or hosted.
`github-projects` is in the schema for the next adapter and is refused until it exists
(PRONTO-207). Plane was chosen for having each piece of the flow built in rather than a convention,
and for being open source; **Taiga**, **OpenProject**, **Forgejo/Gitea** issues and **GitHub
Projects** were considered and not chosen as the first.

```cue
devFlow: {
	board: {
		host:      "plane.bsoneca.com"
		workspace: "pronto"
		project: {name: "pronto", identifier: "PRONTO"}
	}
	token: project: "brawl-chess"
}
```

A repository written before `board` existed names the same as `plane: {…}`, and still vets: it is a
board of kind `plane`. Claude reads and moves the board through the official
[Plane MCP server](https://github.com/makeplane/plane-mcp-server) (work items, cycles, modules).

### The token

The board's API token is kept in one place, `token.kind`:

- `secret-manager` (the default): Google Cloud's Secret Manager, `secret` (default
  `plane-api-token`) in `project`, read with the reader's own `gcloud`.
- `env`: the environment variable `name` (default `PLANE_TOKEN`).

`PLANE_TOKEN` in the environment (a GitHub Actions secret) wins for every kind. A token written as
`{project, secret?}` with no kind is Secret Manager's.

### An installed Plane, or one that exists

With a `cluster`, `connect plane` installs Plane on the repository's node (a k3s node reached over
SSH, its door a Cloudflare Tunnel into the node's Envoy Gateway): the database is a CloudNativePG
cluster (`plane-db`), the namespace `plane`, who may sign in is Plane's own (the instance admin
turns sign-ups off and invites the team). bsoneca/pronto's is the Contabo node `pronto@144.91.92.217`,
the `contabo` kube context.

```cue
cluster: {
	context: "contabo"
	ssh:     "pronto@144.91.92.217"
	tunnel:  "45248135-7212-417a-af6d-b1bb2184e2d7"
}
```

With **no `cluster`**, it installs nothing. It checks that `https://<host>` answers and that the token
signs in (lists the projects), then makes the project, the states, a module per app and the labels as
it does after an install. That is a repository on a hosted Plane, on one installed another way, or
one that reports to a board set up from another repository: its pull requests carry the same board's
keys, and it names the board and its token alone.

Plane's own GitHub integration may be a paid feature when self-hosted, so the design does not rely on
it: the GitHub side is the repository's own workflow ([GitHub glue](#github-glue)).

## Issue states

Every work item, feature or bug, moves through the same states. The flow's rules reason in **roles**
(`backlog`, `refine`, `ready`, `implementing`, `review`, `merged`, `live`, `done`, `cancelled`), and a
repository's states play them. The defaults are:

| state (role) | means | who moves it |
| --- | --- | --- |
| **Backlog** | on the board, not planned | anyone; every new request lands here |
| **Refine** | in the sprint, being turned into an objective that can be met | `/issue` |
| **Ready** | refined: objective, acceptance, flag name and app written down | `/issue` |
| **Implementing** | a Claude session is building it; takes an engineer's or the SRE's slot | `/issue` |
| **Review** | its PR is open | the GitHub workflow, on PR opened |
| **Merged** | its PR merged to `main`; **counts as done for the sprint** | the GitHub workflow, on PR merged |
| **Live** | released by the release cron, flag still off | the release-cron hook |
| **Done** | in production and its flag flipped on successfully; **the task is closed** (an issue with no flag: [below](#when-an-issue-with-no-flag-is-done)) | the flag-flip hook, or release-cron's, or the GitHub workflow |
| **Cancelled** | will not be done, with the reason in a comment | a person |

A repository may replace the list with its own, and says which state plays each role:

```cue
states: [
	{name: "Intake", group: "backlog", color: "#a3a3a3", means: "waiting"},
	{name: "In dev", group: "started", color: "#f59e0b", means: "building"},
	// … a #State for each state the repository has
]
roles: {backlog: "Intake", implementing: "In dev", live: "Shipped", done: "Closed", cancelled: "Dropped"}
```

Each role names a state of `states`, which CUE checks; a role left out keeps its default name, so it
must be among the states too. `connect plane` makes the states a repository lists, and the hooks and
`pronto-devflow` map names to roles and back, so nothing in the flow depends on the word "Implementing".
Merged, Live and Done are in the board's completed group by default: a sprint counts an issue done
once it merged (rule 8), and a cycle's progress is its completed group's share.

Each item states, in its description, the app (also its module), the objective, how it is accepted
(the unit cases and scenarios it adds), and one line naming its flag:

```
Flag: army_pick_usable
```

The flag is declared in the app's `flags_spec.cue` (the flags plugin), so the name on the issue and
the name in the code are the same string, and the hooks below can match them.

## Bugs: P0 to P3

| priority | Plane | what happens |
| --- | --- | --- |
| **P0** | Urgent | fixed now: goes straight to Implementing, ahead of the slots, and released outside the cron if it must be |
| **P1** | High | enters the current sprint, but waits for the work already in progress |
| **P2** | Medium | Backlog, considered at the next planning |
| **P3** | Low | Backlog |

A bug's flag is the flag of the feature it breaks when there is one; turning that flag off is the
first response to a P0. `priorities` in `devflow/devflow.cue` names the board's own word for each
(`priorities: P0: plane: "critical"`) and what each does; what is left out keeps the default.

## The team

The team is written in `devflow/devflow.cue` (`team`), and changed there by a pull request.
bsoneca/pronto started with 2 engineers; from the second sprint it is:

| role | how many | does | slots |
| --- | --- | --- | --- |
| **engineer** | 4 | builds the apps' issues, one Claude session each | one each: at most 4 app issues in Implementing |
| **SRE** | 1 | builds the infrastructure: issues in the `infra` module (infra/, the nodes, Plane itself) | one: at most 1 `infra` issue in Implementing |
| **product manager** | 1 | designs features for later sprints (`/design`): turns ideas and Backlog issues into Ready ones | none: designing builds nothing |

The two lanes are apart on purpose: infrastructure never waits behind app work, nor app work behind
it. `infra` names the modules an SRE builds (default `["infra"]`). `/issue` will not move an item into
Implementing while its lane is full; it says which items hold the slots. P0 bugs are the one
exception.

### Capacity and WIP

A sprint **commits `sprint.perPerson` issues per person** (default 3): with 4 engineers and 1 SRE
that is 12 app issues and 3 `infra` issues. `pronto-devflow next` refuses a plan past a lane's
capacity, and `status` prints planned against capacity per lane and the Ready queue waiting to be
pulled. A split of a lane between apps stays by hand in planning.

**WIP is 1 in Implementing per person** (so `team.engineers` app issues and `team.sre` infra issues
at once; `start` refuses beyond that, a P0 excepted). Review (gate, ci, automerge) holds no slot, so
an engineer is never idle after one issue: when its pull request opens, or its issue is cancelled,
the session runs `pronto-devflow pull . [--lane SRE]`, which starts the lane's next Ready issue of
the current sprint, else of the next sprint, most urgent first, and works it as its own session.

A **designed** issue is Ready and in no sprint. It stays Ready when a sprint ends without it, and the
next planning picks from the designed issues first, so the product manager works a sprint or more
ahead of the engineers.

## Claude skills

Four skills, kept in the plugins' `skills/`, all talking to the board through `pronto-devflow`:

- **`/sprint-plan`**, the lead's loop. When `pronto-devflow status` says the next sprint must be
  planned, it picks that sprint's theme (or takes the owner's), reads the designed issues and the
  backlog, and fills the next sprint with the issues that serve it (`pronto-devflow next --theme`
  makes the cycle when it does not exist yet); it asks no one. When a sprint's work is merged or
  cancelled, it reports what merged, what went Live and what flags turned on, and the next sprint
  becomes current.
- **`/issue PRONTO-123`**, one session per issue. Refines the item until it has an objective,
  acceptance and a flag (Ready), takes its lane's slot (Implementing), builds it on a branch named
  `pronto-123/<slug>`, runs the repository's gate, and opens a PR whose title starts with
  `PRONTO-123`. Anything new it finds is filed as a new item, and the session decides, saying so on
  the issue, whether it is done now (it is needed for this issue's objective) or left in the Backlog
  (everything else).
- **`/design`**, the product manager's. Designs a feature with them and cuts it into issues a session
  can finish, each with an objective, acceptance, app and flag, moved to Ready for a later sprint. It
  never starts or builds one.
- **`/bug`** files a bug with its app, how to reproduce it, the flag involved and a priority, and for
  a P0 starts `/issue` on it at once.

Requests made to Claude in any other session follow rule 3: Claude files the item and says its key,
rather than building it.

## GitHub glue

One workflow in the repository keeps the board in step with GitHub. It finds the item by the
`PRONTO-<n>` key (the project's `identifier`) in the PR's title or branch, and calls the board's API
with a token held as the `PLANE_TOKEN` secret (`connect plane` sets it from the token's source):

| event | the board |
| --- | --- |
| PR opened or reopened | item → Review, PR linked on the item |
| PR merged | item → Merged |
| PR closed without merging | item → Implementing, with a comment |

A PR with no key fails a check, so no work reaches `main` without an issue (or only warns, with
`--warn`, while a repository starts). Pure chores (dependency bumps, a CI fingerprint) are exempt by
the `chore` label (`chore` in `devflow/devflow.cue` names another).

## Releases and Done

The release cron ([release-cron](../release-cron/README.md)) is unchanged: it releases `main` on its
own schedule, whatever the sprint. Two hooks report back to the board, and neither changes when or
how anything ships:

1. **After a release-cron run confirms a release**, items in Merged whose PR is in the released
   commit move to **Live** (**Done** when they have no flag).
2. **After a flag flip completes**, the item whose `Flag:` line names that flag moves to **Done**. A
   flip already runs its flag's cases: it writes the flag for everyone, then runs its `production`
   cases that need no tester, rolled back on a failure ([flag-flips.md](../docs/flag-flips.md)). So "flipped on successfully"
   means the flip reached everyone and was not rolled back. A rollback puts the item back to Live,
   with the failing case in a comment.

### When an issue with no flag is Done

A bug fix or an infrastructure change has no flag to flip, so its end is decided by what it is
(`devflow/flow.js`, `doneAt`):

| the issue | Done when |
| --- | --- |
| names a flag | the flag is on for everyone; a rollback puts it back to Live |
| names none, in an app's module (a bug fix) | it is released: the release that holds its pull request takes it Merged → Done |
| names none, in `infra` or `plugins` | its pull request merges (Review → Done): release-cron ships nothing of it |

`pronto-flags rollback` tells the board as well, for each flag it turned off. A hook that cannot reach
the board logs it and never fails the release or the push.

Turning a flag on stays a person's decision; the hooks only record what happened. An item that sits
in Live is visible on the board as shipped but not switched on, which is the gap we cannot see
without the flow.

## Starting in a repository

1. Write `devflow/devflow.cue`: the board (`board`), the token, and the team; a `cluster` only when
   the repository installs Plane.
2. `bin/pronto connect plane .`: installs Plane when there is a `cluster`, and stops at what a person
   must do (the DNS record, Plane's instance admin, the workspace and its API token); then makes the
   project, the states, a module per app, the `chore` label and the `PLANE_TOKEN` secret. Run again
   it goes on from the step it stopped at.
3. Add the workflow that runs `pronto-devflow pr`, the Plane MCP server in `.mcp.json`, and the hooks
   (release-cron's run after confirm, `pronto-flags push`).
4. Import the open PRs as items in a first catch-up sprint, so the board starts true. Run a week of
   sprints, then make the missing-key check required (drop `--warn`) and back the board's database up.

bsoneca/pronto's [rollout](https://github.com/bsoneca/pronto/blob/main/docs/dev-flow.md) of these
steps, and what it still waits on, is its own.

## Open questions

- **The team's machines**: on which machines the engineers' and the SRE's sessions run.
- **A board of another kind**: GitHub Projects' adapter (PRONTO-207) maps its items, statuses and
  iterations to the interface in `devflow/board/board.ts`.
