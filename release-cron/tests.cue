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

// The defaults: an hour after a release, a wake every ten minutes, each step's limit.
_defaults: #Cron & {watch: ["x"], probes: {}}
defaults: {gap: _defaults.gap, poll: _defaults.poll, minutes: _defaults.minutes} & {gap: 60, poll: 10, minutes: {prepare: 5, slot: 20, rehearse: 35, release: 35, confirm: 5}}

// An app may shorten the gap, widen the wake and lengthen a limit.
_own: #Cron & {gap: 30, poll: 5, watch: ["x"], probes: {}, minutes: release: 60}
own: {gap: _own.gap, poll: _own.poll, release: _own.minutes.release} & {gap: 30, poll: 5, release: 60}
