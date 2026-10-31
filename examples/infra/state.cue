// An invented account: two projects, one found and one made, to show the state's shape.
// `cue export ./examples/infra -e plan.tofu --out json` is the OpenTofu JSON it applies.
package state

import "github.com/bsoneca/pronto-plugins/infra"

plan: infra.#Plan & {
	backend: {bucket: "my-org-infra-tfstate", project: "example-project-123"}

	state: projects: {
		"example-project-123": {
			billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
			apis: {
				"run.googleapis.com":              true
				"artifactregistry.googleapis.com": true
				"secretmanager.googleapis.com":    true
			}
			adoptAll: true
			iam: "roles/owner": "user:admin@example.com": true
			members: "roles/cloudsql.client": "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com": true
			serviceAccounts: "my-app-run": {
				displayName: "my-app's Cloud Run account"
				iam: "roles/iam.serviceAccountUser": "user:admin@example.com": true
			}
			repositories: pronto: {
				location: "us-central1"
				format:   "DOCKER"
				iam: "roles/artifactregistry.reader": "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com": true
			}
			buckets: "my-app-assets": {
				location:         "us-central1"
				uniformAccess:    true
				publicPrevention: "enforced"
				deleteAfterDays:  30
				iam: "roles/storage.objectAdmin": "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com": true
			}
			secrets: "my-app-token": {
				source:    "put by the operator: gcloud secrets versions add my-app-token --data-file=-"
				accessors: "serviceAccount:my-app-run@example-project-123.iam.gserviceaccount.com": true
			}
			runServices: "my-app": {
				location:       "us-central1"
				image:          "us-central1-docker.pkg.dev/example-project-123/pronto/my-app:1.0.0"
				port:           8080
				serviceAccount: "my-app-run@example-project-123.iam.gserviceaccount.com"
				cpu:            "1"
				memory:         "512Mi"
				timeout:        "300s"
				maxInstances:   3
				env: LOG_LEVEL: "info"
				secretEnv: TOKEN: "my-app-token"
				invokers: allUsers: true
			}
		}
		// A project OpenTofu makes: nothing to import, everything new.
		"example-project-456": {
			create:  true
			billing: "billingAccounts/AAAAAA-BBBBBB-CCCCCC"
			apis: "run.googleapis.com": true
			buckets: "my-app-logs": {
				location:         "us-central1"
				uniformAccess:    true
				publicPrevention: "enforced"
				made:             true
			}
		}
	}
}
