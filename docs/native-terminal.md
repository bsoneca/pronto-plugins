---
type: decision
title: A native terminal
description: Native apps as terminal plugins — a shared native host kit in omnishell, one plugin per platform, and three generalizations in pronto so an app holds a terminal per target — with the Android spike that measured SES in QuickJS and a DivKit screen on a phone.
status: unbuilt
---

# A native terminal

A native app is a terminal plugin. Pronto already has the slot: a terminal is
a seat ([component contracts](https://github.com/bonisoft3/pronto/blob/main/docs/component-contracts.md#the-five-parts)) that
declares its tools, the capabilities it offers, and its own verbs and checks,
which `#emit` lowers into sayt rules. What pronto lacks is a terminal per
target. Omnishell owns what every native host shares; each platform is one
plugin on top of it. A password manager on Android, which needs the system's
autofill, is the first app that drives it.

## The layers

| Layer | Owner | Shared by |
|---|---|---|
| The program: entities, handlers, machines, screens | the app | every terminal |
| The runtime: `jessie.js`, the interpreter modules that name no DOM global | omnishell | every terminal |
| The native host kit: the engine contract, the globals a host owes, the bridge contracts, the screen compiler to DivKit, the host battery | omnishell | every native plugin |
| A host plugin: engine binding, bridges, toolchain, verbs, offered capabilities | one module per platform | one platform |

A second platform — iOS, a desktop — is a new plugin against the same kit,
and the app does not change.

## What changes in pronto

1. **A terminal per target.** `#Target` admits `android`, and the emitted
   `bayt.cue` holds `terminals: [Target]: #Terminal` where it holds one
   `terminal` today. The web targets keep omnishell; `android` names its
   plugin through a roster file under `terminals/`, as `omnishell.cue` does.
   `capabilities.native` in [`schema.cue`](https://github.com/bonisoft3/pronto/blob/main/schema.cue) goes: the
   targets say it.
2. **Verbs carry a platform.** A host declares its rules each with a
   `platform`, so `./saytw launch@android` installs on a phone and the web
   verbs never run them. Built for Android in this module:
   [`android/host.cue`](../android/host.cue) declares the toolchain, the
   `setup`, `build`, `test` and `launch` rules and the Gradle project, and
   `bin/pronto-android` writes them into an app: a generated `.say.json`,
   which sayt merges with the `.say.yaml` pronto writes, a mise drop-in pronto
   does not own, and `android/`, whose screen is seeded once and then the
   app's. In pronto, `#emit`
   would write both from `meta.targets`; until sayt's `#Loop` lowers a
   platform on every verb, not only on `release`, it merges the rules where
   the file is written.
3. **Capabilities are judged per target.** An app's request is checked
   against every terminal it targets, and screens against each terminal's
   renderer: a markup element with no DivKit peer fails `lint` for an
   `android` app, never silently.
4. **`Crypto` among the terminal's endowments.** `#SafeEndowment` admits it,
   implemented by each host — WebCrypto's deterministic subset in the page,
   the Keystore on Android
   ([external effects](https://github.com/bonisoft3/pronto/blob/main/docs/decisions/2026-10-03-external-effects.md#a-signature-is-a-computation)).

## The host kit (omnishell)

Every native plugin declares the same things, each named by the spike:

- **Toolchain**, pinned through mise in the host's own drop-in
  (`.config/mise/conf.d/<host>.toml`, locked beside it): a JDK, the
  platform SDK and Gradle. Nothing global, and nothing binary in the template.
- **Engine**: `start()`, `dispatchAction(url)`, a tree stream.
- **Globals owed before `lockdown()`**: `console`, `URL`, `URLSearchParams`,
  `TextEncoder`, `TextDecoder`, `Intl`, `queueMicrotask`, and a clock-injected
  `setTimeout`, plus any repair the engine needs for SES (QuickJS's
  `Iterator.prototype` getters).
- **Bridges**: storage over the platform's SQLite, network over HTTP and SSE,
  crypto over the platform's key store by handle.
- **Renderer**: DivKit, fed by the kit's compiler from the screens' markup.
- **Verbs**: `setup` (the SDK), `build` (the package), `launch` (install and
  start), `release` (signed); **checks**: `test` (the plugin's own suite) and
  `integrate` (the host battery).
- **The host battery**: the spike's tests as a conformance suite every plugin
  runs headless — SES locks down, a handler's clock and randomness throw,
  `jessie.js` loads unchanged, and one event list gives one tree list.

An autofill or credential service is a capability a plugin offers; on
Android it starts the same engine headless in the app's process and asks a
handler which credentials match, so the fill path is not a second
implementation.

## The spike

Measured 2026-10-16 on omnishell v0.12.1, QuickJS 2026-06-04 through
quickjs-kt 1.0.14, SES 1.15.0 and DivKit 33.6.0.

| Claim | Result |
|---|---|
| SES locks down QuickJS | Holds, given a `console` and the `Iterator` repair |
| pronto's idioms `count.js`, unchanged, in a Compartment | Returns its patch; `Date.now` and `Math.random` throw; intrinsics frozen |
| `jessie.js` loads unchanged | No: QuickJS lacks every global listed above |
| One event list gives one tree list | Holds on the JVM |
| A DivKit screen on a phone | Native views on a Pixel 10 Pro, taps round-tripping through the caged handler |

Also found: quickjs-kt cannot compile a module once SES is loaded, and throws
converting a script's completion value; omnishell's engine uses JDBC SQLite,
which Android cannot load; and AGP 9.4.1 needs Gradle 9.6 and an explicit
Kotlin 2.4 plugin to read quickjs-kt.

## Rejected

- **A native plugin type beside the terminal seat.** It would duplicate what
  a terminal already declares — tools, capabilities, verbs, checks.
- **A webview (Capacitor) or a Trusted Web Activity.** Neither answers the
  system's autofill, and served code can read a vault's key.
- **A Compose or SwiftUI client by hand.** It loses replay, the ir bijection
  and every gate.
- **DivKit authored beside the HTML.** A sixth language, and every screen
  written twice.

## Open

- SES on JavaScriptCore for an iOS plugin, and its Credential Provider
  Extension's separate process.
- `adb`'s version: mise carries the SDK's cmdline-tools (`android-sdk`), and
  `setup` adds the packages, but sdkmanager serves platform-tools unversioned.
- The `device` durability over SQLite where the browser has PGlite.
