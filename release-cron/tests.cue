package releasecron

import "strings"

_t: #Host & {package: "myapp"}

// An opt-in writes the driver, its rules and the schema, and seeds the app's own release_cron.cue.
written: [for p, f in _t.files if !f.seed {p}] & ["release-cron/release-cron.ts", "release-cron/cron.js", "release_cron_plugin.cue"]
seeded: [for p, f in _t.files if f.seed {p}] & ["release_cron.cue"]

// The schema and the opt-in join the app's package, and the schema holds releaseCron to #Cron.
inPackage:   strings.Contains(_t.files["release_cron_plugin.cue"].text, "\npackage myapp\n") & true
heldToCron:  strings.Contains(_t.files["release_cron_plugin.cue"].text, "\nreleaseCron: #Cron\n") & true
seedPackage: strings.HasPrefix(_t.files["release_cron.cue"].text, "package myapp\n") & true

// The defaults: an hour after a release, a wake every ten minutes.
_defaults: #Cron & {watch: ["x"], probes: {}}
defaults: {gap: _defaults.gap, poll: _defaults.poll, ready: _defaults.ready, holder: _defaults.holder} & {gap: 60, poll: 10, ready: [], holder: "verify@local"}

// An app may shorten the gap, widen the wake.
_own: #Cron & {gap: 30, poll: 5, watch: ["x"], probes: {}}
own: {gap: _own.gap, poll: _own.poll} & {gap: 30, poll: 5}


// An app may name its slot holder and the services besides its own that must be ready.
_ume: #Cron & {watch: ["x"], probes: {}, ready: ["a-render"], holder: "./saytw integrate@local"}
ume: {ready: _ume.ready, holder: _ume.holder} & {ready: ["a-render"], holder: "./saytw integrate@local"}

// A failed run is bisected within these limits, and the lead is told when no author session is named.
bisectDefaults: _defaults.bisect & {command: "./saytw integrate@local", lead: "local_7c6084eb-07de-487a-b8e6-689748accaaa"}
