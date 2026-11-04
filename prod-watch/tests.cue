package prodwatch

import "strings"

_t: #Host & {package: "myapp"}

// An opt-in writes the driver, its rules and the schema, and seeds the app's own prod_watch.cue.
written: [for p, f in _t.files if !f.seed {p}] & ["prod-watch/prod-watch.ts", "prod-watch/watch.js", "prod_watch_plugin.cue"]
seeded: [for p, f in _t.files if f.seed {p}] & ["prod_watch.cue"]

// The schema and the opt-in join the app's package, and the schema holds prodWatch to #Watch.
inPackage:   strings.Contains(_t.files["prod_watch_plugin.cue"].text, "\npackage myapp\n") & true
heldToWatch: strings.Contains(_t.files["prod_watch_plugin.cue"].text, "\nprodWatch: #Watch\n") & true
seedPackage: strings.HasPrefix(_t.files["prod_watch.cue"].text, "package myapp\n") & true

// Every app gets the shared rules, and the seed adds none of its own.
shared: [for n, _ in prodWatch.noise {n}] & ["scale-down", "erlang-sctp", "electric-not-ready", "cloud-sql-proxy-stopping", "neighbour-away", "gmp-start-time", "gmp-discovery-cancelled"]

// An app's own rule joins them, its own services are kept, and the windows come as defaults.
_own: #Watch & {services: ["x"], noise: mine: {match: "boom", why: "a test"}}
own: {services: _own.services, noise: [for n, _ in _own.noise {n}]} & {services: ["x"], noise: [...string] & ["mine"]}
windows: {start: _own.lifecycle.start.within, shutdown: _own.lifecycle.shutdown.within} & {start: 60, shutdown: 30}
