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
	// Cloud Run services, besides GCP.service, that must be Ready in confirm (Bonk Chess: its renderer).
	ready: [...string]
	// The `what` of a slot's owner line (tests/slot.ts) that marks the rehearsal's main slot: what the
	// app's ./saytw verify@local claims its slot as. The Ume apps' verify@local runs generate, lint and
	// test, then `./saytw integrate@local`, which claims it.
	holder: *"verify@local" | string
	// Each step's limit, in minutes: a guard against a wedged step, far above what each takes
	// (measured per run in runs.jsonl). A step that outlasts its limit is stopped and the run fails.
	minutes: {
		// fetch main, the run's worktree reset to it, what serves read.
		prepare: *5 | (number & >0)
		// verify@local waiting for its slot (tests/slot.ts): past this, the run skips and the next
		// one asks again. A run never waits the slot queue's own two hours.
		slot: *20 | (number & >0)
		// verify@local from its slot to its verdict: measured 17.5 (lanes, one flake retried).
		rehearse: *35 | (number & >0)
		// release@gcp: measured 9.3 with the rc preview skipped, 17-18 with it; with the rehearsal
		// in the cloud (GCP.rehearsal) it holds the rehearsal too, beside the stage.
		release: *45 | (number & >0)
		// production confirmed: the new revision serving, the probes below.
		confirm: *5 | (number & >0)
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
