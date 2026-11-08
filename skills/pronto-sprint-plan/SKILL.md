---
name: pronto-sprint-plan
description: "Close the day's sprint and plan the next one on the dev-flow board (Plane), in a repository with a devflow/devflow.cue such as bsoneca/pronto. Use when the user says plan the sprint, sprint planning, what's next, end of day, close the sprint, or /sprint-plan; also when a scheduled task runs the daily planning."
---

# pronto-sprint-plan

A sprint is one day (bsoneca/pronto's docs/dev-flow.md). Planning is where the developer is most
involved: they set the objective, Claude proposes the issues, they approve. Everything here goes
through `pronto-devflow` (this plugin's `bin/pronto-devflow`, on the PATH while the plugin is
enabled), run bare from the repository: never move an issue on the board by hand.

## Steps

1. **Close the day that ended.** `pronto-devflow close . --json`. It takes the issues that did not
   merge out of that sprint (Refine goes back to the Backlog; Ready, being designed, stays Ready for a
   later sprint; work in progress keeps its state). Report it in a few lines: what merged, what went Live, which flags went on (Done), what
   slipped and why if a comment says.
2. **Ask for the objective.** One question: what should tomorrow's sprint achieve? Offer, as the
   default, the objective the slipped work implies. Ask also whether the team changes
   (devFlow.team in devflow/devflow.cue: engineers, SREs, product managers; a change there is a
   pull request).
3. **Propose the issues.** Read what the product managers designed (`pronto-devflow status . --json`,
   its `designed`: Ready issues in no sprint) and then the Backlog (the Plane MCP server's list of
   work items), and pick the issues that serve the objective, in order, no more than the day can
   merge: about two per engineer for the apps, two per SRE for `infra`. P1 bugs come first, then
   designed issues. Each
   proposal says its key, title, app and why it serves the objective. A need with no issue yet
   is filed first (`pronto-devflow file . --title "..." --app <app>`), never built.
4. **Wait for the developer's yes**, or their edits to the list. Do not plan without it.
5. **Open the sprint.** `pronto-devflow next . PRONTO-12 PRONTO-15 ...`: the day's cycle, those
   issues in Refine. Say the sprint's name, its end, and the first issue to start.

## Rules

- A feature request is never built from planning: it is an issue (rule 3).
- Planning does not start work: each issue is its own session (the pronto-issue skill).
- Without a board token, `pronto-devflow` says so: point the user at `pronto connect plane .`.
