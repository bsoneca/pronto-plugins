package releasenotes

import "strings"

_t: #Host & {package: "myapp"}

// An opt-in writes the driver, its rules and the schema, and seeds nothing: the app's own release_notes.cue is optional.
written: [for p, f in _t.files if !f.seed {p}] & ["release-notes/release-notes.ts", "release-notes/notes.js", "release_notes_plugin.cue"]
seeded: [for p, f in _t.files if f.seed {p}] & []

// The schema joins the app's package, and holds releaseNotes to #Notes.
inPackage:  strings.Contains(_t.files["release_notes_plugin.cue"].text, "\npackage myapp\n") & true
heldToNotes: strings.Contains(_t.files["release_notes_plugin.cue"].text, "\nreleaseNotes: #Notes\n") & true

// With no release_notes.cue every default is what Bonk Chess's Releases have always had.
_defaults: #Notes
defaults: {source: _defaults.source.kind, timeZone: _defaults.timeZone, zoneLabel: _defaults.zoneLabel, model: _defaults.model, audience: _defaults.audience} & {
	source:    "release-cron"
	timeZone:  "America/Sao_Paulo"
	zoneLabel: "BRT"
	model: {kind: "ollama", name: "qwen3-coder:30b", url: "http://localhost:11434"}
	audience: "player"
}
// An app may take its releases from tags or deployments, date them elsewhere, use Claude or no model, and tell another audience.
_own: #Notes & {source: {kind: "tags", prefix: "v"}, timeZone: "Europe/Lisbon", zoneLabel: "WET", model: {kind: "claude", name: "claude-haiku-4-5"}, audience: "operator"}
own: {source: _own.source.prefix, zone: _own.zoneLabel, model: _own.model.name, audience: _own.audience} & {source: "v", zone: "WET", model: "claude-haiku-4-5", audience: "operator"}
_deployed: #Notes & {source: {kind: "deployments", environment: "production"}, model: {kind: "none"}}
deployed: {environment: _deployed.source.environment, model: _deployed.model.kind} & {environment: "production", model: "none"}

// A source of another kind, or one with what its kind does not take, is refused.
badKind:  [if (#Notes & {source: {kind: "ftp"}}) == _|_ {"refused"}, "accepted"][0] & "refused"
strayField: [if (#Notes & {source: {kind: "tags", prefix: "v", environment: "x"}}) == _|_ {"refused"}, "accepted"][0] & "refused"
