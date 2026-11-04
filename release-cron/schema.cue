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
	// There is no per-step limit: no step is stopped for its time. A step that runs long shows in the
	// run's log (a line every 5 minutes while it runs); its minutes are in runs.jsonl and `report`.
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
