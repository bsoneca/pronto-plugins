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

#Plan: Plan={
	state:   #State
	backend: #Backend

	tofu: {
		terraform: {
			required_version: ">= 1.13.0"
			required_providers: google: {source: "hashicorp/google", version: "~> 7.0"}
			backend: gcs: {bucket: Plan.backend.bucket, prefix: Plan.backend.prefix}
		}
		// The operator's own gcloud login, as a token in GOOGLE_OAUTH_ACCESS_TOKEN (say.cue.txt).
		provider: google: {}
		resource: {}
		import: [for i in _imports if !state.projects[i.project].create {to: i.to, id: i.id}]
	}

	// Each import names its project: one this state makes (create) has nothing to import, its
	// resources all new, so its imports are left out.
	_imports: [Address=string]: {to: Address, id: string, project: string}

	for P in state.projects {
		let adopted = {
			for kind in ["apis", "iam", "members", "serviceAccounts", "repositories", "repositoryIam", "buckets", "secrets", "runJobs", "runServices", "databases"] {
				(kind): {for n in *P.adopt[kind] | [] {(n): true}}
			}
		}
		let p = (#name & {in: P.id}).out

		if P.adoptAll {
			tofu: resource: google_project: (p): {
				project_id:      P.id
				name:            P.name
				billing_account: strings.TrimPrefix(P.billing, "billingAccounts/")
				deletion_policy: "PREVENT"
			}
			_imports: "google_project.\(p)": {id: P.id, project: P.id}
		}

		for svc, _ in P.apis if P.adoptAll || adopted.apis[svc] != _|_ {
			let k = (#name & {in: "\(P.id)_\(svc)"}).out
			tofu: resource: google_project_service: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, service: svc, disable_on_destroy: false, disable_dependent_services: false}
			_imports: "google_project_service.\(k)": {id: "\(P.id)/\(svc)", project: P.id}
		}

		for rl, ms in P.iam if P.adoptAll || adopted.iam[rl] != _|_ {
			let k = (#name & {in: "\(P.id)_\(rl)"}).out
			tofu: resource: google_project_iam_binding: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, role: rl, members: (#members & {in: ms}).out}
			_imports: "google_project_iam_binding.\(k)": {id: "\(P.id) \(rl)", project: P.id}
		}

		for rl, ms in P.members if P.adoptAll || adopted.members[rl] != _|_ {
			for m, _ in ms {
				let k = (#name & {in: "\(P.id)_\(rl)_\(m)"}).out
				tofu: resource: google_project_iam_member: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, role: rl, member: m}
				_imports: "google_project_iam_member.\(k)": {id: "\(P.id) \(rl) \(m)", project: P.id}
			}
		}

		for nm, sa in P.serviceAccounts if P.adoptAll || adopted.serviceAccounts[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/serviceAccounts/\(sa.email)"
			tofu: resource: google_service_account: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, account_id: nm, display_name: sa.displayName}
			_imports: "google_service_account.\(k)": {id: at, project: P.id}
			for rl, ms in sa.iam {
				let r = (#name & {in: "\(P.id)_\(nm)_\(rl)"}).out
				tofu: resource: google_service_account_iam_binding: (r): {if P.create {depends_on: ["google_project.\(p)"]}, service_account_id: at, role: rl, members: (#members & {in: ms}).out}
				_imports: "google_service_account_iam_binding.\(r)": {id: "\(at) \(rl)", project: P.id}
			}
		}

		for nm, repo in P.repositories if P.adoptAll || adopted.repositories[nm] != _|_ || adopted.repositoryIam[nm] != _|_ {
			let at = "projects/\(P.id)/locations/\(repo.location)/repositories/\(nm)"
			if P.adoptAll || adopted.repositories[nm] != _|_ {
				let k = (#name & {in: "\(P.id)_\(nm)"}).out
				tofu: resource: google_artifact_registry_repository: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, location: repo.location, repository_id: nm, format: repo.format}
				_imports: "google_artifact_registry_repository.\(k)": {id: at, project: P.id}
			}
			for rl, ms in repo.iam {
				let r = (#name & {in: "\(P.id)_\(nm)_\(rl)"}).out
				tofu: resource: google_artifact_registry_repository_iam_binding: (r): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, location: repo.location, repository: nm, role: rl, members: (#members & {in: ms}).out}
				_imports: "google_artifact_registry_repository_iam_binding.\(r)": {id: "\(at) \(rl)", project: P.id}
			}
		}

		for nm, b in P.buckets if P.adoptAll || adopted.buckets[nm] != _|_ {
			let k = (#name & {in: nm}).out
			tofu: resource: google_storage_bucket: (k): {if P.create {depends_on: ["google_project.\(p)"]}
				name:                        nm
				project:                     P.id
				location:                    b.location
				uniform_bucket_level_access: b.uniformAccess
				public_access_prevention:    b.publicPrevention
				force_destroy:               false
				versioning: enabled: b.versioning
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
				tofu: resource: google_storage_bucket_iam_binding: (r): {if P.create {depends_on: ["google_project.\(p)"]}, bucket: "${google_storage_bucket.\(k).name}", role: rl, members: (#members & {in: ms}).out}
				if !b.made {
					_imports: "google_storage_bucket_iam_binding.\(r)": {id: "b/\(nm) \(rl)", project: P.id}
				}
			}
		}

		for nm, s in P.secrets if P.adoptAll || adopted.secrets[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/secrets/\(nm)"
			tofu: resource: google_secret_manager_secret: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, secret_id: nm, replication: auto: {}}
			// Its grants name it by reference, so OpenTofu makes the secret before granting on it.
			let sid = "${google_secret_manager_secret.\(k).secret_id}"
			if !s.made {
				_imports: "google_secret_manager_secret.\(k)": {id: at, project: P.id}
			}

			// A file's one value: a new version whenever the file changes, never imported (the versions
			// already there stay as they are).
			if s.file != _|_ {
				tofu: resource: google_secret_manager_secret_version: (k): {secret: "${google_secret_manager_secret.\(k).id}", secret_data: "${file(\"${path.module}/../\(s.file)\")}"}
			}
			if len(s.adders) > 0 {
				let r = "\(k)_adders"
				tofu: resource: google_secret_manager_secret_iam_binding: (r): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, secret_id: sid, role: "roles/secretmanager.secretVersionAdder", members: (#members & {in: s.adders}).out}
				if !s.made && !s.newGrants {
					_imports: "google_secret_manager_secret_iam_binding.\(r)": {id: "\(at) roles/secretmanager.secretVersionAdder", project: P.id}
				}
			}
			if len(s.accessors) > 0 {
				tofu: resource: google_secret_manager_secret_iam_binding: (k): {if P.create {depends_on: ["google_project.\(p)"]}, project: P.id, secret_id: sid, role: "roles/secretmanager.secretAccessor", members: (#members & {in: s.accessors}).out}
				// A secret made here has no grant to import either, nor one whose grants are new.
				if !s.made && !s.newGrants {
					_imports: "google_secret_manager_secret_iam_binding.\(k)": {id: "\(at) roles/secretmanager.secretAccessor", project: P.id}
				}
			}
		}

		for nm, j in P.runJobs if P.adoptAll || adopted.runJobs[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			tofu: resource: google_cloud_run_v2_job: (k): {if P.create {depends_on: ["google_project.\(p)"]}
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
			_imports: "google_cloud_run_v2_job.\(k)": {id: "projects/\(P.id)/locations/\(j.location)/jobs/\(nm)", project: P.id}
		}

		for nm, svc in P.runServices if P.adoptAll || adopted.runServices[nm] != _|_ {
			let k = (#name & {in: "\(P.id)_\(nm)"}).out
			let at = "projects/\(P.id)/locations/\(svc.location)/services/\(nm)"

			// A secret this state keeps the version of is read at that version; any other at its latest.
			let readAt = {
				for _, f in svc.secretFiles {
					(f.secret): *"latest" | string
					if P.secrets[f.secret].file != _|_ {
						(f.secret): "${google_secret_manager_secret_version.\((#name & {in: "\(P.id)_\(f.secret)"}).out).version}"
					}
				}
			}
			tofu: resource: google_cloud_run_v2_service: (k): {if P.create {depends_on: ["google_project.\(p)"]}
				name:                nm
				project:             P.id
				location:            svc.location
				deletion_protection: true
				template: {
					service_account: svc.serviceAccount
					timeout:         svc.timeout
					scaling: max_instance_count: svc.maxInstances
					containers: [{
						image: svc.image
						args:  svc.args
						ports: {container_port: svc.port, name: "http1"}
						resources: {limits: {cpu: svc.cpu, memory: svc.memory}, cpu_idle: true, startup_cpu_boost: true}
						env: list.Concat([
							[for n in list.SortStrings([for n, _ in svc.env {n}]) {name: n, value: svc.env[n]}],
							[for n in list.SortStrings([for n, _ in svc.secretEnv {n}]) {name: n, value_source: secret_key_ref: {secret: svc.secretEnv[n], version: "latest"}}],
						])
						volume_mounts: list.Concat([
							[for d in list.SortStrings([for d, _ in svc.secretFiles {d}]) {name: svc.secretFiles[d].secret, mount_path: d}],
							if len(svc.sqlInstances) > 0 {[{name: "cloudsql", mount_path: "/cloudsql"}]},
							if len(svc.sqlInstances) == 0 {[]},
						])
					}]
					volumes: list.Concat([
						[for d in list.SortStrings([for d, _ in svc.secretFiles {d}]) {
							let f = svc.secretFiles[d]
							name: f.secret
							secret: {secret: f.secret, items: [{version: readAt[f.secret], path: f.path}]}
						}],
						if len(svc.sqlInstances) > 0 {[{name: "cloudsql", cloud_sql_instance: instances: svc.sqlInstances}]},
						if len(svc.sqlInstances) == 0 {[]},
					])
				}
				// gcloud and the console stamp who last deployed; that is no change of the service.
				lifecycle: ignore_changes: ["client", "client_version"]
			}
			_imports: "google_cloud_run_v2_service.\(k)": {id: at, project: P.id}
			tofu: resource: google_cloud_run_v2_service_iam_binding: (k): {project: P.id, location: svc.location, name: "${google_cloud_run_v2_service.\(k).name}", role: "roles/run.invoker", members: (#members & {in: svc.invokers}).out}
			_imports: "google_cloud_run_v2_service_iam_binding.\(k)": {id: "\(at) roles/run.invoker", project: P.id}
		}

		for inst, dbs in P.databases if P.adoptAll || adopted.databases[inst] != _|_ {
			for nm, _ in dbs {
				let k = (#name & {in: "\(P.id)_\(inst)_\(nm)"}).out
				tofu: resource: google_sql_database: (k): {project: P.id, instance: inst, name: nm, deletion_policy: "ABANDON"}
				_imports: "google_sql_database.\(k)": {id: "projects/\(P.id)/instances/\(inst)/databases/\(nm)", project: P.id}
			}
		}
	}
}
