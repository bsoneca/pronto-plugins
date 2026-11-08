# modular-design

An app's design split into modules: small CUE packages, each evaluated and exported on its own, so a change re-evaluates the
module it touches and the step that joins them, never the whole design. It pays only when the design's own `cue export` is the
cost: measure first ([`pronto-modular-design` skill](../skills/pronto-modular-design/SKILL.md)).

## What a module is

- A CUE package in the app's `modules/<name>/`, with its own files only.
- It imports the app's **schema** module (`modules/schema`: the shared definitions) as CUE: definitions do not survive an export,
  and a schema is cheap to evaluate.
- It reads any other module's **export**, not its CUE: `modules/build.nu` copies each export a module needs into the module's own
  (ignored) `deps/` and the module embeds it, `@embed(file="deps/<dep>.json")` (cue 0.16 refuses an embed of a parent folder). An
  importer never re-evaluates its dependency, and the cue wrapper's key changes only when that export changes, not when its
  sources are reworded.
- It owns a disjoint subtree of the app's data, declared in `modules/modules.cue`. Two modules never write the same field.
- Its checks are hidden fields of what it exports (`out`), so exporting it is vetting it.

## Use

From a pronto app (a `program.cue`, a `cue.mod`):

```sh
<this repo>/bin/pronto-modular-design . 
./saytw --script tools.nu cue cmd generate ./pronto   # the seat: the generate rule
./saytw generate && ./saytw lint && ./saytw test
```

| Path in the app | Owner |
| --- | --- |
| `pronto/modular_design.cue` | regenerated: the `generate` rule (`nu modules/build.nu`), before pronto's writer, since the writer evaluates a program that reads the exports |
| `modular_design_plugin.cue` | regenerated: the schema (`#ModularDesign`, its `test` check), in the program's package |
| `modules/modules_plugin.cue` | regenerated: `#Modules`, in package `modules` |
| `modules/build.nu` | regenerated: the build step, each module exported in `needs` order, independent ones side by side |
| `modules/lint.ts` | regenerated: the lint |
| `modular_design_spec.cue` | seeded, then the app's: opts the lint into the program's checks |
| `modules/modules.cue`, `modules/schema/`, `modules/example/`, `join/` | seeded once, in an app with no `modules/modules.cue`: the app's own from then on |
| `.gitignore` | each module's `deps/` and each place an export is written for the join, added when missing |

`modules/modules.cue` lists the modules, held by `#Modules`: `needs` (the modules whose exports it reads), `expr` (what of the
package is its export), `join` (where the export is also written, for the package that joins the modules) and `owns` (dotted
paths of the data it writes, a segment `*`, `a|b` or `1-9`).

The **join** is a package of the app's that embeds the exports and merges their disjoint subtrees. It checks only what spans
modules; each module has already checked its own data.

## The lint

`modules/lint.ts` runs in `test` and fails when a module imports another module's CUE (the schema excepted), when two modules own
overlapping paths, when `needs` has a cycle or names a module that is not listed, or when a folder under `modules/` is not listed.

## Tests

- [`tests.cue`](tests.cue): what the host writes, checked with `cue vet`.
- [`test.nu`](test.nu): the installer, the build step and the lint against a fresh example app, including an overlap, a
  cross-module import and a cycle the lint refuses.

```sh
./saytw --script tools.nu cue vet -c ./modular-design
./saytw --script tools.nu cue vet -c -t package=check -t module=check ./modular-design/export
./saytw --script tools.nu nu modular-design/test.nu
```

## First users

aprende (`apps/aprende/modules`): the schema, the BNCC, one module per subject and per exam edition, one per exam, and a join
(`spec/`) that no longer evaluates what the modules checked. A lesson edit costs about 12 CPU-s and 1.2 GB, from about 170-200
CPU-s and 9 GB. Bonk Chess was measured and not split: its spec costs 0.45 CPU-s; the cost is the root package's export.
