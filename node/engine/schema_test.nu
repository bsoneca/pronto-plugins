#!/usr/bin/env nu
# Run with: nu node/engine/schema_test.nu   (needs `cue`, no registry)
#
# schema/node.cue: the cases of tests/ hold (`cue vet -c`), and the renders and releases the engine
# refuses (tests/refused/) are refused, with the reason in CUE's error.

const engine_dir = path self .

use std/assert

def --wrapped cue-in [...args: string]: nothing -> record {
	do { cd ($engine_dir | path join ../..); ^cue ...$args } | complete
}

def main [] {
	print "Running node schema tests...\n"
	test_cases_hold
	test_a_clean_render_passes
	test_an_unserved_kind_is_refused
	test_an_operator_nobody_looked_at_is_refused
	test_an_app_named_otherwise_is_refused
	test_retiring_what_holds_state_is_refused
	test_ssh_must_be_user_at_host
	test_a_preview_cannot_take_the_production_host
	test_a_service_is_only_what_it_says
	test_an_origin_must_be_https
	print "\nAll node schema tests passed."
}

def test_an_origin_must_be_https [] {
	print "test a release's origin that is not https is refused..."
	assert ((refused plainOrigin) | str contains "origin")
}

def refused [expr: string]: nothing -> string {
	let r = (cue-in export ./node/engine/tests/refused -e $expr --out json)
	assert ($r.exit_code != 0) $"($expr) was not refused"
	$r.stderr
}

def test_cases_hold [] {
	print "test every case of tests/ holds..."
	let r = (cue-in vet -c ./node/engine/tests)
	assert equal $r.exit_code 0 $r.stderr
}

def test_a_clean_render_passes [] {
	print "test a render with nothing wrong exports its objects..."
	let r = (cue-in export ./node/engine/tests/refused -e clean --out json)
	assert equal $r.exit_code 0 $r.stderr
	assert equal ($r.stdout | from json | length) 1
}

def test_an_unserved_kind_is_refused [] {
	print "test a kind no operator serves refuses the render, saying which..."
	assert ((refused unserved) | str contains "acme.io/v1 Widget/w is not served by the node's operators")
}

def test_an_operator_nobody_looked_at_is_refused [] {
	print "test an operator version without its row in #Served refuses the render..."
	assert ((refused unlookedOperator) | str contains "1.99.0")
}

def test_an_app_named_otherwise_is_refused [] {
	print "test an App whose name is not the release's refuses the render..."
	assert ((refused otherApp) | str contains "the app is named other, the release app")
}

def test_retiring_what_holds_state_is_refused [] {
	print "test retire refuses state, credentials, archives, aliases, cluster-wide kinds and option-like names..."
	for e in [retireCluster retirePVC retireAlias retireNamespace retireExternalSecret retireObjectStore retireScheduled retireClusterRole retireFlagName] {
		assert ((refused $e) | str contains "retire") $e
	}
}

def test_ssh_must_be_user_at_host [] {
	print "test api.ssh is user@host, never an option or a bare host..."
	for e in [sshOption sshBareHost] { assert ((refused $e) | str contains "api.ssh") $e }
}

def test_a_preview_cannot_take_the_production_host [] {
	print "test a preview named production, or on production's host, is refused; one with its own host is not..."
	for e in [previewProduction previewOnProductionHost] {
		assert (refused $e | str contains "preview") $e
	}
	let ok = (cue-in export ./node/engine/tests/refused -e previewOwnHost --out json)
	assert equal $ok.exit_code 0 $ok.stderr
}

def test_a_service_is_only_what_it_says [] {
	print "test a service or the blob plane with a field the schema does not know, a reserved variable, a seed out of the app, a privileged port, a port of the sidecar's or a reserved name is refused..."
	for e in [serviceUnknownField serviceReservedEnv serviceSeedClimbs servicePrivilegedPort blobsUnknownField serviceDaprPort serviceMetricsDaprPort serviceSecretReserved serviceFilesDotDot serviceSeedAbsolute serviceNamedClock metricsExportUnknown] {
		let r = (cue-in export ./node/engine/tests/refused -e $e --out json)
		assert ($r.exit_code != 0) $"($e) was not refused"
	}
}
