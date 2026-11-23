# pronto-flags' live commands (flags/live.nu) against a stand-in for gcloud
# (fake_gcloud.py), and a store kept in a local directory (flagsLive.dir), on an app the installer writes: setup makes the bucket
# private, versioned and read by the release's accounts, and pushes once; a push
# writes over only the version it read; history lists every version, by whom;
# a rollback writes an earlier one again as the newest. The app's cue is real.
#   ./saytw --script tools.nu nu flags/test/live_test.nu

# Commits the tests make directly (commit-tree on a bare origin) need an identity on a runner with none.
$env.GIT_AUTHOR_NAME = "t"
$env.GIT_AUTHOR_EMAIL = "t@example.com"
$env.GIT_COMMITTER_NAME = "t"
$env.GIT_COMMITTER_EMAIL = "t@example.com"

# Every flag these fixtures flip has no production scenario (PRONTO-439 asks one, or the owner's `liveWaived`): a pattern
# constraint in a file of the app's own waives them all, so the cases below keep testing what they test. The production-check
# cases themselves (the last section) run on an app with no such file.
def waive-all [app: string, pkg: string] {
	$"package ($pkg)\nflags: [string]: liveWaived: \"fixture: the cases below flip flags with no production scenario\"\n" | save -f $"($app)/flags_waive.cue"
}
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
waive-all $app shop
def spec [accounts: list<string>] {
	$"package shop
flags: premium: {default: false, local: true, accounts: ($accounts | to json -r)}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($app)/flags_spec.cue"
}

def livex [args: list<string>, extra: record = {}] {
	with-env ({SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FLAGS_OFREP_CMD: $"python3 ($here)/fake_ofrep.py", FLAGS_POLL_SEC: "0.01", FLAGS_WAIT_SEC: "0.1", PRONTO_FLAGS_JOURNAL: $"($dir)/journal.jsonl", PRONTO_FLAGS_RECORD: "off"} | merge $extra) {
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
check ($held_back.exit_code == 0 and (object | length) == 2 and (premium (object | first)).targeting.if.2.in.1 == [] and ($held_back.stderr | str contains "premium kept as live")) "push: accounts added to a live flag, no --sync: held, nothing written"
live push $app --sync premium --untested "acct" | ignore
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
let plain = (live show $app --sync theme)
check (($plain | str contains "premium") and ($plain | str contains "theme")) "show: a flag local alone, and one with no targeting"
let before = (object | length)
let refused = (livex [push $app --sync theme])
check ($refused.exit_code != 0 and ($refused.stderr | str contains "no cases") and (object | length) == $before) "push: a new flag with no cases is refused, and nothing is written"
let pushed = (live push $app --sync theme --untested "a theme is no feature")
check ((object | length) == $before + 1 and ($pushed | str contains "theme")) "push --untested: written, then summarized"
check ((object | first).metadata.cases == "untested" and ((object | first).metadata.note | str contains "a theme is no feature")) "push --untested: the reason is kept on the version"

# A flip writes the flags for everyone, then runs the flag's production cases that sign in as no one; nothing at hand.
def full-spec [premium: bool, theme: string] {
	$"package shop
flags: premium: {default: ($premium), local: true}
flags: theme: {default: \"($theme)\"}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", url: \"https://shop.example\"}
flagsCases: {
	live:  \"echo live $FLAG $ONLY $APP_URL ${FLAGS_TESTER:-} >> ran.log; test ! -f crash-live || kill -9 $$; test ! -f fail-live || exit 1; if test -f skipped-live; then echo '✓ buy 1s: shop; steps behind '$FLAG' skipped, off here'; elif test -f other-live; then echo '✓ buy 1s: shop; steps behind other skipped, off here'; elif test -f comma-live; then echo '✓ buy 1s: shop; steps behind a, '$FLAG' skipped, off here'; elif test -f multi-live; then echo '✓ buy 1s: shop'; echo '✓ mine 1s: shop; steps behind '$FLAG' skipped, off here'; elif test -f silent-live; then :; elif test -f zero-live; then echo '✓ buy 1s: shop; 0 steps run, 3 skipped'; else echo '✓ buy 1s: shop'; fi\"
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
let launched = (live push $app --sync premium)
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
let off = (livex [push $app --sync premium])
check ($off.exit_code == 0 and ($off.stderr | str contains "turned off: no cases run")) "off-flip: pushed, saying its cases did not run"
check ((object | length) == $n4 + 1 and (ran | length) == $ran4) "off-flip: one version written, no case run"
check ((newest 0).metadata.stage == "all" and (newest 0).metadata.flag == "premium" and ((newest 0).metadata.note | str contains "turned off: premium")) "off-flip: stage=all, and the note records it"
check ((premium (newest 0)).variants.default == false and not ((newest 0).data | str contains "tester-1")) "off-flip: the version holds the new value, no tester named"

# --no-canary "<why>" (pronto-plugins#184) is every push's way now: accepted, its reason kept, the cases run.
let n5 = (object | length)
let ran5 = (ran | length)
full-spec true "light"
let nc = (livex [push $app --no-canary "the owner's go" --sync premium])
check ($nc.exit_code == 0 and ($nc.stderr | str contains "every push's way")) "--no-canary: pushed, saying it is the only way now"
check ((object | length) == $n5 + 2 and (ran | length) == $ran5 + 1) "--no-canary: written for everyone, its production cases run"
check (((newest 0).metadata.note | str contains "no canary: the owner's go")) "--no-canary: the reason kept"
full-spec false "light"
livex [push $app --sync premium] | ignore

# PRONTO_FLAGS_WHO names who asked (Studio's builder: studio:<user id>), kept on the versions and in the journal in place of
# the login; PRONTO_FLAGS_CASES_WRAP prefixes the app's case command, which a wrap that refuses therefore stops.
full-spec true "light"
let ranw = (ran | length)
let wrap_ok = "sh -c 'echo wrapped >> wrap.log; exec \"$0\" \"$@\"'"
let wh = (livex [push $app --sync premium] {PRONTO_FLAGS_WHO: "studio:u-7", PRONTO_FLAGS_CASES_WRAP: $wrap_ok})
check ($wh.exit_code == 0 and (newest 1).metadata.pushed-by == "studio:u-7" and (newest 0).metadata.pushed-by == "studio:u-7" and (newest 0).metadata.cases == "passed") "WHO: the versions of a flip keep the name given, not the login"
check ((open --raw $"($dir)/journal.jsonl" | lines | last | from json | get who) == "studio:u-7") "WHO: the journal names it"
check ((ran | length) == $ranw + 1 and (open --raw $"($app)/wrap.log" | str trim) == "wrapped") "WRAP: the flag's case command ran through the wrap, with its env"
full-spec false "light"
livex [push $app --sync premium] | ignore
full-spec true "light"
let ranx = (ran | length)
let nx = (object | length)
let wf = (livex [push $app --sync premium] {PRONTO_FLAGS_CASES_WRAP: "sh -c 'exit 3'"})
check ($wf.exit_code != 0 and ($wf.stderr | str contains "rolled back") and (ran | length) == $ranx and (newest 0).metadata.stage == "rolled-back") "WRAP: a wrap that refuses stops the cases: the flip is rolled back"
check ((newest 0).metadata.pushed-by == "operator@example.com") "WHO: unset, the login is who pushed"
full-spec false "light"
livex [push $app --sync premium] | ignore

# --stages "5,25,100" (PRONTO-412): a version per stage through flagd's fractional on targetingKey, the flag's production cases
# at each below 100 and the dwell, then the flip. A failure writes the version read before the first stage again.
full-spec true "light"
let ns = (object | length)
let rans = (ran | length)
let stg = (livex [push $app --flip premium --stages "5,25,100" --dwell 0sec] {FLAGS_STAGE_SETTLE_SEC: "0"})
check ($stg.exit_code == 0) $"stages: pushed: ($stg.stderr | str trim | lines | last 3 | str join ' / '); ($stg.stdout | str trim | lines | last 3 | str join ' / ')"
check ((object | length) == $ns + 4) "stages: a version for 5%, one for 25%, then the flip's two"
check ([(newest 3).metadata.stage (newest 2).metadata.stage (newest 1).metadata.stage (newest 0).metadata.stage] == ["5%" "25%" "all" "all"] and (newest 0).metadata.cases == "passed") "stages: each version says its stage; the last passed"
let at5 = (premium (newest 3))
check ($at5.targeting.if.2.fractional == [["on" 5] ["off" 95]] and $at5.variants.default == false and $at5.variants.on == true and $at5.variants.off == false and $at5.defaultVariant == "default") "stages: 5% is flagd's fractional on targetingKey after the at-hand branch; the default and a reader with no key read the value before"
check ((premium (newest 2)).targeting.if.2.fractional == [["on" 25] ["off" 75]]) "stages: 25%"
check ((premium (newest 0)).variants.default == true and (premium (newest 0)).defaultVariant == "default" and not ((newest 0).data | str contains "fractional")) "stages: the last version is the flip, for everyone"
check ((ran | length) == $rans + 3) "stages: the production cases ran at 5%, at 25% and after the flip"
let sh = (with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state} {
	^$nu.current-exe -c $"use ($here)/../live.nu history; history ($app) | to json" | complete
}).stdout | from json
check (($sh | first 4 | get stage) == ["all" "all" "25%" "5%"]) "stages: history shows stage=5%|25%|all"
check ((open --raw $"($dir)/journal.jsonl" | lines | last 4 | each {|l| $l | from json | get stage }) == ["5%" "25%" "all" "all"]) "stages: the journal has a line per stage"
full-spec false "light"
livex [push $app --sync premium] | ignore

# A stage whose cases fail at the second stage writes the version read before the first again, not the 5% one.
full-spec true "light"
let nf = (object | length)
let before_stages = (newest 0)
rm -f $"($app)/wrapn.log"
let wrap2 = "sh -c 'echo x >> wrapn.log; test $(wc -l < wrapn.log) -lt 2 || exit 3; exec \"$0\" \"$@\"'"
let sf = (livex [push $app --flip premium --stages "5,25,100" --dwell 0sec] {FLAGS_STAGE_SETTLE_SEC: "0", PRONTO_FLAGS_CASES_WRAP: $wrap2})
check ($sf.exit_code != 0 and ($sf.stderr | str contains "rolled back") and ($sf.stderr | str contains "at 25%")) "stages: a failing case at the second stage fails the push, rolled back"
check ((object | length) == $nf + 3 and (newest 0).metadata.stage == "rolled-back" and (premium (newest 0)) == (premium $before_stages)) "stages: 5%, 25%, then the version before the first stage written again"

# Refusals write nothing: one flag only, percentages rising to 100, a client flag with no key unless said to have one.
let nr = (object | length)
let two = (livex [push $app --flip premium --sync theme --stages "5,100"])
check ($two.exit_code != 0 and ($two.stderr | str contains "one flag")) "stages: a second flag (--sync) is refused"
let low = (livex [push $app --flip premium --stages "25,5,100"])
check ($low.exit_code != 0 and ($low.stderr | str contains "rising and ending at 100")) "stages: percentages that do not rise are refused"
let open_end = (livex [push $app --flip premium --stages "5,25"])
check ($open_end.exit_code != 0 and ($open_end.stderr | str contains "ending at 100")) "stages: a last stage below 100 is refused"
let dry_bad = (livex [push $app --flip premium --stages "5,25" --dry-run])
check ($dry_bad.exit_code != 0 and ($dry_bad.stderr | str contains "ending at 100")) "stages: a dry run refuses what the real push refuses"
let dry_ok = (livex [push $app --flip premium --stages "5,25,100" --dry-run])
check ($dry_ok.exit_code == 0 and ($dry_ok.stdout | str contains "would go to 5%, 25%, 100%") and (object | length) == $nr) "stages: a dry run says the stages and writes nothing"
open --raw $"($app)/flags_spec.cue" | str replace 'local: true}' 'local: true, client: true}' | save -f $"($app)/flags_spec.cue"
let cl = (livex [push $app --flip premium --stages "5,100"] {FLAGS_STAGE_SETTLE_SEC: "0"})
check ($cl.exit_code != 0 and ($cl.stderr | str contains "client flag") and ($cl.stderr | str contains "no targetingKey")) "stages: a client flag with no stated key is refused"
check ((object | length) == $nr) "stages: a refusal writes nothing"
full-spec false "light"
livex [push $app --sync premium] | ignore

# A flag with no production scenario: written for everyone, nothing run. Production cases with no
# flagsLive.url to run them at: refused, nothing written.
full-spec true "light"
let n1 = (object | length)
let ran1 = (ran | length)
open --raw $"($app)/tests/scenarios/shop.cue" | str replace -a 'production: true, ' '' | save -f $"($app)/tests/scenarios/shop.cue"
let np = (livex [push $app --sync premium])
check ($np.exit_code == 0 and (object | length) == $n1 + 1 and (ran | length) == $ran1 and (newest 0).metadata.cases == "none on production") "no production scenario: written for everyone, no case run"
open --raw $"($app)/tests/scenarios/shop.cue" | str replace 'buy: {flags: ["premium"], ' 'buy: {flags: ["premium"], production: true, ' | str replace 'mine: {flags: ["premium"], ' 'mine: {flags: ["premium"], production: true, ' | save -f $"($app)/tests/scenarios/shop.cue"
full-spec false "light"
livex [push $app --sync premium] | ignore
full-spec true "light"
let n1 = (object | length)
let ran1 = (ran | length)
open --raw $"($app)/flags_spec.cue" | str replace ', url: "https://shop.example"' '' | save -f $"($app)/flags_spec.cue"
let nourl = (livex [push $app --sync premium])
check ($nourl.exit_code != 0 and (object | length) == $n1 and (ran | length) == $ran1 and ($nourl.stderr | str contains "flagsLive.url")) "production cases, no url: refused, nothing written"
full-spec true "light"
let gone = (livex [push $app --skip-live "no tester yet"])
check ($gone.exit_code != 0 and (object | length) == $n1) "--skip-live is gone: refused"

# Live failure: back to the version read before the flip.
touch $"($app)/fail-live"
let pre = (premium (newest 0))
let lv = (livex [push $app --sync premium])
check ($lv.exit_code != 0 and ($lv.stderr | str contains "rolled back")) "live failure: the push fails"
check ((object | length) == $n1 + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back" and (newest 1).metadata.stage == "all") "live failure: the flags before the flip are the newest version again"
rm $"($app)/fail-live"

# The cases' command dies under the push (killed): the same, back to the version before the flip.
touch $"($app)/crash-live"
let n1b = (object | length)
let cr = (livex [push $app --sync premium])
check ($cr.exit_code != 0 and (object | length) == $n1b + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back") "a crashed live command: rolled back"
rm $"($app)/crash-live"

# An OFREP that never answers the new value: back as well.
let n2 = (object | length)
let ran2 = (ran | length)
let st = (livex [push $app --sync premium] {FAKE_OFREP_STALE: "1"})
check ($st.exit_code != 0 and ($st.stderr | str contains "did not answer the new value of premium") and (premium (newest 0)) == $pre and (object | length) == $n2 + 2 and (newest 0).metadata.stage == "rolled-back" and (ran | length) == $ran2) "OFREP timeout (the door still says false): no case ran, rolled back"

# A green run that showed nothing is no pass: every step skipped (the flag off where the cases ran), no scenario
# verdict at all, or a runner that counts its steps and ran none. Each rolls back; one that ran steps passes.
for v in [{f: skipped-live, why: "skipped its steps behind premium"}, {f: silent-live, why: "no passed scenario"}, {f: zero-live, why: "ran no step"}, {f: comma-live, why: "skipped its steps behind premium"}, {f: multi-live, why: "mine skipped its steps behind premium"}] {
	touch $"($app)/($v.f)"
	let n = (object | length)
	let e = (livex [push $app --sync premium])
	check ($e.exit_code != 0 and ($e.stderr | str contains "rolled back") and ($e.stderr | str contains "showed nothing") and ($e.stderr | str contains $v.why) and (object | length) == $n + 2 and (premium (newest 0)) == $pre and (newest 0).metadata.stage == "rolled-back") $"a vacuous run \(($v.f)\): refused and rolled back"
	rm $"($app)/($v.f)"
}
# A verdict naming another flag skipped is no finding against this one.
touch $"($app)/other-live"
let nother = (object | length)
let oth = (livex [push $app --sync premium])
check ($oth.exit_code == 0 and (object | length) == $nother + 2 and (newest 0).metadata.cases == "passed") "a verdict skipping a different flag: passes"
rm $"($app)/other-live"
full-spec false "light"
livex [push $app --sync premium] | ignore
full-spec true "light"
let nok = (object | length)
let okr = (livex [push $app --sync premium])
check ($okr.exit_code == 0 and (object | length) == $nok + 2 and (newest 0).metadata.cases == "passed" and (premium (newest 0)).variants.default == true) "a run that executed steps: passes"
full-spec false "light"
livex [push $app --sync premium] | ignore
full-spec true "light"

# Accounts only on a default-false flag: the runner legitimately skips the flag's steps, so that is no finding.
full-spec false "light"
open --raw $"($app)/flags_spec.cue" | str replace 'flags: premium: {default: false, local: true}' 'flags: premium: {default: false, local: true, accounts: ["acct-1"]}' | save -f $"($app)/flags_spec.cue"
touch $"($app)/skipped-live"
let nacc = (object | length)
let acc = (livex [push $app --sync premium])
check ($acc.exit_code == 0 and (object | length) == $nacc + 2 and (newest 0).metadata.cases == "passed") "accounts only on a default-false flag: its skipped steps pass"
rm $"($app)/skipped-live"
full-spec false "light"
livex [push $app --sync premium] | ignore

# No change to a default value: no cases needed, and none run.
full-spec false "light"
let n3 = (object | length)
let ran3 = (ran | length)
live push $app --sync premium | ignore
check ((object | length) == $n3 + 1 and (ran | length) == $ran3 and (newest 0).metadata.stage == "all") "unchanged defaults: written with no cases run"

# No tester is named anywhere, nor any snooze made: a flip has no testers' stage.
check (object | all {|v| not ($v.data | str contains "tester-1") }) "no version names a tester"
check ((held | get -o snoozes | default []) | is-empty) "no alert is snoozed"

# A flag new to the live object and off: nothing flips, so no cases are asked for and none run.
full-spec false "light"
"flags: shy: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let n6 = (object | length)
let ran6 = (ran | length)
live push $app --sync premium | ignore
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
let fresh_fail = (livex [push $app --sync "premium,fresh"] {PRONTO_DEVFLOW_BIN: $told})
rm $"($app)/fail-live"
check ($fresh_fail.exit_code != 0 and ($fresh_fail.stderr | str contains "rolled back") and not ($fresh_fail.stderr | str contains "variants.default")) "a new flag on, its cases failing: the push fails as a rollback, not on the summary"
check ((object | length) == $n7 + 2 and (newest 1).metadata.stage == "all" and (newest 0).metadata.stage == "rolled-back" and not ((newest 0).data | from json | get flags | columns | any {|c| $c == "fresh" })) "a new flag on, failing: the version before the flip is the newest again"
check ((board-said) | is-empty) "a failed flip tells the board nothing"
let fresh_ok = (livex [push $app --sync "premium,fresh"] {PRONTO_DEVFLOW_BIN: $told})
check ($fresh_ok.exit_code == 0 and ($fresh_ok.stdout | str contains "fresh")) "a new flag on: its summary is said"
check ((newest 1).metadata.stage == "all" and (newest 0).metadata.stage == "all" and ((newest 0).data | from json | get flags.fresh.variants.default) == true) "a new flag on: written for everyone, held on"
check ((board-said | length) == 1 and (board-said | first | str starts-with "flipped ") and (board-said | first | str ends-with "/shop shop fresh")) "a passed flip tells the board, once, after the everyone stage"
rm -rf $"($app)/.git" $"($app)/devflow"

# The cases run under the app's own saytw pin, not the SAYT_VERSION this tool runs under.
full-spec true "light"
open --raw $"($app)/flags_spec.cue" | str replace 'echo live $FLAG' 'echo sayt=${SAYT_VERSION:-none} live $FLAG' | save -f $"($app)/flags_spec.cue"
let pinned = (livex [push $app --sync premium] {SAYT_VERSION: "v0.0.1"})
check ($pinned.exit_code == 0 and ((ran | last) | str starts-with "sayt=none")) "the cases don't inherit this tool's SAYT_VERSION"

# ---- A flip needs no spec PR: --flip X[=value] changes production, then the tool records it back ----
# The record is a stand-in here (PRONTO_FLAGS_RECORD_BIN: <flag> <value as JSON> <version>, one line per flag it
# would write into the spec); the real one, in a scratch worktree with git and gh, is tried below.
let recbin = $"($dir)/record.sh"
let reclog = $"($dir)/record.log"
$"#!/bin/sh\necho \"$*\" >> ($reclog)\ntest -z \"$RECORD_FAIL\" || { echo refused >&2; exit 1; }\n" | save -f $recbin
chmod +x $recbin
def recorded [] { if ($reclog | path exists) { open --raw $reclog | lines } else { [] } }
def rlive [args: list<string>, extra: record = {}] { livex $args ({PRONTO_FLAGS_RECORD: "", PRONTO_FLAGS_RECORD_BIN: $recbin} | merge $extra) }
def newgen [] { (newest 0).generation }
def pspec [premium: bool, theme: string] { full-spec $premium $theme }

# Start from live false everywhere: a sync writes the spec's reach, which is off.
pspec false "light"
livex [push $app --sync "premium,theme"] | ignore
check ((premium (newest 0)).variants.default == false) "flip: start with premium off live"

# (1) --flip X with the spec false: live true, the production cases run, record gets {X, true, version}, the spec is untouched.
let spec_text = (open --raw $"($app)/flags_spec.cue")
let ran_a = (ran | length)
let n_a = (object | length)
let f1 = (rlive [push $app --flip premium])
check ($f1.exit_code == 0 and (premium (newest 0)).variants.default == true and (newest 0).metadata.cases == "passed" and (object | length) == $n_a + 2) "--flip X, spec false: live true, written in two versions"
check ((ran | length) == $ran_a + 1 and ((ran | last) | str starts-with "live premium buy")) "--flip X: the production cases ran"
let v_f1 = (newgen)
check ((recorded) == [$"premium true (newgen)"] and (open --raw $"($app)/flags_spec.cue") == $spec_text) "--flip X: record called with {X, true, version}, the operator's spec untouched"
check ((open --raw $"($dir)/journal.jsonl" | lines | last | from json | get record) == "stand-in") "--flip X: the record is noted in the journal"

# (9) A plain push after an unrecorded flip keeps X live true.
let n9 = (object | length)
let plain = (rlive [push $app])
check ($plain.exit_code == 0 and (premium (newest 0)).variants.default == true and ($plain.stderr | str contains "premium kept as live") and (recorded | length) == 1) "a plain push after an unrecorded flip keeps X live true, and records nothing"

# (3) The spec already equals live: nothing to record.
pspec true "light"
let f3 = (rlive [push $app --flip premium])
check ($f3.exit_code == 0 and (recorded | length) == 1) "spec equals live: record not called"

# (6) A bare --flip is refused where the spec says false and live says true.
pspec false "light"
let n6 = (object | length)
let f6 = (rlive [push $app --flip premium])
check ($f6.exit_code != 0 and ($f6.stderr | str contains "premium=true or premium=false") and (object | length) == $n6 and (recorded | length) == 1) "bare --flip X: refused when the spec says false and live true"

# (2) --flip X=false turns it off: no cases, live false, board and record told.
pspec true "light"
let ran_b = (ran | length)
let f2 = (rlive [push $app --flip premium=false])
check ($f2.exit_code == 0 and (premium (newest 0)).variants.default == false and (ran | length) == $ran_b and ($f2.stderr | str contains "turned off: no cases run")) "--flip X=false: live false, no cases"
check ((recorded | last) == $"premium false (newgen)") "--flip X=false: record called with {X, false, version}"

# (14) --drop on a flag the spec still holds is refused, naming --flip X=false.
let n14 = (object | length)
let f14 = (rlive [push $app --drop premium])
check ($f14.exit_code != 0 and ($f14.stderr | str contains "--flip <flag>=false") and (object | length) == $n14) "--drop of a spec flag: refused, pointing to --flip X=false"

# (4) A production case that fails, or an OFREP that never answers: rolled back, no record.
pspec false "light"
let rec4 = (recorded | length)
touch $"($app)/fail-live"
let f4 = (rlive [push $app --flip premium])
rm $"($app)/fail-live"
check ($f4.exit_code != 0 and ($f4.stderr | str contains "rolled back") and (premium (newest 0)).variants.default == false and (recorded | length) == $rec4) "a failing production case: rolled back, record not called"
let f4b = (rlive [push $app --flip premium] {FAKE_OFREP_STALE: "1"})
check ($f4b.exit_code != 0 and ($f4b.stderr | str contains "OFREP did not answer") and (premium (newest 0)).variants.default == false and (recorded | length) == $rec4) "an OFREP that never answers: rolled back, record not called"

# (5) A value for a string flag; a value of the wrong kind, or a bare name on a non-bool, is refused with nothing written.
let n5 = (object | length)
let f5 = (rlive [push $app --flip theme=dark --untested "a theme"])
check ($f5.exit_code == 0 and ((newest 0).data | from json | get flags.theme.variants.default) == "dark" and (recorded | last) == $"theme \"dark\" (newgen)") "--flip theme=dark: a string flag takes its value, record called"
let n5b = (object | length)
let f5b = (rlive [push $app --flip premium=dark])
check ($f5b.exit_code != 0 and ($f5b.stderr | str contains "premium is a bool") and (object | length) == $n5b) "--flip premium=dark: refused on a bool, nothing written"
let f5c = (rlive [push $app --flip theme])
check ($f5c.exit_code != 0 and ($f5c.stderr | str contains "theme=<value>") and (object | length) == $n5b) "bare --flip on a non-bool: refused, nothing written"

# (10) Two flips, X then Y: each record covers what its own push wrote, and no more.
pspec false "light"
let f10 = (rlive [push $app --flip premium])
let rec10 = (recorded | length)
let f10b = (rlive [push $app --flip theme=dark --untested "a theme"])
check ($f10.exit_code == 0 and $f10b.exit_code == 0 and (recorded | length) == $rec10 + 1 and (recorded | last) == $"theme \"dark\" (newgen)") "two flips: the second record covers its own flag only, not the first's"

# (11) A rollback records what it restored.
pspec false "dark"
let was_light = (object | where {|v| ($v.data | from json | get flags.theme.variants.default) == "light" and (premium $v).variants.default == true } | first | get generation)
let rb11 = (rlive [rollback $app $was_light])
check ($rb11.exit_code == 0 and (recorded | any {|l| $l == $"theme \"light\" (newgen)" })) "rollback: record called with the restored values"

# (12) A dry run records nothing and touches no gh.
let rec12 = (recorded | length)
let fakegh = $"($dir)/ghbin"
mkdir $fakegh
$"#!/bin/sh\necho \"$@\" >> ($dir)/gh.log\n" | save -f $"($fakegh)/gh"
chmod +x $"($fakegh)/gh"
pspec true "light"
let f12 = (rlive [push $app --flip premium=false --dry-run] {PATH: ([$fakegh] | append $env.PATH)})
check ($f12.exit_code == 0 and ($f12.stdout | str contains "dry run: nothing written") and (recorded | length) == $rec12 and not ($"($dir)/gh.log" | path exists)) "--dry-run: record not called, gh not touched"

# (13) --sync keeps PRONTO-1191: it writes the spec's reach (accounts), and there is nothing to record.
pspec false "light"
open --raw $"($app)/flags_spec.cue" | str replace 'premium: {default: false, local: true}' 'premium: {default: false, local: true, accounts: ["acct-sync"]}' | save -f $"($app)/flags_spec.cue"
livex [push $app --sync "premium,theme" --untested "back"] | ignore
let rec13 = (recorded | length)
let acc = (rlive [push $app --sync premium --untested "accounts"])
check ($acc.exit_code == 0 and (premium (newest 0)).targeting.if.2.in.1 == ["acct-sync"] and (recorded | length) == $rec13) "--sync: the spec's reach is written, nothing to record"
pspec false "light"
livex [push $app --sync "premium,theme" --untested "back"] | ignore

# (2) A held spec edit (spec true, live false, not flipped) is left to drift: recording another flip never touches it.
pspec true "light"
let rec2 = (recorded | length)
let fh = (rlive [push $app --flip theme=dark --untested "a theme"])
check ($fh.exit_code == 0 and (recorded | length) == $rec2 + 1 and ((recorded | last) | str starts-with "theme ") and (premium (newest 0)).variants.default == false) "a held spec edit is not recorded with another flip"
pspec false "light"
livex [push $app --sync "premium,theme" --untested "back"] | ignore

# (7) --flip with a comma in its value is one entry; a value mixed with other names is refused; int and float are one kind.
let nc = (object | length)
let fc = (rlive [push $app --flip "theme=a,b" --untested "comma"])
check ($fc.exit_code == 0 and ((newest 0).data | from json | get flags.theme.variants.default) == "a,b" and (recorded | last) == $"theme \"a,b\" (newgen)") "--flip theme=a,b: the comma is in the value"
let nm = (object | length)
let fm = (rlive [push $app --flip "premium,theme=dark"])
check ($fm.exit_code != 0 and ($fm.stderr | str contains "takes one flag with a value; repeat the command") and (object | length) == $nm) "--flip a,b=v: refused, nothing written"
pspec false "light"
livex [push $app --sync "premium,theme" --untested "back"] | ignore
let num = (^$nu.current-exe -c $"use ($here)/../live.nu keep-live; let spec = {flags: {n: {state: 'ENABLED', variants: {default: 1.5}, defaultVariant: 'default'}, m: {state: 'ENABLED', variants: {default: 3}, defaultVariant: 'default'}}}; let r = \(keep-live {flags: {}} $spec null ['n=2' 'm=4.5'] []); $r.doc.flags | to json -r" | complete)
check ($num.exit_code == 0 and ($num.stdout | str contains "\"default\":2}") and ($num.stdout | str contains "\"default\":4.5}")) "--flip on an int or a float default: one numeric kind"

# PRONTO-1518: a flag's metadata (the flag set it is served in: `client`) is the spec's whatever the push keeps of live. flagd namespaces
# flags by flagSetId across its sources, so a baked entry with metadata over a live one without it would serve the baked value to a page.
let kl = $"($dir)/keep_live_metadata.nu"
(r#'
let set = {flagSetId: client}
def entry [v: any, meta: any = null] {
	let e = {state: ENABLED, variants: {default: $v, local: true}, defaultVariant: default}
	if $meta == null { $e } else { $e | insert metadata $meta }
}
# held: live differs in default, has no metadata; the spec says client. off: the spec's flag is new and on. flipped: named in --flip.
# dropmeta: live has the metadata and the spec no longer says client. gone: live only, with its own metadata.
let spec = {flags: {held: (entry true $set), off: (entry true $set), flipped: (entry false $set), dropmeta: (entry false), same: (entry false $set)}}
let live = {flags: {held: (entry false), dropmeta: (entry true $set), gone: (entry true $set), flipped: (entry false), same: (entry false)}}
let r = (keep-live $live $spec null ['flipped=true'] [])
let f = $r.doc.flags
{
	held: ($f.held.metadata? == $set and $f.held.variants.default == false)
	off: ($f.off.metadata? == $set and $f.off.variants.default == false)
	flipped: ($f.flipped.metadata? == $set and $f.flipped.variants.default == true)
	dropmeta: (($f.dropmeta | get -o metadata) == null and $f.dropmeta.variants.default == true)
	gone: ($f.gone.metadata? == $set)
	same: ($f.same.metadata? == $set)
} | to json -r
'#) | $"use ($here)/../live.nu keep-live\n($in)" | save -f $kl
let klr = (^$nu.current-exe $kl | complete)
check ($klr.exit_code == 0 and ($klr.stdout | from json | transpose k v | where v == false | is-empty)) $"keep-live: held, off-form, flipped and set-default entries carry the spec's metadata, a live-only flag its own \(($klr.stdout | str trim) ($klr.stderr | str trim)\)"

# PRONTO-1518: a restore or a rollback writes an older version's flags with the metadata the spec says now (values and targeting kept), so a
# restored document never lacks the mark the door's selector asks for.
let wm = $"($dir)/with_metadata.nu"
(r#'
let set = {flagSetId: client}
def entry [v: any, meta: any = null] {
	let e = {state: ENABLED, variants: {default: $v, local: true}, defaultVariant: default, targeting: {if: [1]}}
	if $meta == null { $e } else { $e | insert metadata $meta }
}
let old = {flags: {a: (entry true), b: (entry false $set), c: (entry true), gone: (entry true)}}
let spec = {flags: {a: (entry false $set), b: (entry false), c: (entry false $set)}}
let f = (with-current-metadata $old $spec).flags
{
	marked: ($f.a.metadata? == $set and $f.a.variants.default == true and $f.a.targeting == {if: [1]})
	unmarked: (($f.b | get -o metadata) == null and $f.b.variants.default == false)
	marked2: ($f.c.metadata? == $set)
	unnamed: (($f.gone | get -o metadata) == null and $f.gone.variants.default == true)
} | to json -r
'#) | $"use ($here)/../live.nu with-current-metadata\n($in)" | save -f $wm
let wmr = (^$nu.current-exe $wm | complete)
check ($wmr.exit_code == 0 and ($wmr.stdout | from json | transpose k v | where v == false | is-empty)) $"with-current-metadata: an older version takes the spec's metadata and keeps its values \((if $wmr.exit_code != 0 { $wmr.stderr } else { $wmr.stdout }))"

# (3) The record is of the version the push wrote: where live has moved on, it is skipped, said and noted.
let rec3 = (recorded | length)
let sk = (rlive [record $app --version $v_f1 --flags premium])
check ($sk.exit_code == 0 and ($sk.stderr | str contains "moved on") and (recorded | length) == $rec3 and ((open --raw $"($dir)/journal.jsonl" | lines | last | from json).record == "skipped")) "record: live moved on since the version: skipped, said, noted"

# (7) The splice: a canonical block changes only the literal; a reference, a second default or no default is refused.
let canon = $"($dir)/canon.cue"
"package x\nflags: premium: {\n\t// default: kept\n\tdefault: false // off\n\tlocal: true\n\ttargeting: {default: 1}\n}\nflags: theme: {default: \"light\", local: \"dark\"}\n" | save -f $canon
def splice-file [file: string, flag: string, value: string] { ^$nu.current-exe -c $"use ($here)/../live.nu splice-default; splice-default \(open --raw ($file)) ($flag) ($value)" | complete }
let spliced = (splice-file $canon premium "true")
check ($spliced.exit_code == 0 and ($spliced.stdout | str contains "\tdefault: true // off") and ($spliced.stdout | str contains "// default: kept") and ($spliced.stdout | str contains "targeting: {default: 1}") and ($spliced.stdout | str contains "default: \"light\"")) "splice: only the literal of the block's depth-1 default changes"
let bad = $"($dir)/bad.cue"
for text in ["flags: r: {default: _d}\n" "flags: r: {default: false, x: {default: 1}, default: true}\n" "flags: r: {local: true}\n" "flags: other: {default: false}\n"] {
	$text | save -f $bad
	let r = (splice-file $bad r "true")
	check ($r.exit_code != 0 and ($r.stderr | str contains "flags: record:") and (open --raw $bad) == $text) $"splice: refused, the file as it was: ($text | str trim)"
}

# ---- The real record, in a scratch worktree of the app's repo, with a git origin and a gh stand-in ----
let rorigin = $"($dir)/rorigin.git"
let rwork = $"($dir)/rwork"
^git init -q --bare -b main $rorigin
^git clone -q $rorigin $rwork
let rapp = $"($rwork)/apps/rec"
mkdir $rapp
"package rec\n" | save $"($rapp)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($rapp)/.mise.toml"
^$real trust -q $"($rapp)/.mise.toml"
^$real exec deno@2.5.0 -- deno run --no-config --allow-read --allow-write $"($here)/../install.ts" $rapp | ignore
waive-all $rapp rec
def rspec [premium: any, extra: string = ""] {
	$"package rec
flags: premium: {default: ($premium), local: true}
($extra)flagsLive: {dir: \"flagstore\"}
" | save -f $"($rapp)/flags_spec.cue"
}
rspec false
"flagstore/\n" | save -f $"($rwork)/.gitignore"
def --wrapped rg [...args] { ^git -C $rwork -c user.name=t -c user.email=t@example.com ...$args }
rg add -A
rg commit -q -m base
rg push -q origin HEAD:main
rg fetch -q origin
# gh: lists the branch's pull request once one was created (rgh.created), a fork's too (rgh.fork), says who the user is,
# refuses a create as already existing (rgh.race: another record opened it first), and logs every call.
let ghscript = r##'#!/usr/bin/env python3
import sys, os, json
D = "DIR"
a = sys.argv[1:]
open("LOG", "a").write(" ".join(a) + "\n")
cmd = " ".join(a[:2])
bodyfile = D + "/rgh.body"
created = D + "/rgh.created"
body = a[a.index("--body") + 1] if "--body" in a else ""
if cmd == "api user":
    print("me")
elif cmd == "pr list":
    out = []
    if os.path.exists(created):
        out.append({"number": 7, "url": "https://example.test/pull/7", "isCrossRepository": False, "author": {"login": "me"}, "body": open(bodyfile).read()})
    if os.path.exists(D + "/rgh.foreign"):
        out.append({"number": 11, "url": "https://example.test/pull/11", "isCrossRepository": False, "author": {"login": "someone-else"}, "body": "theirs"})
    if os.path.exists(D + "/rgh.fork"):
        out.append({"number": 9, "url": "https://example.test/pull/9", "isCrossRepository": True, "author": {"login": "evil"}, "body": "- second: x\nRecords: {\"second\": true}"})
    print(json.dumps(out))
    if os.path.exists(D + "/rgh.moveref"):
        # A concurrent record lands after this list: the branch moves and a pull request of its own appears.
        os.remove(D + "/rgh.moveref")
        g = "git --git-dir=" + D + "/rorigin.git "
        sha = os.popen(g + "commit-tree main^{tree} -p main -m 'record' -m 'Records: {\"premium\": true}'").read().strip()
        os.system(g + "update-ref refs/heads/fix/flags-record-rec " + sha)
        open(bodyfile, "w").write("Records: {\"premium\": true}")
        open(created, "w").close()
elif cmd == "pr view":
    print("CLOSED" if os.path.exists(D + "/rgh.closedview") else "OPEN")
elif cmd == "pr create":
    open(created, "w").close()
    open(bodyfile, "w").write(body)
    if os.path.exists(D + "/rgh.race"):
        sys.stderr.write("a pull request for branch already exists\n")
        sys.exit(1)
    print("https://example.test/pull/7")
elif cmd == "pr edit":
    open(bodyfile, "w").write(body)
elif cmd == "pr close":
    os.remove(created)
'##
let ghlog = $"($dir)/rgh.log"
$ghscript | str replace LOG $ghlog | str replace -a DIR $dir | save -f $"($fakegh)/gh"
def rrun [args: list<string>, extra: record = {}] { livex $args ({GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.com", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.com", PRONTO_FLAGS_RECORD: "", PATH: ([$fakegh] | append $env.PATH), PRONTO_FLAGS_JOURNAL: $"($dir)/rjournal.jsonl"} | merge $extra) }
def rjournal [] { open --raw $"($dir)/rjournal.jsonl" | lines | each {|l| $l | from json } }
def ghcount [prefix: string] { open --raw $ghlog | lines | where {|l| $l | str starts-with $prefix } | length }
let rspec_before = (open --raw $"($rapp)/flags_spec.cue")
rrun [setup $rapp] | ignore
let r1 = (rrun [push $rapp --flip premium --untested "rec"])
check ($r1.exit_code == 0 and (open $"($rapp)/flagstore/flags.json" | get flags.premium.variants.default) == true) "record: the flip is live"
check ((open --raw $ghlog | lines | any {|l| $l | str starts-with "pr create --title rec: record live flag defaults" }) and (open --raw $ghlog | str contains "pr merge https://example.test/pull/7 --auto --squash")) "record: a pull request opened with auto-merge armed"
let branch_spec = (^git -C $rorigin show "fix/flags-record-rec:apps/rec/flags_spec.cue")
check ($branch_spec | str contains "premium: {default: true, local: true}") "record: the branch holds the spec with the new default"
check ((^git -C $rorigin diff --name-only main fix/flags-record-rec | lines) == ["apps/rec/flags_spec.cue"]) "record: the branch changes the app's spec alone"
check ((^git -C $rorigin show main:apps/rec/flags_spec.cue | str trim) == ($rspec_before | str trim) and (open --raw $"($rapp)/flags_spec.cue") == $rspec_before) "record: main and the operator's tree are untouched"
check ((rjournal | last).record == "pr" and (rjournal | last).pr == "https://example.test/pull/7" and (rjournal | last).flags == "premium") "record: the journal says the pull request"
check (not ((^git -C $rwork worktree list) | str contains "flagsrec")) "record: the scratch worktree is gone"

check (rjournal | any {|j| ($j.event == "flags.record") and $j.record == "pending" }) "record: a pending line is noted before the record starts"

# A second flip rebuilds the branch from main and records its own flag only: premium (flipped before) and the held spec
# edit (held: true in the spec, off live) stay as main has them.
rspec false "flags: second: {default: false, local: true}\nflags: held: {default: true, local: true}\n"
rg add -A
rg commit -q -m second
rg push -q origin HEAD:main
rrun [push $rapp --sync second --untested "rec"] | ignore
check ((open $"($rapp)/flagstore/flags.json" | get flags.held.variants.default) == false) "record: a new flag on in the spec is written off live"
let r2b = (rrun [push $rapp --flip second --untested "rec"])
let two = (^git -C $rorigin show "fix/flags-record-rec:apps/rec/flags_spec.cue")
check ($r2b.exit_code == 0 and ($two | str contains "second: {default: true") and ($two | str contains "premium: {default: true") and ($two | str contains "held: {default: true") and (open --raw $ghlog | str contains "pr edit 7 --body")) "record: a second flip before the first's pull request merged: the branch carries both, and the held spec edit stays as main has it"

# A flag the open pull request carried whose live value has moved on is dropped from it, with a word.
rrun [push $rapp --sync premium --untested "rec"] | ignore
check ((open $"($rapp)/flagstore/flags.json" | get flags.premium.variants.default) == false) "record: premium is back off live, behind the open pull request's back"
let r2g = (rrun [push $rapp --flip second=true --untested "rec"])
let three = (^git -C $rorigin show "fix/flags-record-rec:apps/rec/flags_spec.cue")
check ($r2g.exit_code == 0 and ($three | str contains "second: {default: true") and ($three | str contains "premium: {default: false") and ($r2g.stderr | str contains "premium no longer hold their value live")) "record: a carried flag whose live value moved on is dropped from the rebuilt branch"

# Flipped back before the PR merged: nothing is left to record, so the stale pull request is closed with its branch.
let closes = (ghcount "pr close")
let r2c = (rrun [push $rapp --flip second=false --untested "rec"])
check ($r2c.exit_code == 0 and (ghcount "pr close") == $closes + 1 and (open --raw $ghlog | str contains "pr close 7 --delete-branch") and (rjournal | last).record == "none" and (rjournal | last).closed == "https://example.test/pull/7") "record: nothing to record and an open record pull request: it is closed with its branch"

# gh create refused as already existing: the pull request is read again and edited.
touch $"($dir)/rgh.race"
let edits = (ghcount "pr edit 7")
let r2d = (rrun [push $rapp --flip second --untested "rec"])
rm $"($dir)/rgh.race"
check ($r2d.exit_code == 0 and (ghcount "pr edit 7") == $edits + 1 and (rjournal | last).record == "pr") "record: a create that finds the pull request already there edits it"

# A fork's pull request of the same branch name is never edited or closed; a new one is opened.
rm $"($dir)/rgh.created"
touch $"($dir)/rgh.fork"
let r2e = (rrun [push $rapp --flip second=false --untested "rec"])
check ($r2e.exit_code == 0 and (ghcount "pr close 9") == 0 and (ghcount "pr edit 9") == 0) "record: a fork's pull request is not closed"
let creates = (ghcount "pr create")
let r2f = (rrun [push $rapp --flip second --untested "rec"])
rm $"($dir)/rgh.fork"
check ($r2f.exit_code == 0 and (ghcount "pr create") == $creates + 1 and (ghcount "pr edit 9") == 0) "record: a fork's pull request is not edited; the tool opens its own"

# A default that is a reference is refused: the push stands, the failure is said and noted, drift lists it.
rspec false "flags: bad: {default: _d, local: true}\nflags: gen: {default: false, local: true}\nflags: slow: {default: false, local: true}\nflags: two: {default: false, local: true}\n_d: false\n"
rg add -A
rg commit -q -m "bad default"
rg push -q origin HEAD:main
rg fetch -q origin
rrun [push $rapp --sync "bad,gen,slow,two" --untested "rec"] | ignore
let created_before = (open --raw $ghlog | lines | where {|l| $l | str starts-with "pr create" } | length)
let r3 = (rrun [push $rapp --flip bad --untested "rec"])
check ($r3.exit_code == 0 and (open $"($rapp)/flagstore/flags.json" | get flags.bad.variants.default) == true and ($r3.stderr | str contains "NOT recorded")) "record refused: the push exits 0 and the flag stays live, with a warning"
check ((rjournal | last).record == "failed" and ((rjournal | last).note | str contains "is no literal")) "record refused: record failed in the journal"
check ((open --raw $ghlog | lines | where {|l| $l | str starts-with "pr create" } | length) == $created_before) "record refused: no pull request opened for it"
let d1 = (rrun [drift $rapp])
check ($d1.exit_code == 1 and ($d1.stdout | str contains "bad")) "drift: exit 1, listing the flags the spec lacks"
rspec false "flags: second: {default: true, local: true}\nflags: bad: {default: true, local: true}\n"
let d0 = (rrun [drift $rapp])
check ($d0.exit_code == 0) "drift: exit 0 once the spec says what is live"

# The branch moves between the attempt's reads and its push (a concurrent record): the lease fails, the attempt is made again
# over the fresh pull request, and both flags end on the branch and in its Records: line.
rspec false "flags: gen: {default: false, local: true}\nflags: slow: {default: false, local: true}\nflags: two: {default: false, local: true}\n"
rrun [push $rapp --flip premium --untested "rec"] | ignore
rm -f $"($dir)/rgh.created"
touch $"($dir)/rgh.moveref"
let edits_m = (ghcount "pr edit 7")
let merges_m = (ghcount "pr merge")
let rm1 = (rrun [push $rapp --flip gen --untested "rec"])
let moved = (^git -C $rorigin show "fix/flags-record-rec:apps/rec/flags_spec.cue")
let recs = (open --raw $"($dir)/rgh.body" | lines | where {|l| $l | str starts-with "Records: " } | first | str substring 9.. | from json)
check ($rm1.exit_code == 0 and ($moved | str contains "gen: {default: true") and ($moved | str contains "premium: {default: true") and $recs.gen == true and $recs.premium == true and (ghcount "pr edit 7") == $edits_m + 1 and (ghcount "pr merge") == $merges_m + 1) "record: the branch moved under the attempt: retried over the fresh pull request, both flags on the branch and in Records:, auto-merge armed on the edit"

# A Records: line that cannot be read carries nothing, with a word, and fails nothing.
let bad_head = (^git --git-dir $rorigin commit-tree main^{tree} -p main -m "record" -m "Records: {nope" | str trim)
^git --git-dir $rorigin update-ref refs/heads/fix/flags-record-rec $bad_head
let r_bad = (rrun [push $rapp --flip gen=false --untested "rec"])
check ($r_bad.exit_code == 0 and ($r_bad.stderr | str contains "Records: line that is unparsable") and (rjournal | last).record == "none") "record: an unparsable Records: line on the branch head carries nothing and fails nothing"

# A pull request that is no longer open when the branch is pushed: a new one is created.
# The flip back off closed the pull request, as it should: a record commit and a pull request listed as open again.
let ours = (^git --git-dir $rorigin commit-tree main^{tree} -p main -m "rec: record live flag defaults" -m "Records: {}" | str trim)
^git --git-dir $rorigin update-ref refs/heads/fix/flags-record-rec $ours
touch $"($dir)/rgh.created"
"- other: false to true" | save -f $"($dir)/rgh.body"
touch $"($dir)/rgh.closedview"
let creates_v = (ghcount "pr create")
let r_view = (rrun [push $rapp --flip gen --untested "rec"])
rm $"($dir)/rgh.closedview"
check ($r_view.exit_code == 0 and (ghcount "pr create") == $creates_v + 1) "record: a listed pull request that is no longer open is not edited; a new one is created"

# The carry is read from the branch head's commit, not the pull request body: a body not yet updated changes nothing.
"an older body, with no Records line" | save -f $"($dir)/rgh.body"
let r_head = (rrun [push $rapp --flip two --untested "rec"])
let by_head = (^git -C $rorigin show "fix/flags-record-rec:apps/rec/flags_spec.cue")
check ($r_head.exit_code == 0 and ($by_head | str contains "gen: {default: true") and ($by_head | str contains "two: {default: true")) "record: the carry comes from the branch head's commit: a stale pull request body does not lose the first flag"

# A stale carried flag leaves no armed pull request behind: its flags no longer live, and the flip has nothing to record,
# the pull request is closed.
rrun [push $rapp --sync "gen,two" --untested "rec"] | ignore
check ((open $"($rapp)/flagstore/flags.json" | get flags.two.variants.default) == false and (open $"($rapp)/flagstore/flags.json" | get flags.gen.variants.default) == false) "record: both carried flags are off live behind the open pull request's back"
let closes_s = (ghcount "pr close")
let r_stale = (rrun [push $rapp --flip premium=false --untested "rec"])
check ($r_stale.exit_code == 0 and (rjournal | last).record == "none" and (ghcount "pr close") == $closes_s + 1) "record: the carried flags went stale and the flip has no diff: the open pull request is closed"
touch $"($dir)/rgh.created"

# The app's generate gets a time limit: past it the record fails, the push stands.
rspec true "flags: slow: {default: false, local: true}\n"
let closes_f = (ghcount "pr close")
let tm = (rrun [push $rapp --flip slow --untested "rec"] {PRONTO_FLAGS_GENERATE_CMD: $"sleep 300 & echo $! > ($dir)/gen.pid; wait", PRONTO_FLAGS_GENERATE_TIMEOUT_SEC: "1"})
check ($tm.exit_code == 0 and (open $"($rapp)/flagstore/flags.json" | get flags.slow.variants.default) == true and (rjournal | last).record == "failed" and (ghcount "pr close") == $closes_f and ((rjournal | last).note | str contains "generate failed or ran past")) "record: a generate past its limit fails the record, never the push, and a failed record leaves the open pull request open"
# The whole process group goes with the timeout: the child the generate started is gone.
let gen_pid = (open --raw $"($dir)/gen.pid" | str trim)
mut gone = false
for _ in 1..30 { if (do { ^kill -0 $gen_pid } | complete).exit_code != 0 { $gone = true; break }; sleep 100ms }
check $gone "record: the generate's child process is killed with its group at the timeout"

# Another author's open pull request on the branch, or a branch that is not ours with no pull request of ours: nothing is pushed.
rspec true "flags: two: {default: false, local: true}\nflags: gen: {default: false, local: true}\n"
let head0 = (^git --git-dir $rorigin rev-parse refs/heads/fix/flags-record-rec | str trim)
touch $"($dir)/rgh.foreign"
let creates_f = (ghcount "pr create")
let r_for = (rrun [push $rapp --flip two --untested "rec"])
rm $"($dir)/rgh.foreign"
check ($r_for.exit_code == 0 and (rjournal | last).record == "failed" and ((rjournal | last).note | str contains "open pull request of another author") and (^git --git-dir $rorigin rev-parse refs/heads/fix/flags-record-rec | str trim) == $head0 and (ghcount "pr create") == $creates_f) "record: another author's open pull request on the branch: refused, nothing pushed, the push stands"
let theirs = (^git --git-dir $rorigin commit-tree main^{tree} -p main -m "their work" | str trim)
^git --git-dir $rorigin update-ref refs/heads/fix/flags-record-rec $theirs
rm -f $"($dir)/rgh.created"
let r_own = (rrun [push $rapp --flip gen --untested "rec"])
check ($r_own.exit_code == 0 and (rjournal | last).record == "failed" and ((rjournal | last).note | str contains "not a record commit") and (^git --git-dir $rorigin rev-parse refs/heads/fix/flags-record-rec | str trim) == $theirs) "record: a branch that is not ours and no pull request of ours: refused, nothing pushed"

# A generate that succeeds does not wait out its limit, and the watcher's sleep is not left behind.
let fast_head = (^git --git-dir $rorigin commit-tree main^{tree} -p main -m "rec: record live flag defaults" -m "Records: {}" | str trim)
^git --git-dir $rorigin update-ref refs/heads/fix/flags-record-rec $fast_head
rm -f $"($dir)/rgh.created"
let t0 = (date now)
let r_fast = (rrun [push $rapp --flip premium --untested "rec"] {PRONTO_FLAGS_GENERATE_CMD: "echo hi", PRONTO_FLAGS_GENERATE_TIMEOUT_SEC: "777"})
let took = ((date now) - $t0)
let left = (^ps -axo command | lines | where {|l| ($l | str contains "sleep 777") and not ($l | str contains "ps -axo") })
check ($r_fast.exit_code == 0 and (rjournal | last).record == "pr" and $took < 10sec and ($left | is-empty)) "record: a generate that succeeds returns at once and leaves no watcher sleep behind"

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

# A mirror with a kubeconfig instead of ssh (Studio's builder): the ConfigMap is applied by a kubectl here, on that file's
# identity; nothing goes over ssh, and a flip waits for the site's /ofrep/ (the identity has no pods/portforward).
let spec_ssh = (open --raw $"($app)/flags_spec.cue")
let kcsent = $"($dir)/kubectl-sent"
$"#!/bin/sh\necho \"$@\" >> ($kcsent).args\nif [ -n \"$KUBECTL_FAIL\" ]; then echo forbidden >&2; exit 1; fi\ncat > ($kcsent)\n" | save -f $"($bin)/kubectl"
^chmod +x $"($bin)/kubectl"
let ssh_before = (open --raw $"($sent).args" | lines | length)
full-spec false "light"
"flagsLive: mirrors: [{kubeconfig: \"/run/kc.yaml\", namespace: \"game\", configMap: \"game-flags\"}]\n" | save -a $"($app)/flags_spec.cue"
"flags: viakc: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let kcp = (livex [push $app --untested "kc"] {PATH: ([$bin] | append $env.PATH)})
let kcm = (open --raw $kcsent | from json)
check ($kcp.exit_code == 0 and $kcm.kind == "ConfigMap" and $kcm.metadata == {name: "game-flags", namespace: "game"} and ("viakc" in ($kcm.data."flags.json" | from json | get flags | columns))) "kubeconfig mirror: a push applies the ConfigMap, holding the flags pushed"
check ((open --raw $"($kcsent).args" | str trim | lines | last) == "--kubeconfig /run/kc.yaml apply -f -" and (open --raw $"($sent).args" | lines | length) == $ssh_before) "kubeconfig mirror: applied by kubectl on the file's identity, nothing over ssh"
"flags: viakc2: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let kn = (object | length)
let kw = (livex [push $app --untested "kc"] {PATH: ([$bin] | append $env.PATH), KUBECTL_FAIL: "1"})
check ($kw.exit_code == 0 and (object | length) == $kn + 1 and ($kw.stderr | str contains "the mirror at /run/kc.yaml's game/game-flags failed, so it still serves") and ($kw.stderr | str contains "forbidden")) "kubeconfig mirror: a failing one warns, and the push is written"
open --raw $"($app)/flags_spec.cue" | str replace 'configMap: "game-flags"}' 'configMap: "game-flags", required: true}' | save -f $"($app)/flags_spec.cue"
"flags: viakc3: {default: false, local: true}\n" | save -a $"($app)/flags_spec.cue"
let kr = (livex [push $app --untested "kc"] {PATH: ([$bin] | append $env.PATH), KUBECTL_FAIL: "1"})
check ($kr.exit_code != 0 and ($kr.stderr | str contains "the mirror at /run/kc.yaml's game/game-flags failed: forbidden")) "kubeconfig mirror: a required one that fails fails the push"
# OFREP by the door: no stand-in, no node to ask, so the site's /ofrep/ is the way, which does not serve a server-only flag.
open --raw $"($app)/flags_spec.cue" | str replace 'flags: premium: {default: false' 'flags: premium: {default: true' | save -f $"($app)/flags_spec.cue"
let kwrap = {PRONTO_FLAGS_CASES_WRAP: "env"}
let kn0 = (object | length)
let nowrap = (livex [push $app --sync premium] {PATH: ([$bin] | append $env.PATH), FLAGS_OFREP_CMD: ""})
check ($nowrap.exit_code != 0 and ($nowrap.stderr | str contains "must run jailed") and (object | length) == $kn0) "kubeconfig mirror: a flip with cases and no wrap is refused before a write"
let sep = (livex [push $app --sync premium] {PATH: ([$bin] | append $env.PATH), FLAGS_OFREP_CMD: "", PRONTO_FLAGS_CASES_WRAP: "env ;"})
check ($sep.exit_code != 0 and ($sep.stderr | str contains "shell separator") and (object | length) == $kn0) "kubeconfig mirror: a wrap ending in a separator is refused"
let kf = (livex [push $app --sync premium] ({PATH: ([$bin] | append $env.PATH), FLAGS_OFREP_CMD: ""} | merge $kwrap))
check ($kf.exit_code == 0 and ($kf.stdout | str contains "premium is not a client flag: the site's /ofrep/ does not serve it") and (open --raw $"($sent).args" | lines | length) == $ssh_before) "kubeconfig mirror: a flip asks the site's /ofrep/, never ssh"
# One of the two, never both nor none.
"flagsLive: mirrors: [{ssh: \"ops@node.example\", kubeconfig: \"/run/kc.yaml\", namespace: \"game\", configMap: \"game-flags\"}]\n" | save -a $"($app)/flags_spec.cue"
let two = (do { cd $app; ^$real exec -- cue export . -e flagsLive.mirrors --out json } | complete)
check ($two.exit_code != 0) "kubeconfig mirror: ssh and kubeconfig together are refused"
$spec_ssh | save -f $"($app)/flags_spec.cue"
full-spec false "light"
livex [push $app --sync premium --untested "reset"] | ignore
$spec_ssh | save -f $"($app)/flags_spec.cue"

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
let jl = (open --raw $"($dir)/journal.jsonl" | lines | each {|l| $l | from json } | where {|j| $j.event == "flags.write" })
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
waive-all $drill drill
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
let refused2 = (dlive [push $drill --sync drill_break_checkout])
check ($refused2.exit_code != 0 and ($refused2.stderr | str contains "no cases") and (dversions) == 1) "dir store: a flip with no cases is refused, nothing written"
let flip = (dlive [push $drill --untested "the drill" --sync drill_break_checkout])
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
dlive [push $drill --sync drill_break_checkout] | ignore

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
let right = (dlive [push $drill --untested "expected target" --expect $want --sync drill_break_checkout])
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
let base = (dlive [push $drill --untested "the flag back, with its local value" --sync drill_break_checkout])
check ($base.exit_code == 0) "dir store: a push over the stand-in write"
$"package drill
flags: drill_break_checkout: {default: false}
flagsLive: {dir: \"flagstore\"}
" | save -f $"($drill)/flags_spec.cue"
let tgt = (dlive [push $drill --untested "targeting only" --sync drill_break_checkout])
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
let dp = (dlive [push $drill --untested "the database" --sync drill_break_checkout])
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
livex [push $app --sync premium] | ignore
let extras = ((newest 0).data | from json | get flags | columns | where {|c| $c not-in ["premium" "theme"] })
check (($extras | length) > 2) "keep-live: the live flags hold flags the spec no longer names (no record: all kept)"
full-spec true "light"
touch $"($app)/fail-live"
let kf = (livex [push $app --sync premium])
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
let acc_only = (livex [push $app --sync lone --untested "accounts only"] {PRONTO_DEVFLOW_BIN: $told2})
check ($acc_only.exit_code == 0 and (((newest 0).data | from json).flags.lone.targeting.if.2.in.1 == ["u9"]) and not ($board2 | path exists)) "an accounts-only flip is written, and tells the board nothing"
# A flag dropped in a push that flips another is no `rolledback` to the board.
full-spec false "light"
"flags: yon: {default: true, local: true}\n" | save -a $"($app)/flags_spec.cue"
livex [push $app --sync yon --untested "yon on"] | ignore
full-spec false "light"
"flags: lone: {default: false, local: true, accounts: [\"u8\"]}\n" | save -a $"($app)/flags_spec.cue"
let dropped_on = (livex [push $app --sync lone --drop yon --untested "accounts, and yon dropped"] {PRONTO_DEVFLOW_BIN: $told2})
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
klive [push $drill --untested "base" --sync drill_break_checkout] | ignore
kspec {ka: false, kb: false, kc: false}
let k0 = (klive [push $drill])
check ($k0.exit_code == 0 and (kflags | columns | where {|c| $c in ["ka" "kb" "kc"] } | length) == 3) "keep-live: new flags that are off are written"

# 8: a new flag that is on is written off unless --sync names it (PRONTO-1191), and then it needs its cases.
kspec {ka: false, kb: false, kc: false, kn: true}
let nv8 = (dversions)
let k8 = (klive [push $drill])
check ($k8.exit_code == 0 and (dversions) == $nv8 + 1 and (kdef kn) == false and ($k8.stderr | str contains "kn is new and on for everyone: written off") and not ($k8.stderr | str contains "no cases") and (djournal | last).kept == "kn") "keep-live: a new flag that is on is written off, with a warning, no cases asked"
let nv8b = (dversions)
let k8b = (klive [push $drill --sync kn])
check ($k8b.exit_code != 0 and ($k8b.stderr | str contains "no cases") and (dversions) == $nv8b) "keep-live: a new flag that is on, named in --sync, still needs its cases"
kspec {ka: false, kb: false, kc: false}
klive [push $drill --drop kn] | ignore

# 4: defaults that differ, with no --sync: the live entries stay, no cases are asked for, one version is written.
kspec {ka: true, kb: true, kc: false}
let nv4 = (dversions)
let k4 = (klive [push $drill])
check ($k4.exit_code == 0 and (dversions) == $nv4 + 1 and (kdef ka) == false and (kdef kb) == false and ($k4.stderr | str contains "ka kept as live")) "keep-live: a changed default with no --sync is not written"
check ((djournal | last).kept == "ka+kb" and (djournal | last).flag == "" and (djournal | last).changes == []) "keep-live: the journal names what was kept, and no flip"

# 5: --sync names the one that flips.
let k5 = (klive [push $drill --sync ka --untested "flip a"])
check ($k5.exit_code == 0 and (kdef ka) == true and (kdef kb) == false and (djournal | last).flag == "ka" and (djournal | last).kept == "kb") "keep-live: --sync a flips a, b is kept"

# 6: a --sync name the spec lacks is refused, nothing written.
let nv6 = (dversions)
let k6 = (klive [push $drill --sync nope])
check ($k6.exit_code != 0 and ($k6.stderr | str contains "not in the spec") and (dversions) == $nv6) "keep-live: --sync of an unknown flag is refused, nothing written"
let k6b = (klive [push $drill --drop ka])
check ($k6b.exit_code != 0 and ($k6b.stderr | str contains "is in the spec") and (dversions) == $nv6) "keep-live: --drop of a flag the spec holds is refused"

let k6c = (klive [push $drill --drop nowhere])
check ($k6c.exit_code != 0 and ($k6c.stderr | str contains "neither live nor in the spec") and (dversions) == $nv6) "keep-live: --drop of a flag that is neither live nor in the spec is refused"

# show and a dry run print the merge, and write nothing: ka is false live and true in the spec.
def default-shown [out: string, f: string] { $out | parse -r ($f + '\s*│\s*(?<d>\w+)') | get d.0 }
let sh0 = (klive [show $drill])
let sh1 = (klive [show $drill --sync kb])
check ($sh0.exit_code == 0 and (default-shown $sh0.stdout kb) == "false" and ($sh0.stderr | str contains "WARNING: kb kept as live")) "keep-live: show prints the merged result, kb kept as live"
check ($sh1.exit_code == 0 and (default-shown $sh1.stdout kb) == "true" and not ($sh1.stderr | str contains "kb kept")) "keep-live: show --sync kb prints kb flipped"
let nvd = (dversions)
let dr = (klive [push $drill --sync kb --dry-run])
check ($dr.exit_code == 0 and ($dr.stdout | str contains "dry run: nothing written") and (default-shown $dr.stdout kb) == "true" and (dversions) == $nvd) "keep-live: a dry-run push --sync shows the merge and writes nothing"

# PRONTO-1191: who a flag is on for is the push's to change only through --sync, not its default alone.
# (a) accounts added to a live flag, no --sync: the live entry is kept, with a warning, and no cases are asked.
kspec {ka: {default: true, accounts: ["u1"]}, kb: false, kc: false}
let nva = (dversions)
let ka1 = (klive [push $drill])
check ($ka1.exit_code == 0 and (dversions) == $nva + 1 and ((kflags | get ka).targeting.if | length) == 3 and ($ka1.stderr | str contains "ka kept as live") and not ($ka1.stderr | str contains "no cases") and (djournal | last).kept == "ka" and (djournal | last).flag == "") "keep-live: accounts added to a live flag, no --sync: the live entry is kept, no cases"
# (b) the same with --sync: refused with no cases, written with --untested.
let nvb = (dversions)
let ka2 = (klive [push $drill --sync ka])
check ($ka2.exit_code != 0 and ($ka2.stderr | str contains "no cases") and (dversions) == $nvb) "keep-live: --sync of an accounts-only change needs cases, refused, nothing written"
let ka3 = (klive [push $drill --sync ka --untested "accounts"])
check ($ka3.exit_code == 0 and ((kflags | get ka).targeting.if.2.in.1 == ["u1"]) and (djournal | last).flag == "ka" and (djournal | last).cases == "untested") "keep-live: --sync with --untested writes the accounts"
# (g) the same accounts in another order change nothing: not held.
kspec {ka: {default: true, accounts: ["u1" "u2"]}, kb: false, kc: false}
klive [push $drill --sync ka --untested "two accounts"] | ignore
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
let kg = (klive [push $drill])
check ($kg.exit_code == 0 and not ($kg.stderr | str contains "ka kept") and (djournal | last).kept == "") "keep-live: accounts reordered change nothing"
# (e) accounts removed: kept without --sync; with it, a flag turned off runs no cases.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: {default: false, accounts: ["u3"]}, kc: false}
klive [push $drill --sync kb --untested "kb to u3"] | ignore
check ((kflags | get kb).targeting.if.2.in.1 == ["u3"]) "keep-live: accounts on a flag whose default stays off are a flip too"
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
let ke1 = (klive [push $drill])
check ($ke1.exit_code == 0 and ((kflags | get kb).targeting.if.2.in.1 == ["u3"]) and ($ke1.stderr | str contains "kb kept as live")) "keep-live: accounts removed, no --sync: kept"
let ke2 = (klive [push $drill --sync kb])
check ($ke2.exit_code == 0 and ((kflags | get kb).targeting.if.2 == "default") and ($ke2.stderr | str contains "kb turned off") and not ($ke2.stderr | str contains "no cases:")) "keep-live: accounts removed with --sync: written, turned off, no cases run"
# (c) a new flag on for accounts, no --sync: written off, in the store and the database; (i) show prints that.
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
check ($kh.exit_code != 0 and ($kh.stderr | str contains "ks is new and not off: name it in --flip with its value") and (dversions) == $nvh) "keep-live: a new flag that is not a bool is refused with no --sync, nothing written"
# (f) only the at-hand `local` value changed: nothing in production moves, so the spec is written.
kspec {ka: {default: true, accounts: ["u2" "u1"]}, kb: false, kc: false}
open --raw $"($drill)/flags_spec.cue" | str replace 'flags: kc: {default: false, local: true}' 'flags: kc: {default: false, local: false}' | save -f $"($drill)/flags_spec.cue"
let kf = (klive [push $drill])
check ($kf.exit_code == 0 and (kflags | get kc).variants.local == false and not ($kf.stderr | str contains "kc kept")) "keep-live: only the at-hand local value changed: written as the spec"
# Back to the plain spec for the cases below: kw is dropped, ka loses its accounts through --sync.
kspec {ka: true, kb: false, kc: false}
klive [push $drill --drop kw --sync ka --untested "plain again"] | ignore
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
	with-env {SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_GCLOUD_STATE: $state, FLAGS_OFREP_CMD: $"python3 ($here)/fake_ofrep.py", FLAGS_POLL_SEC: "0.01", FLAGS_WAIT_SEC: "0.1", PRONTO_FLAGS_JOURNAL: $"($dir)/journal.jsonl", PRONTO_FLAGS_RECORD: "off"} {
		^$nu.current-exe $"($root)/flags/live.nu" ...$args | complete
	}
}
def pushfrom [] { fromat $clone [push $"($repo)/app" --sync premium --untested "pin"] }
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
let shallow_push = (fromat $shallow [push $"($repo)/app" --sync premium --untested "pin"])
check ($shallow_push.exit_code == 0 and (^git -C $shallow rev-parse --is-shallow-repository | str trim) == "false") "pin: a shallow checkout past the pin fetches the history and the push goes through"
rm $"($repo)/.github/flags.pin"
$"package shop
flags: premium: {default: false, local: true, accounts: [\"acct-nopin\"]}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\"}
GCP: {name: \"shop\", project: \"shop-prod\", previewProject: \"shop-previews\", region: \"europe-west1\"}
" | save -f $"($repo)/app/flags_spec.cue"
let nopin = (pushfrom)
check ($nopin.exit_code == 0 and (premium (object | first)).targeting.if.2.in.1 == ["acct-nopin"]) "pin: with no pin file the push runs as before"

# ---- Where the record writes: flags_spec.cue by default, or the file flagsRecord names (a generated spec's source) ----
# An app that generates flags_spec.cue from spec/flags.cue names the source, so the next generate does not revert the record:
# the record edits the source and runs the app's generate (here a stand-in script) before it checks the spec.
for f in [rgh.created rgh.foreign rgh.fork rgh.race rgh.moveref rgh.closedview] { rm -f $"($dir)/($f)" }
rg fetch -q origin
rg reset -q --hard origin/main
let gapp = $"($rwork)/apps/gen"
mkdir $"($gapp)/spec"
"package gen\n" | save $"($gapp)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($gapp)/.mise.toml"
^$real trust -q $"($gapp)/.mise.toml"
^$real exec deno@2.5.0 -- deno run --no-config --allow-read --allow-write $"($here)/../install.ts" $gapp | ignore
waive-all $gapp gen
# The generator: flags_spec.cue says what spec/flags.cue says (its default), as aprende's generate does from its spec.
let gen_sh = $"($dir)/gen.sh"
'#!/bin/sh
d=$(grep -o "default: [a-z]*" spec/flags.cue | cut -d" " -f2)
printf "package gen\nflagsRecord: file: \"%s\"\nflagsLive: {dir: \"flagstore\"}\nflags: premium: {default: %s, local: true}\n" "$REC_FILE" "$d" > flags_spec.cue
' | save -f $gen_sh
def gspec [file: string, d: string = "false"] {
	$"package gen\nflagsRecord: file: \"($file)\"\nflagsLive: {dir: \"flagstore\"}\nflags: premium: {default: ($d), local: true}\n" | save -f $"($gapp)/flags_spec.cue"
}
"flags: premium: {default: false, local: true}\n" | save -f $"($gapp)/spec/flags.cue"
gspec "spec/flags.cue"
rg add -A
rg commit -q -m gen
rg push -q origin HEAD:main
rg fetch -q origin
rrun [setup $gapp] | ignore
let g1 = (rrun [push $gapp --flip premium --untested "gen"] {PRONTO_FLAGS_GENERATE_CMD: $"REC_FILE=spec/flags.cue sh ($gen_sh)"})
check ($g1.exit_code == 0 and (open $"($gapp)/flagstore/flags.json" | get flags.premium.variants.default) == true) "record source: the flip is live"
let gfiles = (^git -C $rorigin diff --name-only main fix/flags-record-gen | lines | sort)
check ($gfiles == ["apps/gen/flags_spec.cue" "apps/gen/spec/flags.cue"]) "record source: the branch changes the declared source, and the generate rewrites the spec from it"
check ((^git -C $rorigin show "fix/flags-record-gen:apps/gen/spec/flags.cue") | str contains "premium: {default: true, local: true}") "record source: the declared file holds the new default"
check ((^git -C $rorigin show "fix/flags-record-gen:apps/gen/flags_spec.cue") | str contains "default: true") "record source: the generated spec follows, so a later generate keeps the record"
check ((rjournal | last).record == "pr" and (rjournal | last).flags == "premium") "record source: the journal says the pull request"
# A declaration that leaves the app, or names no file, is refused softly: the push stands and nothing is pushed.
for bad in ["../rec/flags_spec.cue" "/etc/hosts" "spec/missing.cue" "spec/link.cue"] {
	"flags: premium: {default: false, local: true}\n" | save -f $"($gapp)/spec/flags.cue"
	if $bad == "spec/link.cue" { ^ln -sf /etc/hosts $"($gapp)/spec/link.cue" }
	gspec $bad
	rg add -A
	rg commit -q -m $"bad ($bad)"
	rg push -q origin HEAD:main
	rg fetch -q origin
	let head_before = (^git --git-dir $rorigin rev-parse refs/heads/fix/flags-record-gen | str trim)
	let rb = (rrun [record $gapp])
	# The schema refuses an absolute path or a `..` outright (the tool stops, nothing is read); a path that is no file is the record's own soft failure.
	let hard = ($bad | str starts-with "/") or ($bad | str starts-with "..")
	let refused = if $hard { $rb.exit_code != 0 and ($rb.stderr | str contains "flagsRecord.file") } else { $rb.exit_code == 0 and (rjournal | last).record == "failed" and ((rjournal | last).note | str contains "flagsRecord.file") }
	check ($refused and (^git --git-dir $rorigin rev-parse refs/heads/fix/flags-record-gen | str trim) == $head_before) $"record source: ($bad) is refused, nothing pushed"
}

# ---- PRONTO-439: a flip needs a production check, or the owner's waiver ----
# An app with no flags_waive.cue: a flag that goes on needs a `production` scenario naming it (cases of any other kind are cases, not a
# live check) or `liveWaived` in the spec; --untested answers for cases alone; turning a flag off is never asked.
let pc = $"($dir)/pc"
mkdir $pc
"package pc\n" | save $"($pc)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($pc)/.mise.toml"
^$real trust -q $"($pc)/.mise.toml"
^$real exec deno@2.5.0 -- deno run --no-config --allow-read --allow-write $"($here)/../install.ts" $pc | ignore
mkdir $"($pc)/tests/scenarios" $"($pc)/tests/unit"
'package scenarios
scenarios: look: {flags: ["seen"], production: true, steps: [{by: "tester", open: "/"}]}
' | save $"($pc)/tests/scenarios/pc.cue"
'package unit
cases: u1: {flags: ["feat", "waived", "plain"], steps: [{call: "x"}]}
' | save $"($pc)/tests/unit/pc.cue"
let waiver = "owner, 2026-11-12: no live page shows it"
def pcspec [waived: bool, plain_waived: bool, acc: bool = false, grants: string = ""] {
	let w = if $waived { $", liveWaived: \"($waiver)\"" } else { "" }
	let wa = if $acc { ", accounts: [\"u1\"]" } else { "" }
	let gr = if $grants != "" { $"flags: grants: {default: \"($grants)\", local: \"($grants)\"}\n" } else { "" }
	let pw = if $plain_waived { ", liveWaived: \"owner, 2026-11-12: plain\"" } else { "" }
	$"package pc
flags: feat: {default: false, local: true}
flags: waived: {default: ($acc), local: true($w)($wa)}
flags: seen: {default: false, local: true}
flags: plain: {default: false, local: true($pw)}
flags: bare: {default: false, local: true}
($gr)flagsLive: {dir: \"flagstore\", url: \"https://pc.example\"}
flagsCases: {live: \"echo '✓ look 1s: pc'\"}
" | save -f $"($pc)/flags_spec.cue"
}
let pcj = $"($dir)/pc-journal.jsonl"
let pcstore = $"(($pc | path expand))/flagstore"
def pclive [args: list<string>] { livex $args {PRONTO_FLAGS_JOURNAL: $pcj, FLAGS_OFREP_CMD: "echo '{\"value\": true}'"} }
def pcgen [] { glob $"($pcstore)/versions/*.meta.json" | length }
def pcflag [f: string] { open $"($pcstore)/flags.json" | get flags | get $f | get variants.default }
def pcj-last [] { open --raw $pcj | lines | each {|l| $l | from json } | last }

pcspec true true
let pcs = (pclive [setup $pc])
check ($pcs.exit_code == 0) "production check: the drill app is set up, every flag off"

# (a) unit cases only: refused, naming the flag, the rule and the two ways out; nothing written; --untested does not get past it.
pcspec false false
let pc0 = (pcgen)
let pa = (pclive [push $pc --flip feat])
let pe = ($pa.stderr | flat)
check ($pa.exit_code != 0 and ($pe | str contains "feat") and ($pe | str contains "production check") and ($pe | str contains "production: true") and ($pe | str contains "liveWaived") and (pcgen) == $pc0 and (pcflag feat) == false) "production check: a flag with unit cases only is refused, naming the flag and both ways out; nothing written"
# --untested passes the no-cases check for a flag with no cases at all, and the production check still refuses it.
let pu = (pclive [push $pc --flip bare --untested "x"])
check ($pu.exit_code != 0 and ($pu.stderr | flat | str contains "bare") and ($pu.stderr | flat | str contains "--untested does not waive") and (pcgen) == $pc0 and (pcflag bare) == false) "production check: --untested passes the no-cases check but not this one; nothing written"
# A dry run asks the same, and writes nothing.
let pdr = (pclive [push $pc --flip feat --dry-run])
check ($pdr.exit_code != 0 and ($pdr.stderr | flat | str contains "production check") and (pcgen) == $pc0) "production check: a dry run refuses what the real run refuses"
let pdr2 = (pclive [push $pc --flip seen --dry-run])
check ($pdr2.exit_code == 0 and ($pdr2.stdout | str contains "dry run: nothing written") and (pcgen) == $pc0) "production check: a dry run of a flag with a production scenario goes"

# (b) the same flag with the owner's waiver: pushed, the waiver in the journal note and on the version.
pcspec true false
let pb = (pclive [push $pc --flip waived])
check ($pb.exit_code == 0 and (pcflag waived) == true and (pcj-last).note =~ "live check waived for waived: owner, 2026-11-12: no live page shows it") "production check: a waived flag is pushed, the waiver in the journal note"
check ((glob $"($pcstore)/versions/*.meta.json" | each {|f| open --raw $f | from json } | where {|m| ($m.metadata.note? | default "") =~ "live check waived for waived" } | is-not-empty) and not ((open --raw $"($pcstore)/flags.json") | str contains "liveWaived")) "production check: the waiver is on the version's note and never in the live document"

# (c) a production scenario naming the flag: pushed, its case run on production.
let pcc = (pclive [push $pc --flip seen])
check ($pcc.exit_code == 0 and (pcflag seen) == true and (pcj-last).cases == "passed") "production check: a flag with a production scenario is pushed and its case passes"

# A data flag is no off-to-on flip: a string changed with --untested is not asked; nor a flag already on that gains accounts.
pcspec false false false "a"
let pg0 = (pclive [push $pc --flip grants=a --untested "data"])
pcspec false false false "b"
let pg = (pclive [push $pc --flip grants=b --untested "data"])
check ($pg0.exit_code == 0 and $pg.exit_code == 0 and (pcflag grants) == "b") "production check: a string flag, new or changed, is not asked for a live check"
pcspec false false true "b"
let pac = (pclive [push $pc --sync waived])
check ($pac.exit_code == 0 and (pcflag waived) == true) "production check: a flag already on that gains accounts is not asked"

# (d) turning a flag off is never refused, waiver or none: plain goes on under a waiver, then off with the waiver gone from the spec.
pcspec true true
let pp = (pclive [push $pc --flip plain])
check ($pp.exit_code == 0 and (pcflag plain) == true) "production check: a second waived flag is on"
pcspec false false
let po = (pclive [push $pc --flip plain=false])
check ($po.exit_code == 0 and (pcflag plain) == false) "production check: turning a flag off is never refused"
let pq = (pclive [push $pc --flip waived=false])
check ($pq.exit_code == 0 and (pcflag waived) == false) "production check: off, with no case and no waiver in the spec"

rm -rf $dir
print "flags: live commands pass"
