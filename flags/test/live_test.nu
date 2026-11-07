# pronto-flags' live commands (flags/live.nu) against a stand-in for gcloud
# (fake_gcloud.py), and a store kept in a local directory (flagsLive.dir), on an app the installer writes: setup makes the bucket
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
	with-env ({SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FLAGS_OFREP_CMD: $"python3 ($here)/fake_ofrep.py", FLAGS_POLL_SEC: "0.01", FLAGS_WAIT_SEC: "0.1", PRONTO_FLAGS_JOURNAL: $"($dir)/journal.jsonl"} | merge $extra) {
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

# A flip runs its flag's cases on production, for the testers alone, then writes it for everyone; nothing at hand.
def full-spec [premium: bool, theme: string] {
	$"package shop
flags: premium: {default: ($premium), local: true}
flags: theme: {default: \"($theme)\"}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", url: \"https://shop.example\", testers: [\"tester-1\"], runAs: \"shop-run@shop-prod.iam.gserviceaccount.com\", alert: \"projects/shop-prod/alertPolicies/42\"}
flagsCases: {
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
check ((ran) == ["live premium buy https://shop.example tester-1 shop-run@shop-prod.iam.gserviceaccount.com"]) "flip: only the production cases ran, as the tester; nothing at hand"
let hist = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
}).stdout | from json
check ($hist.0.stage == "all" and $hist.0.cases == "passed" and $hist.1.stage == "testers") "history: the stage and the verdict of each version"

# No tester, or a flag with no production scenario: the flip is refused, nothing written, nothing run.
full-spec false "light"
let n1 = (object | length)
let ran1 = (ran | length)
open --raw $"($app)/flags_spec.cue" | str replace 'testers: ["tester-1"]' 'testers: []' | save -f $"($app)/flags_spec.cue"
let nt = (livex [push $app])
check ($nt.exit_code != 0 and (object | length) == $n1 and (ran | length) == $ran1 and ($nt.stderr | str contains "flagsLive.testers")) "no tester: the flip is refused, nothing written"
full-spec false "light"
open --raw $"($app)/tests/scenarios/shop.cue" | str replace 'production: true, ' '' | save -f $"($app)/tests/scenarios/shop.cue"
let np = (livex [push $app])
check ($np.exit_code != 0 and (object | length) == $n1 and (ran | length) == $ran1 and ($np.stderr | str contains "no `production` scenario")) "no production scenario: the flip is refused, nothing written"
open --raw $"($app)/tests/scenarios/shop.cue" | str replace 'buy: {flags: ["premium"], ' 'buy: {flags: ["premium"], production: true, ' | save -f $"($app)/tests/scenarios/shop.cue"
let gone = (livex [push $app --skip-live "no tester yet"])
check ($gone.exit_code != 0 and (object | length) == $n1) "--skip-live is gone: refused"

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

# Back to off, through the live stage, for what follows.
full-spec false "light"
live push $app | ignore

# Targeted only during a run: no version outlives a run with a tester named in it.
let named = (object | where {|v| $v.data | str contains "tester-1" } | each {|v| $v.metadata.stage? | default "" })
check ($named | all {|st| $st == "testers" }) "testers: named only in the canary versions"
check (($named | length) == 5) "testers: the canaries are the only ones"

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
open --raw $"($app)/flags_spec.cue" | str replace 'echo live $FLAG' 'echo sayt=${SAYT_VERSION:-none} live $FLAG' | save -f $"($app)/flags_spec.cue"
let pinned = (livex [push $app] {SAYT_VERSION: "v0.0.1"})
check ($pinned.exit_code == 0 and ((ran | last) | str starts-with "sayt=none")) "the cases don't inherit this tool's SAYT_VERSION"

# A mirror (flagsLive.mirrors): each write of the object is applied to a node's ConfigMap over ssh;
# a failing mirror warns, unless it is required. ssh is a stand-in that keeps what it was sent.
let bin = $"($dir)/bin"
mkdir $bin
let sent = $"($dir)/ssh-sent"
$"#!/bin/sh\necho \"$@\" >> ($sent).args\nif [ -n \"$SSH_FAIL\" ]; then echo refused >&2; exit 255; fi\ncat > ($sent)\n" | save -f $"($bin)/ssh"
^chmod +x $"($bin)/ssh"
full-spec false "light"
"flagsLive: mirrors: [{ssh: \"ops@node.example\", namespace: \"shop\", configMap: \"shop-flags\"}]\n" | save -a $"($app)/flags_spec.cue"
"flags: mirrored: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let m = (livex [push $app] {PATH: ([$bin] | append $env.PATH)})
let cm = (open --raw $sent | from json)
check ($m.exit_code == 0 and $cm.kind == "ConfigMap" and $cm.metadata == {name: "shop-flags", namespace: "shop"}) "a push applies the mirror's ConfigMap"
check (($cm.data."flags.json" | from json | get flags | columns | any {|c| $c == "mirrored" }) and (open --raw $"($sent).args" | str contains "ops@node.example sudo k3s kubectl apply -f -")) "the mirror holds the flags pushed, applied as the node's kubectl"
"flags: warned: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let n7 = (object | length)
let w = (livex [push $app] {PATH: ([$bin] | append $env.PATH), SSH_FAIL: "1"})
check ($w.exit_code == 0 and (object | length) == $n7 + 1 and ($w.stderr | str contains "the mirror at ops@node.example's shop/shop-flags failed")) "a failing mirror warns, and the push is written"
open --raw $"($app)/flags_spec.cue" | str replace 'configMap: "shop-flags"}' 'configMap: "shop-flags", required: true}' | save -f $"($app)/flags_spec.cue"
"flags: held: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let r = (livex [push $app] {PATH: ([$bin] | append $env.PATH), SSH_FAIL: "1"})
check ($r.exit_code != 0 and ($r.stderr | str contains "the mirror at ops@node.example's shop/shop-flags failed")) "a required mirror that fails fails the push"

# A dry run never reaches a write. gcloud refuses anything but a read and notes it (FAKE_GCLOUD_READONLY), a
# mirror is set, and push, rollback and setup run under --dry-run and under PRONTO_FLAGS_DRY_RUN: no version,
# no gcloud write, no ssh.
let ro = {PATH: ([$bin] | append $env.PATH), FAKE_GCLOUD_READONLY: "1"}
let gens = (object | length)
let sshed = (open --raw $"($sent).args" | lines | length)
for a in [[push $app --dry-run] [push $app --untested "dry" --dry-run] [rollback $app --dry-run] [setup $app --dry-run]] {
	let r = (livex $a $ro)
	check ($r.exit_code == 0 and ($r.stdout | str contains "dry run: nothing written")) $"--dry-run: ($a | str join ' ') shows and stops"
}
let r_env = (livex [push $app --untested "dry"] ($ro | merge {PRONTO_FLAGS_DRY_RUN: "1"}))
check ($r_env.exit_code == 0 and ($r_env.stdout | str contains "dry run: nothing written")) "PRONTO_FLAGS_DRY_RUN: the same"
check (not ($"($state).writes" | path exists) and (object | length) == $gens and (open --raw $"($sent).args" | lines | length) == $sshed) "dry run: no gcloud write, no new version, no mirror"
# Each write refuses on its own under a dry run, whatever path reaches it: the store, and gcloud itself.
let fakes = {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FAKE_GCLOUD_READONLY: "1", PRONTO_FLAGS_DRY_RUN: "1"}
let put = (with-env $fakes { ^$nu.current-exe -c $"use ($here)/../live.nu store-put; store-put {url: 'gs://shop-prod-flags/flags.json'} '{\"flags\": {}}' {stage: all} '1'" | complete })
check ($put.exit_code != 0 and ($put.stderr | str contains "dry run: refused a write")) "dry run: the store refuses a write"
let cp = (with-env $fakes { ^$nu.current-exe -c $"use ($here)/../live.nu run-gcloud; run-gcloud storage cp /dev/null gs://shop-prod-flags/flags.json" | complete })
check ($cp.exit_code != 0 and ($cp.stderr | str contains "dry run: refused a write")) "dry run: gcloud refuses a write"
let rd = (with-env $fakes { ^$nu.current-exe -c $"use ($here)/../live.nu run-gcloud; run-gcloud config get-value account | get stdout" | complete })
check ($rd.exit_code == 0 and ($rd.stdout | str contains "operator@example.com")) "dry run: gcloud still reads"
check (not ($"($state).writes" | path exists) and (object | length) == $gens) "dry run: still nothing written"

# The journal of the writes above: one JSON line each, with the flags whose default moved.
let jl = (open --raw $"($dir)/journal.jsonl" | lines | each {|l| $l | from json })
check (($jl | all {|j| $j.event == "flags.write" and $j.app == "shop" and ($j.target | str starts-with "gs://shop-prod-flags/") and ($j.at | str ends-with "Z") }) and ($jl | length) > 10) "journal: a line for every write, with its event, app, target and time"
check (($jl | where stage == "rollback" | first).note | str starts-with "rolled back from ") "journal: a rollback says from which version"
check (($jl | where stage == "testers" | first).flag == "premium") "journal: a canary names its flag"
let gh = (livex [history $app --json])
let gj = ($gh.stdout | from json)
check ($gh.exit_code == 0 and ($gj | length) == (object | length) and ($gj | all {|r| "changes" in ($r | columns) }) and ($gj.0.version | into int) > ($gj.1.version | into int)) "history --json on a bucket: newest first, each with its changes"

# ---- A store in a directory (flagsLive.dir): the same versions, with no gcloud ----
let drill = $"($dir)/drill"
mkdir $drill
"package drill\n" | save $"($drill)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($drill)/.mise.toml"
^$real trust -q $"($drill)/.mise.toml"
^$real exec deno@2.5.0 -- deno run --no-config --allow-read --allow-write $"($here)/../install.ts" $drill | ignore
def dspec [broken: bool] {
	$"package drill
flags: drill_break_checkout: {default: ($broken), local: true}
flagsLive: {dir: \"flagstore\"}
" | save -f $"($drill)/flags_spec.cue"
}
let store = $"(($drill | path expand))/flagstore"
let want = $"file://($store)/flags.json"
let jfile = $"($dir)/drill-journal.jsonl"
def dlive [args: list<string>, extra: record = {}] { livex $args ({PRONTO_FLAGS_JOURNAL: $jfile} | merge $extra) }
def djournal [] { if ($jfile | path exists) { open --raw $jfile | lines | each {|l| $l | from json } } else { [] } }
def dversions [] { glob $"($store)/versions/*.meta.json" | length }

dspec false
let dshow = (dlive [show $drill])
check ($dshow.exit_code == 0 and ($dshow.stdout | str contains $want) and not ($store | path exists)) "dir store: show names file://<dir>/flags.json and writes nothing"
let dset = (dlive [setup $drill])
check ($dset.exit_code == 0 and ($dset.stdout | str starts-with $"flags: target ($want)")) "dir store: setup says its target first"
check (($"($store)/flags.json" | path exists) and (dversions) == 1 and (open $"($store)/flags.json" | get flags.drill_break_checkout.variants.default) == false) "dir store: setup makes the directory and the first push"
let v1 = (glob $"($store)/versions/*.meta.json" | first | open --raw | from json)
check ($v1.timeDeleted == null and $v1.metadata.stage == "all" and ($v1.metadata.pushed-by | is-not-empty) and ($v1.generation | into int) > 0) "dir store: a version keeps its generation, time, who and stage"
check ((djournal | length) == 1 and (djournal).0.from == "0" and (djournal).0.flag == "" and (djournal).0.changes == [] and (djournal).0.target == $want and (djournal).0.app == "drill") "dir store: the first push is journaled, from generation 0, with no flip"
let again = (dlive [setup $drill])
check ($again.exit_code == 0 and (dversions) == 1) "dir store: setup again pushes nothing"

# A flip, with no cases and said so.
dspec true
let refused2 = (dlive [push $drill])
check ($refused2.exit_code != 0 and ($refused2.stderr | str contains "no cases") and (dversions) == 1) "dir store: a flip with no cases is refused, nothing written"
let flip = (dlive [push $drill --untested "the drill"])
check ($flip.exit_code == 0 and (dversions) == 2 and (open $"($store)/flags.json" | get flags.drill_break_checkout.variants.default) == true) "dir store: the flip is written to flags.json"
let metas = (glob $"($store)/versions/*.meta.json" | each {|f| open --raw $f | from json } | sort-by {|m| $m.generation | into int })
check ($metas.0.timeDeleted != null and $metas.1.timeDeleted == null and $metas.1.metadata.cases == "untested" and $metas.1.metadata.flag == "drill_break_checkout") "dir store: the replaced version is kept, marked deleted; the new one keeps its stage, cases and flag"
check ((ls -a $store | get name | where {|n| $n | str contains ".tmp" } | is-empty) and ((open --raw $"($store)/flags.json") == (open --raw $"($store)/versions/($metas.1.generation).json"))) "dir store: flags.json is the newest version whole, no temp file left"
let j2 = (djournal | get 1)
check ($j2.flag == "drill_break_checkout" and $j2.changes == [{flag: "drill_break_checkout", from: false, to: true}] and $j2.from == $metas.0.generation and $j2.version == $metas.1.generation and $j2.stage == "all" and $j2.cases == "untested" and ($j2.note | str contains "the drill") and ($j2.who | is-not-empty) and ($flip.stdout | str contains "flags: journal {")) "dir store: the flip's journal line, printed too"

# History as JSON.
let dh = (dlive [history $drill --json])
let dj = ($dh.stdout | from json)
check ($dh.exit_code == 0 and ($dj | length) == 2 and $dj.0.version == $metas.1.generation and $dj.0.live and not $dj.1.live) "dir store: history --json lists every version, newest first"
check ($dj.0.changes == [{flag: "drill_break_checkout", from: false, to: true}] and $dj.1.changes == []) "dir store: history --json: each version's changes against the one before"

# A rollback.
let rb = (dlive [rollback $drill])
check ($rb.exit_code == 0 and (dversions) == 3 and (open $"($store)/flags.json" | get flags.drill_break_checkout.variants.default) == false) "dir store: rollback writes the version before the live one again"
let j3 = (djournal | get 2)
check ($j3.stage == "rollback" and $j3.note == $"rolled back from ($metas.1.generation) to ($metas.0.generation)" and $j3.flag == "drill_break_checkout" and $j3.changes == [{flag: "drill_break_checkout", from: true, to: false}] and $j3.from == $metas.1.generation) "dir store: the rollback's journal line"
check ((djournal | length) == 3) "dir store: the journal holds three lines"
let rh = ((dlive [history $drill --json]).stdout | from json)
check ($rh.0.stage == "rollback" and $rh.0.note == $j3.note and $rh.0.flag == "drill_break_checkout") "dir store: the rollback's stage and note are kept on its version"
let back = (dlive [rollback $drill $metas.1.generation])
check ($back.exit_code == 0 and (open $"($store)/flags.json" | get flags.drill_break_checkout.variants.default) == true and (dversions) == 4) "dir store: rollback to a named version"
let nov = (dlive [rollback $drill 999])
check ($nov.exit_code != 0 and (dversions) == 4) "dir store: rollback to a version that isn't there is refused"
dspec false
dlive [push $drill] | ignore

# The target guard.
let nv = (dversions)
let nj = (djournal | length)
let wrong = (dlive [push $drill --untested x --expect "gs://brawl-chess-flags/flags.json"])
check ($wrong.exit_code != 0 and ($wrong.stdout | str contains $"flags: target ($want)") and ($wrong.stderr | str contains "not the expected") and (dversions) == $nv and (djournal | length) == $nj) "--expect: a different target is refused, nothing written"
let wrong_env = (dlive [rollback $drill] {PRONTO_FLAGS_EXPECT: "gs://brawl-chess-flags/flags.json"})
check ($wrong_env.exit_code != 0 and (dversions) == $nv) "PRONTO_FLAGS_EXPECT: a different target is refused, nothing written"
let wrong_setup = (dlive [setup $drill --expect "gs://brawl-chess-flags/flags.json"])
check ($wrong_setup.exit_code != 0 and (dversions) == $nv) "--expect on setup too"
dspec true
let right = (dlive [push $drill --untested "expected target" --expect $want])
check ($right.exit_code == 0 and (dversions) == $nv + 1) "--expect: the right target is written"
let right_env = (dlive [rollback $drill] {PRONTO_FLAGS_EXPECT: $want})
check ($right_env.exit_code == 0 and (dversions) == $nv + 2) "PRONTO_FLAGS_EXPECT: the right target is written"

# A dry run writes nothing.
let nv2 = (dversions)
let nj2 = (djournal | length)
dspec false
let dry = (dlive [push $drill --untested x] {PRONTO_FLAGS_DRY_RUN: "1"})
check ($dry.exit_code == 0 and ($dry.stdout | str contains "dry run: nothing written") and ($dry.stdout | str contains $want) and (dversions) == $nv2 and (djournal | length) == $nj2) "dry run: push shows and writes nothing"
let dry_rb = (dlive [rollback $drill] {PRONTO_FLAGS_DRY_RUN: "1"})
check ($dry_rb.exit_code == 0 and ($dry_rb.stdout | str contains "dry run: nothing written") and (dversions) == $nv2 and (djournal | length) == $nj2) "dry run: rollback shows and writes nothing"

# Two writers: a write names the generation it read, and is refused when another has written since.
let stale = (^$nu.current-exe -c $"use ($here)/../live.nu store-put; store-put {dir: '($store)', url: '($want)'} '{}' {stage: all} '1'" | complete)
check ($stale.exit_code != 0 and ($stale.stderr | str contains "412 Precondition Failed") and (dversions) == $nv2) "dir store: a write over a generation that is no longer live is refused"
let live_gen = (glob $"($store)/versions/*.meta.json" | each {|f| open --raw $f | from json } | where timeDeleted == null | get generation.0)
let fresh = (^$nu.current-exe -c $"use ($here)/../live.nu store-put; store-put {dir: '($store)', url: '($want)'} '{\"flags\": {}}' {stage: all} '($live_gen)'" | complete)
check ($fresh.exit_code == 0 and (dversions) == $nv2 + 1 and ($fresh.stdout | str trim | into int) > ($live_gen | into int)) "dir store: a write over the live generation goes, with a greater generation"

# A change to a flag's targeting alone (its `local` gone, so no host rule) names the flag, its default unmoved.
dspec false
let base = (dlive [push $drill --untested "the flag back, with its local value"])
check ($base.exit_code == 0) "dir store: a push over the stand-in write"
$"package drill
flags: drill_break_checkout: {default: false}
flagsLive: {dir: \"flagstore\"}
" | save -f $"($drill)/flags_spec.cue"
let tgt = (dlive [push $drill --untested "targeting only"])
let jt = (djournal | last)
check ($tgt.exit_code == 0 and $jt.flag == "drill_break_checkout" and $jt.changes == []) "journal: a targeting-only change names its flag, with no default change"

# Where no file is named, the journal is in the operator's state: XDG_STATE_HOME, else ~/.local/state.
let xdg = $"($dir)/xdg"
let byxdg = (livex [rollback $drill] {PRONTO_FLAGS_JOURNAL: "", XDG_STATE_HOME: $xdg})
check ($byxdg.exit_code == 0 and ($"($xdg)/pronto-flags/drill.jsonl" | path exists)) "journal: XDG_STATE_HOME/pronto-flags/<app>.jsonl by default"
let byhome = (with-env {PRONTO_FLAGS_JOURNAL: "", XDG_STATE_HOME: "", HOME: $"($dir)/home"} { ^$nu.current-exe -c $"use ($here)/../live.nu journal-file; journal-file ($drill)" | complete })
check ($byhome.exit_code == 0 and ($byhome.stdout | str trim) == $"($dir)/home/.local/state/pronto-flags/drill.jsonl") "journal: ~/.local/state/pronto-flags/<app>.jsonl without XDG_STATE_HOME"

rm -rf $dir
print "flags: live commands pass"
