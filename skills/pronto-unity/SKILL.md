---
name: pronto-unity
description: "Opt a pronto app into pronto-csharp's Unity host, or refresh its opt-in: one declaration (unity_surface.cue) naming which screens Unity draws, the USS look of each, the hostDom hatches the host draws, the scenarios it runs. Use when the user wants a pronto app drawn by Unity, on the Unity host, or in a Unity project."
---

# pronto-unity

The Unity host ([bsoneca/pronto-csharp](https://github.com/bsoneca/pronto-csharp): the terminal in C#
on Jint, the screen drawn by UI Toolkit, a UPM package `com.bsoneca.pronto`) runs a pronto app's own
program, handlers and store. An app is drawn there only when it says so. Without the opt-in it has no
Unity file and the host stages nothing of it.

## What the app gets

| Path | Owner |
| --- | --- |
| `unity_surface.cue` | regenerated: the declaration (`unity:`), in the app's package, and `unityOfProgram`, which reads each named screen's route and hatch's kind from the program so `lint` (`cue vet`) refuses a name the program lacks |
| `unity/unity.json` | regenerated: the same declaration as JSON, the only thing the host reads |
| `unity/hatches/<hatch>/binding.json` | regenerated from the app's `binding.cue` (a `generated` key marks it): never edited |
| `unity/screens/<screen>.uss`, each `shared` sheet | seeded once, then the app's: the Unity look, USS over the same markup the web draws (`data-x="v"` is class `x--v`) |

What the declaration says:

- `screens.<s>`: `uss` (default `unity/screens/<s>.uss`) and `shared` sheets. A screen not listed still
  runs (the program is unchanged) but gets no Unity look and no hatch.
- `hatches`: hostDom hatches the host draws, by name. Either a map `{<name>: {binding: "unity/hatches/<name>/binding.json"}}`
  or the older list of names. A name with no binding (every name of the list form) is never mounted, and
  the screen falls back to its markup; a bound one is drawn by the app's own module, with no C#
  ([the contract](https://github.com/bsoneca/pronto-csharp/blob/main/docs/pronto-unity-hatch-contract.md)).
- `scenarios`: scenario files (shared schema, as solitaire's `tests/scenarios/schema.cue`) the host
  runs: the app's own `tests/scenarios/…` or ones written for Unity, `unity/scenarios/…`.
- `suites` (default `all`): which of the app's unit suites (`tests/unit/suites.cue`) run on the host, through its `tests/unit/registry.js`; `server` is a map of the suites left to the server with the reason (SQL on PGlite or a database): every suite the app has is in one or the other, and a server suite is counted, never failed. (`cases=true|false`, the older flag, is all or none.) `cluster` (default false):
  its scenarios need the running stack. `stage`: more of the app a hatch reads.

## Adding it to an app

From a pronto app whose four verbs are green:

1. `${CLAUDE_PLUGIN_ROOT}/bin/pronto-unity . screens=<a,b> [shared=…] [hatches=…] [scenarios=…] [suites=<a,b>] [server=<suite>=<why>;…] [cluster=true] [stage=…]`.
   An argument not given keeps what `unity/unity.json` declares; `hatches=` clears one.
2. Write the look in the seeded `.uss` files.
3. `./saytw generate`, `lint`, `test`, `integrate@local`: none changes for the opt-in, and `lint`
   refuses a screen or hatch the program lacks.
4. On the host: `<pronto-csharp>/tools/unity-check.sh .` runs the cases and scenarios through it.

## Binding a hatch

A hostDom hatch the host draws is the app's own pure JavaScript module plus a binding. Write
`unity/hatches/<hatch>/binding.cue` in the app's package (whatever `program.cue` names) and the module it names:

```cue
package myapp

module: "unity/hatches/battle/board.js"   // an ES module of the app; imports allowed
reads: games: {select: "[data-games] [data-row]", attrs: ["data-row", "data-fen"]}   // what it sees of its screen
submits: ["form[data-intent]"]            // the only forms it may fill and submit
clicks: []                                // the only elements it may click (default [])
tick: hz: 60                              // optional, 1..120: the host calls tick() at this rate
input: ["left", "fire"]                   // optional, only with tick: the held controls passed in
```

Run `bin/pronto-unity . hatches=<hatch>` (a hatch with a `binding.cue` is listed even when `hatches=` omits
it). It checks the binding against `#HatchBinding` (a `module` ending in `.js`/`.mjs` inside the app, a `reads`
selector and attrs, non-empty `submits` selectors, `tick.hz` 1 to 120, `input` only with `tick`), refuses a
module that is not a file of the app, and writes `binding.json` and the map entry. The module's exports
(`init`, `view`, `gesture`, `tick`), its context and its outcomes are in [the contract](https://github.com/bsoneca/pronto-csharp/blob/main/docs/pronto-unity-hatch-contract.md).

What is checked where: the generator checks the schema and that the module file exists (CUE cannot stat
files); `lint` (`cue vet`) checks, from the program, that the hatch is a `hostDom` hatch listed on a screen
that Unity draws and that no `submits` selector is empty. That each selector matches the screen's markup is
not checked by either; a scenario on the host is what proves it.

To opt out, delete `unity_surface.cue` and `unity/`.
