# The released app's live flags: one object in a versioned Cloud Storage bucket,
# which the app's flagd reads (FLAGD_SOURCES, release.cue) and polls, so a flag
# changes with a push and never a deploy. The app's flagsLive (flags_spec.cue)
# names the bucket and its project; its flags are flagd.document, exported from
# the app's CUE as generate writes flags/flags.json. Every push is a version of
# the object, kept: the history, and what a rollback restores.
#   bin/pronto-flags setup <app-dir>               # the bucket, its readers, the first push
#   bin/pronto-flags push <app-dir>                # the flags as flags_spec.cue says them now
#   bin/pronto-flags history <app-dir>             # every version, newest first
#   bin/pronto-flags rollback <app-dir> [version]  # the version before the live one, or the one named
#   bin/pronto-flags show <app-dir>                # what a push would write, and where: nothing written
# Each runs as the operator's own gcloud login.

def --wrapped gc [...args] {
	let input = $in
	let r = ($input | ^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"gcloud ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}
def --wrapped exists [...args]: nothing -> bool {
	(^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet ...$args | complete).exit_code == 0
}

# An expression of the app's CUE, exported with the CUE its own mise pins; null where the app has none.
def cue-of [app: path, expr: string] {
	let r = (do { cd $app; ^$env.SAYT_MISE_BIN exec -- cue export . -e $expr --out json } | complete)
	if $r.exit_code != 0 {
		if ($r.stderr | str contains "not found") or ($r.stderr | str contains "undefined field") { return null }
		error make {msg: $"cue export -e ($expr) in ($app): ($r.stderr | str trim)"}
	}
	$r.stdout | from json
}

def live [app: path] {
	let at = (cue-of $app flagsLive)
	if $at == null { error make {msg: $"($app)'s flags_spec.cue names no flagsLive: say `flagsLive: {project: \"…\", bucket: \"…\"}` there"} }
	$at | insert url $"gs://($at.bucket)/($at.object)"
}

# The live object's generation, or 0 where there is none yet: a push writes only over the one it read.
def generation [url: string] {
	let r = (^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet storage objects describe $url --format "value(generation)" | complete)
	if $r.exit_code == 0 { $r.stdout | str trim } else if ($r.stderr | str contains "404") or ($r.stderr | str contains "not found") or ($r.stderr | str contains "No URLs matched") { "0" } else {
		error make {msg: $"gcloud storage objects describe ($url): ($r.stderr | str trim)"}
	}
}

# Who pushed, and from which commit: kept on each version, which history shows.
def provenance [app: path] {
	let who = (gc config get-value account | str trim)
	let commit = (do { cd $app; ^git rev-parse --short HEAD } | complete | get stdout | str trim)
	# Any of the app's CUE: a flag's value may come from another spec (pronto-billing's grants, say).
	let dirty = (do { cd $app; ^git status --porcelain -- '*.cue' } | complete | get stdout | str trim)
	{who: $who, commit: ($commit + (if ($dirty | is-empty) { "" } else { "+edits" }))}
}

def write-flags [at: record, doc: record, app: path] {
	if not ($doc.flags? | describe | str starts-with "record") { error make {msg: "flagd.document has no flags"} }
	let from = (generation $at.url)
	let file = (mktemp -t --suffix .json)
	$doc | to json --indent 2 | save -f $file
	let p = (provenance $app)
	gc storage cp $file $at.url $"--if-generation-match=($from)" --content-type application/json --cache-control no-store $"--custom-metadata=pushed-by=($p.who),commit=($p.commit)" | ignore
	rm $file
	let now = (generation $at.url)
	print $"flags: ($at.url) is version ($now) \(was ($from)\); flagd reads it within seconds, and a page on its next load"
	summary $doc | print
}

# The accounts a flag names: its targeting's second test (flags_plugin.cue), where it has one.
# A flag local at hand alone has "default" there, and one with no local value no targeting.
def accounts-of [def: record]: nothing -> list<string> {
	let rule = ($def.targeting? | default null)
	if not ($rule | describe | str starts-with "record") { return [] }
	let branches = ($rule | get -o if)
	if not ($branches | describe | str starts-with "list") { return [] }
	let test = ($branches | get -o 2)
	if not ($test | describe | str starts-with "record") { return [] }
	let names = ($test | get -o in | get -o 1)
	if ($names | describe | str starts-with "list") { $names } else { [] }
}

# The flags a push writes, as a table: each flag's values and the accounts it names.
def summary [doc: record] {
	$doc.flags | transpose flag def | each {|f| {flag: $f.flag, default: $f.def.variants.default, local: ($f.def.variants.local? | default "—"), accounts: (accounts-of $f.def | str join ", ")}}
}

export def show [app: path] {
	let at = (live $app)
	print $"flags: a push writes ($at.url) in ($at.project):"
	summary (cue-of $app flagd.document) | print
}

export def push [app: path] {
	write-flags (live $app) (cue-of $app flagd.document) $app
}

# Every version of the object, newest first: `gcloud storage ls -a --json` gives each
# its generation, when it was written, when a newer one replaced it, and what push kept on it.
export def history [app: path] {
	let at = (live $app)
	gc storage ls -a --json $at.url | from json | get metadata
	| each {|o| {version: $o.generation, at: $o.timeCreated, live: ($o.timeDeleted? == null), by: ($o.metadata?.pushed-by? | default ""), commit: ($o.metadata?.commit? | default "")}}
	| sort-by {|v| $v.version | into int } --reverse
}

# The version before the live one, or the one named, written again as the newest:
# a rollback is itself a version, which a rollback undoes.
export def rollback [app: path, version?: string] {
	let at = (live $app)
	let all = (history $app)
	let live = ($all | where live | get version.0? | default "")
	let to = if $version != null { $version } else { $all | where version != $live | get version.0? }
	if $to == null or ($all | where version == $to | is-empty) { error make {msg: $"no version ($to) of ($at.url) to roll back to: `pronto-flags history` lists them"} }
	gc storage cp $"($at.url)#($to)" $at.url $"--if-generation-match=($live)" | ignore
	print $"flags: ($at.url) is ($to)'s flags again, as version (generation $at.url)"
}

# Once per app: the bucket, versioned and private, keeping the last 50 versions;
# the app's run and preview accounts as its readers, since flagd reads it as the
# service it runs in; and the first push, which flagd needs before a release
# names the object (flagd stops at start on a source it cannot read).
export def setup [app: path] {
	let at = (live $app)
	let bucket = $"gs://($at.bucket)"
	if not (exists storage buckets describe $bucket --project $at.project) {
		let region = (cue-of $app GCP.region | default "us-central1")
		gc storage buckets create $bucket --project $at.project --location $region --uniform-bucket-level-access --public-access-prevention | ignore
	}
	gc storage buckets update $bucket --versioning | ignore
	let rules = (mktemp -t --suffix .json)
	{rule: [{action: {type: "Delete"}, condition: {isLive: false, numNewerVersions: 50}}]} | to json | save -f $rules
	gc storage buckets update $bucket $"--lifecycle-file=($rules)" | ignore
	rm $rules
	let gcp = (cue-of $app GCP)
	let readers = if $gcp == null { [] } else {
		[$"($gcp.name)-run@($gcp.project).iam.gserviceaccount.com"]
		| append (if ($gcp.previewProject? | default "" | is-empty) { [] } else { [$"($gcp.name)-preview@($gcp.previewProject).iam.gserviceaccount.com"] })
	}
	for r in $readers {
		gc storage buckets add-iam-policy-binding $bucket --member $"serviceAccount:($r)" --role roles/storage.objectViewer | ignore
		print $"flags: ($r) reads ($bucket)"
	}
	if (generation $at.url) == "0" { push $app } else { print $"flags: ($at.url) is there already; `pronto-flags push` changes it" }
}

def main [] { print "usage: live.nu setup|push|history|rollback|show <app-dir> [version]" }
def "main setup" [app: path] { setup $app }
def "main push" [app: path] { push $app }
def "main history" [app: path] { history $app | table -e | print }
def "main rollback" [app: path, version?: string] { rollback $app $version }
def "main show" [app: path] { show $app }
