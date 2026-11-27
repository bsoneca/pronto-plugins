// The state as OpenTofu applies it (README.md): `cue export -e plan.tofu` is tofu/main.tf.json,
// the Google provider's resources for what each project adopts, and an import for each, so a
// resource already there is taken as it is and never made again (an import of one already in
// OpenTofu's own state changes nothing). IAM is a binding a role: the members of a role named
// are exactly the state's, and a role not named is left as it is.
package infra

import (
	"list"
	"regexp"
	"strings"
)

// An address's name: what OpenTofu takes in one.
#name: {in: string, out: regexp.ReplaceAll("[^a-zA-Z0-9_]", in, "_")}
#members: {in: #Members, out: list.SortStrings([for m, _ in in {m}])}

// The channels of an alert policy or an uptime check: the ones it names, then the project's alert
// subscribers' unless it opts out.
#chans: {in: [...string], subs: [...string], to: bool, out: list.Concat([in, [if to for n in subs if !list.Contains(in, n) {n}]])}

#Plan: Plan={
	state:   #State
	backend: #Backend

	tofu: {
		terraform: {
			required_version: ">= 1.13.0"
			required_providers: google: {source: "hashicorp/google", version: "~> 7.0"}
			if len(beta) > 0 {
				required_providers: "google-beta": {source: "hashicorp/google-beta", version: "~> 7.0"}
			}
			if len(randoms) > 0 {
				required_providers: random: {source: "hashicorp/random", version: "~> 3.6"}
			}
			backend: gcs: {bucket: Plan.backend.bucket, prefix: Plan.backend.prefix}
		}
		// The operator's own gcloud login, as a token in GOOGLE_OAUTH_ACCESS_TOKEN (say.cue.txt).
		// Some APIs (Identity Platform, Billing Budgets, Firebase) refuse a user's login without a
		// quota project: their resources use the alias named for their project, which bills it.
		provider: google: [{}, for P in state.projects {alias: (#name & {in: P.id}).out, billing_project: P.id, user_project_override: true}]
		if len(beta) > 0 {
			provider: "google-beta": [for id in beta {alias: (#name & {in: id}).out, billing_project: id, user_project_override: true}]
		}
		resource: {}
		import: [for i in _imports if !state.projects[i.project].create || i.found {to: i.to, id: i.id}]
		// A forgotten address leaves the state with no delete (#State.forget).
		if len(state.forget) > 0 {
			removed: [for a, _ in state.forget {from: a, lifecycle: destroy: false}]
		}
	}
	// No address is both declared and forgotten.
	forgottenDeclared: [for a, _ in state.forget let t = strings.SplitN(a, ".", 2) if tofu.resource[t[0]][t[1]] != _|_ {a}] & []

	// Each import names its project: one this state makes (create) has nothing to import, its
	// resources all new, so its imports are left out, but for what the project says it found.
	_imports: [Address=string]: {to: Address, id: string, project: string, found: *false | bool}

	// The projects with a Firebase Hosting site, which only the google-beta provider holds.
	let beta = [for P in state.projects if len([for s, _ in P.hostingSites if P.adoptAll || list.Contains(*P.adopt["hostingSites"] | [], s) {s}]) > 0 {P.id}]

	// The SQL users whose passwords OpenTofu makes: random needs its provider.
	let randoms = list.Concat([
		[for P in state.projects for inst, us in P.sqlUsers if P.adoptAll || list.Contains(*P.adopt["sqlUsers"] | [], inst) for u, _ in us {u}],
		[for P in state.projects for nm, sc in P.secrets if sc.random if P.adoptAll || list.Contains(*P.adopt["secrets"] | [], nm) {nm}],
	])

	// The accounts this state keeps in any project, by the member that names them: a grant naming
	// one waits for it, whichever project the grant is in.
	let accounts = {
		for _, Q in state.projects for nm, sa in Q.serviceAccounts if Q.adoptAll || list.Contains(*Q.adopt["serviceAccounts"] | [], nm) {
			("serviceAccount:\(sa.email)"): "google_service_account.\((#name & {in: "\(Q.id)_\(nm)"}).out)"
		}
	}

	for P in state.projects {
		let adopted = {
			for kind in ["apis", "iam", "members", "serviceAccounts", "repositories", "repositoryIam", "buckets", "secrets", "runJobs", "runServices", "databases", "sqlUsers", "sqlBackups", "apiKeys", "identityPlatform", "budgets", "hostingSites"] {
				(kind): {for n in *P.adopt[kind] | [] {(n): true}}
			}
		}
		let fresh = {
			for kind in ["apis", "iam", "members", "serviceAccounts", "serviceAccountIam", "repositories", "repositoryIam", "bucketIam", "runJobs", "runServices", "runServiceIam", "databases", "sqlUsers", "apiKeys", "budgets", "hostingSites"] {
				(kind): {for n in *P.fresh[kind] | [] {(n): true}}
			}
		}
		let p = (#name & {in: P.id}).out
		let proj = list.Concat([if P.create {["google_project.\(p)"]}, if !P.create {[]}])

		// What a resource waits for: the project if this state makes it, and the services it enables.
		let deps = list.Concat([proj, [for svc, _ in P.apis if P.adoptAll || adopted.apis[svc] != _|_ {"google_project_service.\((#name & {in: "\(P.id)_\(svc)"}).out)"}]])

		// A project grant may name an account made beside it.
		let iamDeps = list.Concat([deps, [for nm, _ in P.serviceAccounts if P.adoptAll || adopted.serviceAccounts[nm] != _|_ {"google_service_account.\((#name & {in: "\(P.id)_\(nm)"}).out)"}]])

		// A Cloud Run job or service also waits for the accounts and secrets made beside it.
		let ownDeps = list.Concat([deps,
			[for nm, _ in P.serviceAccounts if P.adoptAll || adopted.serviceAccounts[nm] != _|_ {"google_service_account.\((#name & {in: "\(P.id)_\(nm)"}).out)"}],
			[for nm, _ in P.secrets if P.adoptAll || adopted.secrets[nm] != _|_ {"google_secret_manager_secret.\((#name & {in: "\(P.id)_\(nm)"}).out)"}],
			[for nm, sc in P.secrets if P.adoptAll || adopted.secrets[nm] != _|_ if len(sc.accessors) > 0 {"google_secret_manager_secret_iam_binding.\((#name & {in: "\(P.id)_\(nm)"}).out)"}],
			[for nm, sc in P.secrets if P.adoptAll || adopted.secrets[nm] != _|_ if len(sc.adders) > 0 {"google_secret_manager_secret_iam_binding.\((#name & {in: "\(P.id)_\(nm)"}).out)_adders"}],
			[for nm, sc in P.secrets if sc.file != _|_ || sc.text != _|_ || sc.random || sc.placeholder != _|_ if P.adoptAll || adopted.secrets[nm] != _|_ {"google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(nm)"}).out)"}],
			[for inst, us in P.sqlUsers if P.adoptAll || adopted.sqlUsers[inst] != _|_ for u, c in us for part in ["password", if c.url != _|_ {"url"}] {"google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(inst)_\(u)_\(part)"}).out)"}],
		])

		// A secret this state keeps a version of is read at that version; any other at its latest. A SQL
		// user's credentials are such a secret too: a new password or address is a new revision.
		let readAt = {
			for nm, sc in P.secrets {
				(nm): *"latest" | string
				if sc.file != _|_ || sc.text != _|_ || sc.random if P.adoptAll || adopted.secrets[nm] != _|_ {
					(nm): "${google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(nm)"}).out).version}"
				}
			}
			for inst, us in P.sqlUsers if P.adoptAll || adopted.sqlUsers[inst] != _|_ for u, c in us {
				(c.password): "${google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(inst)_\(u)"}).out)_password.version}"
				if c.url != _|_ {(c.url): "${google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(inst)_\(u)"}).out)_url.version}"}
			}
		}

		if P.adoptAll {
			tofu: resource: google_project: (p): {
				project_id:      P.id
				name:            P.name
				billing_account: strings.TrimPrefix(P.billing, "billingAccounts/")
				deletion_policy: "PREVENT"
				lifecycle: prevent_destroy: true
			}
			_imports: "google_project.\(p)": {id: P.id, project: P.id}
		}

		for svc, _ in P.apis if P.adoptAll || adopted.apis[svc] != _|_ {
			let k = (#name & {in: "\(P.id)_\(svc)"}).out
			tofu: resource: google_project_service: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, service: svc, disable_on_destroy: false, disable_dependent_services: false}
			if fresh.apis[svc] == _|_ {_imports: "google_project_service.\(k)": {id: "\(P.id)/\(svc)", project: P.id}}
		}

		for rl, ms in P.iam if P.adoptAll || adopted.iam[rl] != _|_ {
			let k = (#name & {in: "\(P.id)_\(rl)"}).out
			tofu: resource: google_project_iam_binding: (k): {depends_on: list.Concat([iamDeps, [for m, _ in ms if accounts[m] != _|_ if !list.Contains(iamDeps, accounts[m]) {accounts[m]}]]), project: P.id, role: rl, members: (#members & {in: ms}).out}
			if fresh.iam[rl] == _|_ {_imports: "google_project_iam_binding.\(k)": {id: "\(P.id) \(rl)", project: P.id}}
		}

		for rl, ms in P.members if P.adoptAll || adopted.members[rl] != _|_ {
			for m, _ in ms {
				let k = (#name & {in: "\(P.id)_\(rl)_\(m)"}).out
				tofu: resource: google_project_iam_member: (k): {depends_on: list.Concat([iamDeps, [if accounts[m] != _|_ if !list.Contains(iamDeps, accounts[m]) {accounts[m]}]]), project: P.id, role: rl, member: m}
				if fresh.members[rl] == _|_ if fresh.members["\(rl)/\(m)"] == _|_ {_imports: "google_project_iam_member.\(k)": {id: "\(P.id) \(rl) \(m)", project: P.id, found: list.Contains(*P.found["members"] | [], "\(rl)/\(m)")}}
			}
		}

		for nm, sa in P.serviceAccounts if P.adoptAll || adopted.serviceAccounts[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/serviceAccounts/\(sa.email)"
			tofu: resource: google_service_account: (k): {depends_on: deps, project: P.id, account_id: nm, display_name: sa.displayName, lifecycle: prevent_destroy: true}
			if fresh.serviceAccounts[nm] == _|_ {_imports: "google_service_account.\(k)": {id: at, project: P.id, found: list.Contains(*P.found["serviceAccounts"] | [], nm)}}
			for rl, ms in sa.iam {
				let r = (#name & {in: "\(P.id)_\(nm)_\(rl)"}).out
				tofu: resource: google_service_account_iam_binding: (r): {depends_on: list.Concat([deps, [for m, _ in ms if accounts[m] != _|_ {accounts[m]}]]), service_account_id: "${google_service_account.\(k).name}", role: rl, members: (#members & {in: ms}).out}
				if fresh.serviceAccountIam["\(nm)/\(rl)"] == _|_ {_imports: "google_service_account_iam_binding.\(r)": {id: "\(at) \(rl)", project: P.id}}
			}
		}

		for nm, repo in P.repositories if P.adoptAll || adopted.repositories[nm] != _|_ || adopted.repositoryIam[nm] != _|_ {
			let at = "projects/\(P.id)/locations/\(repo.location)/repositories/\(nm)"
			if P.adoptAll || adopted.repositories[nm] != _|_ {
				let k = (#name & {in: "\(P.id)_\(nm)"}).out
				tofu: resource: google_artifact_registry_repository: (k): {depends_on: deps, project: P.id, location: repo.location, repository_id: nm, format: repo.format, lifecycle: prevent_destroy: true}
				if fresh.repositories[nm] == _|_ {_imports: "google_artifact_registry_repository.\(k)": {id: at, project: P.id}}
			}
			for rl, ms in repo.iam {
				let r = (#name & {in: "\(P.id)_\(nm)_\(rl)"}).out
				tofu: resource: google_artifact_registry_repository_iam_binding: (r): {depends_on: list.Concat([deps, if P.adoptAll || adopted.repositories[nm] != _|_ {["google_artifact_registry_repository.\((#name & {in: "\(P.id)_\(nm)"}).out)"]}, if !(P.adoptAll || adopted.repositories[nm] != _|_) {[]}, [for m, _ in ms if accounts[m] != _|_ {accounts[m]}]]), project: P.id, location: repo.location, repository: nm, role: rl, members: (#members & {in: ms}).out}
				if fresh.repositoryIam["\(nm)/\(rl)"] == _|_ {_imports: "google_artifact_registry_repository_iam_binding.\(r)": {id: "\(at) \(rl)", project: P.id}}
			}
		}

		for nm, b in P.buckets if P.adoptAll || adopted.buckets[nm] != _|_ {
			let k = (#name & {in: nm}).out
			tofu: resource: google_storage_bucket: (k): {depends_on: deps
				name:                        nm
				project:                     P.id
				location:                    b.location
				uniform_bucket_level_access: b.uniformAccess
				public_access_prevention:    b.publicPrevention
				force_destroy:               false
				lifecycle: prevent_destroy: true
				versioning: enabled:        b.versioning
				if b.deleteAfterDays != _|_ {
					lifecycle_rule: [{action: type: "Delete", condition: age: b.deleteAfterDays}]
				}
			}
			if !b.made {
				_imports: "google_storage_bucket.\(k)": {id: "\(P.id)/\(nm)", project: P.id}
			}
			for rl, ms in b.iam {
				let r = (#name & {in: "\(nm)_\(rl)"}).out

				// Its grants name it by reference, so OpenTofu makes the bucket before granting on it.
				tofu: resource: google_storage_bucket_iam_binding: (r): {depends_on: list.Concat([deps, [for m, _ in ms if accounts[m] != _|_ {accounts[m]}]]), bucket: "${google_storage_bucket.\(k).name}", role: rl, members: (#members & {in: ms}).out}
				if !b.made && fresh.bucketIam["\(nm)/\(rl)"] == _|_ {
					_imports: "google_storage_bucket_iam_binding.\(r)": {id: "b/\(nm) \(rl)", project: P.id}
				}
			}
		}

		for nm, s in P.secrets if P.adoptAll || adopted.secrets[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/secrets/\(nm)"
			tofu: resource: google_secret_manager_secret: (k): {depends_on: deps, project: P.id, secret_id: nm, replication: auto: {}, lifecycle: prevent_destroy: true}
			// Its grants name it by reference, so OpenTofu makes the secret before granting on it.
			let sid = "${google_secret_manager_secret.\(k).secret_id}"
			if !s.made {
				_imports: "google_secret_manager_secret.\(k)": {id: at, project: P.id}
			}

			// A file's one value: a new version whenever the file changes, never imported (the versions
			// already there stay as they are).
			if s.file != _|_ {
				tofu: resource: google_secret_manager_secret_version: (k): {secret: "${google_secret_manager_secret.\(k).id}", secret_data: "${file(\"${path.module}/../\(s.file)\")}", deletion_policy: "ABANDON", lifecycle: create_before_destroy: true}
			}
			if s.text != _|_ {
				tofu: resource: google_secret_manager_secret_version: (k): {secret: "${google_secret_manager_secret.\(k).id}", secret_data: s.text, deletion_policy: "ABANDON", lifecycle: create_before_destroy: true}
			}
			if s.placeholder != _|_ {
				tofu: resource: google_secret_manager_secret_version: (k): {secret: "${google_secret_manager_secret.\(k).id}", secret_data: s.placeholder, deletion_policy: "ABANDON", lifecycle: ignore_changes: ["secret_data", "enabled"]}
			}
			if s.random {
				tofu: resource: random_password: (k): {length: 48, special: false}
				tofu: resource: google_secret_manager_secret_version: (k): {secret: "${google_secret_manager_secret.\(k).id}", secret_data: "${random_password.\(k).result}", deletion_policy: "ABANDON"}
			}
			if len(s.adders) > 0 {
				let r = "\(k)_adders"
				tofu: resource: google_secret_manager_secret_iam_binding: (r): {depends_on: list.Concat([deps, [for m, _ in s.adders if accounts[m] != _|_ {accounts[m]}]]), project: P.id, secret_id: sid, role: "roles/secretmanager.secretVersionAdder", members: (#members & {in: s.adders}).out}
				if !s.made && !s.newGrants {
					_imports: "google_secret_manager_secret_iam_binding.\(r)": {id: "\(at) roles/secretmanager.secretVersionAdder", project: P.id}
				}
			}
			if len(s.accessors) > 0 {
				tofu: resource: google_secret_manager_secret_iam_binding: (k): {depends_on: list.Concat([deps, [for m, _ in s.accessors if accounts[m] != _|_ {accounts[m]}]]), project: P.id, secret_id: sid, role: "roles/secretmanager.secretAccessor", members: (#members & {in: s.accessors}).out}
				// A secret made here has no grant to import either, nor one whose grants are new.
				if !s.made && !s.newGrants {
					_imports: "google_secret_manager_secret_iam_binding.\(k)": {id: "\(at) roles/secretmanager.secretAccessor", project: P.id}
				}
			}
		}

		for nm, j in P.runJobs if P.adoptAll || adopted.runJobs[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_cloud_run_v2_job: (k): {depends_on: ownDeps
				name:                nm
				project:             P.id
				location:            j.location
				deletion_protection: true
				template: {
					task_count: j.tasks
					template: {
						containers: [{
							image:   j.image
							command: j.command
							args:    j.args
							resources: limits: {cpu: j.cpu, memory: j.memory}
						}]
						timeout:         j.timeout
						max_retries:     j.maxRetries
						service_account: j.serviceAccount
					}
				}
				lifecycle: ignore_changes: ["template[0].template[0].containers[0].image"]
			}
			if fresh.runJobs[nm] == _|_ {_imports: "google_cloud_run_v2_job.\(k)": {id: "projects/\(P.id)/locations/\(j.location)/jobs/\(nm)", project: P.id}}
		}

		for nm, svc in P.runServices if P.adoptAll || adopted.runServices[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/locations/\(svc.location)/services/\(nm)"

			// Every secret a file of a sidecar reads that the service's own files do not, once: its
			// volumes follow the service's, which stay in the order of their directories.
			let own = {for _, f in svc.secretFiles {(f.secret): true}}
			let extra = {for _, sc in svc.sidecars for _, f in sc.secretFiles if own[f.secret] == _|_ {(f.secret): f}}

			tofu: resource: google_cloud_run_v2_service: (k): {
				depends_on:          ownDeps
				name:                nm
				project:             P.id
				location:            svc.location
				deletion_protection: true
				template: {
					service_account: svc.serviceAccount
					timeout:         svc.timeout
					scaling: {max_instance_count: svc.maxInstances, if svc.minInstances > 0 {min_instance_count: svc.minInstances}}
					if svc.concurrency != _|_ {max_instance_request_concurrency: svc.concurrency}
					containers: list.Concat([[{
						if len(svc.sidecars) > 0 {name: nm}
						image: svc.image
						args:  svc.args
						ports: {container_port: svc.port, name: "http1"}
						resources: {limits: {cpu: svc.cpu, memory: svc.memory}, cpu_idle: svc.cpuIdle, startup_cpu_boost: true}
						env: list.Concat([
							[for n in list.SortStrings([for n, _ in svc.env {n}]) {name: n, value: svc.env[n]}],
							[for n in list.SortStrings([for n, _ in svc.secretEnv {n}]) {name: n, value_source: secret_key_ref: {secret: svc.secretEnv[n], version: [if readAt[svc.secretEnv[n]] != _|_ {readAt[svc.secretEnv[n]]}, "latest"][0]}}],
						])
						volume_mounts: list.Concat([
							[for d in list.SortStrings([for d, _ in svc.secretFiles {d}]) {name: svc.secretFiles[d].secret, mount_path: d}],
							if len(svc.sqlInstances) > 0 {[{name: "cloudsql", mount_path: "/cloudsql"}]},
							if len(svc.sqlInstances) == 0 {[]},
						])
					}], [for sn in list.SortStrings([for sn, _ in svc.sidecars {sn}]) {
						let sc = svc.sidecars[sn]
						name:  sn
						image: sc.image
						args:  sc.args
						resources: {limits: {cpu: sc.cpu, memory: sc.memory}, cpu_idle: svc.cpuIdle}
						env: [for n in list.SortStrings([for n, _ in sc.env {n}]) {name: n, value: sc.env[n]}]
						if len(sc.secretFiles) > 0 {
							volume_mounts: [for d in list.SortStrings([for d, _ in sc.secretFiles {d}]) {name: sc.secretFiles[d].secret, mount_path: d}]
						}
					}]])
					volumes: list.Concat([
						[for d in list.SortStrings([for d, _ in svc.secretFiles {d}]) {
							let f = svc.secretFiles[d]
							name: f.secret
							secret: {secret: f.secret, items: [{version: [if readAt[f.secret] != _|_ {readAt[f.secret]}, "latest"][0], path: f.path}]}
						}],
						[for sname in list.SortStrings([for sname, _ in extra {sname}]) {
							let f = extra[sname]
							name: f.secret
							secret: {secret: f.secret, items: [{version: [if readAt[f.secret] != _|_ {readAt[f.secret]}, "latest"][0], path: f.path}]}
						}],
						if len(svc.sqlInstances) > 0 {[{name: "cloudsql", cloud_sql_instance: instances: svc.sqlInstances}]},
						if len(svc.sqlInstances) == 0 {[]},
					])
				}
				// gcloud and the console stamp who last deployed; that is no change of the service.
				lifecycle: ignore_changes: ["client", "client_version"]
			}
			if fresh.runServices[nm] == _|_ {_imports: "google_cloud_run_v2_service.\(k)": {id: at, project: P.id}}
			tofu: resource: google_cloud_run_v2_service_iam_binding: (k): {depends_on: list.Concat([deps, [for m, _ in svc.invokers if accounts[m] != _|_ {accounts[m]}]]), project: P.id, location: svc.location, name: "${google_cloud_run_v2_service.\(k).name}", role: "roles/run.invoker", members: (#members & {in: svc.invokers}).out}
			if fresh.runServiceIam[nm] == _|_ {_imports: "google_cloud_run_v2_service_iam_binding.\(k)": {id: "\(at) roles/run.invoker", project: P.id}}

			// A domain is mapped here, never imported: the DNS record to it is the registrar's.
			if svc.domain != _|_ {
				tofu: resource: google_cloud_run_domain_mapping: (k): {
					depends_on: ["google_cloud_run_v2_service.\(k)"]
					project:  P.id
					location: svc.location
					name:     svc.domain
					metadata: namespace: P.id
					spec: route_name:    "${google_cloud_run_v2_service.\(k).name}"
				}
			}
		}

		// The provider that bills this project for the APIs that ask a quota project of a user's login.
		let q = "google.\(p)"

		for key, ak in P.apiKeys if P.adoptAll || adopted.apiKeys[key] != _|_ {
			let k = (#name & {in: "\(P.id)_\(key)"}).out
			tofu: resource: google_apikeys_key: (k): {
				provider:     q
				depends_on:   deps
				project:      P.id
				name:         key
				display_name: ak.displayName
				if len(ak.services) > 0 || len(ak.referrers) > 0 {
					restrictions: {
						if len(ak.services) > 0 {api_targets: [for svc in ak.services {service: svc}]}
						if len(ak.referrers) > 0 {browser_key_restrictions: allowed_referrers: ak.referrers}
					}
				}
				lifecycle: prevent_destroy: true
			}
			if fresh.apiKeys[key] == _|_ {_imports: "google_apikeys_key.\(k)": {id: "projects/\(P.id)/locations/global/keys/\(key)", project: P.id}}
		}

		if P.identityPlatform != _|_ if P.adoptAll || adopted.identityPlatform.config != _|_ {
			let c = P.identityPlatform
			tofu: resource: google_identity_platform_config: (p): {
				provider:           q
				depends_on:         deps
				project:            P.id
				authorized_domains: c.authorizedDomains
				// Written whole, off as well as on, since Google reads back both providers.
				sign_in: {
					phone_number: enabled: c.phone
					email: {enabled: c.email, password_required: c.email}
				}
				if len(c.smsRegions) > 0 {sms_region_config: allowlist_only: allowed_regions: c.smsRegions}
				if len(c.blockingFunctions) > 0 {
					blocking_functions: {
						triggers: [for e in list.SortStrings([for e, _ in c.blockingFunctions {e}]) {event_type: e, function_uri: c.blockingFunctions[e]}]
						forward_inbound_credentials: {access_token: false, id_token: false, refresh_token: false}
					}
				}
				lifecycle: prevent_destroy: true
			}
			// Identity Platform is turned on before it is adopted: its config is always there to import.
			_imports: "google_identity_platform_config.\(p)": {id: "projects/\(P.id)/config", project: P.id}
		}

		for nm, b in P.budgets if P.adoptAll || adopted.budgets[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let account = strings.TrimPrefix(P.billing, "billingAccounts/")
			tofu: resource: google_billing_budget: (k): {
				provider:        q
				depends_on:      deps
				billing_account: account
				display_name:    b.displayName
				budget_filter: {
					if len(b.projects) > 0 {projects: b.projects}
					if len(b.services) > 0 {services: b.services}
					credit_types_treatment: b.creditTypesTreatment
					calendar_period:        b.period
				}
				amount: specified_amount: {currency_code: b.amount.currency, units: "\(b.amount.units)"}
				threshold_rules: list.Concat([
					[for t in b.current {threshold_percent: t, spend_basis: "CURRENT_SPEND"}],
					[for t in b.forecasted {threshold_percent: t, spend_basis: "FORECASTED_SPEND"}],
				])
				lifecycle: prevent_destroy: true
			}
			if fresh.budgets[nm] == _|_ {_imports: "google_billing_budget.\(k)": {id: "billingAccounts/\(account)/budgets/\(b.id)", project: P.id, found: true}}
		}

		for site, _ in P.hostingSites if P.adoptAll || adopted.hostingSites[site] != _|_ {
			let k = (#name & {in: "\(P.id)_\(site)"}).out
			tofu: resource: google_firebase_hosting_site: (k): {provider: "google-beta.\(p)", depends_on: deps, project: P.id, site_id: site, lifecycle: prevent_destroy: true}
			if fresh.hostingSites[site] == _|_ {_imports: "google_firebase_hosting_site.\(k)": {id: "projects/\(P.id)/sites/\(site)", project: P.id}}
		}

		// An alert subscriber per entry: a topic Monitoring publishes to and a pull subscription on it,
		// both named by the entry's file, which OpenTofu reads at plan time.
		for nm, sub in P.alertSubscribers if P.adoptAll || list.Contains(*P.adopt["topics"] | [], nm) {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let f = "jsondecode(file(\"${path.module}/../\(sub.file)\"))"
			tofu: data: google_project: (k): {project_id: P.id}
			tofu: resource: google_pubsub_topic: (k): {
				depends_on: deps
				project:    P.id
				name:       "${\(f).topic}"
			}
			// Monitoring's own notification account publishes to it, and nobody else.
			tofu: resource: google_pubsub_topic_iam_member: "\(k)_publisher": {
				project: P.id
				topic:   "${google_pubsub_topic.\(k).name}"
				role:    "roles/pubsub.publisher"
				member:  "serviceAccount:service-${data.google_project.\(k).number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
			}
			// A pull subscription that never expires: it keeps a week of unread alerts while the subscriber is away.
			tofu: resource: google_pubsub_subscription: (k): {
				project:                    P.id
				name:                       "${\(f).subscription}"
				topic:                      "${google_pubsub_topic.\(k).id}"
				ack_deadline_seconds:       "${\(f).ackDeadlineSeconds}"
				message_retention_duration: "${\(f).messageRetentionDuration}"
				retain_acked_messages:      false
				expiration_policy: ttl: ""
			}
			for m in list.SortStrings([for m, _ in sub.subscribers {m}]) {
				tofu: resource: google_pubsub_subscription_iam_member: "\((#name & {in: "\(k)_\(m)"}).out)": {
					project:      P.id
					subscription: "${google_pubsub_subscription.\(k).name}"
					role:         "roles/pubsub.subscriber"
					member:       m
				}
			}
		}

		// The subscribers a policy or a check is sent to: those whose topic and channel are both adopted.
		let subNames = [for nm, _ in P.alertSubscribers if P.adoptAll || (list.Contains(*P.adopt["topics"] | [], nm) && list.Contains(*P.adopt["notificationChannels"] | [], nm)) {nm}]

		for nm, c in P.notificationChannels if P.adoptAll || list.Contains(*P.adopt["notificationChannels"] | [], nm) {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_monitoring_notification_channel: (k): {
				project:      P.id
				display_name: nm
				if c.email != _|_ {
					depends_on: deps
					type:       "email"
					labels: email_address: c.email
				}
				if c.pubsub != _|_ {
					let t = (#name & {in: "\(P.id)_\(c.pubsub.topic)"}).out
					type: "pubsub"
					labels: topic: "${google_pubsub_topic.\(t).id}"
					// Monitoring may publish before the channel is verified, and the topic is there.
					depends_on: list.Concat([deps, ["google_pubsub_topic.\(t)", "google_pubsub_topic_iam_member.\(t)_publisher"]])
				}
			}
		}

		// A custom metric's descriptor per entry, made before the policies that read it.
		for ty, d in P.metricDescriptors if P.adoptAll || list.Contains(*P.adopt["metricDescriptors"] | [], ty) {
			let k = (#name & {in: "\(P.id)_\(ty)"}).out
			tofu: resource: google_monitoring_metric_descriptor: (k): {
				depends_on:   deps
				project:      P.id
				type:         ty
				display_name: d.displayName
				description:  d.description
				metric_kind:  d.kind
				value_type:   d.valueType
				unit:         d.unit
				// Deleting a descriptor wipes its time series.
				lifecycle: prevent_destroy: true
				labels: [for lk in list.SortStrings([for l, _ in d.labels {l}]) {key: lk, value_type: d.labels[lk].valueType, description: d.labels[lk].description}]
			}
		}

		let metricDeps = [for ty, _ in P.metricDescriptors if P.adoptAll || list.Contains(*P.adopt["metricDescriptors"] | [], ty) {"google_monitoring_metric_descriptor.\((#name & {in: "\(P.id)_\(ty)"}).out)"}]

		// One policy per entry of the file: OpenTofu reads it at plan time, so the policies follow
		// the file with no export of this state's.
		for nm, a in P.alertPolicies if P.adoptAll || list.Contains(*P.adopt["alertPolicies"] | [], nm) {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let chs = (#chans & {in: a.channels, subs: subNames, to: a.toSubscribers}).out
			if a.file != _|_ {
				tofu: resource: google_monitoring_alert_policy: (k): {
					depends_on: list.Concat([deps, metricDeps, [for c in chs {"google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out)"}]])
					for_each:     "${{for p in jsondecode(file(\"${path.module}/../\(a.file)\")) : p.name => p}}"
					project:      P.id
					display_name: "${each.value.displayName}"
					combiner:     "OR"
					severity:     "${each.value.severity == \"page\" ? \"CRITICAL\" : \"WARNING\"}"
					user_labels:  "${each.value.labels}"
					notification_channels: [for c in chs {"${google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out).id}"}]
					documentation: {content: "${each.value.documentation}", mime_type: "text/markdown"}
					conditions: [{
						display_name: "${each.value.displayName}"
						condition_prometheus_query_language: {
							query:               "${each.value.expr}"
							duration:            "${each.value.duration}"
							evaluation_interval: "${try(each.value.interval, \"60s\")}"
						}
					}]
					// A burn that stops resolves the incident; one that never fires again closes in a day.
					alert_strategy: auto_close: "86400s"
				}
			}

			// The same policy, written in the state: one resource each, named for the entry.
			for pn, pol in a.policies {
				let pk = (#name & {in: "\(P.id)_\(nm)_\(pn)"}).out
				tofu: resource: google_monitoring_alert_policy: (pk): {
					depends_on: list.Concat([deps, metricDeps, [for c in chs {"google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out)"}]])
					project:      P.id
					display_name: pol.displayName
					combiner:     "OR"
					severity: [if pol.severity == "page" {"CRITICAL"}, "WARNING"][0]
					user_labels: pol.labels
					notification_channels: [for c in chs {"${google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out).id}"}]
					documentation: {content: pol.documentation, mime_type: "text/markdown"}
					conditions: [{
						display_name: pol.displayName
						condition_prometheus_query_language: {
							query:               pol.expr
							duration:            pol.duration
							evaluation_interval: pol.interval
						}
					}]
					alert_strategy: auto_close: "86400s"
				}
			}
		}

		// An outside check per entry, and a policy on it: it mails the channels when the check
		// fails from at least failingLocations checker locations for the window. Never imported.
		for nm, u in P.uptimeChecks if P.adoptAll || list.Contains(*P.adopt["uptimeChecks"] | [], nm) {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let chs = (#chans & {in: u.channels, subs: subNames, to: u.toSubscribers}).out
			tofu: resource: google_monitoring_uptime_check_config: (k): {
				depends_on:       deps
				project:          P.id
				display_name:     nm
				period:           u.period
				timeout:          u.timeout
				selected_regions: u.regions
				http_check: {
					path:           u.path
					port:           443
					use_ssl:        true
					validate_ssl:   true
					request_method: "GET"
					accepted_response_status_codes: [{status_class: "STATUS_CLASS_2XX"}]
				}
				monitored_resource: {
					type: "uptime_url"
					labels: {project_id: P.id, host: u.host}
				}
			}
			tofu: resource: google_monitoring_alert_policy: "\(k)_uptime": {
				depends_on: list.Concat([deps, [for c in chs {"google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out)"}]])
				project:      P.id
				display_name: "Uptime: \(nm)"
				combiner:     "OR"
				severity: [if u.severity == "page" {"CRITICAL"}, "WARNING"][0]
				notification_channels: [for c in chs {"${google_monitoring_notification_channel.\((#name & {in: "\(P.id)_\(c)"}).out).id}"}]
				documentation: {content: u.documentation, mime_type: "text/markdown"}
				conditions: [{
					display_name: "\(u.host)\(u.path) fails from \(u.failingLocations) or more checker locations"
					condition_threshold: {
						filter:          "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.\(k).uptime_check_id}\" AND resource.type=\"uptime_url\""
						comparison:      "COMPARISON_GT"
						threshold_value: u.failingLocations - 1
						duration:        u.window
						trigger: count: 1
						aggregations: [{
							alignment_period:     "60s"
							per_series_aligner:   "ALIGN_NEXT_OLDER"
							cross_series_reducer: "REDUCE_COUNT_FALSE"
							group_by_fields: ["resource.label.host"]
						}]
					}
				}]
				// A whole-node outage stays one incident; one that recovers closes in a day.
				alert_strategy: auto_close: "86400s"
			}
		}

		// A pool and its providers are made, never imported; a provider keeps the keys it is given.
		for pool, w in P.workloadIdentityPools if P.adoptAll || list.Contains(*P.adopt["workloadIdentityPools"] | [], pool) {
			let pk = (#name & {in: "\(P.id)_\(pool)"}).out
			tofu: resource: google_iam_workload_identity_pool: (pk): {
				depends_on:                deps
				project:                   P.id
				workload_identity_pool_id: pool
				if w.displayName != _|_ {display_name: w.displayName}
			}
			for pn, pr in w.providers {
				let k = (#name & {in: "\(P.id)_\(pool)_\(pn)"}).out
				tofu: resource: google_iam_workload_identity_pool_provider: (k): {
					project:                            P.id
					workload_identity_pool_id:          "${google_iam_workload_identity_pool.\(pk).workload_identity_pool_id}"
					workload_identity_pool_provider_id: pn
					attribute_mapping:                  pr.mapping
					if pr.condition != _|_ {attribute_condition: pr.condition}
					oidc: {
						issuer_uri: pr.issuer
						if len(pr.allowedAudiences) > 0 {allowed_audiences: pr.allowedAudiences}
						if pr.jwks != _|_ {jwks_json: pr.jwks}
					}
				}
			}
		}

		for inst, dbs in P.databases if P.adoptAll || adopted.databases[inst] != _|_ {
			for nm, _ in dbs {
				let k = (#name & {in: "\(P.id)_\(inst)_\(nm)"}).out
				tofu: resource: google_sql_database: (k): {project: P.id, instance: inst, name: nm, deletion_policy: "ABANDON"}
				if fresh.databases[inst] == _|_ if fresh.databases["\(inst)/\(nm)"] == _|_ {_imports: "google_sql_database.\(k)": {id: "projects/\(P.id)/instances/\(inst)/databases/\(nm)", project: P.id}}
			}
		}

		// An instance someone else keeps, of which OpenTofu holds the backups alone: imported, never
		// made, destroyed or replaced, and every setting but backup_configuration left as it is.
		// What is being retired (#Project.retire): held, it is imported with its deletion protection off and
		// every other setting ignored, so the import changes nothing but that; dropped, it is in no
		// configuration, and OpenTofu destroys what its state still holds. Its address is the one a kept
		// resource of its kind has, so a resource kept until now is held without being replaced.
		for nm, r in P.retire.runServices if r.phase == "hold" {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_cloud_run_v2_service: (k): {
				name:                nm
				project:             P.id
				location:            r.location
				deletion_protection: false
				template: containers: [{image: _retiredImage}]
				lifecycle: ignore_changes: ["template", "traffic", "labels", "annotations", "client", "client_version", "ingress", "launch_stage", "binary_authorization", "custom_audiences", "scaling", "description", "invoker_iam_disabled", "default_uri_disabled"]
			}
			_imports: "google_cloud_run_v2_service.\(k)": {id: "projects/\(P.id)/locations/\(r.location)/services/\(nm)", project: P.id}
		}
		for nm, r in P.retire.runJobs if r.phase == "hold" {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_cloud_run_v2_job: (k): {
				name:                nm
				project:             P.id
				location:            r.location
				deletion_protection: false
				template: template: containers: [{image: _retiredImage}]
				lifecycle: ignore_changes: ["template", "labels", "annotations", "client", "client_version", "launch_stage", "binary_authorization"]
			}
			_imports: "google_cloud_run_v2_job.\(k)": {id: "projects/\(P.id)/locations/\(r.location)/jobs/\(nm)", project: P.id}
		}
		for nm, r in P.retire.schedulerJobs if r.phase == "hold" {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_cloud_scheduler_job: (k): {
				name:    nm
				project: P.id
				region:  r.location
				http_target: uri: "https://retired.invalid/"
				lifecycle: ignore_changes: ["http_target", "schedule", "time_zone", "description", "attempt_deadline", "retry_config", "paused"]
			}
			_imports: "google_cloud_scheduler_job.\(k)": {id: "projects/\(P.id)/locations/\(r.location)/jobs/\(nm)", project: P.id}
		}

		// A bucket is held with force_destroy on and every other setting left as it is, so the drop's destroy empties it.
		for nm, r in P.retire.buckets if r.phase == "hold" {
			let k = (#name & {in: nm}).out
			tofu: resource: google_storage_bucket: (k): {
				name:          nm
				project:       P.id
				location:      r.location
				force_destroy: true
				lifecycle: ignore_changes: ["location", "storage_class", "versioning", "uniform_bucket_level_access", "public_access_prevention", "labels", "lifecycle_rule", "cors", "website", "logging", "encryption", "soft_delete_policy", "autoclass", "retention_policy", "custom_placement_config", "enable_object_retention", "requester_pays", "rpo", "hierarchical_namespace", "ip_filter"]
			}
			_imports: "google_storage_bucket.\(k)": {id: "\(P.id)/\(nm)", project: P.id}
		}
		for inst, r in P.retire.sqlInstances if r.phase == "hold" {
			let k = (#name & {in: "\(P.id)_\(inst)"}).out
			tofu: resource: google_sql_database_instance: (k): {
				project:             P.id
				name:                inst
				region:              r.location
				database_version:    r.databaseVersion
				deletion_protection: false
				settings: {tier: r.tier, deletion_protection_enabled: false}
				lifecycle: ignore_changes: list.Concat([
					["database_version", "root_password", "settings[0].tier", "settings[0].backup_configuration"],
					[for a in _sqlInstanceOthers if a != "deletion_protection_enabled" {"settings[0].\(a)"}],
				])
			}
			_imports: "google_sql_database_instance.\(k)": {id: "projects/\(P.id)/instances/\(inst)", project: P.id}
		}

		for inst, b in P.sqlBackups if P.adoptAll || adopted.sqlBackups[inst] != _|_ {
			let k = (#name & {in: "\(P.id)_\(inst)"}).out
			tofu: resource: google_sql_database_instance: (k): {
				project:             P.id
				name:                inst
				region:              b.region
				database_version:    b.databaseVersion
				deletion_protection: true
				settings: {
					tier: b.tier
					backup_configuration: {
						enabled:                        true
						start_time:                     b.startTime
						point_in_time_recovery_enabled: b.pointInTimeRecovery
						transaction_log_retention_days: b.transactionLogDays
						backup_retention_settings: {retained_backups: b.retainedBackups, retention_unit: "COUNT"}
					}
				}
				lifecycle: {
					prevent_destroy: true
					ignore_changes: list.Concat([
						["database_version", "root_password", "settings[0].tier"],
						[for a in _sqlInstanceOthers {"settings[0].\(a)"}],
					])
				}
			}
			_imports: "google_sql_database_instance.\(k)": {id: "projects/\(P.id)/instances/\(inst)", project: P.id}
		}

		// A user's password is made by OpenTofu (random_password) and written as a version of the
		// secrets named, so it is in OpenTofu's state (a private, versioned bucket) and in Secret
		// Manager, never in this one. A user is always made here, never imported.
		for inst, us in P.sqlUsers if P.adoptAll || adopted.sqlUsers[inst] != _|_ {
			for nm, c in us {
				let k = (#name & {in: "\(P.id)_\(inst)_\(nm)"}).out
				tofu: resource: random_password: (k): {length: 32, special: false}
				tofu: resource: google_sql_user: (k): {project: P.id, instance: inst, name: nm, password: "${random_password.\(k).result}", deletion_policy: "ABANDON"}
				tofu: resource: google_secret_manager_secret_version: "\(k)_password": {
					depends_on: ["google_sql_user.\(k)"]
					secret:          "${google_secret_manager_secret.\((#name & {in: "\(P.id)_\(c.password)"}).out).id}"
					secret_data:     "${random_password.\(k).result}"
					deletion_policy: "ABANDON"
				}
				if c.url != _|_ {
					tofu: resource: google_secret_manager_secret_version: "\(k)_url": {
						depends_on: ["google_sql_user.\(k)"]
						secret:          "${google_secret_manager_secret.\((#name & {in: "\(P.id)_\(c.url)"}).out).id}"
						secret_data:     "postgresql://\(nm):${random_password.\(k).result}@localhost/\(c.database)?host=/cloudsql/\(P.id):\(c.region):\(inst)\(c.query)"
						deletion_policy: "ABANDON"
					}
				}
			}
		}
	}
}

// What a held Cloud Run service or job is configured with: the provider requires an image, and a held
// one's template is ignored, so this is never deployed.
_retiredImage: "us-docker.pkg.dev/cloudrun/container/hello"

// The settings of a Cloud SQL instance (google 7.x) other than its tier and backup_configuration,
// which an instance whose backups alone are this state's (sqlBackups) leaves to its owner.
_sqlInstanceOthers: [
	"activation_policy", "auto_upgrade_enabled", "availability_type", "collation", "connector_enforcement",
	"data_api_access", "data_disk_provisioned_iops", "data_disk_provisioned_throughput",
	"deletion_protection_enabled", "disk_autoresize", "disk_autoresize_limit", "disk_size", "disk_type",
	"edition", "enable_dataplex_integration", "enable_google_ml_integration", "pricing_plan",
	"replication_lag_max_seconds", "retain_backups_on_delete", "time_zone", "user_labels", "active_directory_config",
	"advanced_machine_features", "connection_pool_config", "data_cache_config", "database_flags",
	"deny_maintenance_period", "entraid_config", "final_backup_config", "insights_config",
	"ip_configuration", "location_preference", "maintenance_window", "password_validation_policy",
	"read_pool_auto_scale_config", "sql_server_audit_config",
]
