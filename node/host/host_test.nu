#!/usr/bin/env nu
# Run with: nu node/host/host_test.nu
#
# host.nu's files for a node's #Host values, applied and checked against a root folder with a stand-in
# systemctl, and docker-gc.sh run by bash against a stand-in docker. Nothing here touches a node.

use std/assert
use host.nu [render apply]

const here = path self | path dirname

def main [] {
	print "Running node host tests...\n"
	test_the_schema_defaults_and_refuses
	test_render_holds_the_defaults_and_the_nodes_values
	test_the_cleanup_picks_only_old_matching_tags_and_keeps_one_it_cannot_read
	test_the_cleanup_goes_on_past_an_image_it_cannot_remove_and_fails_over_the_cap
	test_the_cleanup_never_forces_nor_prunes_images_in_use
	test_apply_writes_what_drifted_and_a_second_run_finds_none
	test_check_changes_nothing_and_says_every_drift
	test_a_failed_last_run_is_drift
	test_a_failed_reload_query_is_an_error_not_no_reload
	test_the_cleanup_stops_on_a_pattern_bash_cannot_compile
	test_a_login_that_fails_is_an_error_not_an_answer
	test_the_settings_are_written_before_the_script
	test_a_world_writable_or_foreign_file_is_drift
	test_a_hand_edited_host_cannot_carry_a_quote_into_the_files
	test_an_invalid_reference_pattern_is_refused
	test_a_failed_job_makes_apply_exit_non_zero
	test_a_pending_daemon_reload_is_drift_and_is_done_though_every_file_matches
	test_a_failed_job_is_run_again_when_files_were_written
	test_a_stale_new_file_is_replaced_not_reused
	test_the_dapr_sidecar_repair_is_a_second_timer_of_the_same_host
	test_a_host_that_drops_daprHeal_loses_its_timer_and_files
	test_removal_keeps_the_files_unless_systemd_says_the_timer_is_stopped
	print "\nAll node host tests passed."
}

def defaults []: nothing -> record {
	{dockerGC: {minAgeHours: 6, refPattern: "^localhost:[0-9]+/", buildCacheGB: 40, capGB: 120, onCalendar: "hourly"}}
}

def tmp []: nothing -> string { mktemp --directory --tmpdir node-host-XXXXXX }

# A stand-in docker: `images` are [ref, hours ago | text], `sizes` is `system df`'s column, `rm` of a ref in
# `stuck` fails. Returns {code, out, calls, would}.
def run-gc [host: record, images: list, sizes: list<string>, stuck: list<string>, args: list<string>]: nothing -> record {
	let dir = (tmp)
	let go_time = {|h| (date now | date to-timezone utc) - ($h * 1hr) | format date "%Y-%m-%d %H:%M:%S.456789 +0000 UTC" }
	($images | each {|i| $i.0} | str join "\n") + "\n" | save --raw ($dir | path join refs)
	($images | each {|i| $"($i.0)|(if ($i.1 | describe) == int { do $go_time $i.1 } else { $i.1 })"} | str join "\n") + "\n" | save --raw ($dir | path join times)
	($sizes | str join "\n") + "\n" | save --raw ($dir | path join sizes)
	($stuck | str join "\n") + "\n" | save --raw ($dir | path join stuck)
	"" | save --raw ($dir | path join calls)
	let env_text = (render $host | where path == "/etc/pronto/docker-gc.env" | first | get text)
	$env_text | save --raw ($dir | path join gc.env)
	r##'#!/bin/bash
d=$(dirname "$0")
case "$1 $2" in
  "image ls") cat "$d/refs" ;;
  "image inspect") awk -F'|' -v r="${!#}" '$1 == r { print $2 }' "$d/times" ;;
  "system df") cat "$d/sizes" ;;
  *) echo "$*" >>"$d/calls"; if [ "$1 $2" = "image rm" ] && grep -qxF -- "$3" "$d/stuck"; then exit 1; fi ;;
esac
'## | save --raw ($dir | path join docker)
	chmod 755 ($dir | path join docker)
	let r = (with-env {PATH: $"($dir):/usr/bin:/bin", DOCKER_GC_ENV: ($dir | path join gc.env)} { ^/bin/bash ($here | path join docker-gc.sh) ...$args | complete })
	let out = $r.stdout + $r.stderr
	let calls = (open --raw ($dir | path join calls) | lines | where {|l| $l != ""})
	rm -rf $dir
	{code: $r.exit_code, out: $out, calls: $calls, would: ($out | lines | where {|l| $l starts-with "would remove "} | each {|l| $l | str replace "would remove " ""})}
}

# Whether `cue export` of #Host with `values` unified holds, and what it gives.
def host-with [values: string]: nothing -> record {
	let f = (mktemp --tmpdir node-host-XXXXXX.cue)
	$"package schema\nhost: #Host & ($values)\n" | save --force --raw $f
	let r = (do { ^cue export ($here | path join schema host.cue) $f -e host --out json } | complete)
	rm -f $f
	{ok: ($r.exit_code == 0), host: (if $r.exit_code == 0 { $r.stdout | from json } else { null })}
}

def test_the_schema_defaults_and_refuses [] {
	print "test #Host's defaults are what the node ran with, and its bounds refuse a value that could not work..."
	assert equal (host-with "{}").host (defaults) "a host with no daprHeal holds none: a non-k3s host gets no repair timer"
	assert equal (host-with "{daprHeal: {namespaces: [\"aprende\", \"brawl-chess\", \"studio\", \"coach\"]}}").host (with-heal)
	assert (not (host-with "{daprHeal: {}}").ok) "no namespaces said: none is assumed"
	assert (not (host-with "{daprHeal: {namespaces: [\"studio-ana-game-1a2b3c\"]}}").ok) "a Studio tenant's namespace"
	assert (not (host-with "{daprHeal: {namespaces: [\"dapr-system\"]}}").ok) "dapr-system"
	assert (not (host-with "{daprHeal: {namespaces: [\"kube-system\"]}}").ok) "kube-system"
	assert (not (host-with "{daprHeal: {namespaces: []}}").ok) "no namespace to sweep"
	assert (not (host-with "{daprHeal: {namespaces: [\"a b\"]}}").ok) "a name with a space"
	assert equal (host-with "{daprHeal: {namespaces: [\"aprende\", \"studio\"]}}").host.daprHeal.namespaces ["aprende" "studio"]
	assert (not (host-with "{daprHeal: {graceSeconds: 5}}").ok) "a grace the injector's own delay could outlast"
	assert (not (host-with "{daprHeal: {cooldownMinutes: 1}}").ok) "a cooldown shorter than a roll"
	assert (not (host-with "{daprHeal: {kubectl: \"k3s' kubectl\"}}").ok) "a quote in kubectl"
	assert (not (host-with "{daprHeal: {kubectl: \"/tmp/evil\"}}").ok) "a program the host JSON names"
	assert (not (host-with "{daprHeal: {kubectl: \"k3s kubectl; id\"}}").ok) "arguments"
	assert equal (host-with "{daprHeal: {kubectl: \"kubectl\", namespaces: [\"aprende\"]}}").host.daprHeal.kubectl "kubectl"
	assert (not (host-with "{daprHeal: {onCalendar: \"\"}}").ok) "no schedule for the repair"
	assert equal (host-with "{dockerGC: {buildCacheGB: 10, capGB: 50}}").host.dockerGC.capGB 50
	assert (not (host-with "{dockerGC: {capGB: 40}}").ok) "a cap at the cache"
	assert (not (host-with "{dockerGC: {minAgeHours: 0}}").ok) "no age"
	assert (not (host-with "{dockerGC: {refPattern: \"localhost\"}}").ok) "a pattern without ^"
	assert (not (host-with "{dockerGC: {refPattern: \"^a'b\"}}").ok) "a quote in the pattern"
	assert (not (host-with "{dockerGC: {onCalendar: \"\"}}").ok) "no schedule"
	assert (not (host-with "{dockerGC: {refPattern: \"^a\\nb\"}}").ok) "a newline in the pattern"
	assert (not (host-with "{dockerGC: {onCalendar: \"hourly\\\\\"}}").ok) "a trailing backslash in the schedule"
	assert (not (host-with "{dockerGC: {onCalendar: \"hourly\\r\"}}").ok) "a carriage return in the schedule"
	assert (not (host-with "{dockerGC: {onCalendar: \"hourly\\n[Service]\"}}").ok) "a schedule that starts another setting"
	# A cache past the default cap needs a cap said: the default is not kept under the cache, or the job would fail every hour.
	assert (not (host-with "{dockerGC: {buildCacheGB: 130}}").ok) "a cache past the default cap"
	assert equal (host-with "{dockerGC: {buildCacheGB: 130, capGB: 200}}").host.dockerGC.capGB 200
}

def test_render_holds_the_defaults_and_the_nodes_values [] {
	print "test the files hold the node's values in an env file docker-gc.sh reads, and the units..."
	let files = (render (defaults))
	# The settings come before the script that reads them.
	assert equal ($files | get path) ["/etc/pronto/docker-gc.env" "/usr/local/lib/pronto/docker-gc.sh" "/etc/systemd/system/pronto-docker-gc.service" "/etc/systemd/system/pronto-docker-gc.timer"]
	let envf = ($files | where path == "/etc/pronto/docker-gc.env" | first | get text)
	assert str contains $envf "PATTERN='^localhost:[0-9]+/'\nMIN_AGE_HOURS=6\nBUILD_CACHE_GB=40\nCAP_GB=120\n"
	let svc = ($files | where path =~ "service" | first | get text)
	assert str contains $svc "\nType=oneshot\nExecStart=/bin/bash /usr/local/lib/pronto/docker-gc.sh\nNice=19\nIOSchedulingClass=idle\n"
	let timer = ($files | where path =~ "timer" | first | get text)
	assert str contains $timer "\nOnCalendar=hourly\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n"
	let other = (render {dockerGC: {minAgeHours: 12, refPattern: "^reg:5000/", buildCacheGB: 10, capGB: 50, onCalendar: "*:0/30"}})
	assert str contains ($other | where path =~ "env" | first | get text) "PATTERN='^reg:5000/'\nMIN_AGE_HOURS=12\nBUILD_CACHE_GB=10\nCAP_GB=50\n"
	assert str contains ($other | where path =~ "timer" | first | get text) "OnCalendar=*:0/30\n"
}

def test_the_cleanup_picks_only_old_matching_tags_and_keeps_one_it_cannot_read [] {
	print "test the cleanup lists only old localhost tags, and keeps one whose time it cannot read..."
	let r = (run-gc (defaults) [
		["localhost:5000/studio-web:a" 7]
		["localhost:5000/studio-web:b" 5]
		["localhost:32000/brawl-chess-auth:latest" 200]
		["localhost:5000/offset:old" "2020-01-02T03:04:05.5-03:00"]
		["localhost:5000/zero:a" "0001-01-01 00:00:00 +0000 UTC"]
		["localhost:5000/empty:a" ""]
		["localhost:5000/junk:a" "yesterday"]
		["localhost:5000/untagged:<none>" 200]
		["postgres:18" 200]
		["ghcr.io/localhost:5000/other:a" 200]
	] ["1GB"] [] ["--dry-run"])
	assert equal $r.code 0
	assert equal $r.calls []
	assert equal $r.would ["localhost:5000/studio-web:a" "localhost:32000/brawl-chess-auth:latest" "localhost:5000/offset:old"]
}

def test_the_cleanup_goes_on_past_an_image_it_cannot_remove_and_fails_over_the_cap [] {
	print "test the cleanup goes on past an image it cannot remove, and fails over the cap..."
	let r = (run-gc (defaults) [["localhost:5000/used:a" 7] ["localhost:5000/old:a" 7] ["localhost:5000/new:a" 1]] ["80.5GB" "12kB" "0B" "39.4GB"] ["localhost:5000/used:a"] [])
	assert equal $r.code 0
	assert equal $r.calls ["image rm localhost:5000/used:a" "image rm localhost:5000/old:a" "image prune -f" "builder prune -af --max-used-space 40GB"]
	let over = (run-gc (defaults) [] ["80.7GB" "0B" "0B" "39.4GB"] [] [])
	assert equal $over.code 1
	assert str contains $over.out "over the cap of 120GB"
	# A tag time no run can read would keep every image for ever, so the unit fails.
	let zero = (run-gc (defaults) [["localhost:5000/zero:a" "0001-01-01 00:00:00 +0000 UTC"]] ["1GB"] [] [])
	assert equal $zero.code 1
	assert (not ($zero.out | str contains "over the cap"))
	# The node's own values reach the job: a smaller cache and cap.
	let own = (run-gc {dockerGC: {minAgeHours: 1, refPattern: "^localhost:[0-9]+/", buildCacheGB: 10, capGB: 50, onCalendar: "hourly"}} [["localhost:5000/a:a" 2]] ["60GB"] [] [])
	assert equal $own.code 1
	assert equal $own.calls ["image rm localhost:5000/a:a" "image prune -f" "builder prune -af --max-used-space 10GB"]
}

def test_the_cleanup_never_forces_nor_prunes_images_in_use [] {
	print "test the cleanup never forces a removal nor prunes what a container uses..."
	let text = (open --raw ($here | path join docker-gc.sh))
	assert (not ($text =~ '(rmi\b|system prune|image rm [^\n]*(-f\b|--force)|(image|volume|container) prune [^\n]*(-a\b|-af|-fa|--all)|volume (rm|prune)|until=)')) "a forced or broad removal"
}

# A stand-in systemctl over files in $dir: `on` (enabled and active), `failed` (its job's last run).
def fake-systemctl [dir: string] {
	mkdir ($dir | path join bin)
	'#!/bin/bash
d=$(dirname "$0")/..
echo "$*" >>"$d/systemctl.log"
case "$1" in
  is-failed) [ -e "$d/failed" ] ;;
  is-enabled | is-active)
    case "$*" in
      *dapr-heal*)
        if [ -n "$UNREADABLE" ]; then echo "Failed to connect to bus" >&2; exit 1; fi
        if [ -e "$d/heal.on" ]; then if [ "$1" = is-active ]; then echo active; else echo enabled; fi; exit 0; fi
        if [ "$1" = is-active ]; then echo inactive; exit 3; else echo disabled; exit 1; fi ;;
    esac
    [ -e "$d/on" ] ;;
  disable) case "$*" in *dapr-heal*) [ -n "$KEEPON" ] || rm -f "$d/heal.on" ;; esac ;;
  enable) touch "$d/on"; case "$*" in *dapr-heal*) touch "$d/heal.on" ;; esac ;;
  show) if [ -e "$d/needreload" ]; then echo yes; else echo no; fi ;;
  daemon-reload) rm -f "$d/needreload" ;;
  start) if [ -n "$STARTEXIT" ]; then exit "$STARTEXIT"; fi; [ "$STAYFAILED" = 1 ] || rm -f "$d/failed" ;;
  *) ;;
esac
' | save --raw ($dir | path join bin systemctl)
	chmod 755 ($dir | path join bin systemctl)
	'#!/bin/bash
shift
exec "$@"
' | save --raw ($dir | path join bin timeout)
	chmod 755 ($dir | path join bin timeout)
	"" | save --raw ($dir | path join systemctl.log)
}

def test_apply_writes_what_drifted_and_a_second_run_finds_none [] {
	print "test apply writes the four files, reloads systemd, enables the timer, and a second run finds no drift..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		let first = (apply (defaults) --root $root)
		assert equal ($first | length) 5
		for f in (render (defaults)) { assert equal (open --raw ($root + $f.path)) $f.text }
		assert equal (open --raw ($root + "/usr/local/lib/pronto/docker-gc.sh") | lines | first) "#!/usr/bin/env bash"
		assert equal (ls ($root + "/etc/pronto") | length) 1 "no .new left"
		let log = (open --raw ($dir | path join systemctl.log))
		assert str contains $log "daemon-reload"
		assert str contains $log "enable --now pronto-docker-gc.timer"
		let second = (apply (defaults) --root $root)
		assert equal $second []
		# A changed value is drift in the env file alone, and the timer is not enabled again.
		let third = (apply {dockerGC: {minAgeHours: 6, refPattern: "^localhost:[0-9]+/", buildCacheGB: 30, capGB: 120, onCalendar: "hourly"}} --root $root)
		assert equal $third [$"($root)/etc/pronto/docker-gc.env differs"]
	}
	rm -rf $dir
}

def test_check_changes_nothing_and_says_every_drift [] {
	print "test --check writes and enables nothing, and says every drift..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		let drift = (apply (defaults) --check --root $root)
		assert equal ($drift | length) 5
		assert (not ($root | path exists)) "nothing written"
		let log = (open --raw ($dir | path join systemctl.log))
		assert (not ($log | str contains "enable --now")) "nothing enabled"
		assert (not ($log | str contains "daemon-reload"))
	}
	rm -rf $dir
}

def test_the_settings_are_written_before_the_script [] {
	print "test apply renames the env file into place before docker-gc.sh, and the units after both..."
	let dir = (tmp)
	fake-systemctl $dir
	'#!/bin/bash
d=$(dirname "$0")/..
echo "$2" >>"$d/mv.log"
exec /bin/mv "$@"
' | save --raw ($dir | path join bin mv)
	chmod 755 ($dir | path join bin mv)
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (defaults) --root $root | ignore
		let order = (open --raw ($dir | path join mv.log) | lines | where {|l| $l != ""} | each {|l| $l | str replace ".new" "" | str replace $root ""})
		assert equal $order ["/etc/pronto/docker-gc.env" "/usr/local/lib/pronto/docker-gc.sh" "/etc/systemd/system/pronto-docker-gc.service" "/etc/systemd/system/pronto-docker-gc.timer"]
	}
	rm -rf $dir
}

def test_a_world_writable_or_foreign_file_is_drift [] {
	print "test a settings file with the right text but mode 0666 is drift, and apply sets it back..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (defaults) --root $root | ignore
		chmod 666 ($root + "/etc/pronto/docker-gc.env")
		let drift = (apply (defaults) --check --root $root)
		assert equal ($drift | length) 1
		assert str contains ($drift | first) "docker-gc.env has mode and owner"
		apply (defaults) --root $root | ignore
		assert equal (apply (defaults) --check --root $root) []
	}
	rm -rf $dir
}

def test_a_hand_edited_host_cannot_carry_a_quote_into_the_files [] {
	print "test render and apply vet the values against #Host: a quote or a newline never reaches the script's settings or a unit..."
	for bad in [{refPattern: "^a'; touch /tmp/x; '"} {onCalendar: "hourly\nExecStart=/bin/sh"} {capGB: 10}] {
		let host = {dockerGC: ((defaults).dockerGC | merge $bad)}
		let msg = (try { render $host | ignore; "accepted" } catch {|e| $e.msg })
		assert str contains $msg "is not what #Host allows" $"($bad)"
	}
}

def test_an_invalid_reference_pattern_is_refused [] {
	print "test a refPattern bash cannot compile is refused, not read as matching no tag..."
	for bad in ["^[" "^(a" "^a{2,1}"] {
		let msg = (try { render {dockerGC: ((defaults).dockerGC | merge {refPattern: $bad})} | ignore; "accepted" } catch {|e| $e.msg })
		assert str contains $msg "not a valid bash ERE" $bad
	}
	render (defaults) | ignore
}

def test_a_failed_job_makes_apply_exit_non_zero [] {
	print "test apply exits 1 when the job's last run failed, which writing files does not clear..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	(defaults) | to json | save --raw ($dir | path join host.json)
	let run = {|| with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} { ^$nu.current-exe ($here | path join host.nu) apply ($dir | path join host.json) --root $root | complete } }
	assert equal (do $run).exit_code 0
	"" | save --raw ($dir | path join failed)
	let r = (do $run)
	assert equal $r.exit_code 1
	assert str contains $r.stderr "the job's last run failed"
	rm -rf $dir
}

def test_a_pending_daemon_reload_is_drift_and_is_done_though_every_file_matches [] {
	print "test units written but not reloaded (every file matches) are drift for --check, and apply reloads without writing..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (defaults) --root $root | ignore
		assert equal (apply (defaults) --check --root $root) [] "reloaded and in step"
		# A run that wrote the units and stopped before daemon-reload: the files match, systemd runs the old ones.
		"" | save --raw ($dir | path join needreload)
		let drift = (apply (defaults) --check --root $root)
		assert equal $drift ["pronto-docker-gc.service needs a daemon-reload" "pronto-docker-gc.timer needs a daemon-reload"]
		assert (($dir | path join needreload) | path exists) "--check reloads nothing"
		let before = (open --raw ($dir | path join systemctl.log) | lines | where {|l| $l == "daemon-reload"} | length)
		let done = (apply (defaults) --root $root)
		assert equal ($done | length) 2
		let after = (open --raw ($dir | path join systemctl.log) | lines | where {|l| $l == "daemon-reload"} | length)
		assert equal $after ($before + 1)
		assert equal (apply (defaults) --check --root $root) [] "nothing pending after the reload"
	}
	rm -rf $dir
}

def test_a_failed_job_is_run_again_when_files_were_written [] {
	print "test a job that failed is run again once its files are set right, and a repair exits 0 and says set; one that fails again exits 1..."
	for stay in ["0" "1"] {
		let dir = (tmp)
		fake-systemctl $dir
		let root = ($dir | path join root)
		(defaults) | to json | save --raw ($dir | path join host.json)
		# The settings drifted (the cause of the failure) and the job's last run failed.
		with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} { apply (defaults) --root $root | ignore }
		"# drifted\n" | save --force --raw ($root + "/etc/pronto/docker-gc.env")
		"" | save --raw ($dir | path join failed)
		let r = (with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')", STAYFAILED: $stay} { ^$nu.current-exe ($here | path join host.nu) apply ($dir | path join host.json) --root $root | complete })
		assert str contains (open --raw ($dir | path join systemctl.log)) "start pronto-docker-gc.service"
		if $stay == "0" {
			assert equal $r.exit_code 0
			assert str contains $r.stdout "node-host: set as #Host says"
		} else {
			assert equal $r.exit_code 1
			assert str contains $r.stderr "set, but the job's last run still fails"
		}
		rm -rf $dir
	}
	# The run again is told apart by its exit: 124 (timeout) is still running, anything else is a failed start; both exit 1.
	for code in ["124" "1"] {
		let dir = (tmp)
		fake-systemctl $dir
		let root = ($dir | path join root)
		(defaults) | to json | save --raw ($dir | path join host.json)
		with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} { apply (defaults) --root $root | ignore }
		"# drifted\n" | save --force --raw ($root + "/etc/pronto/docker-gc.env")
		"" | save --raw ($dir | path join failed)
		let r = (with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')", STARTEXIT: $code} { ^$nu.current-exe ($here | path join host.nu) apply ($dir | path join host.json) --root $root | complete })
		assert equal $r.exit_code 1 $"start exit ($code)"
		if $code == "124" { assert str contains $r.stdout "still running after 600 s" }
		rm -rf $dir
	}
	# Nothing written and a failed job: it is not run again, the exit is 1, and "set" is not said.
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	(defaults) | to json | save --raw ($dir | path join host.json)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} { apply (defaults) --root $root | ignore }
	"" | save --raw ($dir | path join failed)
	let r = (with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} { ^$nu.current-exe ($here | path join host.nu) apply ($dir | path join host.json) --root $root | complete })
	assert equal $r.exit_code 1
	assert str contains $r.stderr "nothing to write, but the job's last run failed"
	assert (not (open --raw ($dir | path join systemctl.log) | str contains "start pronto-docker-gc.service"))
	rm -rf $dir
}

def test_a_stale_new_file_is_replaced_not_reused [] {
	print "test a .new file left by an earlier run (another owner or mode) is removed before the write..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	mkdir ($root + "/etc/pronto")
	"stale\n" | save --raw ($root + "/etc/pronto/docker-gc.env.new")
	chmod 666 ($root + "/etc/pronto/docker-gc.env.new")
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (defaults) --root $root | ignore
		assert equal (apply (defaults) --check --root $root) [] "the env file is whole, mode 644"
	}
	rm -rf $dir
}

def test_a_login_that_fails_is_an_error_not_an_answer [] {
	print "test an ssh that fails (255) when asked whether the timer runs is an error, never read as not failed or not enabled..."
	let dir = (tmp)
	fake-systemctl $dir
	# Over a fake ssh, so the script is single-quoted for the node's shell as in production; its systemctl is-* queries fail as a lost login does.
	'#!/bin/bash
d=$(dirname "$0")/..
while [ "$1" = -o ]; do shift 2; done
shift
case "$1" in *is-failed*|*is-enabled*|*NeedDaemonReload*) exit 255 ;; esac
exec bash -c "$1"
' | save --raw ($dir | path join bin ssh)
	chmod 755 ($dir | path join bin ssh)
	'#!/bin/bash
exec "$@"
' | save --raw ($dir | path join bin sudo)
	chmod 755 ($dir | path join bin sudo)
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		let msg = (try { apply (defaults) --node fake --root $root; "no error" } catch {|e| $e.msg })
		assert str contains $msg "asking whether"
		# What it wrote before asking is whole: the files are as #Host says.
		for f in (render (defaults)) { assert equal (open --raw ($root + $f.path)) $f.text }
	}
	rm -rf $dir
}

def test_a_failed_reload_query_is_an_error_not_no_reload [] {
	print "test an ssh that fails when asked whether a unit needs a daemon-reload is an error, never read as none needed..."
	let dir = (tmp)
	fake-systemctl $dir
	'#!/bin/bash
while [ "$1" = -o ]; do shift 2; done
shift
case "$1" in *NeedDaemonReload*) echo "ssh: connection lost" >&2; exit 255 ;; esac
exec bash -c "$1"
' | save --raw ($dir | path join bin ssh)
	chmod 755 ($dir | path join bin ssh)
	'#!/bin/bash
exec "$@"
' | save --raw ($dir | path join bin sudo)
	chmod 755 ($dir | path join bin sudo)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		let msg = (try { apply (defaults) --node fake --root ($dir | path join root); "no error" } catch {|e| $e.msg })
		assert str contains $msg "needs a daemon-reload"
	}
	rm -rf $dir
}

def test_the_cleanup_stops_on_a_pattern_bash_cannot_compile [] {
	print "test docker-gc.sh itself fails on an invalid PATTERN, before it looks at a single tag..."
	let dir = (tmp)
	"PATTERN='^['\nMIN_AGE_HOURS=6\nBUILD_CACHE_GB=40\nCAP_GB=120\n" | save --raw ($dir | path join gc.env)
	'#!/bin/bash
echo "$*" >>"$(dirname "$0")/calls"
echo "localhost:5000/a:a"
' | save --raw ($dir | path join docker)
	chmod 755 ($dir | path join docker)
	let r = (with-env {PATH: $"($dir):/usr/bin:/bin", DOCKER_GC_ENV: ($dir | path join gc.env)} { ^/bin/bash ($here | path join docker-gc.sh) | complete })
	assert equal $r.exit_code 1
	assert str contains $r.stderr "PATTERN is not a valid regular expression"
	assert (not (($dir | path join calls) | path exists)) "docker was never called"
	rm -rf $dir
}

def test_a_failed_last_run_is_drift [] {
	print "test a job whose last run failed is drift --check reports, and enabling the timer does not clear..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (defaults) --root $root | ignore
		"" | save --raw ($dir | path join failed)
		let drift = (apply (defaults) --check --root $root)
		assert equal $drift ["pronto-docker-gc.service failed its last run"]
	}
	rm -rf $dir
}

def with-heal []: nothing -> record {
	(defaults) | merge {daprHeal: {kubectl: "k3s kubectl", namespaces: ["aprende" "brawl-chess" "studio" "coach"], graceSeconds: 120, cooldownMinutes: 30, onCalendar: "*:0/5"}}
}

def test_the_dapr_sidecar_repair_is_a_second_timer_of_the_same_host [] {
	print "test a host with daprHeal also holds the repair env, script and timer, checks both timers, and finds a failed repair run..."
	let files = (render (with-heal))
	assert equal ($files | get path | last 4) ["/etc/pronto/dapr-heal.env" "/usr/local/lib/pronto/dapr-heal.sh" "/etc/systemd/system/pronto-dapr-heal.service" "/etc/systemd/system/pronto-dapr-heal.timer"]
	assert equal ($files | where path == "/etc/pronto/dapr-heal.env" | first | get text) "# pronto-plugins node/host (Dapr sidecar): what dapr-heal.sh reads, from the node's #Host daprHeal.\nKUBECTL='/usr/local/bin/k3s kubectl'\nNAMESPACES='aprende brawl-chess studio coach'\nGRACE_SECONDS=120\nCOOLDOWN_MINUTES=30\n"
	assert str contains ($files | where path == "/etc/systemd/system/pronto-dapr-heal.timer" | first | get text) "OnCalendar=*:0/5\n"
	assert equal (render (defaults) | length) 4 "a host with no daprHeal holds the cleanup's files alone"
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		assert equal (apply (with-heal) --root $root | length) 10
		let log = (open --raw ($dir | path join systemctl.log))
		assert str contains $log "enable --now pronto-docker-gc.timer"
		assert str contains $log "is-enabled --quiet pronto-dapr-heal.timer"
		assert equal (apply (with-heal) --root $root) []
		# A repair run that failed is drift, as the cleanup's is.
		touch ($dir | path join failed)
		assert equal (apply (with-heal) --root $root | length) 2 "both jobs read the one failed marker the stand-in keeps"
	}
	let bad = (try { render ((with-heal) | merge {daprHeal: {kubectl: "k3s'kubectl", namespaces: ["aprende"], graceSeconds: 120, cooldownMinutes: 30, onCalendar: "*:0/5"}}); "rendered" } catch {|e| $e.msg })
	assert str contains $bad "daprHeal is not what #Host allows"
}

def test_a_host_that_drops_daprHeal_loses_its_timer_and_files [] {
	print "test removing daprHeal is drift for --check (nothing changed) and apply disables the timer, removes its four files and reloads systemd..."
	let dir = (tmp)
	fake-systemctl $dir
	let root = ($dir | path join root)
	let heal_files = ["/etc/pronto/dapr-heal.env" "/usr/local/lib/pronto/dapr-heal.sh" "/etc/systemd/system/pronto-dapr-heal.service" "/etc/systemd/system/pronto-dapr-heal.timer"]
	with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
		apply (with-heal) --root $root | ignore
		for f in $heal_files { assert ($root + $f | path exists) $"($f) installed" }
		# --check says it, per file, and changes nothing.
		"" | save --force --raw ($dir | path join systemctl.log)
		let checked = (apply (defaults) --check --root $root)
		assert equal ($checked | length) 4
		assert str contains ($checked | first) "is installed but the host has no daprHeal"
		for f in $heal_files { assert ($root + $f | path exists) $"($f) still there after --check" }
		assert (not (open --raw ($dir | path join systemctl.log) | str contains "disable"))
		# apply disables and stops the timer, removes the files, reloads systemd.
		let applied = (apply (defaults) --root $root)
		assert equal ($applied | length) 4
		for f in $heal_files { assert (not ($root + $f | path exists)) $"($f) removed" }
		let log = (open --raw ($dir | path join systemctl.log))
		assert str contains $log "disable --now pronto-dapr-heal.timer"
		assert str contains $log "daemon-reload"
		# The cleanup's files are the host's and stay; a second run finds nothing.
		assert ($root + "/etc/pronto/docker-gc.env" | path exists)
		assert equal (apply (defaults) --root $root) []
	}
}

def test_removal_keeps_the_files_unless_systemd_says_the_timer_is_stopped [] {
	print "test removing daprHeal keeps its files when the timer is still running or its state cannot be read, and the next apply finds the drift again..."
	let heal_files = ["/etc/pronto/dapr-heal.env" "/usr/local/lib/pronto/dapr-heal.sh" "/etc/systemd/system/pronto-dapr-heal.service" "/etc/systemd/system/pronto-dapr-heal.timer"]
	for case in [[KEEPON "1" "still"] [UNREADABLE "1" "unreadable"]] {
		let dir = (tmp)
		fake-systemctl $dir
		let root = ($dir | path join root)
		with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')"} {
			apply (with-heal) --root $root | ignore
			let failed = (try { with-env {($case.0): $case.1} { apply (defaults) --root $root }; "applied" } catch {|e| $e.msg })
			assert str contains $failed $case.2 $"removal must fail: ($failed)"
			for f in $heal_files { assert ($root + $f | path exists) $"($f) kept when removal failed ($case.2)" }
			# A later apply, with systemd answering, finishes it.
			assert equal (apply (defaults) --root $root | length) 4
			for f in $heal_files { assert (not ($root + $f | path exists)) $"($f) removed on the retry" }
		}
	}
}
