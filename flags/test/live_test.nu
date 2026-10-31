# pronto-flags' live commands (flags/live.nu) against a stand-in for gcloud
# (fake_gcloud.py), on an app the installer writes: setup makes the bucket
# private, versioned and read by the release's accounts, and pushes once; a push
# writes over only the version it read; history lists every version, by whom;
# a rollback writes an earlier one again as the newest. The app's cue is real.
#   ./saytw --script tools.nu nu flags/test/live_test.nu

const here = path self .
let real = $env.SAYT_MISE_BIN
let dir = (mktemp -d)
let state = $"($dir)/gcloud.json"
let app = $"($dir)/shop"
mkdir $app
"package shop\n" | save $"($app)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($app)/.mise.toml"
^$real trust -q $"($app)/.mise.toml"
^$real exec deno@2.5.0 -- deno run --no-config --allow-read --allow-write $"($here)/../install.ts" $app | ignore
def spec [accounts: list<string>] {
	$"package shop
flags: premium: {default: false, local: true, accounts: ($accounts | to json -r)}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($app)/flags_spec.cue"
}

def live [...args] {
	let r = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
		^$nu.current-exe $"($here)/../live.nu" ...$args | complete
	})
	if $r.exit_code != 0 { error make {msg: $"live.nu ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}
def held [] { open $state }
def object [] { held | get objects."gs://shop-prod-flags/flags.json" }
def premium [v: record] { $v.data | from json | get flags.premium }
def check [ok: bool, what: string] { if not $ok { error make {msg: $"failed: ($what)"} }; print $"ok: ($what)" }

spec []
let shown = (live show $app)
check ($shown | str contains "gs://shop-prod-flags/flags.json") "show names the object, writing nothing"
check (not ($state | path exists)) "show touches no gcloud state"

live setup $app | ignore
let b = (held | get buckets.shop-prod-flags)
check ($b.project == "shop-prod" and $b.location == "europe-west1" and $b.uniform and $b.pap) "setup: a private bucket in the release's project and region"
check ($b.versioning and $b.lifecycle.rule.0.condition.numNewerVersions == 50) "setup: versioned, keeping 50 versions"
check (($b.readers | each {|r| $r.0 }) == ["serviceAccount:shop-run@shop-prod.iam.gserviceaccount.com" "serviceAccount:shop-preview@shop-previews.iam.gserviceaccount.com"] and ($b.readers | all {|r| $r.1 == "roles/storage.objectViewer"})) "setup: the run and preview accounts read it"
check ((object | length) == 1 and (premium (object | first)).targeting.if.2.in.1 == []) "setup: the first push"
live setup $app | ignore
check ((object | length) == 1) "setup again pushes nothing"

spec ["acct-me"]
live push $app | ignore
check ((object | length) == 2 and (premium (object | first)).targeting.if.2.in.1 == ["acct-me"]) "push: the flags as the spec says them now"
check ((object | first).metadata.pushed-by == "operator@example.com") "push: who pushed, kept on the version"

let h = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
})
let versions = ($h.stdout | from json)
check (($versions | length) == 2) "history: every version"
check ($versions.0.live and not $versions.1.live and $versions.0.by == "operator@example.com") "history: newest first, the live one marked"

live rollback $app | ignore
check ((object | length) == 3 and (premium (object | first)).targeting.if.2.in.1 == []) "rollback: the version before the live one, written again as the newest"
live rollback $app ($versions.0.version) | ignore
check ((premium (object | first)).targeting.if.2.in.1 == ["acct-me"]) "rollback to a named version"
let none = (try { live rollback $app "999" | ignore; false } catch { true })
check $none "rollback to a version that isn't there is refused"

# A flag local at hand with no accounts has the string "default" where accounts would be, and one
# with no local value has no targeting at all: show and push summarize them, as a push writes them.
$"package shop
flags: premium: {default: false, local: true}
flags: theme: {default: \"light\"}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($app)/flags_spec.cue"
let plain = (live show $app)
check (($plain | str contains "premium") and ($plain | str contains "theme")) "show: a flag local alone, and one with no targeting"
let before = (object | length)
let pushed = (live push $app)
check ((object | length) == $before + 1 and ($pushed | str contains "theme")) "push: written, then summarized"

rm -rf $dir
print "flags: live commands pass"
