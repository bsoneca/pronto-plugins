#!/bin/sh
# Builds the app's release APK signed with its release key, which lives encrypted in
# android/__RELEASE_FILE__ (SOPS with age: the Secret __RELEASE_SECRET__, key value, JSON
# {keystore: base64 PKCS12, password, alias}) and never in plain text in the repo: the keystore is
# decrypted with this machine's key (tools/secrets/get.sh at the repository's root) into a private
# temporary file, handed to Gradle through the environment, and removed when this ends, on any exit.
#
#   sh android/sign-release.sh [gradle arguments...]
#
# Its arguments go to Gradle (-PprontoBase=<url>, -PprontoVersionCode=<n>, -PprontoVersionName=<x.y.z>).
# Gradle runs without its daemon, which would outlive this and keep the key's password in its
# environment. The APK is android/app/build/outputs/apk/release/app-release.apk; its signer's SHA-256
# is printed upper-case and colon-separated, the form android/android.json's "signing" lists.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# Gradle, the JDK and the SDK are the app's mise's (.config/mise/conf.d/android.toml), as build@android's.
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${PRONTO_SIGN_IN_MISE:-}" ] && command -v mise >/dev/null 2>&1; then
  PRONTO_SIGN_IN_MISE=1 exec mise exec -C "$here" -- sh "$here/sign-release.sh" "$@"
fi
root=$(cd "$here" && git rev-parse --show-toplevel)
get="$root/tools/secrets/get.sh"
[ -f "$get" ] || { echo "sign-release: $get not found" >&2; exit 1; }

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
value=$(sh "$get" "$here/__RELEASE_FILE__" __RELEASE_SECRET__ value)
keystore="$dir/release.p12"
printf '%s' "$value" | jq -r .keystore | base64 -d > "$keystore"
chmod 600 "$keystore"
PRONTO_ANDROID_KEYSTORE_PASSWORD=$(printf '%s' "$value" | jq -r .password)
PRONTO_ANDROID_KEY_ALIAS=$(printf '%s' "$value" | jq -r .alias)
value=
export PRONTO_ANDROID_KEYSTORE="$keystore" PRONTO_ANDROID_KEYSTORE_PASSWORD PRONTO_ANDROID_KEY_ALIAS

(cd "$here" && gradle --console=plain --no-daemon :app:assembleRelease "$@")

apk="$here/app/build/outputs/apk/release/app-release.apk"
apksigner=$(command -v apksigner || ls -d "${ANDROID_HOME:-/nonexistent}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1)
[ -n "$apksigner" ] || { echo "apksigner not found (the SDK's build-tools)" >&2; exit 1; }
# apksigner prints lower-case hex without colons; assetlinks wants 32 upper-case pairs joined by colons.
digest=$("$apksigner" verify --print-certs "$apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')
[ -n "$digest" ] || { echo "sign-release: no signer in the APK" >&2; exit 1; }
echo "signer SHA-256: $digest"
