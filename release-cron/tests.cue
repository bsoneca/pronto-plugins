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

// A failed run is bisected by this check, and nobody is told unless the app names who (notify).
bisectDefaults: _defaults.bisect & {command: "./saytw integrate@local"}
notifyDefault: _defaults.notify & {kind: "none"}
// A lead still set in bisect is a claude-session's, with the notes folder's default; the schema holds no lead of its own.
_lead: #Cron & {watch: ["x"], probes: {}, bisect: lead: "local_a"}
legacyLead: _lead.notify & {kind: "claude-session", lead: "local_a", notes: "Library/Application Support/Claude/side-session-notes"}
_notes: #Cron & {watch: ["x"], probes: {}, bisect: {lead: "local_a", notes: "n"}}
legacyNotes: _notes.notify.notes & "n"
// A notify of its own: a claude-session names its lead, a github-comment nothing more.
_session: #Cron & {watch: ["x"], probes: {}, notify: {kind: "claude-session", lead: "L"}}
session: _session.notify & {kind: "claude-session", lead: "L", notes: "Library/Application Support/Claude/side-session-notes"}
_comment: #Cron & {watch: ["x"], probes: {}, notify: kind: "github-comment"}
comment: _comment.notify & {kind: "github-comment"}
noLead: [if (#Cron & {watch: ["x"], probes: {}, notify: kind: "claude-session"}).notify.lead == _|_ {"refused"}, "accepted"][0] & "refused"

// With no target the release is Cloud Run's; a target that names no kind is a command's (Bonk Chess's, Book a time's), and
// one that names `kind: "command"` is the same.
noTarget: _defaults.target & {kind: "cloud-run"}
_old: #Cron & {watch: ["x"], probes: {}, target: {release: ["./r.sh"], serving: ["./s.sh"], origin: "https://x.example"}}
oldTarget: _old.target & {kind: "command", release: ["./r.sh"]}
_kind: #Cron & {watch: ["x"], probes: {}, target: {kind: "command", release: ["./r.sh"], serving: ["./s.sh"], origin: "https://x.example"}}
kindTarget: _kind.target & {kind: "command"}
// A cloud-run target has nothing of a command's.
cloudWithRelease: [if (#Cron & {watch: ["x"], probes: {}, target: {kind: "cloud-run", release: ["r"]}}) == _|_ {"refused"}, "accepted"][0] & "refused"

// The rehearsal is verify@local in a slot, its holder the top-level holder's default; the top-level holder still works.
rehearsalDefault: _defaults.rehearsal & {command: ["./saytw", "verify@local"], slot: true, holder: "verify@local"}
rehearsalOfHolder: _ume.rehearsal & {holder: "./saytw integrate@local"}
_none: #Cron & {watch: ["x"], probes: {}, rehearsal: {command: null, slot: false, holder: "h"}}
rehearsalNone: _none.rehearsal & {command: null, slot: false, holder: "h"}
_cmd: #Cron & {watch: ["x"], probes: {}, rehearsal: command: ["./check.sh", "fast"]}
rehearsalCommand: _cmd.rehearsal & {command: ["./check.sh", "fast"], slot: true}

// The scheduler is launchd's unless the app names systemd or actions; a hook runs on `released`.
schedulerDefault: _defaults.scheduler & {kind: "launchd"}
_systemd: #Cron & {watch: ["x"], probes: {}, scheduler: kind: "systemd"}
schedulerSystemd: _systemd.scheduler & {kind: "systemd"}
_actions: #Cron & {watch: ["x"], probes: {}, scheduler: kind: "actions"}
schedulerActions: _actions.scheduler & {kind: "actions"}
hooksDefault: _defaults.hooks & []
_hook: #Cron & {watch: ["x"], probes: {}, hooks: [{on: "released", command: ["deno", "run", "hook.ts"]}]}
hook: _hook.hooks[0].command & ["deno", "run", "hook.ts"]
noEvent: [if (#Cron & {watch: ["x"], probes: {}, hooks: [{on: "never", command: ["x"]}]}) == _|_ {"refused"}, "accepted"][0] & "refused"

// An app off Cloud Run names a target: the commands that release and read what serves, and the https address the probes ask.
_aprende: #Cron & {watch: ["x"], probes: {}, target: {release: ["./release.sh"], serving: ["./serving.sh", "prod"], origin: "https://aprende.example"}}
target: {release: _aprende.target.release, origin: _aprende.target.origin} & {release: ["./release.sh"], origin: "https://aprende.example"}
// A target whose origin is not https is refused.
noHttp: [if (#Cron & {watch: ["x"], probes: {}, target: {release: ["r"], serving: ["s"], origin: "http://x"}}) == _|_ {"refused"}, "accepted"][0] & "refused"

// The whole of an old app's releaseCron, as `cue export -e releaseCron` hands it to the driver: its target without a kind a
// command, its top-level holder the rehearsal's, its bisect.lead a claude-session's, the rest the defaults.
_legacy: #Cron & {
	watch: ["x"], probes: {}, holder: "./saytw integrate@local"
	target: {release: ["./r.sh"], serving: ["./s.sh"], origin: "https://x.example"}
	bisect: lead: "local_a"
}
legacyExport: {
	target:    _legacy.target
	rehearsal: _legacy.rehearsal
	notify:    _legacy.notify
	hooks:     _legacy.hooks
	scheduler: _legacy.scheduler
} & {
	target: {kind: "command", release: ["./r.sh"], serving: ["./s.sh"], origin: "https://x.example"}
	rehearsal: {command: ["./saytw", "verify@local"], slot: true, holder: "./saytw integrate@local"}
	notify: {kind: "claude-session", lead: "local_a", notes: "Library/Application Support/Claude/side-session-notes"}
	hooks: []
	scheduler: kind: "launchd"
}
// The rehearsal's own holder wins over the top-level one.
_both: #Cron & {watch: ["x"], probes: {}, holder: "a", rehearsal: holder: "b"}
rehearsalHolderWins: _both.rehearsal.holder & "b"
