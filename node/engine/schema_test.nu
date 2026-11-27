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
	test_jail_google_and_egress_are_studios_builders_alone
	test_the_release_rule_is_written_only_when_asked
	test_a_tenant_release_writes_only_what_its_publisher_may
	print "\nAll node schema tests passed."
}

def test_an_origin_must_be_https [] {
	print "test a release's origin that is not https is refused..."
	assert ((refused plainOrigin) | str contains "origin")
}

def test_jail_google_and_egress_are_studios_builders_alone [] {
	print "test a tenant app that sets jail, google or egress on a service is refused with the reason, as is a service of Studio's other than the builder, and Studio's builder passes..."
	for e in [tenantJail tenantGoogle tenantEgress] {
		let r = (refused $e)
		assert ($r | str contains "which only Studio's builder (app studio, service builder) may (PRONTO-1882)") $"($e): ($r)"
		assert ($r | str contains "service builder of app sets") $"($e): ($r)"
	}
	for e in [studioOtherServiceJail studioOtherServiceGoogle studioOtherServiceEgress] {
		assert ((refused $e) | str contains "service billing of studio sets jail, google or egress") $e
	}
	# Studio's builder is not refused for it: the render here has no pushed images, so its one violation is the unpinned image
	# (a render with them is tests/services.cue's, which holds that its violations are none)
	let ok = (cue-in export ./node/engine/tests/refused -e studioBuilder --out json)
	assert ($ok.stderr | str contains "is not pinned by digest") $ok.stderr
	assert (not ($ok.stderr | str contains "PRONTO-1882")) $ok.stderr
}

def test_the_release_rule_is_written_only_when_asked [] {
	print "test the engine's files carry the release rule in .say.json only with the releaseRule tag, and a regeneration without it leaves an app's .say.json alone..."
	let plain = (cue-in export ./node/engine/export -e files --out json)
	assert equal $plain.exit_code 0 $plain.stderr
	assert (".say.json" not-in ($plain.stdout | from json | columns)) "no .say.json without the flag"
	assert ("node/release.nu" in ($plain.stdout | from json | columns)) "the engine's files are written all the same"
	let ruled = (cue-in export -t releaseRule=true ./node/engine/export -e files --out json)
	assert equal $ruled.exit_code 0 $ruled.stderr
	let say = (($ruled.stdout | from json | get ".say.json").text | from json)
	assert equal ($say.say.release.rulemap | columns) ["node-engine"]
	assert equal $say.say.release.rulemap."node-engine".platform "k8s"
	# write.nu over an app that holds the rule, from the files without the flag: .say.json is not touched
	let app = (mktemp -d -t node-rule.XXXXXX | str trim | path expand)
	let held = '{"say":{"release":{"rulemap":{"node-engine":{"platform":"k8s","priority":-1,"stop":true,"cmds":[{"do":"kept"}]}}}}}\n'
	$held | save -f ($app | path join .say.json)
	$plain.stdout | save -f ($app | path join plain.json)
	let w = (do { cd ($engine_dir | path join ../..); ^$nu.current-exe --no-config-file bin/write.nu ($app | path join plain.json) $app } | complete)
	assert equal $w.exit_code 0 $w.stderr
	assert equal (open --raw ($app | path join .say.json)) $held "an app that holds the rule keeps it"
	rm -rf $app
}

def test_a_tenant_release_writes_only_what_its_publisher_may [] {
	print "test a tenant's release (a namespace's publisher) is refused for a preview, backups, a policy, a clock, a blob plane, a kind or a gateway its Role does not cover, an image outside its path and an origin that is not its host, and a clean one passes..."
	let ok = (cue-in export ./node/engine/tests/refused -e tenantClean --out json)
	assert equal $ok.exit_code 0 $ok.stderr
	let kinds = ($ok.stdout | from json | get kind)
	assert ("Namespace" not-in $kinds) "no Namespace"
	assert ("NetworkPolicy" not-in $kinds) "no NetworkPolicy"
	for row in [
		[tenantPreview "is never a preview"]
		[tenantClusterNoBase "has no approved database base pushed"]
		[tenantLoginRole "database.logins.reader is a member of pg_read_server_files"]
		[tenantBackups "a tenant's release writes no backups"]
		[tenantCeilingEgress "a tenant's release writes no NetworkPolicy"]
		[tenantStudioBuilderJail "which only Studio's builder"]
		[tenantClock "sets clock, a CronJob its publisher may not write"]
		[tenantBlobs "runs no blob plane"]
		[tenantRetireNetworkPolicy "which a tenant's publisher may not delete"]
		[tenantRetireServiceAccount "which a tenant's publisher may not delete"]
		[tenantGatewayHTTPS "a tenant's gateway listens on 80/HTTP alone"]
		[tenantUnservedKind "is not a kind a tenant's publisher writes"]
		[tenantExternalImage "is not in 127.0.0.1:5000/studio-owner-game-1a2b3c4d"]
		[tenantOrigin "a tenant's origin is https://game-game.example.com"]
	] {
		let r = (refused $row.0)
		assert ($r | str contains $row.1) $"($row.0): ($r)"
	}
	# the schema's own conflicts: the operator's buildkitd and registry, the system's namespaces, a namespace with no host
	for e in [tenantBuildkitOperator tenantBuildkitOperatorSvc tenantRegistryMoved tenantNamespaceKube tenantNamespaceRegistry tenantNamespaceDefault tenantHostMissing] {
		let r = (cue-in export ./node/engine/tests/refused -e $e --out json)
		assert ($r.exit_code != 0) $"($e) was not refused"
	}
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
	for e in [serviceUnknownField serviceScratchClimbs serviceScratchSize serviceEgressNoPort serviceEgressBadCIDR serviceEgressBoth serviceEgressNeither serviceEgressNamespace serviceEgressNoLabels serviceEgressExceptNs serviceGoogleProvider serviceJailNotBool serviceReservedEnv serviceSeedClimbs servicePrivilegedPort blobsUnknownField serviceDaprPort serviceMetricsDaprPort serviceSecretReserved serviceFilesDotDot serviceSeedAbsolute serviceNamedClock metricsExportUnknown] {
		let r = (cue-in export ./node/engine/tests/refused -e $e --out json)
		assert ($r.exit_code != 0) $"($e) was not refused"
	}
}
