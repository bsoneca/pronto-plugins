# android

A native Android host for a pronto app: no WebView. The program's own handlers run under SES in QuickJS, screens are drawn by DivKit, and the toolchain is pinned through mise.

## What it adds

- `android/`: a Gradle project from [`template/`](template), its package `dev.pronto.<name>`.
- `.say.json` rules `setup`, `build`, `test` and `launch`, each answering `@android`.
- `.config/mise/conf.d/android.toml`: Temurin JDK, the SDK's cmdline-tools, Gradle.
- The bridges [a native terminal](../docs/native-terminal.md) names: sealed **storage** for `device` tables (built: SQLite, every value AES-256/GCM under an AndroidKeyStore key, see below), a **Keystore** key behind one biometric prompt (PRONTO-104, not built), and an **autofill** service that runs the app's handler over the vault (PRONTO-105, not built).
- `screen.js` and `autofill.json`, written once and then the app's.

## Two modes

- **Terminal** (the default): the app's own omnishell, at its pinned version and unchanged, runs in QuickJS under SES over a headless DOM (linkedom). Its screens, CSS, forms, sync and guest sign-in are the web's. [`template/terminal/`](template/terminal) compiles that DOM and its CSS to a DivKit card (`compile.js`, `css.js`) and sends taps and typing back as DOM events (`display.js`); Kotlin supplies fetch, storage, timers and the clock (`browser.js`, `TerminalEngine.kt`). The app writes no Android code. CSS that Android cannot draw is listed in the log as unsupported, not silently dropped. Hatches: see below. Passkeys are offered in debug builds only (below).
- **Vault**: an app that already has `android/app/src/main/assets/screen.js` keeps its hand-drawn phone screens.

In terminal mode, `build@android` bundles the interpreter (`android/terminal/bundle.ts`), and `integrate@android` runs the app's CUE scenarios (named in `android/android.json`) on an emulator through real taps and typing (`android/terminal/scenarios.ts`). It uses `PRONTO_BASE` when that is set, and otherwise brings up a stack on a slot. A debug build trusts the machine's local stack: Caddy's local root, and mkcert's when present.

### Sealed storage

In terminal mode the `__native_kv_*` bridges (`localStorage`, where omnishell keeps the `device` tables) write to SQLite (`terminal-sealed.db`, table `kv(ns, actor, k, v)`), never to plain text. Each value is sealed with AES/GCM/NoPadding under an AndroidKeyStore AES-256 key (`pronto-terminal-store`, no user authentication): a fresh 12-byte nonce, a 128-bit tag, and the address `actor NUL ns NUL k` as associated data, stored as nonce followed by ciphertext. A value that does not open (tampered, or moved to another address) reads as absent and logs `PRONTO STORE refused <ns>/<k>` once. Values an earlier build left in SharedPreferences move in on first use and the preferences are cleared. The seal (`Seal` in `SealedStore.kt`) is pure over a `SecretKey`, so a JVM test (`SealTest.kt`) runs it on a software key. Scenarios can assert `{undisclosed: "text"}`: no file in the app's private directory (read with `run-as`) holds the text.

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
- **A v3 scene** (3D: `scene`, `model`, `anim`, `camera`, `audio`, the contract's "Contract v3") is drawn natively:
  - `bound.js` checks it as the Unity host does (an unknown attribute, a non-number, a model with neither or both of `shape` and `prefab`, an unknown shape, a colour that is not `#rrggbb`, a child under a 3D kind is a `PRONTO FAULT`) and keeps it in the DOM with its attributes and classes, so a scenario counts `#scene .model` and reads `#scene[data-fight]`.
  - `compile.js` compiles the scene element, children included, to one DivKit `custom` div, `custom_type: "pronto-scene"`, sized by the element's CSS (else the page's width and a square). Its `custom_props` is `{background, camera: {x, y, z, lookX, lookY, lookZ, fov}, models: [{key, shape, prefab, color, x, y, z, rx, ry, rz, sx, sy, sz}], anims: [{key, target, clip, duration, dx, dy, dz, spin, loop}], audios: [{key, clip, volume, loop}]}`, numbers as numbers and the contract's defaults applied.
  - `SceneView.kt` (`SceneAdapter`, registered in `MainActivity`) draws it with OpenGL ES 2.0: the six primitives at Unity's sizes, one directional light, Unity's left-handed transforms, the camera, and the background as the clear colour. An anim whose key appeared runs its tween out and back, turning `spin`. An audio whose key appeared plays the APK asset `unity/audio/<clip>.wav` or `.ogg`. A `prefab` draws as a cube. Each bind logs `PRONTO SCENE drew <n> models` (tag `pronto`); a clip the app does not ship is `PRONTO SCENE audio <clip> not shipped`, a prefab `PRONTO SCENE prefab <name> not on Android`, once each.
- **Held input** (a ticked hatch whose binding lists `input`): `bound.js` mounts a touch layout beside the hatch, `div#hatch-<name>-pad` holding one `button[data-hatch-hold=<control>]` per control in the binding's order. `compile.js` gives each one DivKit's `press_start_actions` and `press_end_actions` (`pronto://press/<id>`, `pronto://release/<id>`) and no tap. `MainActivity` hands them to `display.js` as `pointerdown` and `pointerup`. Each tick gets the controls held then, in the binding's order, as Unity's keyboard gives them. A press let go before the tick still counts for that one tick.
- **Not yet:** there is no ad network, so an ad ends `none`.

### Passkeys

`navigator.credentials` is the host's (`browser.js` over `__native_passkey`, answered by Kotlin's `Passkeys`), so omnishell's own register and sign-in ceremonies run unchanged. There are two source sets, like `Driver.kt`:

- **debug**: a software authenticator (EC P-256, ES256, "none" attestation, user always verified), its credentials kept per actor in SharedPreferences. Its clientDataJSON `origin` is the app's base origin, as a browser at that door would send, so the door's pinned origin accepts it. This is what lets `integrate@android` run a scenario that signs up with a passkey (`signUp`), unchanged from the web.
- **release**: the device's passkeys, through Credential Manager (androidx.credentials; Play services before Android 14). The page's options go to it as WebAuthn's JSON and its answer comes back the same way. Its clientData origin is the app's signing certificate (`android:apk-key-hash:...`), not a page. `android/android.json`'s `signing` lists the SHA-256 fingerprints of the certificates that sign the release (`AB:CD:...`, as keytool prints them), and `pronto-android` writes them into `android_surface.cue`:
  - `code: capabilities: auth: android`: the door's auth admits those origins (mecha's `WEBAUTHN_ANDROID_ORIGINS`, passed by release@gcp and release@k8s; pronto 0.24.1-gcp.129, mecha 0.18.1-host.12);
  - the app's statement in the door's `/.well-known/assetlinks.json` (`get_login_creds` and `handle_all_urls`), so Android lets the app use the door's relying party. The Unity player's statement joins it in the same file ([assetlinks](../assetlinks/assetlinks.cue)).

  Without `signing`, the door admits no app, and a release's ceremony is refused there as a browser's at a wrong origin would be.

### Signing a release

`:app:assembleRelease` signs the APK only when `PRONTO_ANDROID_KEYSTORE` (a path), `PRONTO_ANDROID_KEYSTORE_PASSWORD` and `PRONTO_ANDROID_KEY_ALIAS` are all set; without them it makes the unsigned APK it always did, so ci and the gates need no secret. The key itself is never a file in a repo: it is one Secret Manager secret, a JSON value `{"keystore": <base64 PKCS12>, "password": ..., "alias": ...}` that the app's owner puts once with their own command.

`android/android.json`'s `release` says where it lives:

```json
{"release": {"project": "my-project", "secret": "android-release-signing"}}
```

`secret` defaults to `android-release-signing`; `project` is the Secret Manager project. With `release`, `pronto-android` writes `android/sign-release.sh` (none without it). Run `sh android/sign-release.sh` signed in to gcloud: it reads the secret's latest version with your own gcloud (`ANDROID_SIGNING_PROJECT` and `ANDROID_SIGNING_SECRET` override the names), writes the keystore to a mode-600 temporary file removed on exit, exports the three variables, runs Gradle as `build@android` does (the app's mise), checks the APK with the SDK's `apksigner verify --print-certs` and prints the signer's SHA-256. That fingerprint is what `signing` lists, so the door admits the release's passkeys. It needs `gcloud` and `jq`.

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
