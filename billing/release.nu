# Releases the billing broker to Cloud Run, the one an operator serves for every
# pronto-billing app: bin/pronto-billing-broker release --project P --domain D
#
# The broker keeps nothing of its own but its secrets, which Secret Manager holds:
# BROKER_SECRET and BILLING_SIGNING_KEY, which this generates once; the platform
# account's Stripe key, which the operator stores under <service>-stripe-key, never
# passed through here; and the secret of the one webhook Stripe sends it, which this
# registers once for https://<domain>/stripe (again with --webhook, as after the key
# changes from test to live). An entitlement's `ver` is the broker's clock: so one
# instance at most.

const here = path self .
const deno = "denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e"

def --wrapped gc [...args] {
	let input = $in
	let r = ($input | ^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"gcloud ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}
def --wrapped exists [...args]: nothing -> bool {
	(^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet ...$args | complete).exit_code == 0
}

# A secret's value stored as a new version, the secret made first if it is not there.
def store [name: string, project: string] {
	let value = $in
	if (exists secrets describe $name --project $project) {
		$value | gc secrets versions add $name --project $project --data-file=- | ignore
	} else {
		$value | gc secrets create $name --project $project --replication-policy automatic --data-file=- | ignore
	}
}

# The broker's own command line (keygen, webhook), on Deno as the plugin pins it.
def --wrapped broker [...args] {
	let r = (^$env.SAYT_MISE_BIN exec deno@2.5.0 -- deno run --no-config --allow-net --allow-env $"($here)/broker/main.ts" ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"billing/broker/main.ts ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout | str trim
}

# The domain onto the service, through Cloud Run's domain-mapping API (gcloud
# reaches it only from its beta component); its DNS records, once Google has them.
def map-domain [domain: string, service: string, project: string, region: string] {
	let api = $"https://($region)-run.googleapis.com/apis/domains.cloudrun.com/v1/namespaces/($project)/domainmappings"
	let auth = [Authorization $"Bearer (gc auth print-access-token | str trim)"]
	let got = (http get --full --allow-errors --headers $auth $"($api)/($domain)")
	let mapping = if $got.status == 404 {
		let made = (http post --full --allow-errors --headers $auth --content-type application/json $api {
			apiVersion: "domains.cloudrun.com/v1", kind: "DomainMapping"
			metadata: {name: $domain, namespace: $project}
			spec: {routeName: $service}
		})
		if $made.status >= 300 { error make {msg: $"($domain) is not mapped: ($made.body.error?.message? | default ($made.body | to json))"} }
		$made.body
	} else if $got.status >= 300 {
		error make {msg: $"($api)/($domain) answered ($got.status): ($got.body | to json)"}
	} else { $got.body }
	let ready = ($mapping.status?.conditions? | default [] | where type == "Ready" | get 0?)
	if ($ready.status? | default "") != "True" {
		print $"billing: ($domain) is mapped but not ready: ($ready.message? | default 'Google is still provisioning it')"
	}
	let records = ($mapping.status?.resourceRecords? | default [])
	if ($records | is-not-empty) { print $"billing: ($domain)'s DNS records:"; print ($records | select -o type name rrdata | table) }
}

export def main [
	--project: string             # The Google Cloud project
	--domain: string              # Where the broker answers, its issuer: billing.example.com
	--fee: int = 0                # The share of each payment the platform keeps, in percent
	--webhook                     # Register Stripe's webhook again, as after the Stripe key changed
	--region: string = "us-central1"
	--service: string = "billing-broker"
	--repository: string = "pronto"
	--sandbox-tenants: string = ""  # A pattern: the tenants (an app's previews) that buy through Stripe's sandbox
] {
	if ([$project $domain] | any { is-empty }) { error make {msg: "--project and --domain are both required"} }
	if not ($fee >= 0 and $fee < 100) { error make {msg: "--fee is a percentage under 100"} }
	let p = $project
	let issuer = $"https://($domain)"
	let sa = $"($service)-run@($p).iam.gserviceaccount.com"
	let stripe_key = $"($service)-stripe-key"
	let webhook_secret = $"($service)-webhook-secret"
	gc services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com iam.googleapis.com --project $p | ignore
	if not (exists secrets describe $stripe_key --project $p) {
		error make {msg: $"store the platform account's Stripe key first, never through this: read -rs S; printf '%s' \"$S\" | gcloud secrets create ($stripe_key) --project ($p) --data-file=-"}
	}
	if not (exists secrets describe $"($service)-secret" --project $p) {
		^$env.SAYT_MISE_BIN exec python@3.12.11 -- python -I -c 'import secrets;print(secrets.token_urlsafe(48),end="")' | store $"($service)-secret" $p
	}
	if not (exists secrets describe $"($service)-signing-key" --project $p) {
		broker keygen | store $"($service)-signing-key" $p
	}
	# The one endpoint Stripe sends every app's subscriptions to; the key reaches the
	# broker's command line only through its environment.
	if $webhook or not (exists secrets describe $webhook_secret --project $p) {
		let key = (gc secrets versions access latest --secret $stripe_key --project $p)
		let made = (with-env {BROKER_ISSUER: $issuer, BROKER_SECRET: "webhook", STRIPE_SECRET_KEY: $key} { broker webhook })
		$made | str replace "STRIPE_WEBHOOK_SECRET=" "" | store $webhook_secret $p
		print $"billing: Stripe sends ($issuer)/stripe the subscriptions' events"
	}
	if not (exists iam service-accounts describe $sa --project $p) {
		gc iam service-accounts create $"($service)-run" --project $p --display-name "billing broker on Cloud Run" | ignore
	}
	# The sandbox beside the live account, for the tenants --sandbox-tenants matches: its key and
	# its webhook's secret, stored by the operator as the live ones are.
	let sandbox_key = $"($service)-sandbox-stripe-key"
	let sandbox_webhook = $"($service)-sandbox-webhook-secret"
	if ($sandbox_tenants | is-not-empty) {
		for s in [$sandbox_key $sandbox_webhook] {
			if not (exists secrets describe $s --project $p) {
				error make {msg: $"--sandbox-tenants needs the sandbox's ($s) stored first: read -rs S; printf '%s' \"$S\" | gcloud secrets create ($s) --project ($p) --data-file=-"}
			}
		}
	}
	let secrets = [$"($service)-secret" $"($service)-signing-key" $stripe_key $webhook_secret] | append (if ($sandbox_tenants | is-empty) { [] } else { [$sandbox_key $sandbox_webhook] })
	for s in $secrets {
		gc secrets add-iam-policy-binding $s --project $p --member $"serviceAccount:($sa)" --role roles/secretmanager.secretAccessor | ignore
	}
	if not (exists artifacts repositories describe $repository --location $region --project $p) {
		gc artifacts repositories create $repository --repository-format docker --location $region --project $p --description "pronto images" | ignore
	}

	# The broker's own files, on Deno as the plugin pins it, built in Cloud Build
	# for Cloud Run's linux/amd64: no docker on the operator's machine.
	let work = (mktemp -d)
	mkdir $"($work)/billing/broker"
	cp $"($here)/shared.ts" $"($work)/billing/"
	cp $"($here)/broker/main.ts" $"($here)/broker/core.ts" $"($here)/broker/stripe.ts" $"($here)/broker/fake.ts" $"($work)/billing/broker/"
	$"FROM ($deno)\nWORKDIR /app\nCOPY billing /app/billing\nRUN [\"deno\", \"cache\", \"/app/billing/broker/main.ts\"]\nENV PORT=8080\nCMD [\"run\", \"--allow-net\", \"--allow-env\", \"/app/billing/broker/main.ts\"]\n" | save $"($work)/Dockerfile"
	let image = $"($region)-docker.pkg.dev/($p)/($repository)/($service)"
	print $"billing: building ($service) in Cloud Build"
	gc builds submit $work --tag $"($image):release" --project $p | ignore
	rm -rf $work
	let digest = (gc artifacts docker images describe $"($image):release" --format "value(image_summary.digest)" | str trim)

	# Each secret by its version now, not `latest`: a version stored since is a new revision,
	# where `latest` would reach only instances started after it.
	let version = {|name| gc secrets versions describe latest --secret $name --project $p --format "value(name)" | str trim | path basename }
	let from = {|var, name| {name: $var, valueFrom: {secretKeyRef: {name: $name, key: (do $version $name)}}} }
	let vars = [
			{name: "BROKER_ISSUER", value: $issuer}
			{name: "BILLING_FEE_PERCENT", value: ($fee | into string)}
			(do $from BROKER_SECRET $"($service)-secret")
			(do $from BILLING_SIGNING_KEY $"($service)-signing-key")
			(do $from STRIPE_SECRET_KEY $stripe_key)
			(do $from STRIPE_WEBHOOK_SECRET $webhook_secret)
		] | append (if ($sandbox_tenants | is-empty) { [] } else { [
			{name: "BILLING_SANDBOX_TENANTS", value: $sandbox_tenants}
			(do $from STRIPE_SANDBOX_SECRET_KEY $sandbox_key)
			(do $from STRIPE_SANDBOX_WEBHOOK_SECRET $sandbox_webhook)
		] })
	let spec = {
		apiVersion: "serving.knative.dev/v1", kind: "Service"
		metadata: {name: $service, labels: {"cloud.googleapis.com/location": $region}, annotations: {"run.googleapis.com/ingress": "all"}}
		spec: {template: {
			metadata: {annotations: {
				"autoscaling.knative.dev/minScale": "0"
				# An entitlement's `ver` is this instance's clock: a second would race it.
				"autoscaling.knative.dev/maxScale": "1"
			}}
			spec: {
				serviceAccountName: $sa
				containers: [{
					image: $"($image)@($digest)"
					ports: [{name: "http1", containerPort: 8080}]
					env: $vars
					startupProbe: {httpGet: {path: "/health", port: 8080}, periodSeconds: 1, failureThreshold: 30}
				}]
			}
		}}
	}
	let file = (mktemp -t --suffix .yaml)
	$spec | to yaml | save -f $file
	gc run services replace $file --region $region --project $p | ignore
	rm $file
	gc run services add-iam-policy-binding $service --region $region --project $p --member allUsers --role roles/run.invoker | ignore
	map-domain $domain $service $p $region
	let address = (gc run services describe $service --region $region --project $p --format "value(status.url)" | str trim)
	let health = (^curl --silent --output /dev/null --write-out "%{http_code}" --retry 5 --retry-all-errors $"($address)/health")
	if $health != "200" { error make {msg: $"($address)/health answered ($health)"} }
	print $"billing: the broker is live at ($address), its issuer ($issuer), keeping ($fee)% of each payment"
	print $"billing: an app sells through it with `pronto connect stripe <app> --broker ($issuer)`, which names it in the app's release.cue"
}
