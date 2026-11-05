// What release-cron (README.md) reads besides an app's release.cue: the app's opt-in, its
// schedule, each step's limit and what production must answer. Written once here and in the app's
// releaseCron, never in the script. bin/pronto-release-cron writes it into the app's own package
// (release_cron_plugin.cue), where the app's release_cron.cue gives releaseCron its values.
package releasecron

releaseCron: #Cron

#Cron: {
	// Minutes to wait after a run that released (or failed) before the next starts: release, wait,
	// release again. A run that skipped waits only for the next wake.
	gap: *60 | (number & >=0)
	// Minutes between launchd's wakes (StartInterval): each wake starts a run once the gap is over.
	poll: *10 | (int & >=1)
	// The paths whose change since the last run that released makes a release, relative to the
	// repository; the app's own folder when not named. Nothing changed: the run skips.
	watch: [...string]
	// An app released elsewhere than Cloud Run (aprende, on Cloudflare Pages), with no release.cue: the
	// command that releases the checked-out tree and the one that prints the commit production serves,
	// both run in the app's folder, and the address the probes ask. Absent: release.cue's GCP,
	// `./saytw release@gcp` and Cloud Run's traffic.
	target?: {
		release!: [string, ...string]
		serving!: [string, ...string]
		origin!:  string & =~"^https://"
	}
	// Cloud Run services, besides GCP.service, that must be Ready in confirm (Bonk Chess: its renderer).
	ready: [...string]
	// The `what` of a slot's owner line (tests/slot.ts) that marks the rehearsal's main slot: what the
	// app's ./saytw verify@local claims its slot as. The Ume apps' verify@local runs generate, lint and
	// test, then `./saytw integrate@local`, which claims it.
	holder: *"verify@local" | string
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
		// The Claude Desktop session told of the culprit when its pull request names no author
		// session (a `local_<uuid>` in its body), and the folder (under HOME) session notes go in.
		lead:  *"local_7c6084eb-07de-487a-b8e6-689748accaaa" | string
		notes: *"Library/Application Support/Claude/side-session-notes" | string
	}
	// What production must answer once the release is serving, each fetched from the release's domain.
	probes: [Name=string]: #Probe
}

#Probe: {
	path!:  string & =~"^/"
	agent?: string
	status: int | *200
	// Text the body holds, when the status alone does not prove the right server answered.
	has: [...string]
	why?: string
}
