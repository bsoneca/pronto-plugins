#!/bin/sh
# mise as live.nu calls it, but gcloud is fake_gcloud.py: `mise exec gcloud@… python@… -- gcloud …`
# reaches the stand-in, and anything else (the app's cue) the real mise (REAL_MISE). The stand-in
# fails unless CLOUDSDK_PYTHON=python3.12 reached it: live.nu must keep gcloud off the shared virtenv.
case "${2:-}" in
gcloud@*)
	if [ "${CLOUDSDK_PYTHON:-}" != python3.12 ]; then
		echo "fake gcloud: CLOUDSDK_PYTHON is '${CLOUDSDK_PYTHON:-}', want python3.12" >&2
		exit 1
	fi
	while [ "$1" != "--" ]; do shift; done
	shift 2
	exec python3 "$(dirname "$0")/fake_gcloud.py" "$@"
	;;
esac
exec "$REAL_MISE" "$@"
