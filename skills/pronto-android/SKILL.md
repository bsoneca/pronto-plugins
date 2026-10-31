---
name: pronto-android
description: "Add pronto's Android host to a pronto app, or refresh it: a native Android app with no WebView that runs the program's own handlers under SES in QuickJS and draws DivKit, with its toolchain pinned through mise and @android sayt verbs. Use when the user wants a pronto app on Android or on their phone."
---

# pronto-android

The Android host is a plugin beside pronto, not a pronto target: pronto 0.14.0
admits no `android` in `meta.targets`, so the app stays a web pronto app and
holds the host's generated files. Why it is shaped this way:
[a native terminal](../../docs/native-terminal.md). A working app:
[examples/hello-android](../../examples/hello-android).

## What the app gets

| Path | Owner |
| --- | --- |
| `.say.json` | regenerated: `setup`, `build`, `test`, `launch` rules, each answering `@android` alone; sayt merges it with pronto's `.say.yaml` |
| `.config/mise/conf.d/android.toml` | regenerated: Temurin JDK, the SDK's cmdline-tools, Gradle |
| `android/` Gradle project, engine and activity | regenerated: the app's package is `dev.pronto.<name>`, hyphens as `_` |
| `android/app/src/main/assets/screen.js` | seeded once, then the app's: the phone's screen |
| `android/app/src/main/assets/autofill.json` | seeded once, then the app's: the fill handler, the tables it reads, and the vault's columns |

The Gradle project takes the app's `shell/` as its assets, so the phone runs
the handlers pronto lints and tests, and starts from the seed pronto emits
into `shell/shell.json`. The program's `device` tables live in SQLite, each
row AES-GCM sealed under a data key that a strong-biometric Keystore key
wraps: the app opens locked, unlocks once, and locks when it leaves the
screen. An `AutofillService` runs the handler `autofill.json` names, headless
and caged, to choose which rows fill a site or an app.

## Adding it

The app must already be a bootstrapped pronto app with its four verbs green
(pronto's `pronto-turn` skill and its bootstrap reference). Then, from the app:

```sh
${CLAUDE_PLUGIN_ROOT}/bin/pronto-android .
./saytw --script tools.nu mise trust .config/mise/conf.d/android.toml
./saytw --script tools.nu mise lock
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw setup@android
./saytw build@android
```

`bin/pronto-android <app-dir> [name] [label]` takes the name from the
directory, as pronto's `meta.name` does; pass it when they differ. `label` is
what the launcher, the unlock prompt and the autofill picker show. It needs the plugin's own
toolchain once: `./saytw --script tools.nu mise install` in
`${CLAUDE_PLUGIN_ROOT}`. Each run overwrites the regenerated files and keeps
an existing `screen.js` and `autofill.json`.

## The phone's screen

Pronto does not compile `shell/screens` for Android yet, so
`android/app/src/main/assets/screen.js` draws each screen as a DivKit card.
It runs after SES's `lockdown()` and sees:

- `__shell`: the program's `shell.json`, its seed rows under `seed.<table>`;
- `rows`: every table, a `device` one from the unlocked store and any other
  from its seed; `commit(table, updates)` applies a handler's updates and
  returns the refused event when shell.json's schema refuses a row;
  `settle(name, table, reads)` runs a fold to rest;
- `__signers(package)`: an installed app's signing-certificate digests,
  current first, to pin an app login;
- `__handlers`: each `shell/handlers/<name>.js` source by name, to cage with
  `new Compartment().evaluate(__handlers.<name>)`, as the web terminal does;
- `emitUiAst(card)` to draw, and `onAction(url => …)` for a tap on an action
  whose `url` is `pronto://event/<type>?from=<id>`.

Mirror each web screen: same rows, same handler, same event shape
(`{type: "click", from}`), so the same presses give the same rows on both
hosts. The example's `screen.js` is the counter.

## Running it

```sh
./saytw launch@android    # build, install, start on the attached device
```

Unlock the phone first: a window started under the lock screen may never take
input. The web verbs (`generate`, `lint`, `test`, `integrate`, `launch`) are
unchanged and never run the Android rules.

## Done

The four web verbs exit 0, `build@android` and `launch@android` exit 0, and on
the phone the same presses give the same screens as in the browser. Capture
both and add them to the app's journal.

## Limits

- `adb` is whatever platform-tools sdkmanager serves the day `setup@android`
  runs; it publishes no versions.
- The device has no sync or network bridge: a vault lives on one phone.
- An app login added before its app is installed trusts the signer of its
  first fill.
- Nothing checks the phone's screen against the web one.
