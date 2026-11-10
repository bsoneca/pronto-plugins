#!/bin/sh
# Makes the emulator in ANDROID_SERIAL one the terminal's biometric prompt can be answered on: a
# screen lock (a strong biometric needs one) and an enrolled fingerprint (`adb emu finger touch 1`
# is the sensor). Idempotent: an emulator that already has a print is left as it is.
set -eu
adb=${ADB:-adb}
: "${ANDROID_SERIAL:?name the emulator in ANDROID_SERIAL}"
enrolled() { "$adb" shell dumpsys fingerprint | grep -q '"count":[1-9]'; }
tap() { # tap the visible text $1
	"$adb" shell uiautomator dump /sdcard/pronto-ui.xml >/dev/null
	xy=$("$adb" exec-out cat /sdcard/pronto-ui.xml | tr '>' '\n' | sed -n "s/.*text=\"$1\".*bounds=\"\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]\".*/\1 \2 \3 \4/p" | head -n 1)
	[ -n "$xy" ] || return 1
	set -- $xy
	"$adb" shell input tap $((($1 + $3) / 2)) $((($2 + $4) / 2))
}
wait_tap() { i=0; until tap "$1"; do i=$((i + 1)); [ $i -lt 20 ] || { echo "no \"$1\" on the screen" >&2; exit 1; }; sleep 1; done; }
enrolled && { echo "a fingerprint is enrolled"; exit 0; }
"$adb" shell locksettings set-pin 1234 || true
"$adb" shell svc power stayon true
"$adb" shell am start -a android.settings.BIOMETRIC_ENROLL >/dev/null
sleep 3
"$adb" shell input text 1234
"$adb" shell input keyevent KEYCODE_ENTER
wait_tap MORE
wait_tap "I AGREE"
sleep 2
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do "$adb" emu finger touch 1 >/dev/null; sleep 1; done
wait_tap DONE
enrolled || { echo "the fingerprint was not enrolled" >&2; exit 1; }
"$adb" shell input keyevent KEYCODE_HOME
