#!/bin/sh
# Publishes the identity broker's runtime, as pronto's forks publish theirs:
# $IMAGE:<version>, in the operator's own registry (there is no default), the
# broker's code at this commit, without its tests, on Deno, built with crane (no Docker). An app's docker
# launch runs the image as the front; its launch@local takes the image's /app
# and runs hydra/local.sh from it on the host (identity/host.cue).
# Run from anywhere, with what ships (oidc.ts, broker/, hydra/) committed:
#   IMAGE=ghcr.io/<you>/pronto-identity identity/publish.sh 0.1.0
# A version once published never changes: what is already there is reused.
# It prints the image's digest, which an app names as bin/pronto-identity's
# frontImage=<image>:<version>@<digest>.
set -eu
V=${1:?the version to publish, e.g. 0.1.0}
IMAGE=${IMAGE:?the image to publish to, in your own registry: IMAGE=<registry>/pronto-identity}
# The Deno the broker's Cloud Run release runs (release.nu).
DENO=denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e
here=$(cd "$(dirname "$0")" && pwd)
# What ships must be what is committed: the image names this commit.
[ -z "$(git -C "$here" status --porcelain -- oidc.ts broker hydra)" ] || { echo "plugins/identity has uncommitted changes in what ships" >&2; exit 1; }
rev=$(git -C "$here" rev-parse HEAD)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/broker/vendor" "$work/src/hydra"
cp "$here/oidc.ts" "$work/src/"
cp "$here/broker/core.ts" "$here/broker/main.ts" "$here/broker/phone.ts" "$here/broker/otp.ts" "$here/broker/door.ts" "$here/broker/store.ts" "$work/src/broker/"
cp "$here/broker/vendor/postgres.js" "$work/src/broker/vendor/"
cp "$here/hydra/front.ts" "$here/hydra/fake.ts" "$here/hydra/local.sh" "$work/src/hydra/"
cat > "$work/src/README.md" <<EOF
# pronto-identity $V

The identity broker's runtime: Ory Hydra behind a front that signs people in
through Google (or, on a developer's machine, a stand-in for it) and a phone
number texted a code (Identity Platform, or its emulator on a developer's machine) and gives each
application its own subject for them. Published from bsoneca/pronto-plugins
identity/ at $rev; its source, tests and docs live there.

- \`$IMAGE:$V\`: the front, for an app's docker launch.
- \`hydra/local.sh hydra|front\`: the broker as two of an app's launch@local
  processes, run from this image's /app.
EOF

# The front's image, without Docker anywhere (PRONTO-180): the base's linux/amd64 and linux/arm64
# images, each with one layer of /app, set up as the Dockerfile this replaced did (WORKDIR /app,
# PORT=28443, deno run front.ts), staged in a registry on localhost (`crane registry serve`) and
# copied up as one index. Pushing needs a login to the registry that can write the package
# (`crane auth login`, or Docker's config). The broker imports nothing remote, so no Deno cache ships:
# a cache made here would be keyed by this machine's paths, not /app.
CRANE=${CRANE:-crane}
command -v "$CRANE" >/dev/null || { echo "publish.sh needs crane (go-containerregistry) on PATH or in \$CRANE" >&2; exit 1; }
if ! "$CRANE" digest "$IMAGE:$V" >/dev/null 2>&1; then
	mkdir -p "$work/layer/app"
	cp -R "$work/src/." "$work/layer/app/"
	if tar --version 2>/dev/null | grep -q GNU; then owner="--owner=0 --group=0 --numeric-owner"; else owner="--uid 0 --gid 0"; fi
	# shellcheck disable=SC2086
	tar -C "$work/layer" $owner -cf "$work/app.tar" app
	port=${STAGE_PORT:-5058}
	"$CRANE" registry serve --address "localhost:$port" >"$work/registry.log" 2>&1 &
	reg=$!
	trap 'kill "$reg" 2>/dev/null; rm -rf "$work"' EXIT
	stage=localhost:$port/pronto-identity
	for _ in 1 2 3 4 5 6 7 8 9 10; do "$CRANE" catalog --insecure "localhost:$port" >/dev/null 2>&1 && break; sleep 1; done
	for arch in amd64 arm64; do
		"$CRANE" append --insecure --platform "linux/$arch" -b "$DENO" -f "$work/app.tar" -t "$stage:$arch" >/dev/null
		"$CRANE" mutate --insecure "$stage:$arch" -t "$stage:$arch" --workdir /app -e PORT=28443 \
			--cmd run,--no-config,--allow-net,--allow-env,/app/hydra/front.ts \
			-l org.opencontainers.image.source=https://github.com/bsoneca/pronto-plugins >/dev/null
	done
	"$CRANE" index append --insecure -m "$stage:amd64" -m "$stage:arm64" -t "$stage:$V" >/dev/null
	"$CRANE" copy --insecure "$stage:$V" "$IMAGE:$V"
fi
digest=$("$CRANE" digest "$IMAGE:$V")
echo "image    $IMAGE:$V@$digest"
