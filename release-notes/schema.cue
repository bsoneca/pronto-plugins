// What release-notes (README.md) reads of an app besides its release records: where they come from,
// the time zone its Releases are dated in, which model words the changes, and who the changes are
// told to. Written once here and in the app's releaseNotes, never in the script. bin/pronto-release-notes
// writes it into the app's own package (release_notes_plugin.cue), where the app's optional
// release_notes.cue gives releaseNotes its values; without one every default is what Bonk Chess's
// Releases have always had.
package releasenotes

releaseNotes: #Notes

#Notes: {
	// Where the live releases of the app are read from.
	source: *#ReleaseCron | #Tags | #Deployments
	// The IANA time zone a Release's title and "Went live" are written in, and the label after the time.
	timeZone:  *"America/Sao_Paulo" | string
	zoneLabel: *"BRT" | string
	// What words a pull request in a line (and says whether the audience would notice it); the rules of notes.js
	// answer when it cannot. RELEASE_NOTES_MODEL in the environment overrides the name.
	model: *#Ollama | #Claude | #None
	// Who the changes are told to: the first section is "What <audience>s see", the model is asked for
	// a line an <audience> understands.
	audience: *"player" | string
}

// pronto's release records, ~/.cache/pronto/releases/<name>.jsonl; the name is release.cue's GCP.name unless given.
#ReleaseCron: {
	kind:  "release-cron"
	name?: string
}

// The git tags `<prefix>*`: the version is the tag without the prefix, the commit the tag's, the time its tagger's or
// committer's date.
#Tags: {
	kind:   "tags"
	prefix: string
}

// The GitHub deployments of an environment whose latest status is success (read with `gh api`): the version is the
// deployment's ref, else its sha.
#Deployments: {
	kind:        "deployments"
	environment: string
}

// A local model through Ollama.
#Ollama: {
	kind: "ollama"
	name: *"qwen3-coder:30b" | string
	url:  *"http://localhost:11434" | string
}

// Claude through the Messages API, with ANTHROPIC_API_KEY from the environment.
#Claude: {
	kind: "claude"
	name: string
}

// No model: the rules of notes.js alone, and nothing kept in the cache.
#None: {
	kind: "none"
}
