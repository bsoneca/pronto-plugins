---
name: pronto-modular-design
description: "Split a pronto app's design (its CUE spec) into modules, small CUE packages each exported on its own and joined by a small package, so an edit re-evaluates one module and not the whole spec; or start a new app that way. Use when an app's own `cue export` of its spec is slow or large (tens of seconds or gigabytes) and an edit to one family of data (a lesson, a question, a level) costs as much as a fresh build; not for a cheap design."
---

# pronto-modular-design

A plugin beside pronto, not part of it: the app holds the modules, the plugin writes what every modular app shares (the build
step, the lint, the generate rule, the `#Modules` schema).

## When to use it, and how to measure first

Only when the design's own export is the cost. Measure before touching anything, through the machine's budget:

```sh
deno run -A tests/slot.ts --weight 6 --what "spec build" -- /usr/bin/time -l <the export generate runs>
```

Run `CUE_EXPORTED=off` for a full build, then the same again (unchanged), then after an edit to one family of data. Report CPU-s
(user+sys) and the peak resident set. Run each export `generate` makes separately, too: the cost is often not the one you think.

- aprende: the spec was 8 evaluations of the whole spec, about 20 CPU-s and 9 GB each, and an edit to one lesson re-ran all of them.
  Split: an edit is one module and a join, about 12 CPU-s and 1.2 GB.
- Bonk Chess: the spec export is 0.45 CPU-s and 158 MB. The 9 CPU-s and 3.5 GB are `cue export .`, the app's root package, which does
  not read `spec/`. Splitting the spec would have saved nothing: it was not split. Find what is evaluated before splitting it.

If the spec alone costs a few CPU-seconds and well under a GB, stop and say so.

## Start a new modular app

From a pronto app whose four verbs are green:

```sh
${CLAUDE_PLUGIN_ROOT}/bin/pronto-modular-design .
./saytw --script tools.nu cue cmd generate ./pronto
./saytw generate && ./saytw lint && ./saytw test
```

It writes the generate rule, the build step (`modules/build.nu`), the lint (`modules/lint.ts`) and `#Modules`, and seeds, once, a
`modules/modules.cue`, a schema module, an example module and a `join/` package, which `generate` runs end to end. Replace the
example with the app's families: one module per family of data that changes together (a subject, an exam edition, a level pack).
Rerunning it changes only what is missing or regenerated; the app's own files are kept.

## Split an existing app, family by family

1. Map the families and what each reads of the others (grep the data's references). Shared definitions go in the schema; shared
   data (a list every family checks against) is its own module, read through its export.
2. Keep the output byte-identical, and diff it after every step: the file the readers read (`spec.json` in aprende), compared to
   main's after merging main. Never drop a check or slim a value; a check that spans families moves to the join.
3. One family at a time: move its files to `modules/<name>/` (package `<name>`), list it in `modules/modules.cue` (`needs`, `expr`,
   `join`, `owns`), and leave a one-line stub in the old file name in the join package that reads the module's export, so the join's
   field order stays what it was (a struct read from JSON can reorder fields).
4. A module checks its own data and exports it finished: its schema defaults and derived fields applied, its checks as hidden fields
   inside `out`. The join embeds the exports and merges their disjoint subtrees, and does not evaluate the schema over them again.

## The rules

- **Schema**: a module imports only the schema module as CUE; any other module only through its export. `modules/lint.ts` fails the
  test otherwise, and for overlapping `owns` and a `needs` cycle.
- **`deps/` embed**: `build.nu` writes each export beside every module that needs it, `modules/<m>/deps/<dep>.json`, and the module
  embeds it with `@embed(file="deps/<dep>.json")` (needs `@extern(embed)` at the top of the file). Both `deps/` and the join's
  output are ignored, never committed.
- **Join**: embeds the exports (`join` paths) and keeps only the checks that span modules (ids unique across everything, no repeats,
  derived walks). Its stubs keep the field order of the original files.

## Pitfalls

- **Hidden fields are package-scoped.** A check another package must read (`_ids`, `_habilidades`) becomes a definition field
  (`#ids`) in the schema; the old package aliases it back (`#Trilha: T={schema.#Trilha, _ids: T.#ids}`; an embedding does not bring
  its labels into scope, a `T=` alias does).
- **A definition that reads ambient data takes it as a parameter**: `#Cabe` reads the skills map, so it takes `#hab` (the one skill),
  and the package that owns the data binds it (`#Cabe: schema.#Cabe & {codigo: _, #hab: skills[codigo]}`). Pass the one entry, not
  the whole map: unifying a big map per use costs more than the split saves. Do not write `let h = #hab` and use `h` in another
  `let`: it hid conflicts from `cue vet`; inline `#hab`.
- **No parent-folder embed.** cue 0.16 refuses `@embed(file="../x/out.json")`, hence `deps/` and the join's own folder.
- **A pattern-closed definition is closed.** A struct that used to be an open pattern (`trilhasExame: [#Fonte]: {...}`) becomes
  a definition that rejects extra fields: add `...`.
- **Exports are gitignored build output.** A fresh checkout has none, so whatever evaluates the join first (the package's own
  generate step, another app that imports the spec: aprende-professor's catalogue) runs `modules/build.nu` first.
- **`generate` runs the build before pronto's writer**, which evaluates the program that reads the exports. An app whose own step
  writes module files first (an importer) calls `modules/build.nu` itself after it.
- **A tool that copies the spec** (a designer's vetting copy) needs the module's own files as data of the join's package, and the
  schema linked: see aprende's `designer/copia.ts`.
