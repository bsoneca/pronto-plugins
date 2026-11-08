---
name: pronto-issue
description: "Work one issue of the dev-flow board (Plane) from refinement to a merged pull request, in a repository with a devflow/devflow.cue such as bsoneca/pronto. Use when the user names an issue key (PRONTO-123), says work on / pick up / start / implement an issue, or /issue; also when any request to build a feature arrives, which this files as an issue instead of building it."
---

# pronto-issue

One issue, one Claude session (bsoneca/pronto's docs/dev-flow.md, rule 5). The board moves through
`pronto-devflow` (this plugin's `bin/pronto-devflow`, run bare from the repository) and the hooks;
never by hand.

## A request that is not an issue yet

A feature or change asked for in plain words is filed, not built (rule 3):
`pronto-devflow file . --title "<what it does>" --app <app> --body "<the request, in the user's words>"`.
Say its key, and that planning picks it up. Build it now only if the user says it is today's
sprint's, and then it goes through the steps below like any other.

## Steps for PRONTO-<n>

1. **Read it**: the issue, its comments and links (the Plane MCP server's work-item tools).
2. **Refine** (Refine, then `pronto-devflow move . PRONTO-<n> Ready`): it is Ready when its
   description says the objective, how it is accepted (the unit cases and scenarios it adds, as
   tests/unit/*.cue and tests/scenarios/*.cue), its app (its module), and its flag on a line of
   its own, `Flag: <name>`, the flag declared in the app's `flags_spec.cue`. An objective that
   cannot merge within the day is split into issues, each filed, before it is Ready.
3. **Start**: `pronto-devflow start . PRONTO-<n>`. It refuses while its lane is full, a P0
   excepted: an `infra` issue takes an SRE's slot, any other an engineer's (devFlow.team). Then
   say which issues hold the lane's slots and stop.
4. **Build** on a branch named `pronto-<n>/<slug>`, following the repository's AGENTS.md: behind
   the flag, tests as data, its gate.
5. **Open the pull request** ready for review, its title starting `PRONTO-<n>:`. The plane
   workflow moves the issue to Review, and to Merged once it merges; release-cron makes it Live and
   the flag's flip Done.
6. **What you learn on the way** becomes new issues (`pronto-devflow file ...`), each linked in a
   comment. Do it now only when this issue's objective needs it; say on the issue which you chose.

## Rules

- Never move an issue to Review, Merged, Live or Done yourself: the hooks do, from what happened.
- Cancelled is `pronto-devflow move . PRONTO-<n> Cancelled --why "<reason>"`.
