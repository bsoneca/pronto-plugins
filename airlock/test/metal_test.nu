# An app's airlock on a metal cluster (airlock/metal.nu manifests), from a spec shaped as Studio's
# model doors (PRONTO-271): ./saytw --script tools.nu nu airlock/test/metal_test.nu
use std/assert
use ../metal.nu

let builder = {podSelector: {matchLabels: {"app.kubernetes.io/name": studio, "app.kubernetes.io/component": builder}}}
let gateway = {to: [{podSelector: {matchLabels: {"app.kubernetes.io/name": pronto-llm}}}], ports: [{protocol: TCP, port: 4000}]}
let chatgpt = {to: [{podSelector: {matchLabels: {"app.kubernetes.io/name": pronto-llm-chatgpt}}}], ports: [{protocol: TCP, port: 4000}]}
let spec = {
	namespace: pronto-llm, name: studio-model-airlock, caller: builder, partOf: pronto-llm
	from: [({namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": studio}}} | merge $builder) ({namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": studio-rc}}} | merge {podSelector: {matchLabels: {"app.kubernetes.io/name": studio-rc, "app.kubernetes.io/component": builder}}})]
	doors: [
		{door: model, base: "http://pronto-llm.pronto-llm.svc:4000", headers: [Anthropic-Version Anthropic-Beta {name: X-Api-Key, hidden: true}], timeoutMs: 300000, egress: [$gateway]}
		{door: model-chatgpt, base: "http://pronto-llm-chatgpt.pronto-llm.svc:4000", var: LLM_CHATGPT_KEY, secret: {name: pronto-llm-chatgpt, key: LITELLM_MASTER_KEY}, headers: [Anthropic-Version Anthropic-Beta], timeoutMs: 300000, egress: [$chatgpt]}
	]
}
let docs = (metal manifests $spec | split row "---\n" | each { from yaml })
let at = {|k, n| $docs | where kind == $k and metadata.name == $n | first }
assert equal ($docs | get kind) [ConfigMap ConfigMap PersistentVolumeClaim Deployment Service NetworkPolicy]
assert equal ($docs | get metadata.namespace | uniq) [pronto-llm]

# The doors as the airlock reads them: model holds no credential (the person's key, hidden, is the
# gateway's), model-chatgpt the ChatGPT gateway's key; both wait five minutes.
let manifest = ((do $at ConfigMap studio-model-airlock-effects).data."effects.json" | from json)
assert equal ($manifest.doors | columns) [model model-chatgpt]
assert equal $manifest.doors.model {idempotent: true, headers: [Anthropic-Version Anthropic-Beta {name: X-Api-Key, hidden: true}], callers: [builder], timeoutMs: 300000}
assert equal $manifest.doors.model-chatgpt.credential {header: Authorization, scheme: Bearer, secret: LLM_CHATGPT_KEY}
assert equal $manifest.doors.model-chatgpt.timeoutMs 300000

# The credential from the Secret its owner wrote, under the airlock's own variable; no other key.
let air = ((do $at Deployment studio-model-airlock).spec.template.spec.containers | where name == airlock | first)
assert equal ($air.env | where valueFrom? != null) [{name: LLM_CHATGPT_KEY, valueFrom: {secretKeyRef: {name: pronto-llm-chatgpt, key: LITELLM_MASTER_KEY}}}]

# daprd: an endpoint per door at its gateway, the wall admitting those two alone, and each door's
# timeout as long as the door's.
let dapr = (do $at ConfigMap studio-model-airlock-dapr).data
assert equal ($dapr."model.yaml" | from yaml).spec.baseUrl "http://pronto-llm.pronto-llm.svc:4000"
assert equal ($dapr."model-chatgpt.yaml" | from yaml).spec.baseUrl "http://pronto-llm-chatgpt.pronto-llm.svc:4000"
assert (($dapr."wall.yaml" | from yaml).spec.metadata.0.value | str contains "invoke/(model|model-chatgpt)/method/")
let res = ($dapr."resiliency.yaml" | from yaml).spec
assert equal $res.policies.timeouts {model: "300s", model-chatgpt: "300s"}
assert equal $res.targets.apps.model {circuitBreaker: sink, timeout: model}

# In from Studio's builders alone (studio and studio-rc); out to DNS and the two gateways, no public HTTPS.
let pol = (do $at NetworkPolicy studio-model-airlock).spec
assert equal ($pol.ingress | first).from $spec.from
assert equal (($pol.ingress | first).ports | first).port 9998
assert equal ($pol.egress | skip 1) [$gateway $chatgpt]
assert equal ($pol.egress | where {|e| ($e.to? | default [] | any {|t| $t.ipBlock? != null }) } | length) 0 "no way out but the gateways"

# A spec that cannot be released is refused before anything is applied.
let refused = {|s| try { metal manifests $s; false } catch { true } }
assert (do $refused ($spec | update doors []))
assert (do $refused ($spec | update from []))
assert (do $refused ($spec | update doors {|s| $s.doors | each {|d| $d | upsert timeoutMs 700000 } }))
assert (do $refused ($spec | update doors {|s| $s.doors | each {|d| $d | upsert timeoutMs 1500 } }))
assert (do $refused ($spec | update doors {|s| $s.doors | each {|d| $d | upsert base "http://x.svc:4000/v1" } }))
assert (do $refused ($spec | update doors {|s| [($s.doors.1 | reject secret)] }))
assert (do $refused ($spec | update doors {|s| [$s.doors.0 $s.doors.0] }))
print "airlock metal_test: ok"
