---
name: pronto-bug
description: "File a bug on the dev-flow board (Plane) with its priority, P0 to P3, in a repository with a devflow/devflow.cue such as bsoneca/pronto. Use when the user reports something broken, a regression, an error in production, or says /bug, P0, P1, urgent fix."
---

# pronto-bug

A bug carries a priority that decides whether it waits for a sprint (bsoneca/pronto's
docs/dev-flow.md, rule 6). Filed through `pronto-devflow` (this plugin's `bin/pronto-devflow`,
run bare from the repository).

| Priority | When | Where it goes |
| --- | --- | --- |
| P0 | production is broken for players or payments, data is at risk | Implementing now, past the slots |
| P1 | a real feature is broken, with a way around it | the current sprint, after the work in progress |
| P2 | wrong, but few notice | the Backlog, for a coming sprint |
| P3 | cosmetic | the Backlog |

## Steps

1. Find out, in at most two questions: the app, what happens, what should, how to make it
   happen, and the flag of the feature it breaks if there is one (the app's `flags_spec.cue`).
2. Propose the priority with the table's reason; the user may change it.
3. File it: `pronto-devflow file . --bug --priority P1 --app <app> --title "<what is broken>"
   --body "<steps, what happens, what should>" [--flag <flag>]`. Say its key.
4. For a P0: the first response is turning its flag off (`pronto-flags push`, with the flag's
   default false) when it has one; then work it at once with the pronto-issue skill.
