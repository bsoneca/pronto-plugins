# android

A native Android host for a pronto app: no WebView. The program's own handlers run under SES in QuickJS, screens are drawn by DivKit, and the toolchain is pinned through mise.

## What it adds

- `android/`: a Gradle project from [`template/`](template), its package `dev.pronto.<name>`.
- `.say.json` rules `setup`, `build`, `test` and `launch`, each answering `@android`.
- `.config/mise/conf.d/android.toml`: Temurin JDK, the SDK's cmdline-tools, Gradle.
- The three bridges [a native terminal](../docs/native-terminal.md) names as unbuilt: sealed **storage** for `device` tables (SQLite, AES-GCM), a **Keystore** key behind one biometric prompt, and an **autofill** service that runs the app's handler over the vault.
- `screen.js` and `autofill.json`, written once and then the app's.

## Two modes

- **Terminal** (the default): the app's own omnishell, at its pinned version and unchanged, runs in QuickJS under SES over a headless DOM (linkedom). Its screens, CSS, forms, sync and guest sign-in are the web's. [`template/terminal/`](template/terminal) compiles that DOM and its CSS to a DivKit card (`compile.js`, `css.js`) and sends taps and typing back as DOM events (`display.js`); Kotlin supplies fetch, storage, timers and the clock (`browser.js`, `TerminalEngine.kt`). The app writes no Android code. CSS that Android cannot draw is listed in the log as unsupported, not silently dropped. Hatches: see below. Passkeys are offered in debug builds only (below).
- **Vault**: an app that already has `android/app/src/main/assets/screen.js` keeps its hand-drawn phone screens.

In terminal mode, `build@android` bundles the interpreter (`android/terminal/bundle.ts`), and `integrate@android` runs the app's CUE scenarios (named in `android/android.json`) on an emulator through real taps and typing (`android/terminal/scenarios.ts`). It uses `PRONTO_BASE` when that is set, and otherwise brings up a stack on a slot. A debug build trusts the machine's local stack: Caddy's local root, and mkcert's when present.

### Hatches

A web hatch is a host-DOM module (three.js, a canvas, Web Audio) that the phone cannot draw. The phone runs the hatch the way the Unity host does: through the app's binding under the hatch contract (pronto-csharp `docs/pronto-unity-hatch-contract.md`, v2). That binding is the app's `binding.json` and its pure module (`init`, `view`, `gesture`, `tick`, `ad`), and Unity runs the same files.

- **Declaring one:** `android/android.json` names the bindings, for example `"hatches": {"battle": {"binding": "unity/hatches/battle/binding.json"}}`.
- **Building:** `build@android` turns every host-DOM hatch the shell declares into one module of its own, with the hatch's imports inlined, because QuickJS resolves no relative import between the app's files. `TerminalEngine` registers each module at the hatch's web address, so omnishell mounts, pauses and stops it unchanged. A bound hatch's module is [`bound.js`](template/terminal/bound.js) over the app's pure module, and the web's module is never loaded.
- **Running:**
  - The driver reads the screen through the binding's selectors.
  - It draws the view's nodes under `div#hatch-<name>`, like any element.
  - A tap on one of them becomes `gesture()`.
  - It carries out an outcome only within the binding: one form of `submits`, one element of `clicks`.
  - Anything else is `PRONTO FAULT hatch <name>: ...`, and the state is kept.
- **Not yet:**
  - A v3 scene (3D: `scene`, `model`, `anim`, `camera`, `audio`) stays in the DOM, hidden, so its attributes can be read, but it is not drawn.
  - A ticked hatch gets no held input, because there is no touch layout yet.
  - There is no ad network, so an ad ends `none`.

### Passkeys

`navigator.credentials` is the host's (`browser.js` over `__native_passkey`, answered by Kotlin's `Passkeys`), so omnishell's own register and sign-in ceremonies run unchanged. There are two source sets, like `Driver.kt`:

- **debug**: a software authenticator (EC P-256, ES256, "none" attestation, user always verified), its credentials kept per actor in SharedPreferences. Its clientDataJSON `origin` is the app's base origin, as a browser at that door would send, so the door's pinned origin accepts it. This is what lets `integrate@android` run a scenario that signs up with a passkey (`signUp`), unchanged from the web.
- **release**: the device's passkeys, through Credential Manager (androidx.credentials; Play services before Android 14). The page's options go to it as WebAuthn's JSON and its answer comes back the same way. Its clientData origin is the app's signing certificate (`android:apk-key-hash:...`), not a page. `android/android.json`'s `signing` lists the SHA-256 fingerprints of the certificates that sign the release (`AB:CD:...`, as keytool prints them), and `pronto-android` writes them into `android_surface.cue`:
  - `code: capabilities: auth: android`: the door's auth admits those origins (mecha's `WEBAUTHN_ANDROID_ORIGINS`, passed by release@gcp and release@k8s; pronto 0.24.1-gcp.129, mecha 0.18.1-host.12);
  - the app's statement in the door's `/.well-known/assetlinks.json` (`get_login_creds` and `handle_all_urls`), so Android lets the app use the door's relying party. The Unity player's statement joins it in the same file ([assetlinks](../assetlinks/assetlinks.cue)).

  Without `signing`, the door admits no app, and a release's ceremony is refused there as a browser's at a wrong origin would be.

Scenario steps beyond the DOM's: `signUp`, `pay` (the stand-in checkout), `address`, `response` (a request the page made and what it answered), and a step's `flag`/`unless`.

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
- [`test/bound_test.ts`](test/bound_test.ts): Deno tests of the hatch driver `bound.js` over linkedom.
- `test@android` in an app runs the template's JVM tests ([`FillTest.kt`](template/app/src/test/kotlin/FillTest.kt)).

```sh
./saytw --script tools.nu cue vet -c ./android
deno test --allow-read --allow-env android/test/host_test.ts android/test/bound_test.ts
```
