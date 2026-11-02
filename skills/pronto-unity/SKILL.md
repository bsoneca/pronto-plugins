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
| `unity/screens/<screen>.uss`, each `shared` sheet | seeded once, then the app's: the Unity look, USS over the same markup the web draws (`data-x="v"` is class `x--v`) |

What the declaration says:

- `screens.<s>`: `uss` (default `unity/screens/<s>.uss`) and `shared` sheets. A screen not listed still
  runs (the program is unchanged) but gets no Unity look and no hatch.
- `hatches`: hostDom hatches the host draws, by name. Their C# is the host's (pronto-csharp
  `hatches/`), never a loose file in the app; a hatch not listed is never mounted.
- `scenarios`: scenario files (shared schema, as solitaire's `tests/scenarios/schema.cue`) the host
  runs: the app's own `tests/scenarios/…` or ones written for Unity, `unity/scenarios/…`.
- `cases` (default true): the app's `tests/unit/*.cue` run on the host. `cluster` (default false):
  its scenarios need the running stack. `stage`: more of the app a hatch reads.

## Adding it to an app

From a pronto app whose four verbs are green:

1. `${CLAUDE_PLUGIN_ROOT}/bin/pronto-unity . screens=<a,b> [shared=…] [hatches=…] [scenarios=…] [cases=false] [cluster=true] [stage=…]`.
   An argument not given keeps what `unity/unity.json` declares; `hatches=` clears one.
2. Write the look in the seeded `.uss` files.
3. `./saytw generate`, `lint`, `test`, `integrate@local`: none changes for the opt-in, and `lint`
   refuses a screen or hatch the program lacks.
4. On the host: `<pronto-csharp>/tools/unity-check.sh .` runs the cases and scenarios through it.

To opt out, delete `unity_surface.cue` and `unity/`.
