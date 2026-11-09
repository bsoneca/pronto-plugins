# The broker's objects on a metal cluster (billing/metal.nu manifests), from this checkout's files:
#   ./saytw --script tools.nu nu billing/test/metal_test.nu
use std/assert
use ../metal.nu

let secrets = [BROKER_SECRET BILLING_SIGNING_KEY STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET]
let docs = (metal manifests --domain billing.example.com --sources (metal sources) --settings [{name: "BILLING_FEE_PERCENT", value: "0"}] --secrets $secrets | split row "---\n" | each { from yaml })
let kind = {|k| $docs | where kind == $k | first }
assert equal ($docs | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy]
assert equal ($docs | get metadata.namespace? | compact | uniq) [billing]

# Every file the broker imports is mounted where its import finds it, and nothing outside is fetched.
let files = (do $kind ConfigMap).data
for f in [shared.ts main.ts core.ts stripe.ts fake.ts] { assert ($f in ($files | columns)) $"($f) is mounted" }
for f in ($files | values) { assert ($f | lines | where {|l| $l =~ '^import .* from "(https?|npm|jsr):' } | is-empty) "a mounted file imports from outside" }
let pod = (do $kind Deployment).spec.template.spec
let mount = (($pod.containers | first).volumeMounts | where name == files | first).mountPath
let items = ($pod.volumes | where name == files | first).configMap.items
assert equal $"($mount)/(($items | where key == "main.ts" | first).path)" "/app/billing/broker/main.ts" "main.ts where the container runs it"
assert equal $"($mount)/(($items | where key == "shared.ts" | first).path)" "/app/billing/shared.ts" "shared.ts where ../shared.ts finds it"
assert ("/app/billing/broker/main.ts" in ($pod.containers | first).args)

# One pod, replaced, never two: an entitlement's `ver` is its clock.
let dep = (do $kind Deployment)
assert equal $dep.spec.replicas 1
assert equal $dep.spec.strategy.type Recreate
let c = ($pod.containers | first)
assert equal ($c.env | where name == BROKER_ISSUER | first).value "https://billing.example.com"
assert equal ($c.env | where name == BILLING_FEE_PERCENT | first).value "0"
for v in $secrets { assert equal ($c.env | where name == $v | first).valueFrom.secretKeyRef {name: "billing-broker", key: $v} }
assert equal ($c.env | where name == STRIPE_SANDBOX_SECRET_KEY | length) 0 "no sandbox unless asked"
assert equal $c.startupProbe.httpGet.path "/health"

# A new file is a new pod.
let other = (metal manifests --domain billing.example.com --sources ((metal sources) | merge {"core.ts": "// changed\n"}) | split row "---\n" | each { from yaml } | where kind == Deployment | first)
assert not equal $other.spec.template.metadata.annotations $dep.spec.template.metadata.annotations

# Routed by its host alone, and let out only to DNS and public HTTPS.
assert equal (do $kind HTTPRoute).spec.hostnames ["billing.example.com"]
assert equal ((do $kind Gateway).spec.listeners | first).hostname "billing.example.com"
let egress = (do $kind NetworkPolicy).spec.egress
assert equal ($egress | get ports | flatten | get port | uniq | sort) [53 443]
assert equal (($egress | where to? != null | first).to | first).ipBlock.except ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]
print "metal_test: ok"
