# Builds, checks and deploys a pronto app's door on Cloud Run. The rules
# pronto-gcp merges into .say.json call it with sayt's tools in the
# environment ($env.SAYT_MISE_BIN), the pinned gcloud and cue among them.
#
# Written into the app by pronto-gcp; regenerated, do not edit.

const local = "pronto-gcp"

def --wrapped tool [name: string, ...args] {
	^$env.SAYT_MISE_BIN exec -- $name ...$args
}

# The door's image, built for Cloud Run's linux/amd64 from bayt's definition of
# it (.bayt/compose.caddy.yaml: its Dockerfile, stage and every additional
# context), then started and asked for /health and / before anything leaves
# this machine. The build context is streamed without .certs: the developer's
# localhost key never enters an image that is published.
export def image [app: string] {
	let scope = (tool cue export . -e '{server: [for _, e in code.state.entities if e.server {e.table}], auth: code.capabilities.auth != _|_}' --out json | from json)
	if ($scope.server | is-not-empty) or $scope.auth {
		let what = ([(if ($scope.server | is-not-empty) { $"server rows \(($scope.server | str join ', ')\)" }), (if $scope.auth { "auth" })] | compact | str join " and ")
		error make {msg: $"pronto-gcp releases a door alone, and this app has ($what): they need Cloud SQL and the services beside the door, which pronto-gcp does not build yet"}
	}
	let build = (open .bayt/compose.caddy.yaml | get services | values | first | get build)
	if $build.context != ".." { error make {msg: $"the door builds from ($build.context), not the app's root"} }
	let contexts = ($build.additional_contexts? | default {} | transpose name value | each {|c|
		# A compose default, ${VAR:-image}${VAR:+…}, is the image outside a monorepo.
		let parsed = ($c.value | parse --regex '^\$\{MONOREPO_COMPOSE_MODE:-(?<image>[^}]+)\}')
		let value = (if ($parsed | is-not-empty) { $parsed.0.image } else if $c.value == ".." { "." } else { $c.value })
		[--build-context $"($c.name)=($value)"]
	} | flatten)
	let ref = $"($local)/($app):local"
	(^tar --create --file - --exclude ./.certs --exclude ./.git --exclude ./.task --exclude ./dist --exclude '*/node_modules' --exclude ./node_modules .
		| ^docker buildx build --platform linux/amd64 --load --tag $ref --file $build.dockerfile --target $build.target ...$contexts -)
	check $ref
	$ref
}

# What the door is told as it starts: what compose tells it, for Cloud Run.
# The origin is the address readers reach; the Electric gate's secret guards a
# route a door-only app never uses, but its Caddyfile will not parse without
# one, so it gets a random one rather than compose's public default. A
# variable this does not know refuses, rather than a door starting without it.
def door-env [origin: string] {
	let names = (open .bayt/compose.caddy.yaml | get services | values | first | get environment? | default {} | columns)
	let unknown = ($names | where {|n| $n not-in [ORIGIN ELECTRIC_SECRET]})
	if ($unknown | is-not-empty) { error make {msg: $"the door reads ($unknown | str join ', '), which pronto-gcp does not set"} }
	[[name value]; [ORIGIN $origin] [ELECTRIC_SECRET (random chars --length 40)]] | where {|e| $e.name in $names}
}

# The image answers as the deployed door will: on :8080, with its environment.
def check [ref: string] {
	if (^docker run --rm --platform linux/amd64 --entrypoint sh $ref -c 'test -e /certs/localhost-key.pem && echo leaked || echo clean' | str trim) != "clean" {
		error make {msg: $"($ref) carries a localhost key in /certs"}
	}
	let vars = (door-env "https://check.invalid" | each {|e| [--env $"($e.name)=($e.value)"]} | flatten)
	let id = (^docker run --detach --platform linux/amd64 --publish 127.0.0.1::8080 ...$vars $ref | str trim)
	try {
		let port = (^docker port $id 8080 | lines | first | split row ":" | last)
		mut ok = false
		for _ in 1..60 {
			if (do { ^curl --silent --output /dev/null --write-out "%{http_code}" $"http://127.0.0.1:($port)/health" } | complete).stdout == "200" { $ok = true; break }
			sleep 1sec
		}
		if not $ok { error make {msg: $"($ref) never answered /health on :8080:\n(^docker logs --tail 20 $id e>| str trim)"} }
		let page = (^curl --silent --output /dev/null --write-out "%{http_code}" $"http://127.0.0.1:($port)/")
		if $page != "200" { error make {msg: $"($ref) answered / with ($page)"} }
		print $"gcp: ($ref) answers /health and / on :8080, linux/amd64, no localhost key"
	} catch {|e| ^docker rm --force $id | ignore; error make {msg: $e.msg} }
	^docker rm --force $id | ignore
}

# Pushes the checked image under `tag` and moves the service to it by digest
# (a revision resolves a tag once: deploying the same tag would pull nothing).
# The service scales to zero, answers everyone, and is told the address readers
# reach it at.
export def deploy [app: string, service: string, tag: string, --project: string, --region: string, --repository: string, --max-scale: int, --memory: string, --origin: string = ""] {
	let ref = $"($local)/($app):local"
	tool gcloud services enable run.googleapis.com artifactregistry.googleapis.com --project $project
	# An API just enabled refuses for a minute or two while it propagates.
	mut ready = false
	for _ in 1..24 {
		if (do { tool gcloud artifacts repositories describe $repository --location $region --project $project } | complete).exit_code == 0 { $ready = true; break }
		let made = (do { tool gcloud artifacts repositories create $repository --repository-format docker --location $region --project $project --description "pronto images" } | complete)
		if $made.exit_code == 0 { $ready = true; break }
		if not ($made.stderr | str contains "has not been used in project") { error make {msg: $made.stderr} }
		print "gcp: waiting for Artifact Registry to come up in the project"
		sleep 10sec
	}
	if not $ready { error make {msg: $"Artifact Registry never came up in ($project)"} }
	let host = $"($region)-docker.pkg.dev"
	let image = $"($host)/($project)/($repository)/($app)"
	# A short-lived token, not a credential helper written into Docker's config.
	tool gcloud auth print-access-token | ^docker login --username oauth2accesstoken --password-stdin $"https://($host)"
	^docker tag $ref $"($image):($tag)"
	^docker push $"($image):($tag)"
	let digest = (^docker inspect --format '{{json .RepoDigests}}' $ref | from json | where {|d| $d | str starts-with $image} | first)
	let number = (tool gcloud projects describe $project --format "value(projectNumber)" | str trim)
	let address = (if $origin != "" { $origin } else { $"https://($service)-($number).($region).run.app" })
	let spec = {
		apiVersion: "serving.knative.dev/v1"
		kind: "Service"
		metadata: {name: $service, labels: {"pronto-app": $app}, annotations: {"run.googleapis.com/ingress": "all"}}
		spec: {template: {
			metadata: {annotations: {
				"autoscaling.knative.dev/minScale": "0"
				"autoscaling.knative.dev/maxScale": ($max_scale | into string)
				"run.googleapis.com/startup-cpu-boost": "true"
			}}
			spec: {
				containerConcurrency: 80
				timeoutSeconds: 60
				containers: [{
					image: $digest
					ports: [{name: "http1", containerPort: 8080}]
					env: (door-env $address)
					resources: {limits: {cpu: "1", memory: $memory}}
					startupProbe: {httpGet: {path: "/health", port: 8080}, periodSeconds: 1, timeoutSeconds: 1, failureThreshold: 60}
				}]
			}
		}}
	}
	mkdir dist/gcp
	let file = $"dist/gcp/($service).yaml"
	$spec | to yaml | save --force $file
	tool gcloud run services replace $file --region $region --project $project
	tool gcloud run services add-iam-policy-binding $service --region $region --project $project --member allUsers --role roles/run.invoker | ignore
	# Live means the address the door was told answers, not that gcloud returned.
	let health = (^curl --silent --output /dev/null --write-out "%{http_code}" --retry 5 --retry-all-errors $"($address)/health")
	if $health != "200" { error make {msg: $"($address)/health answered ($health)"} }
	print $"gcp: ($service) serves ($digest)"
	print $"gcp: ($address)"
}
