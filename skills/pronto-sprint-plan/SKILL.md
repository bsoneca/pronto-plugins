---
name: pronto-sprint-plan
description: "Run the endless loop of sprints on the dev-flow board (Plane), in a repository with a devflow/devflow.cue such as bsoneca/pronto: close a finished sprint and plan the next one, choosing its theme from the board. Use when the user says plan the sprint, sprint planning, what's next, close the sprint, or /sprint-plan; when an engineer reports its lane is empty; when a sprint finishes; and when a scheduled task checks the loop."
---

# pronto-sprint-plan

Sprints run in an endless loop (the owner, 2026-11-10). Everything on the board is work the owner
wants built, so a sprint needs no one's yes: the lead (this session) groups Backlog and designed
issues into a sprint, the engineers build it, and the next sprint is already there when they run
out. A sprint is a Plane cycle named `Sprint <n>: <theme>`; it ends when all its issues merge (or
are cancelled), at any hour, not on a calendar. Everything here goes through `pronto-devflow` (this
plugin's `bin/pronto-devflow`, on the PATH while the plugin is enabled), run bare from the
repository: never move an issue on the board by hand.

## The loop

There are at most two open sprints: the **current** one and the **next**. `pronto-devflow status .`
says both, the lanes that have nothing left to start in the current sprint (`dry`), and `plan: true`
when the next sprint must be planned now.

1. **Plan the next sprint as soon as a lane runs dry.** An engineer or SRE that finds nothing to
   start in the current sprint pulls from the next (the pronto-issue skill, 5b), so the next sprint
   has to exist before that happens. Plan it the moment `status` says `plan: true`, or an engineer
   reports its lane empty, or the first sprint is due (no sprint open). Never wait for the current
   sprint to finish.
2. **Choose the theme.** The owner's word wins: when he has said what a sprint is about ("next
   sprint: payments"), that is the next one's theme, and its issues are the ones that serve it.
   Otherwise choose it yourself, without asking, in this order:
   1. P1 bugs not in a sprint yet.
   2. What the sprint that just merged unblocked: issues that waited on it.
   3. A coherent theme: issues of one app or one feature, so the engineers' pull requests touch
      the same code and conflict less. Designed issues (`status --json`, `designed`) before Backlog
      ones of the same theme.
   4. Value and age: what the owner filed first, among the rest.
   A need with no issue yet is filed first (`pronto-devflow file . --title "..." --app <app>`).
3. **Fill it to capacity.** `sprint.perPerson` (3) for each engineer and each SRE: 12 app issues and
   3 `infra` issues for 4 engineers and 1 SRE. `next` refuses a plan past a lane's capacity. Keep
   each app's share by hand (2 on Bonk Chess, 2 on Studio). A lane with too few issues in the theme
   takes the most urgent of the rest, so no lane starts the sprint short.
4. **Open it.** `pronto-devflow next . --theme "<theme>" PRONTO-12 PRONTO-15 ...`: the issues go to
   the next sprint (made when absent; the current one when nothing is open) in Refine. Then tell the
   owner in a few lines: the sprint's name, its theme and why, its issues by lane. Do not wait for
   an answer; tell the dry engineers to pull (SendMessage to their sessions).
5. **Close a finished sprint.** When `status` shows a sprint finished (its `current` moved on, or
   `last finished` changed), `pronto-devflow close . --json` reports it: what merged, what went
   Live, which flags went on (Done), what was cancelled. Tell the owner in a few lines, with the
   next theme. Nothing slips: a sprint ends only when its issues have.
6. **Back to 1.** The loop never ends while the board has work. With the Backlog empty and nothing
   designed, say so to the owner and stop; the next issue filed starts it again.

## The team

The team is devFlow.team in devflow/devflow.cue (engineers, SREs, product managers). Change it
only when the owner asks; a change there is a pull request.

## Rules

- The owner never has to approve a sprint. He steers it when he wants to: a theme, an issue to
  take now, an issue to leave out. His word wins over every rule above.
- A feature request is never built from planning: it is an issue (rule 3).
- Planning does not start work: each issue is its own session (the pronto-issue skill).
- **No idle engineer, ever.** An engineer finishing an issue starts the next one at once: the
  current sprint's, then the next sprint's (`pronto-devflow pull`). So the next sprint is planned
  while the current one still runs. An issue the owner files goes into the next sprint planned;
  the owner can say to take it now, and then it joins the current sprint.
- **A blocked issue does not hold a sprint open.** An issue that waits on the owner (a question, an
  account, a decision) goes back to the Backlog with the question
  (`pronto-devflow move . PRONTO-<n> Backlog --why "<the question>"`), which takes it out of its
  sprint; the next planning after his answer picks it up.
- Stop and ask the owner only before what cannot be undone: production data, deleting what is
  his, spending money, anything sent outside. Everything else goes on.
- Without a board token, `pronto-devflow` says so: point the user at `pronto connect plane .`.
- A scheduled task may run this skill as a safety net (every few hours: `status`, then plan or
  close as it says). The loop does not depend on it.
