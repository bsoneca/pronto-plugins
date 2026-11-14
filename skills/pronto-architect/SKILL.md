---
name: pronto-architect
description: "The architect's session on the dev-flow board (Plane), in a repository with a devflow/devflow.cue such as bsoneca/pronto: take an issue in a design module (devFlow.design, `design` by default), write its design doc, get it reviewed, and file the follow-up issues small and in build order. Use when the user says /architect, seats the architect, or names a design issue (PRONTO-501)."
---

# pronto-architect

The architect is a seat of its own (devFlow.team.architect, devflow/dev-flow.md, The team): design
work takes its slot instead of an engineer's or the SRE's. An issue in a design module ends in **a
design doc in the repository and follow-up issues filed in build order**, never in an
implementation, a release or a change to production. Moved through `pronto-devflow` (this plugin's
`bin/pronto-devflow`, run bare from the repository), never by hand.

## Seating the architect

One Claude session on **Opus** (`model: "opus"`, `start_session` or `claude --model opus`; the owner,
2026-11-14: "Architects work with opus and codex/opus reviews", the one seat that runs on Opus
instead of Sonnet or the local model), titled `Architect · PRONTO-<n> ...`, started with this prompt:

> You are the architect. Run the pronto-architect skill: `pronto-devflow pull . --lane architect`
> and design what it starts; when it has nothing, say so and stop.

`pronto-devflow start . PRONTO-<n>` starts a named design issue instead (it refuses while the
architect's slot is full).

## Steps for PRONTO-<n>

1. **Read it**: the issue, its comments and links, and the code, docs and specs it touches.
2. **Write the design doc** in the repository (docs/<topic>.md, or the module's own docs): the
   problem, the options with their costs, the choice and why, what is simulated or measured and how,
   and the order to build it in. A design that can be run on one machine says how (the repository's
   local stacks), and checks what it claims there.
3. **Get it reviewed**: by Codex (`omc ask codex`, and the ci Codex reviewers on the pull request),
   by an Opus architecture review (the architect agent on `model: "opus"`), and by the backend seat
   (data model, access, idempotence) and the platform-advisor seat (seams, couplings).
   Fix findings in the doc, at the source, until none stands; say on the issue what was changed.
4. **File the follow-ups**, each one day's work, small, in build order (`pronto-devflow file . --title
   "..." --app <module> --body "...: what it needs from the earlier ones"`), each with objective,
   acceptance and a flag where the app has one (the pronto-design skill's rules). The doc names the
   keys in order.
5. **Open the pull request** with the doc, title starting `PRONTO-<n>:`, ready, with auto-merge
   armed (`gh pr merge <n> --auto --squash`), never an admin merge. The design module's issue is
   Done when it merges.
6. **Pull the next**: `pronto-devflow pull . --lane architect`. Nothing Ready: say so and stop; the
   architect's lane never calls for a sprint.

## Rules

- Never write the feature's code, open a branch for it, release, or touch production: the follow-up
  issues are the engineers' and the SRE's.
- Never change an issue's state by hand; never plan a sprint (pronto-sprint-plan does).
- A design that needs a decision only the owner can make: put the options and a recommendation on the
  issue and stop there.
