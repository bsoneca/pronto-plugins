---
name: pronto-ios
description: "Add pronto's iOS host to a pronto app, or refresh it: a Swift project generated from CUE by XcodeGen, with @ios sayt verbs that build, test and launch on the iOS Simulator. Use when the user wants a pronto app on iOS or an iPhone."
---

# pronto-ios

The iOS host is a plugin beside pronto, as the Android one is. Run
`bin/pronto-ios <app-dir> [name] [label]` from this repository: it writes `.say.json`
(`setup`, `build`, `lint`, `test`, `launch`, each answering `@ios`), `.config/mise/conf.d/ios.toml`
(XcodeGen and SwiftLint) and `ios/`. Then `./saytw --script tools.nu mise lock` in the app and
`./saytw setup@ios`.

- Xcode is the Mac's own, found at `DEVELOPER_DIR`; never run `xcode-select -s` or sudo. `setup@ios` names
  the Xcode version, runtime and simulator to install when they differ.
- `ios/project.yml` and the Swift files are regenerated: change `ios/host.cue`, not them. The app's
  `ios/ios.json` holds its entitlements, versions and unlock.
- Use the simulator only; builds and tests claim `tests/slot.ts`'s budget.
