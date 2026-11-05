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

def livex [args: list<string>, extra: record = {}] {
	with-env ({SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FLAGS_OFREP_CMD: $"python3 ($here)/fake_ofrep.py", FLAGS_POLL_SEC: "0.01", FLAGS_WAIT_SEC: "0.1"} | merge $extra) {
		^$nu.current-exe $"($here)/../live.nu" ...$args | complete
	}
}
def --wrapped live [...args] {
	let r = (livex $args)
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
let refused = (livex [push $app])
check ($refused.exit_code != 0 and ($refused.stderr | str contains "no cases") and (object | length) == $before) "push: a new flag with no cases is refused, and nothing is written"
let pushed = (live push $app --untested "a theme is no feature")
check ((object | length) == $before + 1 and ($pushed | str contains "theme")) "push --untested: written, then summarized"
check ((object | first).metadata.cases == "untested" and ((object | first).metadata.note | str contains "a theme is no feature")) "push --untested: the reason is kept on the version"

# A flip runs its flag's cases: at hand, then on production for the testers alone, then for everyone.
def full-spec [premium: bool, theme: string] {
	$"package shop
flags: premium: {default: ($premium), local: true}
flags: theme: {default: \"($theme)\"}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", url: \"https://shop.example\", testers: [\"tester-1\"], runAs: \"shop-run@shop-prod.iam.gserviceaccount.com\", alert: \"projects/shop-prod/alertPolicies/42\"}
flagsCases: {
	local: \"echo local $FLAG $ONLY $UNIT_ONLY $SLOW >> ran.log; test ! -f fail-local\"
	live:  \"echo live $FLAG $ONLY $APP_URL $FLAGS_TESTER $CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT >> ran.log; test ! -f crash-live || kill -9 $$; test ! -f fail-live\"
}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($app)/flags_spec.cue"
}
mkdir $"($app)/tests/scenarios" $"($app)/tests/unit"
'package scenarios
scenarios: buy: {flags: ["premium"], production: true, steps: [{by: "tester", open: "/"}]}
scenarios: shelf: {steps: [{by: "lia", flag: "premium"}, {by: "lia", open: "/"}]}
scenarios: unrelated: {flags: ["theme-x"], steps: [{by: "lia", open: "/"}]}
' | save $"($app)/tests/scenarios/shop.cue"
'package unit
cases: price: {flags: ["premium"], steps: [{call: "price"}]}
' | save $"($app)/tests/unit/shop.cue"
def ran [] { if ($"($app)/ran.log" | path exists) { open --raw $"($app)/ran.log" | lines } else { [] } }
def newest [n: int] { object | get $n }

let found = (live cases $app premium)
check (($found | str contains "buy") and ($found | str contains "shelf") and ($found | str contains "price") and not ($found | str contains "unrelated")) "cases: a flag's scenarios (flags, or a step's flag) and unit cases"
let none = (live cases $app theme)
check (not ($none | str contains "buy")) "cases: a flag nothing names has none"

full-spec true "light"
let n0 = (object | length)
let launched = (live push $app)
check ((object | length) == $n0 + 2) "flip: the canary and then the final version are written"
check ((newest 1).metadata.stage == "testers" and (newest 1).metadata.flag == "premium") "flip: the canary says its stage and flag"
let canary = (premium (newest 1))
check ($canary.targeting.if.0.in.1 == ["tester-1"] and $canary.targeting.if.1 == "new" and $canary.variants.new == true and $canary.variants.old == false) "flip: the canary is on for the testers alone"
check ((newest 0).metadata.stage == "all" and (newest 0).metadata.cases == "passed" and (newest 0).metadata.flag == "premium") "flip: the final version is for all, cases passed"
check ((premium (newest 0)).variants.default == true) "flip: the final version holds the new value"
check ((ran) == ["local premium buy,shelf price 1" "live premium buy https://shop.example tester-1 shop-run@shop-prod.iam.gserviceaccount.com"]) "flip: the cases ran at hand, slowed, then the production ones as the tester"
let hist = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
}).stdout | from json
check ($hist.0.stage == "all" and $hist.0.cases == "passed" and $hist.1.stage == "testers") "history: the stage and the verdict of each version"

# Local failure: nothing is written.
full-spec false "light"
touch $"($app)/fail-local"
let n1 = (object | length)
let lf = (livex [push $app])
check ($lf.exit_code != 0 and (object | length) == $n1 and ($lf.stderr | str contains "failed at hand")) "local failure: refused, nothing written"
rm $"($app)/fail-local"

# Live failure: back to the version read before the canary.
touch $"($app)/fail-live"
let pre = (premium (newest 0))
let lv = (livex [push $app])
check ($lv.exit_code != 0 and ($lv.stderr | str contains "rolled back")) "live failure: the push fails"
check ((object | length) == $n1 + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back" and (newest 1).metadata.stage == "testers") "live failure: the pre-canary flags are the newest version again"
rm $"($app)/fail-live"

# The cases' command dies under the push (killed): the same, back to the version before the canary.
touch $"($app)/crash-live"
let n1b = (object | length)
let cr = (livex [push $app])
check ($cr.exit_code != 0 and (object | length) == $n1b + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back") "a crashed live command: rolled back"
rm $"($app)/crash-live"

# An OFREP that never answers the new value: back as well.
let n2 = (object | length)
let st = (livex [push $app] {FAKE_OFREP_STALE: "1"})
check ($st.exit_code != 0 and ($st.stderr | str contains "did not answer") and (premium (newest 0)) == $pre and (object | length) == $n2 + 2) "OFREP timeout: rolled back"

# No change to a default value: no cases needed, and none run.
full-spec true "light"
let n3 = (object | length)
let ran3 = (ran | length)
live push $app | ignore
check ((object | length) == $n3 + 1 and (ran | length) == $ran3 and (newest 0).metadata.stage == "all") "unchanged defaults: written with no cases run"

# The monitoring window: one snooze per live stage, made before the canary and ended with the run, passed or not.
let zs = (held | get snoozes)
check (($zs | length) == 4 and ($zs | all {|z| $z.ended and $z.policies == "projects/shop-prod/alertPolicies/42" }) and ($zs.0.start <= $zs.0.end)) "snooze: each live stage has one, ended with the run"

# --skip-live: the cases at hand only, and the reason kept.
full-spec false "light"
let n4 = (object | length)
live push $app --skip-live "no tester yet" | ignore
check ((object | length) == $n4 + 1 and (newest 0).metadata.cases == "local-only" and ((newest 0).metadata.note | str contains "no tester yet") and ((ran | last) | str starts-with "local")) "--skip-live: no canary, the reason kept"

# Targeted only during a run: no version outlives a run with a tester named in it.
let named = (object | where {|v| $v.data | str contains "tester-1" } | each {|v| $v.metadata.stage? | default "" })
check ($named | all {|st| $st == "testers" }) "testers: named only in the canary versions"
check (($named | length) == 4) "testers: the canaries are the only ones"

# A flag cannot name a tester in its accounts, nor a live stage run without the release identity.
$"package shop
flags: premium: {default: false, local: true, accounts: [\"tester-1\"]}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", testers: [\"tester-1\"]}
" | save -f $"($app)/flags_spec.cue"
let named_in = (livex [show $app])
check ($named_in.exit_code != 0 and ($named_in.stderr | str replace -a -r "[ |\\n]+" " " | str contains "names the tester tester-1 in accounts")) "a tester named in a flag's accounts is refused"
full-spec true "light"
open --raw $"($app)/flags_spec.cue" | str replace -r 'runAs: [^,]*, ' '' | save -f $"($app)/flags_spec.cue"
full-spec true "light"
open --raw $"($app)/flags_spec.cue" | str replace -r ', runAs: [^,]*,' ',' | save -f $"($app)/flags_spec.cue"
let n5 = (object | length)
let norun = (livex [push $app])
check (($norun.stderr | str contains "flagsLive.runAs") and (object | length) == $n5) "no runAs: the live stage is refused"

# A flag new to the live object and off: nothing flips, so no cases are asked for and none run.
full-spec false "light"
"flags: shy: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let n6 = (object | length)
let ran6 = (ran | length)
live push $app | ignore
check ((object | length) == $n6 + 1 and (ran | length) == $ran6 and ((newest 0).data | from json | get flags | columns | any {|c| $c == "shy" })) "a new flag that is off: written with no cases run"

# The cases run under the app's own saytw pin, not the SAYT_VERSION this tool runs under.
full-spec true "light"
open --raw $"($app)/flags_spec.cue" | str replace 'echo local $FLAG' 'echo sayt=${SAYT_VERSION:-none} local $FLAG' | save -f $"($app)/flags_spec.cue"
let pinned = (livex [push $app --skip-live "no tester yet"] {SAYT_VERSION: "v0.0.1"})
check ($pinned.exit_code == 0 and ((ran | last) | str starts-with "sayt=none")) "the cases don't inherit this tool's SAYT_VERSION"

rm -rf $dir
print "flags: live commands pass"
