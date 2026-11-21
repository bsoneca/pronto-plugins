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
def flat []: string -> string { $in | str replace -a -r '\s*\n\s*\|?\s*' " " }
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
let held_back = (livex [push $app])
check ($held_back.exit_code == 0 and (object | length) == 2 and (premium (object | first)).targeting.if.2.in.1 == [] and ($held_back.stderr | str contains "premium kept as live")) "push: accounts added to a live flag, no --flip: held, nothing written"
live push $app --flip premium --untested "acct" | ignore
check ((object | length) == 3 and (premium (object | first)).targeting.if.2.in.1 == ["acct-me"]) "push: the flags as the spec says them now"
check ((object | first).metadata.pushed-by == "operator@example.com") "push: who pushed, kept on the version"

let h = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
})
let versions = ($h.stdout | from json)
check (($versions | length) == 3) "history: every version"
check ($versions.0.live and not $versions.1.live and $versions.0.by == "operator@example.com") "history: newest first, the live one marked"

live rollback $app | ignore
check ((object | length) == 4 and (premium (object | first)).targeting.if.2.in.1 == []) "rollback: the version before the live one, written again as the newest"
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
let plain = (live show $app --flip theme)
check (($plain | str contains "premium") and ($plain | str contains "theme")) "show: a flag local alone, and one with no targeting"
let before = (object | length)
let refused = (livex [push $app --flip theme])
check ($refused.exit_code != 0 and ($refused.stderr | str contains "no cases") and (object | length) == $before) "push: a new flag with no cases is refused, and nothing is written"
let pushed = (live push $app --flip theme --untested "a theme is no feature")
check ((object | length) == $before + 1 and ($pushed | str contains "theme")) "push --untested: written, then summarized"
check ((object | first).metadata.cases == "untested" and ((object | first).metadata.note | str contains "a theme is no feature")) "push --untested: the reason is kept on the version"

# A flip writes the flags for everyone, then runs the flag's production cases that sign in as no one; nothing at hand.
def full-spec [premium: bool, theme: string] {
	$"package shop
flags: premium: {default: ($premium), local: true}
flags: theme: {default: \"($theme)\"}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", url: \"https://shop.example\"}
flagsCases: {
	live:  \"echo live $FLAG $ONLY $APP_URL ${FLAGS_TESTER:-} >> ran.log; test ! -f crash-live || kill -9 $$; test ! -f fail-live\"
}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($app)/flags_spec.cue"
}
mkdir $"($app)/tests/scenarios" $"($app)/tests/unit"
'package scenarios
scenarios: buy: {flags: ["premium"], production: true, steps: [{by: "tester", open: "/"}]}
scenarios: mine: {flags: ["premium"], production: true, steps: [{by: "tester", signIn: true}]}
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
let launched = (live push $app --flip premium)
check ((object | length) == $n0 + 2) "flip: the version for everyone, then its verdict"
check ((newest 1).metadata.stage == "all" and (newest 1).metadata.cases == "running" and (newest 1).metadata.flag == "premium") "flip: written for everyone at once, its cases running"
check ((premium (newest 1)).variants.default == true and ((premium (newest 1)).variants | columns | all {|v| $v != "new" })) "flip: the new value for everyone, no canary"
check ((newest 0).metadata.stage == "all" and (newest 0).metadata.cases == "passed" and (newest 0).metadata.flag == "premium") "flip: the verdict, cases passed"
check ((premium (newest 0)).variants.default == true) "flip: the final version holds the new value"
check ((ran) == ["live premium buy https://shop.example"]) "flip: only the production cases that sign in as no one ran, as no one; nothing at hand"
let hist = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
}).stdout | from json
check ($hist.0.stage == "all" and $hist.0.cases == "passed" and $hist.1.cases == "running") "history: the stage and the verdict of each version"

# A flag turned off (its default now false) skips its cases, which test it on: stage=all, none run, the
# note says so (2026-11-08, card_chess).
let n4 = (object | length)
let ran4 = (ran | length)
full-spec false "light"
let off = (livex [push $app --flip premium])
check ($off.exit_code == 0 and ($off.stderr | str contains "turned off: no cases run")) "off-flip: pushed, saying its cases did not run"
check ((object | length) == $n4 + 1 and (ran | length) == $ran4) "off-flip: one version written, no case run"
check ((newest 0).metadata.stage == "all" and (newest 0).metadata.flag == "premium" and ((newest 0).metadata.note | str contains "turned off: premium")) "off-flip: stage=all, and the note records it"
check ((premium (newest 0)).variants.default == false and not ((newest 0).data | str contains "tester-1")) "off-flip: the version holds the new value, no tester named"

# --no-canary "<why>" (pronto-plugins#184) is every push's way now: accepted, its reason kept, the cases run.
let n5 = (object | length)
let ran5 = (ran | length)
full-spec true "light"
let nc = (livex [push $app --no-canary "the owner's go" --flip premium])
check ($nc.exit_code == 0 and ($nc.stderr | str contains "every push's way")) "--no-canary: pushed, saying it is the only way now"
check ((object | length) == $n5 + 2 and (ran | length) == $ran5 + 1) "--no-canary: written for everyone, its production cases run"
check (((newest 0).metadata.note | str contains "no canary: the owner's go")) "--no-canary: the reason kept"
full-spec false "light"
livex [push $app --flip premium] | ignore

# A flag with no production scenario: written for everyone, nothing run. Production cases with no
# flagsLive.url to run them at: refused, nothing written.
full-spec true "light"
let n1 = (object | length)
let ran1 = (ran | length)
open --raw $"($app)/tests/scenarios/shop.cue" | str replace -a 'production: true, ' '' | save -f $"($app)/tests/scenarios/shop.cue"
let np = (livex [push $app --flip premium])
check ($np.exit_code == 0 and (object | length) == $n1 + 1 and (ran | length) == $ran1 and (newest 0).metadata.cases == "none on production") "no production scenario: written for everyone, no case run"
open --raw $"($app)/tests/scenarios/shop.cue" | str replace 'buy: {flags: ["premium"], ' 'buy: {flags: ["premium"], production: true, ' | str replace 'mine: {flags: ["premium"], ' 'mine: {flags: ["premium"], production: true, ' | save -f $"($app)/tests/scenarios/shop.cue"
full-spec false "light"
livex [push $app --flip premium] | ignore
full-spec true "light"
let n1 = (object | length)
let ran1 = (ran | length)
open --raw $"($app)/flags_spec.cue" | str replace ', url: "https://shop.example"' '' | save -f $"($app)/flags_spec.cue"
let nourl = (livex [push $app --flip premium])
check ($nourl.exit_code != 0 and (object | length) == $n1 and (ran | length) == $ran1 and ($nourl.stderr | str contains "flagsLive.url")) "production cases, no url: refused, nothing written"
full-spec true "light"
let gone = (livex [push $app --skip-live "no tester yet"])
check ($gone.exit_code != 0 and (object | length) == $n1) "--skip-live is gone: refused"

# Live failure: back to the version read before the flip.
touch $"($app)/fail-live"
let pre = (premium (newest 0))
let lv = (livex [push $app --flip premium])
check ($lv.exit_code != 0 and ($lv.stderr | str contains "rolled back")) "live failure: the push fails"
check ((object | length) == $n1 + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back" and (newest 1).metadata.stage == "all") "live failure: the flags before the flip are the newest version again"
rm $"($app)/fail-live"

# The cases' command dies under the push (killed): the same, back to the version before the flip.
touch $"($app)/crash-live"
let n1b = (object | length)
let cr = (livex [push $app --flip premium])
check ($cr.exit_code != 0 and (object | length) == $n1b + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back") "a crashed live command: rolled back"
rm $"($app)/crash-live"

# An OFREP that never answers the new value: back as well.
let n2 = (object | length)
let st = (livex [push $app --flip premium] {FAKE_OFREP_STALE: "1"})
check ($st.exit_code != 0 and ($st.stderr | str contains "did not answer") and (premium (newest 0)) == $pre and (object | length) == $n2 + 2) "OFREP timeout: rolled back"

# No change to a default value: no cases needed, and none run.
full-spec false "light"
let n3 = (object | length)
let ran3 = (ran | length)
live push $app --flip premium | ignore
check ((object | length) == $n3 + 1 and (ran | length) == $ran3 and (newest 0).metadata.stage == "all") "unchanged defaults: written with no cases run"

# No tester is named anywhere, nor any snooze made: a flip has no testers' stage.
check (object | all {|v| not ($v.data | str contains "tester-1") }) "no version names a tester"
check ((held | get -o snoozes | default []) | is-empty) "no alert is snoozed"

# A flag new to the live object and off: nothing flips, so no cases are asked for and none run.
full-spec false "light"
"flags: shy: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let n6 = (object | length)
let ran6 = (ran | length)
live push $app --flip premium | ignore
check ((object | length) == $n6 + 1 and (ran | length) == $ran6 and ((newest 0).data | from json | get flags | columns | any {|c| $c == "shy" })) "a new flag that is off: written with no cases run"

# A flag new to the live object and on, through the flip (PRONTO-43, 2026-11-08 18:02 BRT: trial_banner's
# canary has variants {old, new} and no `default`, and the push failed past its testers write, unrolled back,
# with the board told the flag was on for everyone). The board is a stand-in that keeps what it was told.
^git -C $app init -q
mkdir $"($app)/devflow"
"package devflow\n" | save -f $"($app)/devflow/devflow.cue"
let board = $"($dir)/board.log"
let told = $"($dir)/devflow.sh"
$"#!/bin/sh\necho \"$*\" >> ($board)\n" | save -f $told
chmod +x $told
def board-said [] { if ($board | path exists) { open --raw $board | lines } else { [] } }
"scenarios: fresh_buy: {flags: [\"fresh\"], production: true, steps: [{by: \"tester\", open: \"/\"}]}\n" | save -a $"($app)/tests/scenarios/shop.cue"
full-spec false "light"
"flags: fresh: {default: true, local: true}\n" | save -a $"($app)/flags_spec.cue"
let n7 = (object | length)
touch $"($app)/fail-live"
let fresh_fail = (livex [push $app --flip "premium,fresh"] {PRONTO_DEVFLOW_BIN: $told})
rm $"($app)/fail-live"
check ($fresh_fail.exit_code != 0 and ($fresh_fail.stderr | str contains "rolled back") and not ($fresh_fail.stderr | str contains "variants.default")) "a new flag on, its cases failing: the push fails as a rollback, not on the summary"
check ((object | length) == $n7 + 2 and (newest 1).metadata.stage == "all" and (newest 0).metadata.stage == "rolled-back" and not ((newest 0).data | from json | get flags | columns | any {|c| $c == "fresh" })) "a new flag on, failing: the version before the flip is the newest again"
check ((board-said) | is-empty) "a failed flip tells the board nothing"
let fresh_ok = (livex [push $app --flip "premium,fresh"] {PRONTO_DEVFLOW_BIN: $told})
check ($fresh_ok.exit_code == 0 and ($fresh_ok.stdout | str contains "fresh")) "a new flag on: its summary is said"
check ((newest 1).metadata.stage == "all" and (newest 0).metadata.stage == "all" and ((newest 0).data | from json | get flags.fresh.variants.default) == true) "a new flag on: written for everyone, held on"
check ((board-said | length) == 1 and (board-said | first | str starts-with "flipped ") and (board-said | first | str ends-with "/shop shop fresh")) "a passed flip tells the board, once, after the everyone stage"
rm -rf $"($app)/.git" $"($app)/devflow"

# The cases run under the app's own saytw pin, not the SAYT_VERSION this tool runs under.
full-spec true "light"
open --raw $"($app)/flags_spec.cue" | str replace 'echo live $FLAG' 'echo sayt=${SAYT_VERSION:-none} live $FLAG' | save -f $"($app)/flags_spec.cue"
let pinned = (livex [push $app --flip premium] {SAYT_VERSION: "v0.0.1"})
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
check (($jl | where cases? == "running" | first).flag == "premium") "journal: a flip names its flag"
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
let refused2 = (dlive [push $drill --flip drill_break_checkout])
check ($refused2.exit_code != 0 and ($refused2.stderr | str contains "no cases") and (dversions) == 1) "dir store: a flip with no cases is refused, nothing written"
let flip = (dlive [push $drill --untested "the drill" --flip drill_break_checkout])
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
dlive [push $drill --flip drill_break_checkout] | ignore

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
let right = (dlive [push $drill --untested "expected target" --expect $want --flip drill_break_checkout])
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
let base = (dlive [push $drill --untested "the flag back, with its local value" --flip drill_break_checkout])
check ($base.exit_code == 0) "dir store: a push over the stand-in write"
$"package drill
flags: drill_break_checkout: {default: false}
flagsLive: {dir: \"flagstore\"}
" | save -f $"($drill)/flags_spec.cue"
let tgt = (dlive [push $drill --untested "targeting only" --flip drill_break_checkout])
let jt = (djournal | last)
check ($tgt.exit_code == 0 and $jt.flag == "drill_break_checkout" and $jt.changes == []) "journal: a targeting-only change names its flag, with no default change"

# Where no file is named, the journal is in the operator's state: XDG_STATE_HOME, else ~/.local/state.
let xdg = $"($dir)/xdg"
let byxdg = (livex [rollback $drill] {PRONTO_FLAGS_JOURNAL: "", XDG_STATE_HOME: $xdg})
check ($byxdg.exit_code == 0 and ($"($xdg)/pronto-flags/drill.jsonl" | path exists)) "journal: XDG_STATE_HOME/pronto-flags/<app>.jsonl by default"
let byhome = (with-env {PRONTO_FLAGS_JOURNAL: "", XDG_STATE_HOME: "", HOME: $"($dir)/home"} { ^$nu.current-exe -c $"use ($here)/../live.nu journal-file; journal-file ($drill)" | complete })
check ($byhome.exit_code == 0 and ($byhome.stdout | str trim) == $"($dir)/home/.local/state/pronto-flags/drill.jsonl") "journal: ~/.local/state/pronto-flags/<app>.jsonl without XDG_STATE_HOME"

# The database (flagsLive.database): each write is also put() into the app's database with the host the document is
# served at (flagsLive.url's), a write that fails there fails the push, and a dry run writes nothing there. The
# command is a stand-in that keeps the SQL it was sent.
check ($tgt.stdout | str contains "no flagsLive.database") "database: a push without one says so"
let dbsql = $"($dir)/db.sql"
def dbspec [] {
	$"package drill
flags: drill_break_checkout: {default: false, local: true}
flagsLive: {dir: \"flagstore\", url: \"https://drill.example\", database: \"test -z $DB_FAIL || { echo refused >&2; exit 3; }; cat >> ($dbsql)\"}
" | save -f $"($drill)/flags_spec.cue"
}
def puts [] { if ($dbsql | path exists) { open --raw $dbsql | lines | where {|l| $l | str starts-with "SELECT pronto_flags.put(" } } else { [] } }
def put-doc [line: string] { $line | str replace "SELECT pronto_flags.put('" "" | str replace "'::jsonb, 'drill.example');" "" | str replace -a "''" "'" | from json }
dbspec
let dp = (dlive [push $drill --untested "the database" --flip drill_break_checkout])
check ($dp.exit_code == 0 and (puts | length) == 1 and ($dp.stdout | str contains "written to the database")) "database: a push puts the document"
check ((put-doc (puts | last)) == (open $"($store)/flags.json") and ((puts | last) | str ends-with "'drill.example');")) "database: the document written, with flagsLive.url's host"
let drb = (dlive [rollback $drill])
check ($drb.exit_code == 0 and (puts | length) == 2 and (put-doc (puts | last)) == (open $"($store)/flags.json")) "database: a rollback puts the version it restored"
let nv3 = (dversions)
let ddry = (dlive [rollback $drill] {PRONTO_FLAGS_DRY_RUN: "1"})
check ($ddry.exit_code == 0 and (puts | length) == 2 and (dversions) == $nv3) "database: a dry run writes nothing there"
let dfail = (dlive [rollback $drill] {DB_FAIL: "1"})
check ($dfail.exit_code != 0 and ($dfail.stderr | str contains "the database write through") and ($dfail.stderr | str contains "refused") and (puts | length) == 2) "database: a write that fails there fails the push"

# ---- PRONTO-680: a push merges over the live flags (keep-live) and a release record lets a retired one go ----

# On a bucket. A flip whose live stage fails goes back to the version read before it, with the flags kept live as they were.
full-spec false "light"
livex [push $app --flip premium] | ignore
let extras = ((newest 0).data | from json | get flags | columns | where {|c| $c not-in ["premium" "theme"] })
check (($extras | length) > 2) "keep-live: the live flags hold flags the spec no longer names (no record: all kept)"
full-spec true "light"
touch $"($app)/fail-live"
let kf = (livex [push $app --flip premium])
rm $"($app)/fail-live"
let flipped = ((newest 1).data | from json | get flags | columns)
let restored = ((newest 0).data | from json | get flags | columns)
check ($kf.exit_code != 0 and ($extras | all {|c| $c in $flipped }) and ($extras | all {|c| $c in $restored }) and (premium (newest 0)).variants.default == false and (newest 0).metadata.stage == "rolled-back") "keep-live: a failed flip's restore keeps the kept flags intact"
full-spec false "light"
let nrec = (livex [push $app])
check ($nrec.exit_code == 0 and ($nrec.stderr | str contains "no release record") and ((newest 0).data | from json | get flags | columns | where {|c| $c not-in ["premium" "theme"] } | length) == ($extras | length)) "keep-live, bucket: no record, every live flag kept, with a warning"
let rurl = "gs://shop-prod-flags/released.json"
let rdry = (livex [released $app] {FAKE_GCLOUD_READONLY: "1", PRONTO_FLAGS_DRY_RUN: "1"})
check ($rdry.exit_code != 0 and ($rdry.stderr | str contains "dry run: refused a write") and (held | get objects | get -o $rurl | default [] | is-empty)) "released: refused under a dry run, nothing written"
let rng = (livex [released $app])
check ($rng.exit_code != 0 and ($rng.stderr | str contains "not in a git tree") and (held | get objects | get -o $rurl | default [] | is-empty)) "released: refused outside a git tree, nothing written"
^git -C $app init -q
^git -C $app add -A
^git -C $app -c user.name=t -c user.email=t@example.com commit -q -m base
let rw = (livex [released $app])
let rrec = (held | get objects | get $rurl | first | get data | from json)
check ($rw.exit_code == 0 and ($rrec.flags | sort) == ["premium" "theme"] and ($rrec.at | str ends-with "Z") and $rrec.commit == (^git -C $app rev-parse --short HEAD | str trim) and ($rrec.commit | is-not-empty)) "released, bucket: the record names the tree's flags, with the commit's value and the time"
let nd = (object | length)
let drop3 = (livex [push $app])
check ($drop3.exit_code == 0 and (object | length) == $nd + 1 and ((newest 0).data | from json | get flags | columns | sort) == ["premium" "theme"] and ($drop3.stderr | str contains "the release no longer reads it")) "keep-live, bucket: flags the record does not name are dropped"
check ((open --raw $"($dir)/journal.jsonl" | lines | last | from json | get dropped | split row "+" | sort) == ($extras | sort)) "keep-live: the journal line names what was dropped"

# PRONTO-1191 (j): accounts added to a flag are a flip, but no default moved: the board is told nothing.
mkdir $"($app)/devflow"
"package devflow\n" | save -f $"($app)/devflow/devflow.cue"
let board2 = $"($dir)/board2.log"
let told2 = $"($dir)/devflow2.sh"
$"#!/bin/sh\necho \"$*\" >> ($board2)\n" | save -f $told2
chmod +x $told2
full-spec false "light"
"flags: lone: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
livex [push $app] | ignore
full-spec false "light"
"flags: lone: {default: false, local: true, accounts: [\"u9\"]}\n" | save -a $"($app)/flags_spec.cue"
let acc_only = (livex [push $app --flip lone --untested "accounts only"] {PRONTO_DEVFLOW_BIN: $told2})
check ($acc_only.exit_code == 0 and (((newest 0).data | from json).flags.lone.targeting.if.2.in.1 == ["u9"]) and not ($board2 | path exists)) "an accounts-only flip is written, and tells the board nothing"
# A flag dropped in a push that flips another is no `rolledback` to the board.
full-spec false "light"
"flags: yon: {default: true, local: true}\n" | save -a $"($app)/flags_spec.cue"
livex [push $app --flip yon --untested "yon on"] | ignore
full-spec false "light"
"flags: lone: {default: false, local: true, accounts: [\"u8\"]}\n" | save -a $"($app)/flags_spec.cue"
let dropped_on = (livex [push $app --flip lone --drop yon --untested "accounts, and yon dropped"] {PRONTO_DEVFLOW_BIN: $told2})
check ($dropped_on.exit_code == 0 and "yon" not-in ((newest 0).data | from json).flags and not (($board2 | path exists) and (open --raw $board2 | str contains "rolledback"))) "a dropped flag that was on tells the board no rolledback"
rm -rf $"($app)/devflow"

# On a directory store: a drill app under git, its flags a, b, c, d over a push that names flips.
let dbsql = $"($dir)/db.sql"
def kspec [defs: record] {
	let body = ($defs | items {|k, v|
		let d = if ($v | describe | str starts-with "record") { $v } else { {default: $v} }
		let acc = if ($d.accounts? | default [] | is-empty) { "" } else { $", accounts: ($d.accounts | to json -r)" }
		$"flags: ($k): {default: ($d.default), local: true($acc)}\n" } | str join)
	$"package drill\nflags: drill_break_checkout: {default: false, local: true}\n($body)flagsLive: {dir: \"flagstore\", url: \"https://drill.example\", database: \"cat >> ($dbsql)\", mirrors: [{ssh: \"ops@node.example\", namespace: \"drill\", configMap: \"drill-flags\"}]}\n" | save -f $"($drill)/flags_spec.cue"
}
def klive [args: list<string>, extra: record = {}] { dlive $args ({PATH: ([$bin] | append $env.PATH)} | merge $extra) }
def kflags [] { open $"($store)/flags.json" | get flags }
def kdef [f: string] { (kflags | get $f).variants.default }
def kputs [] { if ($dbsql | path exists) { open --raw $dbsql | lines | where {|l| $l | str starts-with "SELECT pronto_flags.put(" } } else { [] } }
def kdoc [line: string] { $line | str replace "SELECT pronto_flags.put('" "" | str replace "'::jsonb, 'drill.example');" "" | str replace -a "''" "'" | from json }
kspec {}
klive [push $drill --untested "base" --flip drill_break_checkout] | ignore
kspec {ka: false, kb: false, kc: false}
let k0 = (klive [push $drill])
check ($k0.exit_code == 0 and (kflags | columns | where {|c| $c in ["ka" "kb" "kc"] } | length) == 3) "keep-live: new flags that are off are written"

# 8: a new flag that is on is written off unless --flip names it (PRONTO-1191), and then it needs its cases.
kspec {ka: false, kb: false, kc: false, kn: true}
let nv8 = (dversions)
let k8 = (klive [push $drill])
check ($k8.exit_code == 0 and (dversions) == $nv8 + 1 and (kdef kn) == false and ($k8.stderr | str contains "kn is new and on for everyone: written off") and not ($k8.stderr | str contains "no cases") and (djournal | last).kept == "kn") "keep-live: a new flag that is on is written off, with a warning, no cases asked"
let nv8b = (dversions)
let k8b = (klive [push $drill --flip kn])
check ($k8b.exit_code != 0 and ($k8b.stderr | str contains "no cases") and (dversions) == $nv8b) "keep-live: a new flag that is on, named in --flip, still needs its cases"
kspec {ka: false, kb: false, kc: false}
klive [push $drill --drop kn] | ignore

# 4: defaults that differ, with no --flip: the live entries stay, no cases are asked for, one version is written.
kspec {ka: true, kb: true, kc: false}
let nv4 = (dversions)
let k4 = (klive [push $drill])
check ($k4.exit_code == 0 and (dversions) == $nv4 + 1 and (kdef ka) == false and (kdef kb) == false and ($k4.stderr | str contains "ka kept as live")) "keep-live: a changed default with no --flip is not written"
check ((djournal | last).kept == "ka+kb" and (djournal | last).flag == "" and (djournal | last).changes == []) "keep-live: the journal names what was kept, and no flip"

# 5: --flip names the one that flips.
let k5 = (klive [push $drill --flip ka --untested "flip a"])
check ($k5.exit_code == 0 and (kdef ka) == true and (kdef kb) == false and (djournal | last).flag == "ka" and (djournal | last).kept == "kb") "keep-live: --flip a flips a, b is kept"

# 6: a --flip name the spec lacks is refused, nothing written.
let nv6 = (dversions)
let k6 = (klive [push $drill --flip nope])
check ($k6.exit_code != 0 and ($k6.stderr | str contains "not in the spec") and (dversions) == $nv6) "keep-live: --flip of an unknown flag is refused, nothing written"
let k6b = (klive [push $drill --drop ka])
check ($k6b.exit_code != 0 and ($k6b.stderr | str contains "is in the spec") and (dversions) == $nv6) "keep-live: --drop of a flag the spec holds is refused"

let k6c = (klive [push $drill --drop nowhere])
check ($k6c.exit_code != 0 and ($k6c.stderr | str contains "neither live nor in the spec") and (dversions) == $nv6) "keep-live: --drop of a flag that is neither live nor in the spec is refused"

# show and a dry run print the merge, and write nothing: ka is false live and true in the spec.
def default-shown [out: string, f: string] { $out | parse -r ($f + '\s*│\s*(?<d>\w+)') | get d.0 }
let sh0 = (klive [show $drill])
let sh1 = (klive [show $drill --flip kb])
check ($sh0.exit_code == 0 and (default-shown $sh0.stdout kb) == "false" and ($sh0.stderr | str contains "WARNING: kb kept as live")) "keep-live: show prints the merged result, kb kept as live"
check ($sh1.exit_code == 0 and (default-shown $sh1.stdout kb) == "true" and not ($sh1.stderr | str contains "kb kept")) "keep-live: show --flip kb prints kb flipped"
let nvd = (dversions)
let dr = (klive [push $drill --flip kb --dry-run])
check ($dr.exit_code == 0 and ($dr.stdout | str contains "dry run: nothing written") and (default-shown $dr.stdout kb) == "true" and (dversions) == $nvd) "keep-live: a dry-run push --flip shows the merge and writes nothing"

# PRONTO-1191: who a flag is on for is the push's to change only through --flip, not its default alone.
# (a) accounts added to a live flag, no --flip: the live entry is kept, with a warning, and no cases are asked.
kspec {ka: {default: true, accounts: ["u1"]}, kb: false, kc: false}
let nva = (dversions)
let ka1 = (klive [push $drill])
check ($ka1.exit_code == 0 and (dversions) == $nva + 1 and ((kflags | get ka).targeting.if | length) == 3 and ($ka1.stderr | str contains "ka kept as live") and not ($ka1.stderr | str contains "no cases") and (djournal | last).kept == "ka" and (djournal | last).flag == "") "keep-live: accounts added to a live flag, no --flip: the live entry is kept, no cases"
# (b) the same with --flip: refused with no cases, written with --untested.
let nvb = (dversions)
let ka2 = (klive [push $drill --flip ka])
check ($ka2.exit_code != 0 and ($ka2.stderr | str contains "no cases") and (dversions) == $nvb) "keep-live: --flip of an accounts-only change needs cases, refused, nothing written"
let ka3 = (klive [push $drill --flip ka --untested "accounts"])
check ($ka3.exit_code == 0 and ((kflags | get ka).targeting.if.2.in.1 == ["u1"]) and (djournal | last).flag == "ka" and (djournal | last).cases == "untested") "keep-live: --flip with --untested writes the accounts"
# (g) the same accounts in another order change nothing: not held.
kspec {ka: {default: true, accounts: ["u1" "u2"]}, kb: false, kc: false}
klive [push $drill --flip ka --untested "two accounts"] | ignore
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
let kg = (klive [push $drill])
check ($kg.exit_code == 0 and not ($kg.stderr | str contains "ka kept") and (djournal | last).kept == "") "keep-live: accounts reordered change nothing"
# (e) accounts removed: kept without --flip; with it, a flag turned off runs no cases.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: {default: false, accounts: ["u3"]}, kc: false}
klive [push $drill --flip kb --untested "kb to u3"] | ignore
check ((kflags | get kb).targeting.if.2.in.1 == ["u3"]) "keep-live: accounts on a flag whose default stays off are a flip too"
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
let ke1 = (klive [push $drill])
check ($ke1.exit_code == 0 and ((kflags | get kb).targeting.if.2.in.1 == ["u3"]) and ($ke1.stderr | str contains "kb kept as live")) "keep-live: accounts removed, no --flip: kept"
let ke2 = (klive [push $drill --flip kb])
check ($ke2.exit_code == 0 and ((kflags | get kb).targeting.if.2 == "default") and ($ke2.stderr | str contains "kb turned off") and not ($ke2.stderr | str contains "no cases:")) "keep-live: accounts removed with --flip: written, turned off, no cases run"
# (c) a new flag on for accounts, no --flip: written off, in the store and the database; (i) show prints that.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false, kw: {default: true, accounts: ["u5"]}}
let shw = (klive [show $drill])
check ($shw.exit_code == 0 and (default-shown $shw.stdout kw) == "false" and ($shw.stderr | str contains "kw is new and on for accounts")) "keep-live: show prints the new flag off"
let kc1 = (klive [push $drill])
check ($kc1.exit_code == 0 and (kdef kw) == false and ((kflags | get kw).targeting.if | length) == 3 and ((kdoc (kputs | last)).flags.kw.variants.default == false) and ((kdoc (kputs | last)).flags.kw.targeting.if | length) == 3) "keep-live: a new flag on for accounts is written off, in the store and the database"
let kc2 = (klive [push $drill])
check ($kc2.exit_code == 0 and (kdef kw) == false and ($kc2.stderr | str contains "kw kept as live")) "keep-live: a second plain push keeps the written-off flag held, with the warning again"
# (h) a new flag that is not a bool has no off form: refused, nothing written.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
"flags: ks: {default: \"dark\"}\n" | save -a $"($drill)/flags_spec.cue"
let nvh = (dversions)
let kh = (klive [push $drill])
check ($kh.exit_code != 0 and ($kh.stderr | str contains "ks is new and not off: name it in --flip") and (dversions) == $nvh) "keep-live: a new flag that is not a bool is refused with no --flip, nothing written"
# (f) only the at-hand `local` value changed: nothing in production moves, so the spec is written.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
open --raw $"($drill)/flags_spec.cue" | str replace 'flags: kc: {default: false, local: true}' 'flags: kc: {default: false, local: false}' | save -f $"($drill)/flags_spec.cue"
let kf = (klive [push $drill])
check ($kf.exit_code == 0 and (kflags | get kc).variants.local == false and not ($kf.stderr | str contains "kc kept")) "keep-live: only the at-hand local value changed: written as the spec"
# Back to the plain spec for the cases below: kw is dropped, ka loses its accounts through --flip.
kspec {ka: true, kb: false, kc: false}
klive [push $drill --drop kw --flip ka --untested "plain again"] | ignore
check ("kw" not-in (kflags | columns) and (kflags | get ka).targeting.if.2 == "default") "keep-live: back to the plain flags"

# 1: no record, the spec drops a live flag: it is kept, with a warning, in one version.
kspec {ka: true, kb: false}
let nv1 = (dversions)
let k1 = (klive [push $drill])
check ($k1.exit_code == 0 and (dversions) == $nv1 + 1 and "kc" in (kflags | columns) and ($k1.stderr | str contains "no release record") and ($k1.stderr | str contains "kc kept as live")) "keep-live, dir: no record, the dropped flag is kept, with a warning"

# 9: released writes the record from a clean tree, and refuses a dirty tree and a dry run.
kspec {ka: true, kb: false, kc: false}
mkdir $"($drill)/flags"
'{"flags": {"drill_break_checkout": {}, "ka": {}, "kb": {}, "kc": {}}}' | save -f $"($drill)/flags/flags.json"
^git -C $drill init -q
^git -C $drill add -A
^git -C $drill -c user.name=t -c user.email=t@example.com commit -q -m base
let rfile = $"($store)/released.json"
let rd = (klive [released $drill] {PRONTO_FLAGS_DRY_RUN: "1"})
check ($rd.exit_code != 0 and ($rd.stderr | str contains "dry run: refused a write") and not ($rfile | path exists)) "released, dir: refused under a dry run"
"// an edit\n" | save -a $"($drill)/flags_spec.cue"
let rdirty = (klive [released $drill])
check ($rdirty.exit_code != 0 and ($rdirty.stderr | str contains "edits") and not ($rfile | path exists)) "released, dir: refused on a tree with CUE edits"
^git -C $drill checkout -q -- flags_spec.cue
'{"flags": {"ka": {}}}' | save -f $"($drill)/flags/flags.json"
let rdirty2 = (klive [released $drill])
check ($rdirty2.exit_code != 0 and ($rdirty2.stderr | str contains "edits") and not ($rfile | path exists)) "released, dir: refused on a tree with an edited flags/flags.json"
^git -C $drill checkout -q -- flags/flags.json
"stray\n" | save -f $"($drill)/stray.cue"
let rstray = (klive [released $drill])
check ($rstray.exit_code == 0 and ($rfile | path exists)) "released, dir: an untracked leftover does not block it"
rm $"($drill)/stray.cue" $rfile
let rok = (klive [released $drill])
let rec = (open $rfile)
check ($rok.exit_code == 0 and ($rec.flags | sort) == ["drill_break_checkout" "ka" "kb" "kc"] and ($rec.commit | is-not-empty) and ($rec.commit | str contains "+" | not $in) and ($rec.at | str ends-with "Z")) "released, dir: the record names the flags, with the commit and time"

# 2: the record names the flag the spec drops: it is kept, said as waiting for a release. 11: the database got the merge.
kspec {ka: true, kb: false}
let k2 = (klive [push $drill])
check ($k2.exit_code == 0 and "kc" in (kflags | columns) and ($k2.stderr | str contains "waits for a release") and (djournal | last).kept == "kc") "keep-live, dir: a flag the release reads is kept as retired"
check ((kdoc (kputs | last)) == (open $"($store)/flags.json") and "kc" in ((kdoc (kputs | last)).flags | columns)) "keep-live: the database holds the merged document"
check ((open --raw $sent | from json | get data."flags.json" | from json) == (open $"($store)/flags.json") and "kc" in (open --raw $sent | from json | get data."flags.json" | from json | get flags | columns)) "keep-live: the mirror receives the merged document"
check ((open $"($store)/flags.json") == (open $"($store)/versions/((glob $"($store)/versions/*.meta.json" | each {|f| open --raw $f | from json } | where timeDeleted == null | get generation.0)).json")) "keep-live: the live object is the merged document"

# 7: --drop removes it whatever the record says.
let k7 = (klive [push $drill --drop kc])
check ($k7.exit_code == 0 and "kc" not-in (kflags | columns) and ($k7.stderr | str contains "forced by --drop") and (djournal | last).dropped == "kc") "keep-live: --drop removes a flag the record names, noted as forced"

# 3: a flag the record does not name is dropped.
kspec {ka: true, kb: false, kd: false}
klive [push $drill] | ignore
check ("kd" in (kflags | columns)) "keep-live: a flag added after the record is live"
kspec {ka: true, kb: false}
let k3 = (klive [push $drill])
check ($k3.exit_code == 0 and "kd" not-in (kflags | columns) and (djournal | last).dropped == "kd" and ($k3.stderr | str contains "no longer reads it")) "keep-live, dir: a flag the record lacks is dropped, the journal says so"

# setup's first push is merged like any: a new flag that is on, or has accounts, lands off; a non-bool one is refused.
$"package drill\nflags: son: {default: true, local: true}\nflags: sacc: {default: false, local: true, accounts: [\"u1\"]}\nflagsLive: {dir: \"setupstore\"}\n" | save -f $"($drill)/flags_spec.cue"
let sset = (klive [setup $drill])
let sdoc = (open $"($drill)/setupstore/flags.json").flags
check ($sset.exit_code == 0 and $sdoc.son.variants.default == false and ($sdoc.son.targeting.if | length) == 3 and $sdoc.sacc.variants.default == false and ($sdoc.sacc.targeting.if | length) == 3) "setup: a new flag on, or with accounts, is written off"
$"package drill\nflags: ss: {default: \"dark\"}\nflagsLive: {dir: \"setupstore2\"}\n" | save -f $"($drill)/flags_spec.cue"
let sbad = (klive [setup $drill])
check ($sbad.exit_code != 0 and ($sbad.stderr | str contains "is new and not off") and not ($"($drill)/setupstore2/flags.json" | path exists)) "setup: a new flag that is not a bool is refused, nothing written"

# PRONTO-718: a repo pins the pronto-flags commit its pushes run from (.github/flags.pin); a push from a
# checkout below the pin is refused before anything is read or written. The scratch clone is this checkout
# plus one commit, the pin; the checkout the push runs from is that clone one commit back, then at the pin.
let repo = $"($dir)/repo"
mkdir $repo
^git -C $repo init -q
cp -r $app $"($repo)/app"
rm -rf $"($repo)/app/.git" $"($repo)/app/tests"
^$real trust -q $"($repo)/app/.mise.toml"
$"package shop
flags: premium: {default: false, local: true, accounts: [\"acct-pin\"]}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($repo)/app/flags_spec.cue"
# The checkouts run the working tree's flags/ and bin/, committed in an origin of its own (base, pin, past), so these
# cases test the current code and never depend on this checkout's history or depth (CI's is shallow).
let origin = $"($dir)/origin"
^git init -q $origin
cp -r $"($here)/.." $"($origin)/flags"
cp -r $"($here)/../../bin" $"($origin)/bin"
def --wrapped ogt [...args] { ^git -C $origin -c user.name=t -c user.email=t@example.com ...$args }
ogt add -A
ogt commit -q -m code
let code = (ogt rev-parse HEAD | str trim)
ogt commit -q --allow-empty -m pin
let pin = (ogt rev-parse HEAD | str trim)
ogt commit -q --allow-empty -m past
# A full checkout one commit below the pin; and a shallow one past it, whose history stops short of the pin, which origin has.
let clone = $"($dir)/p"
^git clone -q --no-local $origin $clone
def --wrapped gt [...args] { ^git -C $clone ...$args }
gt checkout -q $code
let shallow = $"($dir)/s"
^git clone -q --depth 1 $"file://($origin)" $shallow
def fromat [root: string, args: list<string>] {
	with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FLAGS_OFREP_CMD: $"python3 ($here)/fake_ofrep.py", FLAGS_POLL_SEC: "0.01", FLAGS_WAIT_SEC: "0.1", PRONTO_FLAGS_JOURNAL: $"($dir)/journal.jsonl"} {
		^$nu.current-exe $"($root)/flags/live.nu" ...$args | complete
	}
}
def pushfrom [] { fromat $clone [push $"($repo)/app" --flip premium --untested "pin"] }
let before_pin = (held)
mkdir $"($repo)/.github"
$pin | save -f $"($repo)/.github/flags.pin"
let below = (pushfrom)
check ($below.exit_code != 0 and ($below.stderr | flat | str contains $"does not contain the pinned commit ($pin | str substring 0..<9)") and ($below.stderr | flat | str contains "PRONTO-680") and (held) == $before_pin) "pin: a push from below the pin is refused, naming it, and the store is unchanged"
for verb in [rollback released setup] {
	let r = (fromat $clone [$verb $"($repo)/app"])
	check ($r.exit_code != 0 and ($r.stderr | flat | str contains "does not contain the pinned commit") and (held) == $before_pin) $"pin: ($verb) from below the pin is refused, the store unchanged"
}
^git -C $clone checkout -q $pin
let at_pin = (pushfrom)
check ($at_pin.exit_code == 0 and (premium (object | first)).targeting.if.2.in.1 == ["acct-pin"] and (object | first).metadata.plugin == (^git -C $clone rev-parse --short HEAD | str trim)) "pin: with the pin at HEAD the push goes through, the version names the plugin commit"
let after_pin = (held)
(1..40 | each { "f" } | str join) | save -f $"($repo)/.github/flags.pin"
let unknown = (pushfrom)
check ($unknown.exit_code != 0 and ($unknown.stderr | flat | str contains "is unknown here") and (held) == $after_pin) "pin: a commit this checkout does not have is refused"
"nonsense\n" | save -f $"($repo)/.github/flags.pin"
let bad = (pushfrom)
check ($bad.exit_code != 0 and ($bad.stderr | str contains "40 hex") and (held) == $after_pin) "pin: a file that is not a commit is refused"
# A shallow checkout past the pin fetches its missing history from origin, then writes.
$pin | save -f $"($repo)/.github/flags.pin"
let shallow_push = (fromat $shallow [push $"($repo)/app" --flip premium --untested "pin"])
check ($shallow_push.exit_code == 0 and (^git -C $shallow rev-parse --is-shallow-repository | str trim) == "false") "pin: a shallow checkout past the pin fetches the history and the push goes through"
rm $"($repo)/.github/flags.pin"
$"package shop
flags: premium: {default: false, local: true, accounts: [\"acct-nopin\"]}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($repo)/app/flags_spec.cue"
let nopin = (pushfrom)
check ($nopin.exit_code == 0 and (premium (object | first)).targeting.if.2.in.1 == ["acct-nopin"]) "pin: with no pin file the push runs as before"

rm -rf $dir
print "flags: live commands pass"
