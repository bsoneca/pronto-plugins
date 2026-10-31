package __PACKAGE__

// The app's feature flags (pronto-flags): each a value it reads while it runs.
// `default` is its value wherever the app is released; `local`, when given, its
// value wherever the door is reached at hand (a developer's launch, CI) and for
// the `accounts` it names. A page reads them through OpenFeature
// (flags_plugin.cue says how). Where the app is released they are live: a change
// here reaches it with `pronto-flags push <app-dir>`, never a deploy.
flags: {
	// example: {
	// 	note:     "What it turns on, and why it is a flag."
	// 	default:  false
	// 	local:    true
	// 	accounts: ["<an account's id>"]
	// }
}

// Where the released app's flags live, once `pronto-flags setup <app-dir>` made it.
// release.cue hands flagd the object, spelled out since a release reads that file
// alone (`cue export -e flagsLive.sources` prints it), and this holds it there:
// flagsLive: {project: "<the release's project>", bucket: "<project>-flags"}
// GCP: sidecars: flagd: env: FLAGD_SOURCES: flagsLive.sources
