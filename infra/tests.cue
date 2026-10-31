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
