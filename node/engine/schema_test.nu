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
	test_retiring_a_cluster_is_refused
	print "\nAll node schema tests passed."
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

def test_retiring_a_cluster_is_refused [] {
	print "test retire may not name a Cluster..."
	assert ((refused retireCluster) | str contains "retire")
}
