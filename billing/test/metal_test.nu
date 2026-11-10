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

# --airlock (PRONTO-135): Stripe through the airlock's door beside the broker. The broker names no
# Stripe key and reaches the door; the airlock holds the key, reached by the broker alone.
let sandboxed = ($secrets ++ [STRIPE_SANDBOX_SECRET_KEY STRIPE_SANDBOX_WEBHOOK_SECRET])
let locked = (metal manifests --domain billing.example.com --sources (metal sources) --settings [{name: "BILLING_FEE_PERCENT", value: "0"} {name: "BILLING_SANDBOX_TENANTS", value: "^https://pr-"}] --secrets $sandboxed --airlock | split row "---\n" | each { from yaml })
let at = {|k, n| $locked | where kind == $k and metadata.name == $n | first }
assert equal ($locked | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy ConfigMap ConfigMap PersistentVolumeClaim Deployment Service NetworkPolicy]
let broker = ((do $at Deployment billing-broker).spec.template.spec.containers | first)
assert equal ($broker.env | where name =~ "^STRIPE_(SANDBOX_)?SECRET_KEY$" | length) 0 "the broker holds no Stripe key"
assert equal ($broker.env | where name == STRIPE_DOOR | first).value "http://billing-broker-airlock:9998"
assert equal ($broker.env | where name == STRIPE_WEBHOOK_SECRET | length) 1 "a webhook is the broker's to check"
let lock = (do $at Deployment billing-broker-airlock).spec.template.spec
let air = ($lock.containers | where name == airlock | first)
assert equal ($air.env | where valueFrom? != null | get name) [STRIPE_SECRET_KEY STRIPE_SANDBOX_SECRET_KEY]
assert equal ($air.env | where name == STRIPE_SECRET_KEY | first).valueFrom.secretKeyRef {name: "billing-broker", key: STRIPE_SECRET_KEY}
let manifest = ((do $at ConfigMap billing-broker-airlock-effects).data."effects.json" | from json)
assert equal ($manifest.doors | columns) [stripe stripe-sandbox]
assert equal $manifest.doors.stripe {idempotent: true, credential: {header: Authorization, scheme: Bearer, secret: STRIPE_SECRET_KEY}, headers: [Stripe-Version], callers: [billing-broker]}
let dapr = (do $at ConfigMap billing-broker-airlock-dapr).data
assert equal ($dapr."stripe.yaml" | from yaml).spec.baseUrl "https://api.stripe.com"
assert (($dapr."wall.yaml" | from yaml).spec.metadata.0.value | str contains "invoke/(stripe|stripe-sandbox)/method/")
# The door from the broker alone; the broker's own way to it.
let lockpol = (do $at NetworkPolicy billing-broker-airlock).spec
assert equal ($lockpol.ingress | first).from [{podSelector: {matchLabels: {"app.kubernetes.io/name": billing-broker, "app.kubernetes.io/part-of": pronto-billing}}}]
assert equal (($lockpol.ingress | first).ports | first).port 9998
assert equal ((do $at NetworkPolicy billing-broker).spec.egress | where to? != null | get to | flatten | where podSelector? != null | length) 1
print "metal_test: ok"

# --door-asked (PRONTO-218): while each tenant's flag moves it, the broker keeps its keys beside the
# door; the airlock holds them as well.
let moving = (metal manifests --domain billing.example.com --sources (metal sources) --settings [] --secrets $sandboxed --airlock --door-asked | split row "---\n" | each { from yaml })
let mb = (($moving | where kind == Deployment and metadata.name == billing-broker | first).spec.template.spec.containers | first)
assert equal ($mb.env | where name =~ "^STRIPE_(SANDBOX_)?SECRET_KEY$" | get name) [STRIPE_SECRET_KEY STRIPE_SANDBOX_SECRET_KEY] "the broker keeps its keys while the flag moves it"
assert equal ($mb.env | where name == STRIPE_DOOR_ASKED | first).value "1"
assert equal ($mb.env | where name == STRIPE_DOOR | first).value "http://billing-broker-airlock:9998"
let ma = (($moving | where kind == Deployment and metadata.name == billing-broker-airlock | first).spec.template.spec.containers | where name == airlock | first)
assert equal ($ma.env | where valueFrom? != null | get name) [STRIPE_SECRET_KEY STRIPE_SANDBOX_SECRET_KEY]
assert equal ($dep.spec.template.spec.containers | first | get env | where name == STRIPE_DOOR_ASKED | length) 0 "not asked without --door-asked"
assert (try { metal manifests --domain billing.example.com --sources (metal sources) --door-asked; false } catch { true }) "--door-asked needs --airlock"
