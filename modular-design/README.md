# modular-design

An app's design split into modules: small CUE packages, each evaluated and exported on its own,
so a change re-evaluates the module it touches and the step that joins them, never the whole
design. Smaller cues, faster builds. Design status: proposed (2026-11-08); the measures below
decide it.

## Why

An app's design is one CUE package today. aprende's (`apps/aprende/spec`) is ~30 MB of output:
`cue export` of it costs ~1,350 CPU-s and 14.5 GB, and an edit to one ENEM question costs the
same as a fresh build because the package is one evaluation. pronto's cue wrapper
(`tools/cue-budget`, bsoneca/pronto#858) already replays any export whose inputs are unchanged,
keyed by its package's files, its in-module imports and its embeds. What it cannot do is replay
*part* of a package. Modules give it parts.

## What a module is

- A CUE package in the app's `modules/<name>/`, with its own files only.
- It imports the app's **schema** module (`#Defs`, the shared constraints) as CUE: definitions do
  not survive an export, and a schema is cheap to evaluate.
- It reads any other module's **export**, not its CUE: the build copies each export it needs into
  the module's own (ignored) `deps/` and the module embeds it, `@embed(file=deps/<dep>.json)` (cue
  0.16 refuses an embed of a parent folder). An importer never re-evaluates its dependency, and the
  wrapper's key changes only when that export changes, not when its sources are reworded.
- It owns a disjoint subtree of the app's data (`trilhas."7".ma`, `exames.enem."2021"`), declared
  in the app's `modules.cue`. Two modules never write the same field.

## What the app writes

`modules.cue`, the app's own, held by this plugin's `#Modules`:

```cue
modules: {
	schema: {}
	bncc:   {needs: ["schema"], owns: ["habilidades"]}
	ma:     {needs: ["schema", "bncc"], owns: ["trilhas.*.ma", "aulas.*.ma"]}
	enem2021: {needs: ["schema", "bncc"], owns: ["exames.enem.\"2021\""]}
}
join: "spec"  // the package that reads every module's export and checks what spans them
```

## What the plugin adds

- A generate rule that exports each module in `needs` order through the cue wrapper, independent
  ones in parallel within the app's slot weight. An unchanged module is replayed in well under a
  second, and its export file stays byte-identical, so its dependents' keys stay the same too.
- The **join** step: a small package that embeds every module's export, merges the disjoint
  subtrees (a merge, not a unification of whole programs) and runs only the checks that span
  modules (unique ids, the paths between subjects, the exam grids). Its result is the file the
  app's readers already read, so `program.cue`, tests and scenarios are unchanged.
- A lint, run in `test`: a module that imports another module's CUE (other than the schema),
  two modules owning overlapping paths, or a `needs` cycle fails it.

## Order of work

1. This document.
2. aprende split into modules (map: subjects ma, lp, ci, hi, ge, li; bncc; rumo; one per exam
   edition; join), its `spec.json` byte-identical to today's, then measured through
   `tests/slot.ts` with `/usr/bin/time -l`: full build, unchanged, one ENEM 2021 question
   changed, one subject's lesson changed (CPU-s and peak memory, before and after).
3. Bonk Chess (`apps/brawl-chess/spec`) the same way.
4. Every other app takes it when its design grows past one cheap evaluation.

## First measure: aprende, two modules (2026-11-08)

bsoneca/pronto branch `feat/aprende-modules`: `ma` (Matemática 1–9) and `enem2021` split out
beside `schema` and `bncc`; `spec.json` byte-identical to main's. Through `tests/slot.ts`, CPU-s
(user+sys) and peak memory:

| case | before | after |
| --- | --- | --- |
| full build, cache off | 199.7 s, 8.9 GB | 222.6 s, 10.6 GB |
| unchanged | 1.7 s, 0.37 GB | 3.3 s, 0.54 GB |
| one ENEM 2021 question | 45.9 s, 8.7 GB | 26.0 s, 9.0 GB |
| one ma lesson | 167.3 s, 8.9 GB | 23.5 s, 9.0 GB |

A module costs ~1 s and 0.5 GB; the join (~21 s, 9 GB) is now every edit's cost. So the next
step is a smaller join: it merges the exports' disjoint subtrees without evaluating `#Trilha` or
`#Aula` over them again, the per-module checks having already run. Hidden fields read across
files become definitions (`#ids`), and definitions that read ambient data (`#Cabe`) take it as a
parameter.

## Not in scope

- Slimming any design: every value and every check stays, the cross-module ones in the join.
- Per-app scripts: what an app has is its `modules.cue`; the rule, the join and the lint are the
  plugin's, written once.
