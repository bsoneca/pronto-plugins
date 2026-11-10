# Grafana's and Umami's objects on a metal cluster (analytics/metal.nu manifests):
#   ./saytw --script tools.nu nu analytics/test/metal_test.nu
use std/assert
use ../metal.nu

let dashes = [{app: "bonk-chess", name: "business", folder: "Bonk Chess", text: "{\"uid\": \"b\"}"} {app: "ume", name: "journeys", folder: "Ume", text: "{}"}]
let users = {"b@example.com": "Viewer", "a@example.com": "Admin"}
let docs = (metal manifests --grafana-domain metrics.example.com --umami-domain umami.example.com --users $users --dashboards $dashes | split row "---\n" | each { from yaml })
let named = {|k, n| $docs | where kind == $k and metadata.name == $n | first }
assert equal ($docs | get metadata.namespace? | compact | uniq) [analytics]

# Each login's password is generated in the namespace, and its Secret is what the operator and Umami read.
let cluster = (do $named Cluster analytics-db)
assert equal ($cluster.spec.managed.roles | get name) [grafana umami]
assert equal ($cluster.spec.managed.roles | get passwordSecret.name) [grafana-db umami-db]
assert equal $cluster.spec.bootstrap.initdb {database: grafana, owner: grafana, secret: {name: grafana-db}}
assert equal (do $named Database umami).spec {name: umami, owner: umami, cluster: {name: analytics-db}}
let es = (do $named ExternalSecret umami-db)
assert equal $es.spec.target.template.type "kubernetes.io/basic-auth"
assert equal $es.spec.target.template.data.url "postgresql://umami:{{ .password }}@analytics-db-rw.analytics.svc:5432/umami?sslmode=disable"
assert equal $es.spec.dataFrom.0.sourceRef.generatorRef.name umami-db-password
assert equal ($docs | where kind == Password | get metadata.name | sort) [grafana-db-password umami-db-password]

# Grafana: the cluster's VictoriaMetrics, each dashboard under its app, and Google's sign-in for those named alone.
let prov = (do $named ConfigMap grafana-provisioning).data
assert equal ($prov."datasources.yaml" | from yaml).datasources.0.url "http://vmsingle.observability.svc.cluster.local:8428"
# The Google Managed Prometheus datasource Grafana's database brought from Cloud Run is removed (PRONTO-189).
assert equal ($prov."datasources.yaml" | from yaml).deleteDatasources [{name: "Google Managed Prometheus", orgId: 1}]
# The node's logs (PRONTO-158): VictoriaLogs through its plugin, which Grafana installs at start.
let vl = ($prov."datasources.yaml" | from yaml).datasources | where uid == "victorialogs" | first
assert equal [$vl.type $vl.url] ["victoriametrics-logs-datasource" "http://victoria-logs.logs.svc.cluster.local:9428"]
assert equal (($prov."dashboards.yaml" | from yaml).providers | select name folder) [[name folder]; [bonk-chess "Bonk Chess"] [ume Ume]]
assert equal (do $named ConfigMap grafana-dashboards-bonk-chess-business).data."business.json" "{\"uid\": \"b\"}"
let g = (do $named Deployment grafana).spec.template.spec
let ge = ($g.containers.0.env | reduce -f {} {|e, acc| $acc | merge {($e.name): (if "value" in $e { $e.value } else { $e.valueFrom })} })
assert equal $ge.GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH "(email=='a@example.com' && 'Admin') || (email=='b@example.com' && 'Viewer')"
assert equal $ge.GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_STRICT "true"
assert equal $ge.GF_AUTH_DISABLE_LOGIN_FORM "true"
assert equal $ge.GF_SECURITY_SECRET_KEY {secretKeyRef: {name: grafana, key: GF_SECURITY_SECRET_KEY}}
assert equal $ge.GF_DATABASE_PASSWORD {secretKeyRef: {name: grafana-db, key: password}}
assert ($g.containers.0.volumeMounts | any {|m| $m.mountPath == "/dashboards/ume/journeys.json" }) "a dashboard is where its provider reads"

# A changed dashboard is a new pod.
let other = (metal manifests --grafana-domain metrics.example.com --umami-domain umami.example.com --users $users --dashboards ($dashes | update 0.text "{}") | split row "---\n" | each { from yaml } | where kind == Deployment and metadata.name == grafana | first)
assert not equal ($other.spec.template.metadata.annotations."pronto.dev/config") ((do $named Deployment grafana).spec.template.metadata.annotations."pronto.dev/config")

# Umami: its database URL from the login's Secret, its app secret from the operator's.
let u = (do $named Deployment umami).spec.template.spec.containers.0.env
assert equal ($u | where name == DATABASE_URL | first).valueFrom.secretKeyRef {name: umami-db, key: url}
assert equal ($u | where name == APP_SECRET | first).valueFrom.secretKeyRef {name: umami, key: APP_SECRET}

# Each answers at its own host through the gateway.
assert equal (do $named HTTPRoute grafana).spec.hostnames [metrics.example.com]
assert equal (do $named Gateway umami).spec.listeners.0.hostname umami.example.com

# Umami reaches its database and nothing else; Grafana adds the metrics and Google's 443; the database
# admits its two clients and its operator.
let up = (do $named NetworkPolicy umami).spec.egress
assert equal ($up | get ports | flatten | get port | uniq | sort) [53 5432]
let gp = (do $named NetworkPolicy grafana).spec.egress
assert equal ($gp | get ports | flatten | get port | uniq | sort) [53 443 5432 8428 9428]
let dbp = (do $named NetworkPolicy analytics-db).spec.ingress
assert equal $dbp.0.from.0.podSelector.matchExpressions.0.values [grafana umami]

print "metal_test: ok"
