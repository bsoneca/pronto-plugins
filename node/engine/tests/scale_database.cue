package tests

import (
	"github.com/bsoneca/pronto-plugins/node/engine/schema"
)

// What a release says of replicas, resources and the database: patches over upstream's Deployments and Cluster
// (the fixture's are upstream's shapes), and refused where they name nothing.

_tuned: {
	release: {...}
	_m: schema.#Manifests & {
		"release": schema.#Release & _base & {hosts: rc: "rc.example.com"} & release
		upstream:  (_fixture & {ns: "app", host: "app.example.com", reg: "127.0.0.1:5000"}).objects
	}
	objects:    _m.objects
	violations: _m.violations
	replicas:   {for o in _m.objects if o.kind == "Deployment" {(o.metadata.name): o.spec.replicas}}
	cluster:    [for o in _m.objects if o.kind == "Cluster" {o}][0]
	crud:       [for o in _m.objects if o.kind == "Deployment" && o.metadata.name == "app-crud" {o}][0]
}
_tunedPreview: {
	release: {...}
	_m: schema.#Manifests & {
		"release": schema.#Release & _base & {preview: "rc", hosts: rc: "rc.example.com"} & release
		upstream:  (_fixture & {ns: "app-rc", host: "rc.example.com", reg: "127.0.0.1:5000"}).objects
	}
	replicas: {for o in _m.objects if o.kind == "Deployment" {(o.metadata.name): o.spec.replicas}}
	cluster:  [for o in _m.objects if o.kind == "Cluster" {o}][0]
}

cases: {
	"scale sets the named Deployments' replicas and leaves the rest as upstream renders them": {
		_got:  (_tuned & {release: scale: {"app-crud": {replicas: 3, preview: 2}, "app-caddy": {replicas: 2}}}).replicas
		_want: {"app-crud": 3, "app-caddy": 2, "app-ticker": 1, "app-electric": 1}
	}
	"in a preview scale takes its preview number, and a Deployment with none keeps upstream's": {
		_got:  (_tunedPreview & {release: scale: {"app-crud": {replicas: 3, preview: 2}, "app-caddy": {replicas: 3}}}).replicas
		_want: {"app-crud": 2, "app-caddy": 1, "app-ticker": 1, "app-electric": 1}
	}
	"the default replicas apply to every Deployment but a single writer's, which only scale names": {
		_prod: (_tuned & {release: {replicas: 3, scale: "app-ticker": replicas: 2}}).replicas
		_rc:   (_tunedPreview & {release: {replicas: 3, previewReplicas: 2}}).replicas
		_got:  {prod: _prod, rc: _rc}
		_want: {prod: {"app-crud": 3, "app-caddy": 3, "app-ticker": 2, "app-electric": 1}, rc: {"app-crud": 2, "app-caddy": 2, "app-ticker": 1, "app-electric": 1}}
	}
	"scale beats the default": {
		_got:  (_tuned & {release: {replicas: 3, scale: "app-crud": replicas: 5}}).replicas
		_want: {"app-crud": 5, "app-caddy": 3, "app-ticker": 1, "app-electric": 1}
	}
	"Electric is a single writer: the defaults leave it at one and scale refuses it": {
		_got: {
			default: (_tuned & {release: replicas: 3}).replicas."app-electric"
			scaled:  (_tuned & {release: scale: "app-electric": replicas: 3}).violations
		}
		_want: {default: 1, scaled: [=~"^scale names app-electric, a single writer"]}
	}
	"a login named for one of upstream's roles, or whose objects the render has, is refused": {
		_got: [
			(_tuned & {release: database: logins: electric: inRoles: []}).violations,
			(_tuned & {release: database: logins: postgres: inRoles: []}).violations,
		]
		_want: [[=~"^database.logins names electric, a role of upstream's own"], [=~"^database.logins names postgres, a role of upstream's own"]]
	}
	"scale naming a Deployment the render has not is refused": {
		_got:  (_tuned & {release: scale: "app-nope": replicas: 2}).violations
		_want: [=~"^scale names app-nope, which is no Deployment of the render"]
	}
	"a container's resources replace the fields named and keep upstream's others, in the container alone": {
		_crud: (_tuned & {release: containerResources: crud: {requests: memory: "256Mi", limits: {cpu: "1", memory: "512Mi"}}}).crud
		_got: {
			resources: _crud.spec.template.spec.containers[0].resources
			init:      _crud.spec.template.spec.initContainers[0]
		}
		_want: {
			resources: {requests: {cpu: "50m", memory: "256Mi"}, limits: {cpu: "1", memory: "512Mi"}}
			init:      {name: "wait", image: =~"^127.0.0.1:5000/app-crud:latest@sha256:"}
		}
	}
	"a container with no resources upstream gets what the release names": {
		_got:  [for o in (_tuned & {release: containerResources: ticker: limits: memory: "1Gi"}).objects if o.metadata.name == "app-ticker" {o.spec.template.spec.containers[0].resources}][0]
		_want: {limits: memory: "1Gi"}
	}
	"containerResources naming no container is refused, postgres excepted": {
		_got:  (_tuned & {release: {database: {}, containerResources: {nope: limits: cpu: "1", postgres: limits: cpu: "1"}}}).violations
		_want: ["containerResources names nope, which is no container of the render's Deployments (or postgres)"]
	}
	"a database that is set but asks for little changes little: one instance, CloudNativePG's own stop settings stay": {
		_c: (_tuned & {release: database: {}}).cluster
		_got: {
			instances: _c.spec.instances
			storage:   _c.spec.storage
			params:    _c.spec.postgresql.parameters
			sync:      _c.spec.postgresql.synchronous != _|_
			smart:     _c.spec.smartShutdownTimeout != _|_
			stop:      _c.spec.stopDelay != _|_
			pdb:       _c.spec.enablePDB != _|_
			slots:     _c.spec.replicationSlots != _|_
			update:    _c.spec.primaryUpdateStrategy != _|_
			roles:     len(_c.spec.managed.roles)
		}
		_want: {
			instances: 1
			storage:   {size: "1Gi", storageClass: "local-path"}
			params:    {wal_level: "logical", max_connections: "200", max_replication_slots: "128"}
			sync:      false
			smart:     false
			stop:      false
			pdb:       false
			slots:     false
			update:    false
			roles:     2
		}
	}
	"a database of three: standbys, synchronous commit, slots, a switchover, a volume and its WAL cap, the app's parameters": {
		_c: (_tuned & {release: database: {instances: 3, storage: "4Gi", parameters: max_connections: "300"}}).cluster
		_got: {
			instances: _c.spec.instances
			size:      _c.spec.storage.size
			class:     _c.spec.storage.storageClass
			params:    _c.spec.postgresql.parameters
			sync:      _c.spec.postgresql.synchronous
			smart:     _c.spec.smartShutdownTimeout
			update:    [_c.spec.primaryUpdateStrategy, _c.spec.primaryUpdateMethod]
			slots:     _c.spec.replicationSlots
			pdb:       _c.spec.enablePDB
		}
		_want: {
			instances: 3
			size:      "4Gi"
			class:     "local-path"
			params:    {wal_level: "logical", max_connections: "300", max_replication_slots: "128", max_slot_wal_keep_size: "1024MB"}
			sync:      {method: "any", number: 1, dataDurability: "preferred"}
			smart:     0
			update:    ["unsupervised", "switchover"]
			slots: highAvailability: enabled: true
			pdb: true
		}
	}
	"a database's synchronous settings, PDB, slots and shutdown are the app's to change": {
		_c:    (_tuned & {release: database: {instances: 2, enablePDB: false, haSlots: false, smartShutdown: 30, synchronous: {number: 1, dataDurability: "required"}}}).cluster
		_got:  {pdb: _c.spec.enablePDB, slots: _c.spec.replicationSlots.highAvailability.enabled, smart: _c.spec.smartShutdownTimeout, durability: _c.spec.postgresql.synchronous.dataDurability}
		_want: {pdb: false, slots: false, smart: 30, durability: "required"}
	}
	"postgres's resources go to the Cluster, and without a database set they are refused": {
		_got: {
			resources: (_tuned & {release: {database: {}, containerResources: postgres: {requests: cpu: "500m"}}}).cluster.spec.resources
			refused:   (_tuned & {release: containerResources: postgres: {requests: cpu: "500m"}}).violations
		}
		_want: {resources: {requests: cpu: "500m"}, refused: ["containerResources.postgres needs `database` to be set, even as {}"]}
	}
	"each login is a managed role, a generated password and the Secret the operator reads": {
		_t:      _tuned & {release: database: logins: analytics_reader: inRoles: ["analytics_viewer"]}
		_role:   [for r in _t.cluster.spec.managed.roles if r.name == "analytics_reader" {r}][0]
		_secret: [for o in _t.objects if o.kind == "ExternalSecret" && o.metadata.name == "app-analytics-reader-db" {o}][0]
		_gen:    [for o in _t.objects if o.kind == "Password" {o}][0]
		_got: {
			roles:  [for r in _t.cluster.spec.managed.roles {r.name}]
			role:   _role
			secret: {name: _secret.metadata.name, user: _secret.spec.target.template.data.username, url: _secret.spec.target.template.data.url, from: _secret.spec.dataFrom[0].sourceRef.generatorRef.name, key: _secret.spec.dataFrom[0].rewrite[0].regexp.target}
			gen:    _gen.metadata.name
			clean:  _t.violations
		}
		_want: {
			roles:  ["electric", "authenticator", "analytics_reader"]
			role:   {name: "analytics_reader", ensure: "present", login: true, inherit: true, inRoles: ["analytics_viewer"], passwordSecret: name: "app-analytics-reader-db"}
			secret: {name: "app-analytics-reader-db", user: "analytics_reader", url: "postgres://analytics_reader:{{ .ANALYTICS_READER_PASSWORD }}@database:5432/app?sslmode=disable", from: "app-analytics-reader-password", key: "ANALYTICS_READER_PASSWORD"}
			gen:    "app-analytics-reader-password"
			clean:  []
		}
	}
	"database.backup is the release's backups: one store, one schedule, the archiver on the Cluster": {
		_t: _tuned & {release: database: backup: {bucket: "b", path: "app/db"}}
		_got: {
			kinds:  [for o in _t.objects if o.kind == "ObjectStore" || o.kind == "ScheduledBackup" {o.kind}]
			plugin: _t.cluster.spec.plugins[0].parameters.barmanObjectName
			dest:   [for o in _t.objects if o.kind == "ObjectStore" {o.spec.configuration.destinationPath}][0]
		}
		_want: {kinds: ["ObjectStore", "ScheduledBackup"], plugin: "app-backup", dest: "s3://b/app/db"}
	}
	"a preview runs as many database instances as it is told, and no backups": {
		_c:    (_tunedPreview & {release: database: {instances: 3, backup: {bucket: "b", path: "app/db"}}}).cluster
		_got:  {instances: _c.spec.instances, plugins: _c.spec.plugins != _|_}
		_want: {instances: 3, plugins: false}
	}
}
