#!/bin/sh
# Runs the terminal autofill scenario on an emulator (PRONTO-148): the vault fixture is written
# into a scratch app as an app gets the Android host (bin/pronto-android), bundled and built, the
# asker is built, and android/template/terminal/scenarios.ts runs the vault's scenario. Needs the
# toolchain on PATH (the app's mise: JDK, Android SDK, Gradle, Deno, cue) and one emulator selected
# by ANDROID_SERIAL, whose fingerprint android/test/autofill/emulator.sh enrolled.
#   android/test/autofill/run.sh <scratch-dir> <omnishell-dir>
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
app=$1
omnishell=$2
: "${ANDROID_SERIAL:?name the emulator in ANDROID_SERIAL}"
mkdir -p "$app"
cp -R "$here/android/test/autofill/vault/." "$app/"
"$here/bin/pronto-android" "$app" vault Vault
(cd "$here/android/test/autofill/asker" && gradle --console=plain :app:assembleDebug)
(cd "$app" && deno run -A --no-lock android/terminal/bundle.ts "$omnishell")
(cd "$app/android" && gradle --console=plain :app:assembleDebug)
"${ADB:-adb}" install -r "$here/android/test/autofill/asker/app/build/outputs/apk/debug/app-debug.apk"
cd "$app"
deno run -A --no-lock android/terminal/scenarios.ts dev.pronto.vault android/app/build/outputs/apk/debug/app-debug.apk https://vault.invalid scenarios/autofill.cue
