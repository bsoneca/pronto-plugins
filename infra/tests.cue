package infra

import (
	"strings"
)

_plan: #Plan & {
	backend: {bucket: "my-org-infra-tfstate", project: "example-project-123"}
	state: projects: {
		"example-project-123": {
			billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
			apis: "run.googleapis.com": true
			iam: "roles/viewer": {"user:b@example.com": true, "user:a@example.com": true}
			adopt: iam: ["roles/viewer"]
			serviceAccounts: "my-app-run": displayName: "my-app"
			buckets: "my-app-assets": {
				location:         "us-central1"
				uniformAccess:    true
				publicPrevention: "enforced"
				deleteAfterDays:  7
			}
			adopt: buckets: ["my-app-assets"]
		}
		"example-project-456": {
			create:  true
			billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
			apis: "run.googleapis.com": true
			secrets: "my-app-token": {
				source: "put by the operator"
				accessors: "user:a@example.com": true
				file: "config/token.txt"
			}
		}
	}
}
_tofu: _plan.tofu

// The schema holds what the live API would refuse.
badProjectID: "Example_Project" & matchN(0, [#ProjectID])
shortProjectID: "abc" & matchN(0, [#ProjectID])
goodProjectID: "example-project-123" & #ProjectID
badBilling: "012345" & matchN(0, [#Billing])
badMember: "someone@example.com" & matchN(0, [#Member])
badBucket: "A" & matchN(0, [#BucketName])
badApi: "run" & matchN(0, [=~"^[a-z0-9-]+\\.googleapis\\.com$"])

// Defaults: the display name is the id, nothing is adopted, a made project is adopted whole.
defaultName:          _plan.state.projects["example-project-123"].name & "example-project-123"
defaultAdopt:         _plan.state.projects["example-project-123"].adoptAll & false
createAdopts:         _plan.state.projects["example-project-456"].adoptAll & true
accountEmail:         _plan.state.projects["example-project-123"].serviceAccounts["my-app-run"].email & "my-app-run@example-project-123.iam.gserviceaccount.com"
defaultBackendPrefix: _plan.backend.prefix & "infra"

// A bucket anyone may read must say why; one nobody reads needs no reason.
publicNeedsWhy: matchN(0, [#Bucket & {
	location: "us-central1", uniformAccess: true, publicPrevention: "inherited"
	iam: "roles/storage.objectViewer": allUsers: true
}]) & true
publicWithWhy: (#Bucket & {
	location: "us-central1", uniformAccess: true, publicPrevention: "inherited"
	iam: "roles/storage.objectViewer": allUsers: true
	public: "a static site"
}).public & "a static site"

// The export: the backend, the provider, and only what each project adopts.
backendBucket: _tofu.terraform.backend.gcs.bucket & "my-org-infra-tfstate"
backendPrefix: _tofu.terraform.backend.gcs.prefix & "infra"
providerPin:   _tofu.terraform.required_providers.google.version & "~> 7.0"
onlyAdopted: [for k, _ in _tofu.resource.google_project_service {k}] & ["example_project_456_run_googleapis_com"]
adoptedRole: _tofu.resource.google_project_iam_binding.example_project_123_roles_viewer.role & "roles/viewer"
membersSorted: _tofu.resource.google_project_iam_binding.example_project_123_roles_viewer.members & ["user:a@example.com", "user:b@example.com"]
notAdopted: [for k, _ in _tofu.resource if k == "google_service_account" {k}] & []
bucketLifecycle: _tofu.resource.google_storage_bucket.my_app_assets.lifecycle_rule & [{action: type: "Delete", condition: age: 7}]
bucketNeverForceDestroyed: _tofu.resource.google_storage_bucket.my_app_assets.force_destroy & false

// A project this state makes: its project resource, its resources after it, and no import.
createdProject: _tofu.resource.google_project.example_project_456.deletion_policy & "PREVENT"
billingBare:    _tofu.resource.google_project.example_project_456.billing_account & "AAAAAA-BBBBBB-CCCCCC"
createdAfterProject: _tofu.resource.google_project_service.example_project_456_run_googleapis_com.depends_on & ["google_project.example_project_456"]
createdNotImported: [for i in _tofu.import if strings.Contains(i.id, "example-project-456") {i}] & []
foundImported: [for i in _tofu.import if i.to == "google_project_service.example_project_123_run_googleapis_com" {i.id}] & []

// A secret's file is read from beside the state folder, and its version rolls with the file.
secretFile: _tofu.resource.google_secret_manager_secret_version.example_project_456_my_app_token.secret_data & "$"+"{file(\"$"+"{path.module}/../config/token.txt\")}"

// The files the host writes: verbs, pins, the state to start from, a module for it.
_host: #Host & {module: "example.com/infra@v0", bucket: "my-org-infra-tfstate", project: "example-project-123"}
hostFiles: [for p, _ in _host.files {p}] & [".say.cue", ".mise.toml", ".gitignore", "cue.mod/module.cue", "state.cue"]
hostSeeded: [for p, f in _host.files if f.seed {p}] & ["cue.mod/module.cue", "state.cue"]
hostPins:           strings.Contains(_host.files[".mise.toml"].text, "opentofu = \"1.13.2\"") & true
hostVerbs:          strings.Contains(_host.files[".say.cue"].text, "verify: rulemap: infra:") & true
hostPlanReadsFresh: strings.Contains(_host.files[".say.cue"].text, "plan -input=false -detailed-exitcode") & true
hostStateBucket:    strings.Contains(_host.files["state.cue"].text, "bucket: \"my-org-infra-tfstate\"") & true

// Validation on real state values, not only on the patterns: each bad project is refused whole.
_ok: {id: "example-project-123", billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"}
okProject: _ok & matchN(1, [#Project])
bareMember: _ok & {iam: "roles/viewer": user: true} & matchN(0, [#Project])
badBucketKey: _ok & {buckets: A: {location: "us-central1", uniformAccess: true, publicPrevention: "enforced"}} & matchN(0, [#Project])
shortBilling: {id: "example-project-123", billing: "billingAccounts/A"} & matchN(0, [#Project])
bothIamAndMembers: _ok & {iam: "roles/viewer": "user:a@example.com": true, members: "roles/viewer": "user:b@example.com": true} & matchN(0, [#Project])
iamAndMembersApart: _ok & {iam: "roles/viewer": "user:a@example.com": true, members: "roles/editor": "user:b@example.com": true} & matchN(1, [#Project])
_bucket: {location: "us-central1", uniformAccess: true, publicPrevention: "inherited"}
publicAuthenticated: _ok & {buckets: "my-app-assets": _bucket & {iam: "roles/storage.objectViewer": allAuthenticatedUsers: true}} & matchN(0, [#Project])
publicAdmin: _ok & {buckets: "my-app-assets": _bucket & {iam: "roles/storage.objectAdmin": allUsers: true}} & matchN(0, [#Project])
publicExplained: _ok & {buckets: "my-app-assets": _bucket & {iam: "roles/storage.objectAdmin": allUsers: true, public: "a static site"}} & matchN(1, [#Project])

// What the plugin did not create is not destroyed by a plan of this state, and what it removes
// from the state is held by the verbs (say.cue.txt).
accountKept:        _s.google_service_account.example_project_123_my_app_run.lifecycle.prevent_destroy & true
bucketKept:         _tofu.resource.google_storage_bucket.my_app_assets.lifecycle.prevent_destroy & true
secretKept:         _tofu.resource.google_secret_manager_secret.example_project_456_my_app_token.lifecycle.prevent_destroy & true
verbsRefuseDeletes: strings.Contains(_host.files[".say.cue"].text, "INFRA_ALLOW_DESTROY") & true
verbsDropOldPlan:   strings.Contains(_host.files[".say.cue"].text, "{do: \"rm -f tofu/infra.tfplan tofu/infra.tfplan.tmp\"}") & true

// A grant that is new is made, not imported; one that is there is imported.
_new: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing:  "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adoptAll: true
		members: {"roles/viewer": "user:a@example.com": true, "roles/editor": "user:b@example.com": true}
		fresh: members: ["roles/editor"]
	}
}
freshNotImported: [for i in _new.tofu.import if strings.Contains(i.id, "roles/editor") {i}] & []
existingImported: [for i in _new.tofu.import if strings.Contains(i.id, "roles/viewer") {i.id}] & ["example-project-123 roles/viewer user:a@example.com"]

// A new service waits for its account, its secrets and the services it needs; its account's grants
// name the account by reference.
_svc: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing:  "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adoptAll: true
		apis: "run.googleapis.com": true
		serviceAccounts: "my-app-run": {displayName: "my-app", iam: "roles/iam.serviceAccountUser": "user:a@example.com": true}
		secrets: {
			"my-app-token": {source: "operator", accessors: "user:a@example.com": true, file: "config/token.txt"}
			"other": {source: "operator", accessors: "user:a@example.com": true}
		}
		runServices: "my-app": {
			location:       "us-central1", image:                                          "us-docker.pkg.dev/example-project-123/pronto/my-app:1", port: 8080
			serviceAccount: "my-app-run@example-project-123.iam.gserviceaccount.com", cpu: "1", memory:                                                   "512Mi", timeout: "300s", maxInstances: 2
			secretEnv: {TOKEN: "my-app-token", OTHER: "other"}
			invokers: "user:a@example.com": true
		}
	}
}
_s: _svc.tofu.resource
serviceWaits: _s.google_cloud_run_v2_service.example_project_123_my_app.depends_on & [
	"google_project_service.example_project_123_run_googleapis_com",
	"google_service_account.example_project_123_my_app_run",
	"google_secret_manager_secret.example_project_123_my_app_token",
	"google_secret_manager_secret.example_project_123_other",
	"google_secret_manager_secret_iam_binding.example_project_123_my_app_token",
	"google_secret_manager_secret_iam_binding.example_project_123_other",
	"google_secret_manager_secret_version.example_project_123_my_app_token",
]
accountGrantByReference: _s.google_service_account_iam_binding.example_project_123_my_app_run_roles_iam_serviceAccountUser.service_account_id & "${google_service_account.example_project_123_my_app_run.name}"
managedEnvVersion:       _s.google_cloud_run_v2_service.example_project_123_my_app.template.containers[0].env[1].value_source.secret_key_ref.version & "${google_secret_manager_secret_version.example_project_123_my_app_token.version}"
unmanagedEnvLatest:      _s.google_cloud_run_v2_service.example_project_123_my_app.template.containers[0].env[0].value_source.secret_key_ref.version & "latest"
rotationKeepsOld: _s.google_secret_manager_secret_version.example_project_123_my_app_token & {deletion_policy: "ABANDON", lifecycle: create_before_destroy: true}

// A secret described with a file but not adopted is not referenced: its reader takes the latest.
_draft: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adopt: runServices: ["my-app"]
		secrets: "my-app-token": {source: "operator", accessors: "user:a@example.com": true, file: "config/token.txt"}
		runServices: "my-app": _svc.state.projects["example-project-123"].runServices["my-app"]
	}
}
draftReadsLatest: _draft.tofu.resource.google_cloud_run_v2_service.example_project_123_my_app.template.containers[0].env[0].value_source.secret_key_ref.version & "latest"
draftNoVersion: [for k, _ in _draft.tofu.resource if k == "google_secret_manager_secret_version" {k}] & []

// The verbs: the destroy flag is exactly "1"; a plan is made apart and kept only once read; the
// whole state is vetted before it is exported; release reads the plan again before applying.
_verbs:                _host.files[".say.cue"].text
_verify:               strings.Split(strings.Split(_verbs, "verify: rulemap: infra")[1], "release: rulemap: infra")[0]
_release:              strings.Split(_verbs, "release: rulemap: infra")[1]
destroyFlagExact:      strings.Contains(_verbs, "$env.INFRA_ALLOW_DESTROY? != '1'") & true
planMadeApart:         strings.Contains(_verify, "-out=infra.tfplan.tmp") & true
planKeptAfterCheck:    strings.Index(_verify, "check-plan infra.tfplan.tmp") < strings.Index(_verify, "mv tofu/infra.tfplan.tmp tofu/infra.tfplan") & true
tmpRemovedOnFailure:   strings.Count(_verify, "rm -f tofu/infra.tfplan.tmp") & 2
planMustBeReadable:    strings.Contains(_verbs, "get -o format_version") & true
vetsBeforeExport:      strings.Index(_verify, "cue vet -c .") < strings.Index(_verify, "cue export . -e plan.tofu") & true
releaseReadsPlanAgain: strings.Index(_release, "check-plan infra.tfplan;") < strings.Index(_release, "apply -input=false infra.tfplan") & true

// fresh marks a binding on its own, so a parent that exists can be given a new binding; and it
// has no entry for a kind it cannot honour.
_binding: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing:  "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adoptAll: true
		serviceAccounts: "my-app-run": {displayName: "my-app", iam: "roles/iam.serviceAccountUser": "user:a@example.com": true}
		repositories: pronto: {location: "us-central1", format: "DOCKER", iam: "roles/artifactregistry.reader": "user:a@example.com": true}
		buckets: "my-app-assets": {location: "us-central1", uniformAccess: true, publicPrevention: "enforced", iam: "roles/storage.objectAdmin": "user:a@example.com": true}
		runServices: "my-app": {
			location:       "us-central1", image:                                          "us-docker.pkg.dev/example-project-123/pronto/my-app:1", port: 8080
			serviceAccount: "my-app-run@example-project-123.iam.gserviceaccount.com", cpu: "1", memory:                                                   "512Mi", timeout: "300s", maxInstances: 2
			invokers: "user:a@example.com": true
		}
		fresh: {
			serviceAccountIam: ["my-app-run/roles/iam.serviceAccountUser"]
			repositoryIam: ["pronto/roles/artifactregistry.reader"]
			bucketIam: ["my-app-assets/roles/storage.objectAdmin"]
			runServiceIam: ["my-app"]
		}
	}
}
_ims: [for i in _binding.tofu.import {i.to}]
parentsStillImported: [for a in _ims if a == "google_service_account.example_project_123_my_app_run" || a == "google_artifact_registry_repository.example_project_123_pronto" || a == "google_storage_bucket.my_app_assets" || a == "google_cloud_run_v2_service.example_project_123_my_app" {a}] & [
	"google_service_account.example_project_123_my_app_run",
	"google_storage_bucket.my_app_assets",
	"google_cloud_run_v2_service.example_project_123_my_app",
	"google_artifact_registry_repository.example_project_123_pronto",
]
bindingsNotImported: [for a in _ims if strings.Contains(a, "_iam_binding") {a}] & []
freshBucketsRefused: _ok & {fresh: buckets: ["my-app-assets"]} & matchN(0, [#Project])
freshSecretsRefused: _ok & {fresh: secrets: ["my-app-token"]} & matchN(0, [#Project])

// Ordering: a project grant waits for the accounts made beside it; a repository's grant for the
// repository; a service for its secrets' grants (above).
_order: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing:  "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adoptAll: true
		iam: "roles/viewer": "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com": true
		serviceAccounts: "my-app-run": displayName:                                                   "my-app"
		repositories: pronto: {location: "us-central1", format: "DOCKER", iam: "roles/artifactregistry.reader": "user:a@example.com": true}
	}
}
projectGrantWaitsForAccount: _order.tofu.resource.google_project_iam_binding.example_project_123_roles_viewer.depends_on & ["google_service_account.example_project_123_my_app_run"]
repositoryGrantWaitsForRepository: _order.tofu.resource.google_artifact_registry_repository_iam_binding.example_project_123_pronto_roles_artifactregistry_reader.depends_on & ["google_artifact_registry_repository.example_project_123_pronto"]

// A grant that names an account this state keeps waits for it, whatever it is a grant on.
_acct: "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com"
_named: #Plan & {
	backend: _plan.backend
	state: projects: "example-project-123": {
		billing:  "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
		adoptAll: true
		serviceAccounts: {
			"my-app-run": displayName: "my-app"
			"other": iam: "roles/iam.serviceAccountUser": (_acct): true
		}
		repositories: pronto: {location: "us-central1", format: "DOCKER", iam: "roles/artifactregistry.reader": (_acct): true}
		buckets: "my-app-assets": {location: "us-central1", uniformAccess: true, publicPrevention: "enforced", iam: "roles/storage.objectAdmin": (_acct): true}
		secrets: "my-app-token": {source: "operator", accessors: (_acct): true, adders: (_acct): true}
		runServices: "my-app": {
			location:       "us-central1", image:                                          "us-docker.pkg.dev/example-project-123/pronto/my-app:1", port: 8080
			serviceAccount: "my-app-run@example-project-123.iam.gserviceaccount.com", cpu: "1", memory:                                                   "512Mi", timeout: "300s", maxInstances: 2
			invokers: (_acct): true
		}
	}
}
_n: _named.tofu.resource
_waitsAccount: ["google_service_account.example_project_123_my_app_run"]
accountGrantWaits: _n.google_service_account_iam_binding.example_project_123_other_roles_iam_serviceAccountUser.depends_on & _waitsAccount
repositoryGrantWaitsForAccount: _n.google_artifact_registry_repository_iam_binding.example_project_123_pronto_roles_artifactregistry_reader.depends_on & ["google_artifact_registry_repository.example_project_123_pronto", "google_service_account.example_project_123_my_app_run"]
bucketGrantWaitsForAccount:  _n.google_storage_bucket_iam_binding.my_app_assets_roles_storage_objectAdmin.depends_on & _waitsAccount
secretGrantWaitsForAccount:  _n.google_secret_manager_secret_iam_binding.example_project_123_my_app_token.depends_on & _waitsAccount
secretAddersWaitForAccount:  _n.google_secret_manager_secret_iam_binding.example_project_123_my_app_token_adders.depends_on & _waitsAccount
invokerGrantWaitsForAccount: _n.google_cloud_run_v2_service_iam_binding.example_project_123_my_app.depends_on & _waitsAccount

// Every plan file the verbs write is ignored.
ignoresPlans: strings.Contains(_host.files[".gitignore"].text, "tofu/*.tfplan*") & true
