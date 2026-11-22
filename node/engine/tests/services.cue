package tests

import (
	"list"

	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// What a release's services, blob plane and metrics export are as objects, and what is refused of them (the fixture's
// upstream objects are upstream's shapes; the app's own are the engine's).

_pushedImages: {for s in ["crud", "billing", "flagd", "pulse", "writer", "collector", "analyst", "exporter", "notifier", "rclone-s3", "imgproxy"] {(s): {tag: "release", digest: "sha256:\(_d)"}}}

_withServices: {
	release:  {...}
	appExtra: {...}
	_m: schema.#Manifests & {
		app:       {name: "app", namespace: "app", image: pushed: _pushedImages} & appExtra
		"release": schema.#Release & _base & {hosts: rc: "rc.example.com"} & release
		upstream:  (_fixture & {ns: "app", host: "app.example.com", reg: "127.0.0.1:5000"}).objects
	}
	objects:    _m.objects
	violations: _m.violations
	named:      {for o in _m.objects {"\(o.kind)/\(o.metadata.name)": o}}
}

// a release at the limit of a name, which the cases above (named `app`) cannot reach
_named: {
	release: {...}
	_m: schema.#Manifests & {
		"release": schema.#Release & {name: "a-release-named-at-its-limit", context: "contabo2", api: ssh: "deploy@node.example", hosts: production: "app.example.com"} & release
		upstream:  []
	}
	violations: _m.violations
}

_flagd: {port: 8693, env: FLAGD_SOURCES: "x", files: "/etc/flags-live": "app-flags", seed: "app-flags": "flags/flags.json"}

cases: {
	"a service is a Deployment and a Service in the mesh, its image the one pushed, its environment the release's and its own": {
		_s:  (_withServices & {release: services: billing: {port: 8688, env: BILLING_BROKER: "https://b.example"}}).named
		_d1: _s["Deployment/app-billing"]
		_c:  _d1.spec.template.spec.containers[0]
		_got: {
			image:    _c.image
			replicas: _d1.spec.replicas
			strategy: _d1.spec.strategy != _|_
			app:      _d1.spec.template.metadata.annotations["dapr.io/app-id"]
			appPort:  _d1.spec.template.metadata.annotations["dapr.io/app-port"]
			config:   _d1.spec.template.metadata.annotations["dapr.io/config"]
			env:      [for e in _c.env {e.name}]
			origin:   [for e in _c.env if e.name == "ORIGIN" {e.value}]
			token:    [for e in _c.env if e.name == "SERVICE_JWT" {e.valueFrom.secretKeyRef}]
			selector: _d1.spec.selector.matchLabels
			service:  _s["Service/billing"].spec.ports
			pods:     _d1.spec.template.metadata.labels["app.kubernetes.io/component"]
		}
		_want: {
			image:    "127.0.0.1:5000/app-billing:release@sha256:\(_d)"
			replicas: 1
			strategy: false
			app:      "billing"
			appPort:  "8688"
			config:   "app-dapr-config"
			env:      ["BILLING_BROKER", "PORT", "ORIGIN", "SERVICE_JWT", "OTEL_DENO", "OTEL_SERVICE_NAME", "OTEL_EXPORTER_OTLP_ENDPOINT"]
			origin:   ["https://app.example.com"]
			token:    [{name: "app-service-token", key: "SERVICE_JWT"}]
			selector: {"app.kubernetes.io/name": "app", "app.kubernetes.io/component": "billing"}
			service:  [{name: "http", port: 8688, targetPort: 8688, protocol: "TCP"}]
			pods:     "billing"
		}
	}
	"the origin is the release's host, a preview's own, unless the service names it": {
		_prod:  [for e in (_withServices & {release: services: billing: port: 8688}).named["Deployment/app-billing"].spec.template.spec.containers[0].env if e.name == "ORIGIN" {e.value}]
		_named: [for e in (_withServices & {release: services: billing: {port: 8688, env: ORIGIN: "https://o.example"}}).named["Deployment/app-billing"].spec.template.spec.containers[0].env if e.name == "ORIGIN" {e.value}]
		_got:   {prod: _prod, named: _named}
		_want:  {prod: ["https://app.example.com"], named: ["https://o.example"]}
	}
	"files are mounted read-only from their ConfigMap, one volume a ConfigMap, and the seed is what the release makes it from": {
		_r: (_withServices & {release: services: flagd: _flagd & {files: "/etc/more": "app-flags"}}).named["Deployment/app-flagd"].spec.template.spec
		_got: {
			mounts:   list.SortStrings([for m in _r.containers[0].volumeMounts {m.mountPath}])
			readonly: [for m in _r.containers[0].volumeMounts {m.readOnly}]
			volumes:  _r.volumes
		}
		_want: {
			mounts:   ["/etc/flags-live", "/etc/more"]
			readonly: [true, true]
			volumes:  [{name: "files-app-flags", configMap: name: "app-flags"}]
		}
	}
	"a seed for a ConfigMap no directory reads is refused": {
		_got:  (_withServices & {release: services: flagd: {port: 8693, seed: "other": "flags/flags.json"}}).violations
		_want: ["services.flagd.seed names the ConfigMap other, which no directory of its files reads"]
	}
	"secrets are read from their Secret under the variable's name, and one named in env too is refused": {
		_s:   (_withServices & {release: services: notifier: {port: 8698, secrets: VAPID_PRIVATE_KEY: "notify-vapid-private-key"}}).named["Deployment/app-notifier"].spec.template.spec.containers[0].env
		_dup: (_withServices & {release: services: notifier: {port: 8698, env: VAPID_PRIVATE_KEY: "x", secrets: VAPID_PRIVATE_KEY: "notify-vapid-private-key"}}).violations
		_got: {
			secret: [for e in _s if e.name == "VAPID_PRIVATE_KEY" {e.valueFrom.secretKeyRef}]
			dup:    _dup
		}
		_want: {
			secret: [{name: "notify-vapid-private-key", key: "VAPID_PRIVATE_KEY"}]
			dup:    ["services.notifier.env and secrets both name VAPID_PRIVATE_KEY"]
		}
	}
	"a database login is the URL of the login's own Secret, with a policy to reach the database": {
		_r:   (_withServices & {release: {database: logins: reader: inRoles: ["viewer"], services: exporter: {port: 9399, database: {login: "reader", env: "TARGET_DSN"}}}})
		_env: [for e in _r.named["Deployment/app-exporter"].spec.template.spec.containers[0].env if e.name == "TARGET_DSN" {e.valueFrom.secretKeyRef}]
		_np:  _r.named["NetworkPolicy/app-exporter-database-egress"].spec
		_got: {
			env:    _env
			target: _np.egress[0].to
			port:   _np.egress[0].ports
		}
		_want: {
			env:    [{name: "app-reader-db", key: "url"}]
			target: [{podSelector: matchLabels: "cnpg.io/cluster": "app-db"}]
			port:   [{port: 5432, protocol: "TCP"}]
		}
	}
	"a login the release does not declare, or a variable the login fills that env names, is refused": {
		_got: [
			(_withServices & {release: services: exporter: {port: 9399, database: login: "reader"}}).violations,
			(_withServices & {release: {database: logins: reader: inRoles: [], services: exporter: {port: 9399, env: DATABASE_URL: "x", database: login: "reader"}}}).violations,
		]
		_want: [
			["services.exporter.database names the login reader, which database.logins does not declare"],
			["services.exporter.env names DATABASE_URL, which its database login fills"],
		]
	}
	"metrics are annotated for the scrapers, on the Service, and admitted by the services' policy": {
		_r:   (_withServices & {release: services: collector: {port: 8687, metrics: port: 9599}}).named
		_pol: _r["NetworkPolicy/app-services-netpol"].spec
		_got: {
			annotations: {for k, v in _r["Deployment/app-collector"].spec.template.metadata.annotations if k =~ "^prometheus" {(k): v}}
			ports:       _r["Service/collector"].spec.ports
			scrapers:    [for i in _pol.ingress if i.from[0].namespaceSelector != _|_ {i.ports}]
		}
		_want: {
			annotations: {"prometheus.io/scrape": "true", "prometheus.io/port": "9599", "prometheus.io/path": "/metrics"}
			ports:       [{name: "http", port: 8687, targetPort: 8687, protocol: "TCP"}, {name: "metrics", port: 9599, targetPort: 9599, protocol: "TCP"}]
			scrapers:    [[{port: 9090, protocol: "TCP"}, {port: 9599, protocol: "TCP"}]]
		}
	}
	"a clock is a CronJob that pokes the service with the service role's token": {
		_c: (_withServices & {release: services: pulse: {port: 9998, clock: {}}}).named["CronJob/app-pulse-clock"]
		_got: {
			schedule: _c.spec.schedule
			zone:     _c.spec.timeZone
			policy:   _c.spec.concurrencyPolicy
			image:    _c.spec.jobTemplate.spec.template.spec.containers[0].image
			cmd:      _c.spec.jobTemplate.spec.template.spec.containers[0].command[2]
			token:    _c.spec.jobTemplate.spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef
			labels:   _c.spec.jobTemplate.spec.template.metadata.labels["app.kubernetes.io/name"]
		}
		_want: {
			schedule: "* * * * *"
			zone:     "Etc/UTC"
			policy:   "Forbid"
			image:    =~"^docker.io/curlimages/curl:[0-9.]+@sha256:[0-9a-f]{64}$"
			cmd:      =~"u=http://pulse.app.svc.cluster.local:9998\n"
			token:    {name: "app-service-token", key: "SERVICE_JWT"}
			labels:   "app"
		}
	}
	"a clock whose CronJob name would pass 52 characters is refused": {
		_got:  [for v in (_named & {release: services: "a-service-with-long-name": {port: 9998, clock: {}}}).violations if v =~ "clock would be" {v}]
		_want: ["services.a-service-with-long-name.clock would be the CronJob a-release-named-at-its-limit-a-service-with-long-name-clock, whose name a Job's pods cannot carry past 52 characters"]
	}
	"a single writer keeps the Recreate strategy and the release's default replicas leave it at one": {
		_r: (_withServices & {release: {replicas: 3, services: {writer: {port: 9998, singleWriter: true}, billing: port: 8688}}})
		_got: {
			strategy: _r.named["Deployment/app-writer"].spec.strategy
			replicas: {writer: _r.named["Deployment/app-writer"].spec.replicas, billing: _r.named["Deployment/app-billing"].spec.replicas}
		}
		_want: {strategy: type: "Recreate", replicas: {writer: 1, billing: 3}}
	}
	"scale and containerResources take a service's Deployment and container by name": {
		_r:  (_withServices & {release: {services: billing: port: 8688, scale: "app-billing": {replicas: 2, preview: 1}, containerResources: billing: limits: memory: "512Mi"}})
		_d1: _r.named["Deployment/app-billing"]
		_got: {
			replicas:  _d1.spec.replicas
			resources: _d1.spec.template.spec.containers[0].resources
		}
		_want: {
			replicas:  2
			resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {cpu: "500m", memory: "512Mi"}}
		}
	}
	"a service's resources are the app's, else the shared default": {
		_app:  (_withServices & {release: services: billing: port: 8688, appExtra: resources: {requests: {cpu: "100m", memory: "128Mi"}, limits: {cpu: "1", memory: "1Gi"}}}).named["Deployment/app-billing"].spec.template.spec.containers[0].resources
		_got:  _app
		_want: {requests: {cpu: "100m", memory: "128Mi"}, limits: {cpu: "1", memory: "1Gi"}}
	}
	"scale naming a service that is not declared is refused": {
		_got:  (_withServices & {release: scale: "app-billing": replicas: 2}).violations
		_want: [=~"^scale names app-billing, which is no Deployment of the render"]
	}
	"a service named for one of upstream's, or whose objects the render has, is refused": {
		_got: (_withServices & {release: services: crud: port: 3000}).violations
		_want: [
			"services, blobs or metricsExport would emit Deployment/app-crud, which the render already has",
			"services, blobs or metricsExport would emit Service/crud, which the render already has",
		]
	}
	"a service whose image the build did not push is refused for its digest": {
		_got:  (_withServices & {release: services: other: port: 8000}).violations
		_want: ["image 127.0.0.1:5000/app-other:latest is not pinned by digest"]
	}
	"with the policy off a service has no policy of its own": {
		_r:    (_withServices & {release: services: billing: port: 8688, appExtra: networkPolicy: enabled: false})
		_got:  [for k, _ in _r.named if k =~ "^NetworkPolicy/" {k}]
		_want: []
	}
	"the services' policy selects them and the blob plane, and admits the mesh, the door and the ports of each": {
		_pol: (_withServices & {release: {services: billing: port: 8688, blobs: _blobs}}).named["NetworkPolicy/app-services-netpol"].spec
		_got: {
			selected: _pol.podSelector.matchExpressions[0].values
			ports:    _pol.ingress[0].ports
		}
		_want: {
			selected: ["billing", "rclone-s3", "imgproxy"]
			ports:    [{port: 8688, protocol: "TCP"}, {port: 3900, protocol: "TCP"}, {port: 8081, protocol: "TCP"}, {port: 50002, protocol: "TCP"}, {port: 3500, protocol: "TCP"}]
		}
	}
	"the blob plane is rclone and imgproxy, signed in through the pod's token with no key": {
		_r:  (_withServices & {release: blobs: _blobs}).named
		_rc: _r["Deployment/app-rclone-s3"].spec.template
		_got: {
			kinds:       list.SortStrings([for k, _ in _r if k =~ "blobs$|rclone|imgproxy" {k}])
			account:     _rc.spec.serviceAccountName
			rclone:      _rc.spec.containers[0].image
			imgproxy:    _r["Deployment/app-imgproxy"].spec.template.spec.containers[0].image
			upstreams:   [for e in _rc.spec.containers[0].env if e.name == "RCLONE_CONFIG_OBJECTS_UPSTREAMS" {e.value}]
			credentials: _json
			audience:    _rc.spec.volumes[1].projected.sources[0].serviceAccountToken.audience
			app:         _rc.metadata.annotations["dapr.io/app-id"]
		}
		_json: _r["ConfigMap/app-blobs"].data["credentials.json"]
		_want: {
			kinds:       ["ConfigMap/app-blobs", "Deployment/app-imgproxy", "Deployment/app-rclone-s3", "Service/imgproxy", "Service/rclone-s3", "ServiceAccount/app-blobs"]
			account:     "app-blobs"
			rclone:      "127.0.0.1:5000/app-rclone-s3:release@sha256:\(_d)"
			imgproxy:    "127.0.0.1:5000/app-imgproxy:release@sha256:\(_d)"
			upstreams:   ["mecha-objects=gcs:app-blobs-bucket"]
			credentials: =~"\"audience\":\"//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q\""
			audience:    "contabo-k3s"
			app:         "rclone-s3"
		}
	}
	"the blob plane and a runtime service of upstream's of the same name are refused": {
		_got:  (_withServices & {release: {blobs: _blobs, services: "rclone-s3": port: 3900}}).violations
		_want: ["services, blobs and metricsExport would emit Deployment/app-rclone-s3 twice", "services, blobs and metricsExport would emit Service/rclone-s3 twice"]
	}
	"the metrics export scrapes each service's metrics port and signs in with no key": {
		_r:   (_withServices & {release: {services: {collector: {port: 8687, metrics: port: 9599}, billing: port: 8688}, metricsExport: _export}}).named
		_cm:  _r["ConfigMap/app-metrics-export"].data
		_pod: _r["Deployment/app-metrics-export"].spec.template.spec
		_got: {
			config:  _cm["config.yaml"]
			image:   _pod.containers[0].image
			account: _pod.serviceAccountName
		}
		_want: {
			config:  =~"job_name: collector"
			image:   =~"^docker.io/otel/opentelemetry-collector-contrib:[0-9.]+@sha256:[0-9a-f]{64}$"
			account: "app-metrics-export"
		}
	}
	"the metrics export is one pod, scale refuses it, and a service it scrapes runs one": {
		_got: [
			(_withServices & {release: {services: collector: {port: 8687, metrics: port: 9599}, metricsExport: _export, replicas: 3}}).violations,
			(_withServices & {release: {services: collector: {port: 8687, metrics: port: 9599}, metricsExport: _export, replicas: 3, scale: "app-collector": replicas: 1}}).violations,
			(_withServices & {release: {services: collector: {port: 8687, metrics: port: 9599}, metricsExport: _export, scale: "app-metrics-export": replicas: 2}}).violations,
			[(_withServices & {release: {services: collector: {port: 8687, metrics: port: 9599}, metricsExport: _export, replicas: 3, scale: "app-collector": replicas: 1}}).named["Deployment/app-metrics-export"].spec.strategy.type],
		]
		_want: [
			["metricsExport scrapes services.collector through its Service, which mixes the counters of its pods: it must run one (scale names it)"],
			[],
			["scale names app-metrics-export, a single writer: two collectors would write the same series"],
			["Recreate"],
		]
	}
	"a seed that names a ConfigMap the release writes, and a secret the database login fills, are refused": {
		_got: [
			(_withServices & {release: services: flagd: {port: 8693, files: "/etc/f": "pronto-release", seed: "pronto-release": "flags/flags.json"}}).violations,
			(_withServices & {release: {blobs: _blobs, services: flagd: {port: 8693, files: "/etc/f": "app-blobs", seed: "app-blobs": "flags/flags.json"}}}).violations,
			(_withServices & {release: {database: logins: reader: inRoles: [], services: exporter: {port: 9399, secrets: DSN: "x", database: {login: "reader", env: "DSN"}}}}).violations,
		]
		_want: [
			["services.flagd.seed names the ConfigMap pronto-release, which the release writes itself"],
			["services.flagd.seed names the ConfigMap app-blobs, which the release writes itself"],
			["services.exporter.secrets names DSN, which its database login fills"],
		]
	}
	"a metrics export with nothing to scrape is refused": {
		_got:  (_withServices & {release: {services: billing: port: 8688, metricsExport: _export}}).violations
		_want: ["metricsExport needs a service with `metrics` to scrape"]
	}
	"a release with every service, the blob plane and the metrics export is refused for nothing: the engine's own external images are pinned": {
		_got:  (_withServices & {release: {services: {collector: {port: 8687, metrics: port: 9599}, pulse: {port: 9998, clock: {}}}, blobs: _blobs, metricsExport: _export}}).violations
		_want: []
	}
}

_blobs:  {bucket: "app-blobs-bucket", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "blobs@proj.iam.gserviceaccount.com", audience: "contabo-k3s"}
_export: {project: "my-project", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "metrics@proj.iam.gserviceaccount.com"}
