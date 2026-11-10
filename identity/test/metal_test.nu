# The broker's objects on a metal cluster (identity/metal.nu manifests), from this checkout's files:
#   ./saytw --script tools.nu nu identity/test/metal_test.nu
use std/assert
use ../metal.nu

let docs = (metal manifests --domain id.example.com --sources (metal sources) --settings [{name: "GOOGLE_CLIENT_ID", value: "c"}] | split row "---\n" | each { from yaml })
let kind = {|k| $docs | where kind == $k | first }
assert equal ($docs | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy]
assert equal ($docs | get metadata.namespace? | compact | uniq) [identity]

# Every file the broker imports is mounted where its import finds it, and nothing outside is fetched.
let files = (do $kind ConfigMap).data
for f in [oidc.ts main.ts core.ts phone.ts otp.ts] { assert ($f in ($files | columns)) $"($f) is mounted" }
for f in ($files | values) { assert ($f | lines | where {|l| $l =~ '^import .* from "(https?|npm|jsr):' } | is-empty) "a mounted file imports from outside" }
let pod = (do $kind Deployment).spec.template.spec
let items = ($pod.volumes | where name == files | first).configMap.items
assert equal ($items | where key == "main.ts" | first).path "broker/main.ts"
assert equal ($items | where key == "oidc.ts" | first).path "oidc.ts"

# One pod, replaced, never two: a code one minted is unknown to another.
let dep = (do $kind Deployment)
assert equal $dep.spec.replicas 1
assert equal $dep.spec.strategy.type Recreate
let c = ($pod.containers | first)
assert equal ($c.env | where name == BROKER_ISSUER | first).value "https://id.example.com"
assert equal ($c.env | where name == BROKER_SECRET | first).valueFrom.secretKeyRef {name: "identity-broker", key: "BROKER_SECRET"}
assert equal ($c.env | where name == GOOGLE_CLIENT_ID | first).value "c"
assert equal $c.startupProbe.httpGet.path "/health"

# A new file is a new pod.
let other = (metal manifests --domain id.example.com --sources ((metal sources) | merge {"core.ts": "// changed\n"}) | split row "---\n" | each { from yaml } | where kind == Deployment | first)
assert not equal $other.spec.template.metadata.annotations $dep.spec.template.metadata.annotations

# Routed by its host alone, and let out only to DNS and public HTTPS.
assert equal (do $kind HTTPRoute).spec.hostnames ["id.example.com"]
assert equal ((do $kind Gateway).spec.listeners | first).hostname "id.example.com"
let egress = (do $kind NetworkPolicy).spec.egress
assert equal ($egress | get ports | flatten | get port | uniq | sort) [53 443]
assert equal (($egress | where to? != null | first).to | first).ipBlock.except ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]
print "metal_test: ok"

# --secrets: the SOPS file's manifests, held to the Secret the broker reads (common/sops.nu).
use ../../common/sops.nu
let plain = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: identity-broker\ntype: Opaque\ndata:\n  BROKER_SECRET: YQ==\n  GOOGLE_CLIENT_SECRET: Yg==\n"
let applied = ($plain | sops secret-manifests identity-broker identity [BROKER_SECRET GOOGLE_CLIENT_SECRET] | from yaml)
assert equal $applied.metadata {name: "identity-broker", namespace: "identity"}
assert equal ($applied.data | columns) [BROKER_SECRET GOOGLE_CLIENT_SECRET]
assert error { $plain | sops secret-manifests identity-broker identity [BROKER_SECRET OTHER] }
assert error { $plain | sops secret-manifests billing-broker identity [BROKER_SECRET] }
assert error { $"($plain)---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n" | sops secret-manifests identity-broker identity [BROKER_SECRET] }
let two = ($"($plain)---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: other\ndata:\n  K: YQ==\n" | sops secret-manifests identity-broker identity [BROKER_SECRET] | split row "---\n" | each { from yaml })
assert equal ($two | get metadata.namespace) [identity identity]
assert ((sops apply-command "kubectl" identity) =~ "--server-side --force-conflicts --field-manager=pronto-sops")
print "identity metal: --secrets"
