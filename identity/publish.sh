#!/bin/sh
# Publishes the identity broker's runtime, as pronto's forks publish theirs:
# $IMAGE:<version>, in the operator's own registry (there is no default), the
# broker's code at this commit, without its tests, on Deno. An app's docker
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
mkdir -p "$work/src/broker" "$work/src/hydra"
cp "$here/oidc.ts" "$work/src/"
cp "$here/broker/core.ts" "$here/broker/main.ts" "$work/src/broker/"
cp "$here/hydra/front.ts" "$here/hydra/fake.ts" "$here/hydra/local.sh" "$work/src/hydra/"
cat > "$work/src/README.md" <<EOF
# pronto-identity $V

The identity broker's runtime: Ory Hydra behind a front that signs people in
through Google (or, on a developer's machine, a stand-in for it) and gives each
application its own subject for them. Published from bsoneca/pronto-plugins
identity/ at $rev; its source, tests and docs live there.

- \`$IMAGE:$V\`: the front, for an app's docker launch.
- \`hydra/local.sh hydra|front\`: the broker as two of an app's launch@local
  processes, run from this image's /app.
EOF

# The front's image.
if ! docker buildx imagetools inspect "$IMAGE:$V" >/dev/null 2>&1; then
	printf 'FROM %s\nWORKDIR /app\nCOPY . /app/\nRUN ["deno", "cache", "--no-config", "/app/hydra/front.ts"]\nENV PORT=28443\nCMD ["run", "--no-config", "--allow-net", "--allow-env", "/app/hydra/front.ts"]\n' "$DENO" > "$work/src/Dockerfile"
	docker buildx inspect identitypub >/dev/null 2>&1 || docker buildx create --name identitypub --driver docker-container >/dev/null
	docker buildx build --builder identitypub --platform linux/amd64,linux/arm64 \
		--label "org.opencontainers.image.source=https://github.com/bsoneca/pronto-plugins" \
		--annotation "index:org.opencontainers.image.source=https://github.com/bsoneca/pronto-plugins" \
		-t "$IMAGE:$V" --push -q "$work/src" >/dev/null
fi
digest=$(docker buildx imagetools inspect "$IMAGE:$V" --format '{{json .Manifest}}' | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["digest"])')
echo "image    $IMAGE:$V@$digest"
