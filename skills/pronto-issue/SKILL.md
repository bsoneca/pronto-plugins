---
name: pronto-issue
description: "Work one issue of the dev-flow board (Plane) from refinement to a merged pull request, in a repository with a devflow/devflow.cue such as bsoneca/pronto. Use when the user names an issue key (PRONTO-123), says work on / pick up / start / implement an issue, or /issue; also when any request to build a feature arrives, which this files as an issue instead of building it."
---

# pronto-issue

One issue, one Claude session (devflow/dev-flow.md, rule 5). The board moves through
`pronto-devflow` (this plugin's `bin/pronto-devflow`, run bare from the repository) and the hooks;
never by hand.

## A request that is not an issue yet

A feature or change asked for in plain words is filed, not built (rule 3):
`pronto-devflow file . --title "<what it does>" --app <app> --body "<the request, in the user's words>"`.
Say its key, and that the next sprint's planning picks it up. Build it now only if the user says
to take it now (it joins the current sprint), and then it goes through the steps below like any
other.

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
5a. **A flag merged off gets its own flip issue.** When there are flags to be flipped, there is an
   issue for each (the owner, 2026-11-10). The plane workflow files it: a merged pull request that
   adds a flag whose default is false to an app's `flags_spec.cue` gets "Flip <flag> on in <app>" in
   the Backlog, in the app's module, with the flag's note, a `Flag: <flag>` line and the pull request
   linked; one already titled so for that app (filed by hand) is reused, never doubled.
   `pronto-flags push` of the flag for everyone marks it Done (`hook.ts flipped`). Don't file one by
   hand for a flag a pull request adds; a flip waits for the owner's go, so it is never pulled into a
   sprint unless the owner says so.
   **A flag on for a week gets its removal issue.** Once a flip issue has been Done for 7 days, the
   released hook (release-cron runs it after each release, so there is no scheduler) files "Remove flag
   <flag> from <app>" in the Backlog, in the app's module, linking the flip issue (the owner,
   2026-11-11). Done means the flag and its off-path code are deleted from the app (`flags_spec.cue`,
   `flags/flags.json`, the code, the scenarios) and shipped through release-cron. One already on the
   board, in any state, is reused, never doubled. `pronto-devflow removals . <app>` runs it by hand.
5b. **Pull the next one, always.** An idle engineer is money spent for nothing (the owner,
   2026-11-09), so the moment an issue leaves your hands (its pull request opens, or it is
   cancelled or abandoned) you start the next one in the same turn; you never end a turn idle
   while the board has work. Sprints run in an endless loop (the owner, 2026-11-10): when the
   current sprint has nothing left for you, you start the next sprint. Review holds no slot. In
   this order:
   1. `pronto-devflow pull . [--lane SRE]` (engineer by default): it starts the lane's next Ready
      issue, the current sprint's first and then the next sprint's, most urgent first.
   2. Nothing Ready: take the most urgent issue still in Refine in your lane
      (`pronto-devflow status .`), the current sprint's first and then the next sprint's, that no
      one else is refining and that waits on nothing the owner must do. Refine it yourself
      (step 2), move it to Ready, and start it (step 3).
   3. Neither sprint has anything left to refine or start, or there is no next sprint yet: tell
      the lead (SendMessage to the session that started you, or a comment on the sprint) that your
      lane is empty. The lead plans the next sprint at once (the pronto-sprint-plan skill); help
      (5c) until it does, then pull again.
   Work each issue the same way, as its own session, and say which you started.
5c. **Nothing to start: help finish the sprint.** An engineer or SRE for whom 5b found nothing to
   start becomes a helper until the lead plans the next sprint. A helper takes no new issue from the Backlog and files none to keep busy; it
   helps the current sprint's open issues (`pronto-devflow status .`: Implementing and Review) merge.
   It looks first in its own app or lane, then in any. In this order:
   1. **A failing gate or ci on an open pull request.** Reproduce it, find the cause, and hand the
      issue's owner the diagnosis: the failing step, the evidence and the fix it points to.
   2. **A piece of an Implementing issue that can merge on its own,** such as a plugin change an
      app's change waits on, or one app of many in a bump. Agree it with the owner first. It is a
      pull request of the helper's own, titled with the same key (`PRONTO-<n>: ...`) on
      `pronto-<n>/<slug>-<part>`, with its own gate.
   3. **Evidence an open pull request still lacks,** such as a scenario it added run alone, or a
      measure its description promises.
   Ask the owner before starting (SendMessage to its session, or a comment on the issue), and say
   on the issue what you are doing. The issue keeps its owner: a helper never pushes to the
   owner's branch, never edits files the owner has in hand, and never moves the issue. Gates
   share the machine's slots, so when they are full (`deno run -A tests/slot.ts status` in an app, or the
   machine dashboard), diagnosis and reading come before starting another gate. When nothing in
   the sprint needs help, say so to the lead, and pull the moment it says the next sprint is
   planned.
6. **What you learn on the way** becomes new issues (`pronto-devflow file ...`), each linked in a
   comment. Do it now only when this issue's objective needs it; say on the issue which you chose.

## Rules

- Never move an issue to Review, Merged, Live or Done yourself: the hooks do, from what happened.
- Cancelled is `pronto-devflow move . PRONTO-<n> Cancelled --why "<reason>"`.
- An engineer is never idle: finishing one issue means starting the next (5b), from the next
  sprint when the current one has nothing left, refining it first when nothing is Ready. Being idle is still never a reason to file new work.
