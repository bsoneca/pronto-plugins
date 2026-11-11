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
for f in [oidc.ts main.ts core.ts phone.ts otp.ts door.ts] { assert ($f in ($files | columns)) $"($f) is mounted" }
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
# --airlock (PRONTO-268, flag signin_door): Google's token exchange through the airlock's door beside the
# broker. The broker names no client secret and reaches the door; the airlock holds the credential
# (client_secret_basic), reached by the broker alone.
let locked = (metal manifests --domain id.example.com --sources (metal sources) --settings [{name: "GOOGLE_CLIENT_ID", value: "c"}] --airlock | split row "---\n" | each { from yaml })
let at = {|k, n| $locked | where kind == $k and metadata.name == $n | first }
assert equal ($locked | get kind) [Namespace ConfigMap Deployment Service Gateway HTTPRoute NetworkPolicy ConfigMap ConfigMap PersistentVolumeClaim Deployment Service NetworkPolicy]
let broker = ((do $at Deployment identity-broker).spec.template.spec.containers | first)
assert equal ($broker.env | where name == GOOGLE_CLIENT_SECRET | length) 0 "the broker holds no client secret"
assert equal ($broker.env | where name == BROKER_SECRET | length) 1
assert equal ($broker.env | where name == GOOGLE_DOOR | first).value "http://identity-broker-airlock:9998"
assert equal ($broker.env | where name == GOOGLE_DOOR_ASKED | length) 0 "not asked without --door-asked"
let lock = (do $at Deployment identity-broker-airlock).spec.template.spec
let air = ($lock.containers | where name == airlock | first)
assert equal ($air.env | where valueFrom? != null | get name) [GOOGLE_CLIENT_BASIC]
assert equal ($air.env | where name == GOOGLE_CLIENT_BASIC | first).valueFrom.secretKeyRef {name: "identity-broker", key: GOOGLE_CLIENT_BASIC}
let manifest = ((do $at ConfigMap identity-broker-airlock-effects).data."effects.json" | from json)
assert equal ($manifest.doors | columns) [google]
assert equal $manifest.doors.google {idempotent: true, credential: {header: Authorization, scheme: Basic, secret: GOOGLE_CLIENT_BASIC}, headers: [], callers: [identity-broker]}
let dapr = (do $at ConfigMap identity-broker-airlock-dapr).data
assert equal ($dapr."google.yaml" | from yaml).spec.baseUrl "https://oauth2.googleapis.com"
# The door from the broker alone; the broker's own way to it.
let lockpol = (do $at NetworkPolicy identity-broker-airlock).spec
assert equal $lockpol.ingress [{from: [{podSelector: {matchLabels: {"app.kubernetes.io/name": "identity-broker", "app.kubernetes.io/part-of": "pronto-identity"}}}], ports: [{protocol: TCP, port: 9998}]}]
assert equal ((do $at NetworkPolicy identity-broker).spec.egress | where to? != null | get to | flatten | where podSelector? != null | first).podSelector.matchLabels."app.kubernetes.io/name" "identity-broker-airlock"
# --door-asked: while each tenant's flag moves it, the broker keeps its secret beside the door.
let moving = (metal manifests --domain id.example.com --sources (metal sources) --settings [] --airlock --door-asked | split row "---\n" | each { from yaml })
let mb = (($moving | where kind == Deployment and metadata.name == identity-broker | first).spec.template.spec.containers | first)
assert equal ($mb.env | where name == GOOGLE_DOOR_ASKED | first).value "1"
assert equal ($mb.env | where name == GOOGLE_DOOR | first).value "http://identity-broker-airlock:9998"
assert equal ($mb.env | where name == GOOGLE_CLIENT_SECRET | length) 1 "the broker keeps its secret while the flag moves it"
assert equal ($mb.env | where name == GOOGLE_CLIENT_BASIC | length) 0 "the credential is the airlock's alone"
assert (try { metal manifests --domain id.example.com --sources (metal sources) --door-asked; false } catch { true }) "--door-asked needs --airlock"
assert equal ($c.env | where name == GOOGLE_DOOR | length) 0 "no door unless asked"
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
