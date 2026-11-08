---
name: pronto-design
description: "The product manager's session on the dev-flow board (Plane), in a repository with a devflow/devflow.cue such as bsoneca/pronto: design new features for later sprints, turning an idea or a Backlog issue into Ready ones (objective, acceptance, app, flag), each one day's work. Use when the user wants to design, spec, shape or plan a feature ahead of a sprint, or says /design."
---

# pronto-design

The team has product managers (devFlow.team.product in devflow/devflow.cue) who build nothing and
take no slot: they design what later sprints build (bsoneca/pronto's docs/dev-flow.md, Agents and
the team). A designed issue is **Ready** and in no sprint; the next planning (`pronto-sprint-plan`)
picks from those first. Moved through `pronto-devflow` (this plugin's `bin/pronto-devflow`, run
bare from the repository): never move an issue on the board by hand.

## Steps

1. **Start from the board.** `pronto-devflow status . --json` says what is already designed and
   how big the Backlog is; read the issues the idea touches (the Plane MCP server's work items). An
   idea with no issue is filed first: `pronto-devflow file . --title "..." --app <app>`.
2. **Design it with the user**: who it is for, what they can do after it that they cannot now, and
   how we will know it works. Read the app enough to say where it lands (its spec in CUE, its
   screens), not to build it.
3. **Cut it into days.** Each piece is one issue that one session can merge in a day, behind one
   flag. File every piece (`pronto-devflow file`), each in its app's module, an infrastructure
   piece in `infra` (an SRE's).
4. **Write each piece down**, in its description: the objective, how it is accepted (the unit cases
   and scenarios it adds, as tests/unit/*.cue and tests/scenarios/*.cue), its app, and its flag on
   a line of its own, `Flag: <name>`, a new flag named as the app's `flags_spec.cue` would declare
   it. Then `pronto-devflow move . PRONTO-<n> Ready --why "designed"`.
5. **Say what is ready**: the keys, in the order a sprint should build them, and what each needs
   from another.

## Rules

- Never start an issue, open a branch or write the app's code: building is a sprint's.
- Never add an issue to a sprint: planning does, with the developer's yes.
