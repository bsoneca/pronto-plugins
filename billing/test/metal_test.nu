# The broker's objects on a metal cluster (billing/metal.nu manifests), from this checkout's files:
#   ./saytw --script tools.nu nu billing/test/metal_test.nu
use std/assert
use ../metal.nu

let secrets = [BROKER_SECRET BILLING_SIGNING_KEY STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET]
let docs = (metal manifests --domain billing.example.com --sources (metal sources) --settings [{name: "BILLING_FEE_PERCENT", value: "0"}] --secrets $secrets | split row "---\n" | each { from yaml })
let kind = {|k| $docs | where kind == $k | first }
# The airlock is always beside the broker (PRONTO-270): no flag asks for it.
assert equal ($docs | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy Password ExternalSecret Cluster NetworkPolicy ConfigMap ConfigMap PersistentVolumeClaim Deployment Service NetworkPolicy]
assert equal ($docs | get metadata.namespace? | compact | uniq) [billing]

# Every file the broker imports is mounted where its import finds it, and nothing outside is fetched.
let files = (do $kind ConfigMap).data
for f in [shared.ts rules.ts main.ts core.ts stripe.ts door.ts fake.ts store.ts postgres.js] { assert ($f in ($files | columns)) $"($f) is mounted" }
for f in ($files | values) { assert ($f | lines | where {|l| $l =~ '^import .* from "(https?|npm|jsr):' } | is-empty) "a mounted file imports from outside" }
let pod = (do $kind Deployment).spec.template.spec
let mount = (($pod.containers | first).volumeMounts | where name == files | first).mountPath
let items = ($pod.volumes | where name == files | first).configMap.items
assert equal $"($mount)/(($items | where key == "main.ts" | first).path)" "/app/billing/broker/main.ts" "main.ts where the container runs it"
assert equal $"($mount)/(($items | where key == "shared.ts" | first).path)" "/app/billing/shared.ts" "shared.ts where ../shared.ts finds it"
assert ("/app/billing/broker/main.ts" in ($pod.containers | first).args)

# One pod for now, replaced rather than overlapped until the scaling change; what it keeps is in its
# own database, which it reads by the URL of the login generated in the cluster (PRONTO-371).
let dep = (do $kind Deployment)
assert equal $dep.spec.replicas 1
assert equal $dep.spec.strategy.type Recreate
let c = ($pod.containers | first)
assert equal ($c.env | where name == DATABASE_URL | first).valueFrom.secretKeyRef {name: "billing-broker-db", key: "url"}
let cluster = (do $kind Cluster)
assert equal [$cluster.metadata.name $cluster.spec.instances $cluster.spec.bootstrap.initdb.owner $cluster.spec.bootstrap.initdb.secret.name] [billing-broker-db 1 billing billing-broker-db]
let login = (do $kind ExternalSecret)
assert equal $login.spec.target.template.type "kubernetes.io/basic-auth"
assert equal $login.spec.target.template.data.url "postgres://billing:{{ .password }}@billing-broker-db-rw.billing.svc:5432/billing?sslmode=disable"
# Only the broker (and the operator, and its own instances) reaches the database; the broker reaches it by 5432.
let db_policy = ($docs | where kind == NetworkPolicy and metadata.name == billing-broker-db | first)
assert equal ($db_policy.spec.ingress | first).from [{podSelector: {matchLabels: {"app.kubernetes.io/name": "billing-broker", "app.kubernetes.io/part-of": "pronto-billing"}}}]
assert equal $db_policy.spec.policyTypes [Ingress]
# What the release brings up before it replaces the broker: the database alone.
let only_db = (metal manifests --database-only --domain billing.example.com --sources (metal sources) | split row "---\n" | each { from yaml })
assert equal ($only_db | get kind) [Namespace Password ExternalSecret Cluster NetworkPolicy]
assert equal ($c.env | where name == BROKER_ISSUER | first).value "https://billing.example.com"
assert equal ($c.env | where name == BILLING_FEE_PERCENT | first).value "0"
for v in ($secrets | where $it != STRIPE_SECRET_KEY) { assert equal ($c.env | where name == $v | first).valueFrom.secretKeyRef {name: "billing-broker", key: $v} }
assert equal ($c.env | where name =~ "^STRIPE_(SANDBOX_)?SECRET_KEY$" | length) 0 "the broker holds no Stripe key, with no flag asked"
assert equal ($c.env | where name == STRIPE_DOOR | first).value "http://billing-broker-airlock:9998"
assert equal (($docs | where kind == Deployment and metadata.name == billing-broker-airlock | first).spec.template.spec.containers | where name == airlock | first | get env | where valueFrom? != null | get name) [STRIPE_SECRET_KEY]
assert equal ($c.env | where name == STRIPE_SANDBOX_SECRET_KEY | length) 0 "no sandbox unless asked"
assert equal $c.startupProbe.httpGet.path "/health"

# A new file is a new pod.
let other = (metal manifests --domain billing.example.com --sources ((metal sources) | merge {"core.ts": "// changed\n"}) | split row "---\n" | each { from yaml } | where kind == Deployment | first)
assert not equal $other.spec.template.metadata.annotations $dep.spec.template.metadata.annotations

# Routed by its host alone, and let out only to DNS and public HTTPS.
assert equal (do $kind HTTPRoute).spec.hostnames ["billing.example.com"]
assert equal ((do $kind Gateway).spec.listeners | first).hostname "billing.example.com"
let egress = (do $kind NetworkPolicy).spec.egress
assert equal ($egress | get ports | flatten | get port | uniq | sort) [53 443 5432 9998]
assert equal (($egress | where {|e| $e.to? != null and ("ipBlock" in ($e.to | first | columns)) } | first).to | first).ipBlock.except ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]

# Stripe through the airlock's door beside the broker (PRONTO-135, the only way since PRONTO-270). The
# broker names no Stripe key and reaches the door; the airlock holds the keys, reached by the broker alone.
let sandboxed = ($secrets ++ [STRIPE_SANDBOX_SECRET_KEY STRIPE_SANDBOX_WEBHOOK_SECRET])
let locked = (metal manifests --domain billing.example.com --sources (metal sources) --settings [{name: "BILLING_FEE_PERCENT", value: "0"} {name: "BILLING_SANDBOX_TENANTS", value: "^https://pr-"}] --secrets $sandboxed | split row "---\n" | each { from yaml })
let at = {|k, n| $locked | where kind == $k and metadata.name == $n | first }
assert equal ($locked | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy Password ExternalSecret Cluster NetworkPolicy ConfigMap ConfigMap PersistentVolumeClaim Deployment Service NetworkPolicy]
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
assert equal ((do $at NetworkPolicy billing-broker).spec.egress | where to? != null | get to | flatten | where podSelector? != null | get podSelector.matchLabels | each { values | first }) [billing-broker-db billing-broker-airlock] "the broker reaches its database and its door, no other pod"
print "metal_test: ok"

# --door-asked (PRONTO-218): while each tenant's flag moves it, the broker keeps its keys beside the
# door; the airlock holds them as well.
let moving = (metal manifests --domain billing.example.com --sources (metal sources) --settings [] --secrets $sandboxed --door-asked | split row "---\n" | each { from yaml })
let mb = (($moving | where kind == Deployment and metadata.name == billing-broker | first).spec.template.spec.containers | first)
assert equal ($mb.env | where name =~ "^STRIPE_(SANDBOX_)?SECRET_KEY$" | get name) [STRIPE_SECRET_KEY STRIPE_SANDBOX_SECRET_KEY] "the broker keeps its keys while the flag moves it"
assert equal ($mb.env | where name == STRIPE_DOOR_ASKED | first).value "1"
assert equal ($mb.env | where name == STRIPE_DOOR | first).value "http://billing-broker-airlock:9998"
let ma = (($moving | where kind == Deployment and metadata.name == billing-broker-airlock | first).spec.template.spec.containers | where name == airlock | first)
assert equal ($ma.env | where valueFrom? != null | get name) [STRIPE_SECRET_KEY STRIPE_SANDBOX_SECRET_KEY]
assert equal ($dep.spec.template.spec.containers | first | get env | where name == STRIPE_DOOR_ASKED | length) 0 "not asked without --door-asked"
assert (try { metal manifests --domain billing.example.com --sources (metal sources) --door-asked; false } catch { true }) "--door-asked needs a Stripe key to move"
# No flag turns the airlock off.
let flags = {|cmd| (scope commands | where name == $cmd | first).signatures | values | flatten | get parameter_name | compact }
for cmd in ["metal manifests" "metal"] {
	assert ("door-asked" in (do $flags $cmd)) $"($cmd) is the command read"
	assert ("airlock" not-in (do $flags $cmd)) $"($cmd) has no --airlock"
}
# Secrets with no Stripe key: the airlock still beside it, holding nothing, and the broker no door.
let keyless = (metal manifests --domain billing.example.com --sources (metal sources) --secrets [BROKER_SECRET BILLING_SIGNING_KEY] | split row "---\n" | each { from yaml })
assert equal ($keyless | where kind == Deployment | get metadata.name) [billing-broker billing-broker-airlock]
assert equal (($keyless | where kind == Deployment and metadata.name == billing-broker | first).spec.template.spec.containers | first | get env | where name == STRIPE_DOOR | length) 0
print "metal_test: door-asked ok"
