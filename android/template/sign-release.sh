#!/bin/sh
# Builds the app's release APK signed with its release key, which lives in Secret Manager
# (android/android.json's "release": project __RELEASE_PROJECT__, secret __RELEASE_SECRET__) and
# never in a file of the repo: the keystore is read with the caller's own gcloud into a private
# temporary file, handed to Gradle through the environment, and removed when this ends.
#
#   sh android/sign-release.sh
#
# ANDROID_SIGNING_PROJECT and ANDROID_SIGNING_SECRET override the project and the secret. The APK
# is android/app/build/outputs/apk/release/app-release.apk; its signer's SHA-256 is printed, and
# is the value android/android.json's "signing" lists.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# Gradle, the JDK and the SDK are the app's mise's (.config/mise/conf.d/android.toml), as build@android's.
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${PRONTO_SIGN_IN_MISE:-}" ] && command -v mise >/dev/null 2>&1; then
  PRONTO_SIGN_IN_MISE=1 exec mise exec -C "$here" -- sh "$here/sign-release.sh"
fi
PROJECT=${ANDROID_SIGNING_PROJECT:-__RELEASE_PROJECT__}
SECRET=${ANDROID_SIGNING_SECRET:-__RELEASE_SECRET__}

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
umask 077
value=$(gcloud secrets versions access latest --secret "$SECRET" --project "$PROJECT")
keystore="$dir/release.p12"
printf '%s' "$value" | jq -r .keystore | base64 -d > "$keystore"
chmod 600 "$keystore"
PRONTO_ANDROID_KEYSTORE_PASSWORD=$(printf '%s' "$value" | jq -r .password)
PRONTO_ANDROID_KEY_ALIAS=$(printf '%s' "$value" | jq -r .alias)
value=
export PRONTO_ANDROID_KEYSTORE="$keystore" PRONTO_ANDROID_KEYSTORE_PASSWORD PRONTO_ANDROID_KEY_ALIAS

(cd "$here" && gradle --console=plain :app:assembleRelease)

apk="$here/app/build/outputs/apk/release/app-release.apk"
apksigner=$(command -v apksigner || ls -d "${ANDROID_HOME:-/nonexistent}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1)
[ -n "$apksigner" ] || { echo "apksigner not found (the SDK's build-tools)" >&2; exit 1; }
"$apksigner" verify --print-certs "$apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: /signer SHA-256: /p'
