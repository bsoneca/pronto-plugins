# android

A native Android host for a pronto app: no WebView. The program's own handlers run under SES in QuickJS, screens are drawn by DivKit, and the toolchain is pinned through mise.

## What it adds

- `android/`: a Gradle project from [`template/`](template), its package `dev.pronto.<name>`.
- `.say.json` rules `setup`, `build`, `test` and `launch`, each answering `@android`.
- `.config/mise/conf.d/android.toml`: Temurin JDK, the SDK's cmdline-tools, Gradle.
- The three bridges [a native terminal](../docs/native-terminal.md) names as unbuilt: sealed **storage** for `device` tables (SQLite, AES-GCM), a **Keystore** key behind one biometric prompt, and an **autofill** service that runs the app's handler over the vault.
- `screen.js` and `autofill.json`, written once and then the app's.

## Two modes

- **Terminal** (the default): the app's own omnishell, at its pinned version and unchanged, runs in QuickJS under SES over a headless DOM (linkedom). Its screens, CSS, forms, sync and guest sign-in are the web's. [`template/terminal/`](template/terminal) compiles that DOM and its CSS to a DivKit card (`compile.js`, `css.js`) and sends taps and typing back as DOM events (`display.js`); Kotlin supplies fetch, storage, timers and the clock (`browser.js`, `TerminalEngine.kt`). The app writes no Android code. CSS that Android cannot draw is listed in the log as unsupported, not silently dropped. Hatches (canvas, three.js) and passkeys are not supported yet.
- **Vault**: an app that already has `android/app/src/main/assets/screen.js` keeps its hand-drawn phone screens.

In terminal mode, `build@android` bundles the interpreter (`android/terminal/bundle.ts`), and `integrate@android` runs the app's CUE scenarios (named in `android/android.json`) on an emulator through real taps and typing (`android/terminal/scenarios.ts`). It uses `PRONTO_BASE` when that is set, and otherwise brings up a stack on a slot. A debug build trusts the machine's local stack: Caddy's local root, and mkcert's when present.

## Use

From a bootstrapped pronto app whose four verbs are green:

```sh
<this repo>/bin/pronto-android . [name] [label]
./saytw setup@android
./saytw launch@android
```

`bin/pronto-android` exports [`host.cue`](host.cue)'s files with this repo's pinned CUE and writes them. The mise steps between are in the [root README](../README.md#pronto-android). The [`pronto-android` skill](../skills/pronto-android/SKILL.md) adds or refreshes the host and writes the phone screens. A working app: [`examples/hello-android`](../examples/hello-android).

## Tests

- [`tests.cue`](tests.cue): the host's exported files, checked with `cue vet`.
- [`test/host_test.ts`](test/host_test.ts): Deno tests of the template's `host.js`.
- `test@android` in an app runs the template's JVM tests ([`FillTest.kt`](template/app/src/test/kotlin/FillTest.kt)).

```sh
./saytw --script tools.nu cue vet -c ./android
deno test --allow-read --allow-env android/test/host_test.ts
```
