// What release-cron (README.md) reads besides an app's release.cue: the app's opt-in, its
// schedule, each step's limit and what production must answer. Written once here and in the app's
// releaseCron, never in the script. bin/pronto-release-cron writes it into the app's own package
// (release_cron_plugin.cue), where the app's release_cron.cue gives releaseCron its values.
package releasecron

import "strings"

releaseCron: #Cron

#Cron: {
	// Minutes to wait after a run that released (or failed) before the next starts: release, wait,
	// release again. A run that skipped waits only for the next wake.
	gap: *60 | (number & >=0)
	// Minutes between the scheduler's wakes (launchd's StartInterval, the systemd timer's OnUnitActiveSec): each
	// wake starts a run once the gap is over.
	poll: *10 | (int & >=1)
	// What wakes the run: `launchd` (a LaunchAgent on a Mac, today's), `systemd` (a user timer and service on
	// Linux) or `actions` (nothing is installed: the app's workflow runs `release-cron.ts <app> run` itself).
	scheduler: *#Launchd | #Systemd | #Actions
	// The paths whose change since the last run that released makes a release, relative to the
	// repository; the app's own folder when not named. Nothing changed: the run skips.
	watch: [...string]
	// Where the app is released. `cloud-run` (the default, no target named): release.cue's GCP, `./saytw release@gcp`
	// and Cloud Run's traffic. `command`: an app released elsewhere (aprende, on Cloudflare Pages, with no release.cue;
	// Bonk Chess, on the Contabo node): the command that releases the checked-out tree and the one that prints the
	// commit production serves, both run in the app's folder, and the address the probes ask. A target that names no
	// `kind` is a command's.
	target: *#CloudRun | #Command
	// What the rehearsal is, run before the release on the tree it releases. `command` is run in the app's folder
	// (its exit says pass or fail; null: no rehearsal, the release follows the schedule alone) and, with `slot`, the
	// run waits until it holds a slot of the machine's pool (tests/slot.ts) whose owner line is `holder`: the `what` the
	// app's rehearsal claims its main slot as. The Ume apps' verify@local runs generate, lint and test, then
	// `./saytw integrate@local`, which claims it. `slot: false` runs it without waiting for a slot. GCP.rehearsal (the
	// cloud's) replaces it. The top-level `holder` below is still read, as rehearsal.holder.
	rehearsal: {
		command: *["./saytw", "verify@local"] | [...string] | null
		slot:    *true | bool
		holder:  *_holder | string
	}
	// The top-level `holder`, kept for the apps that set it: the default of rehearsal.holder.
	holder: *"verify@local" | string
	_holder: holder
	// Cloud Run services, besides GCP.service, that must be Ready in confirm (Bonk Chess: its renderer).
	ready: [...string]
	// There is no per-step limit: no step is stopped for its time. A step that runs long shows in the
	// run's log (a line every 5 minutes while it runs); its minutes are in runs.jsonl and `report`.
	// Accepted and ignored, so an app that still sets its old step limits keeps loading; delete them.
	minutes?: {...}
	// A failed run is bisected (README.md, "A failed run is bisected"): main between the last run that
	// released and the failing commit, by the records first, else by running the failing check on
	// the commits left. It runs apart from the run, as a low-priority claim on the machine's slots
	// (tests/slot.ts, waiting for release-active like any job); it never releases.
	bisect: {
		// There is no limit on the bisect or on one check: nothing is stopped for its time, a line every
		// 5 minutes in the bisect's log says a check is still running. Accepted and ignored, so an app
		// that still sets its old bisect limits (minutes, check) keeps loading; delete them.
		minutes?: number
		check?:   number
		// The check run in a commit's tree, in the app's folder, with ONLY=<the failed scenarios>
		// and SLOW=1 set; its exit says good or bad.
		command: *"./saytw integrate@local" | string
		// Who is told of a culprit, and the folder session notes go in, as notify below. Still read, for the apps that set
		// them: a `lead` is a claude-session notify (the schema holds no lead of its own).
		lead?:  string
		notes?: string
	}
	// Who is told of what release-cron finds (a bisect's culprit, the scenarios that flaked or failed new): the log alone
	// (`none`, the default), a comment on the pull request (`github-comment`), or that comment, a notes file in a Claude
	// Desktop session's folder (the author's when the pull request's body names its `local_<uuid>`, else `lead`'s, under
	// HOME/`notes`) and, on a Mac, a notification (`claude-session`).
	notify: *#NoNotify | #ClaudeSession | #GithubComment
	if bisect.lead != _|_ {
		notify: {kind: "claude-session", lead: bisect.lead}
	}
	if bisect.notes != _|_ {
		notify: {kind: "claude-session", notes: bisect.notes}
	}
	// Commands run when something happens, each in the run's worktree with `<worktree> <app> <commit>` appended: `released`,
	// after the release is confirmed. A hook that fails is logged and never changes the run's outcome.
	// (The dev flow's board: ["deno", "run", "-A", "--reload=https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/",
	// "https://raw.githubusercontent.com/bsoneca/pronto-plugins/main/devflow/hook.ts", "released"].)
	hooks: [...#Hook]
	// What production must answer once the release is serving, each fetched from the release's domain.
	probes: [Name=string]: #Probe
}

#Launchd: {kind: "launchd"}
#Systemd: {kind: "systemd"}
#Actions: {kind: "actions"}

#CloudRun: {kind: "cloud-run"}

// A command that opens an ssh connection says how it learns the other end is gone: ServerAliveInterval. A step has no time
// limit (a release takes as long as it takes), so a connection to a node that rebooted, its TCP state lost with it, would be
// waited on for ever: on 2026-11-11 a rc preview sat 104 min on a dead ssh to a node that had restarted at 15:41 BRT, and the
// run was recorded only once the lead killed the ssh by hand. With it ssh ends with 255 after interval x count seconds and
// the run records the failure itself.
#SshAlive: {
	cmd: [string, ...string]
	_text: strings.Join(cmd, " ")
	ok:    !strings.Contains(_text, "ssh ") || strings.Contains(_text, "ServerAliveInterval=")
	ok:    true
}
#Command: {
	kind: *"command" | "command"
	release!: [string, ...string]
	serving!: [string, ...string]
	origin!:  string & =~"^https://"
	// A release preview (rc) proven before the release: `up` releases it (the node's release@k8s --preview=rc), `reach`
	// makes it answer at `origin` for as long as it runs (a port-forward, killed when the check is done), `down`
	// removes it, always. The probes below that do not say `preview: false` are asked of it, and it must answer them
	// all before the release goes ahead: its images, migrations and config proven on the node, before traffic moves.
	preview?: {
		up!:    [string, ...string]
		reach!: [string, ...string]
		down!:  [string, ...string]
		origin: *"http://localhost:18080" | (string & =~"^http://localhost:[0-9]+$")
	}
	_alive: [
		(#SshAlive & {cmd: release}).ok,
		(#SshAlive & {cmd: serving}).ok,
		if preview != _|_ {(#SshAlive & {cmd: preview.up}).ok},
		if preview != _|_ {(#SshAlive & {cmd: preview.reach}).ok},
		if preview != _|_ {(#SshAlive & {cmd: preview.down}).ok},
	]
}

#NoNotify: {kind: "none"}
#GithubComment: {kind: "github-comment"}
#ClaudeSession: {
	kind:  "claude-session"
	lead!: string
	notes: *"Library/Application Support/Claude/side-session-notes" | string
}

#Hook: {
	on!:      "released"
	command!: [string, ...string]
}

#Probe: {
	path!:  string & =~"^/"
	agent?: string
	status: int | *200
	// Text the body holds, when the status alone does not prove the right server answered.
	has: [...string]
	// Where a redirect must send the probe (the Location's start): the probe is asked without
	// following it, so the address the app sends to is what is checked (PRONTO-6's Google start).
	location?: string & =~"^https://"
	// `false`: the release preview is not asked this probe (it holds no production rows, say).
	preview?: false
	why?: string
}
