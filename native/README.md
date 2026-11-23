# native

What every native terminal host shares, written once in CUE ([a native terminal](../docs/native-terminal.md), "The layers"). [android](../android/README.md) imports it, and the iOS host will.

- [`host.cue`](host.cue): `#Core`, the part of a host's spec that names no platform (app, label, base, CUE package, unlock, scenarios and the config file's first text). A host embeds it and adds its own identifiers, toolchain, project files and association statements.
- [`bridges.cue`](bridges.cue): the bridge contracts. `bridges` are the functions a host defines on its engine (name, argument types, result, the callback that answers), `callbacks` the functions the terminal bundle defines for the host to call. A bridge's answer must be a callback with the same arguments, or the CUE does not vet.
- [`battery.cue`](battery.cue), [`battery.js`](battery.js): the host battery, a conformance suite at the JS level written once as data. SES locks down, a handler's clock and randomness throw, a handler sees no bridge, a caged handler folds one event list to one tree list, the host's storage round-trips, the passkey bridge keeps its shape. The runner takes the host's engine (`eval`) and the battery, defines no bridge of its own, and a host adds no case here. Argument types in the contract are not yet checked against a host's code, only its names.
- [`deno_host.ts`](deno_host.ts): the headless engine the battery runs on today, Deno under the SES the phones load, with the contract's storage in memory (`memoryKv`). A host runs the same cases on its own engine.

`tests/unit/native.cue` holds it all to the code: Android defines exactly the contract's bridges and callbacks, the battery passes, and Android's generated files equal `android/golden/*.json`, digests of what the host wrote before the core moved here. A change to a template is meant to change them: regenerate with `GOLDEN_UPDATE=1 deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- native` and commit the digests that moved.

Not in the battery yet: `jessie.js` loading unchanged, which needs the app's omnishell and so belongs to a host that builds the bundle.
