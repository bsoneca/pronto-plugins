#!/bin/sh
# mise as live.nu calls it, but gcloud is fake_gcloud.py: `mise exec gcloud@… python@… -- gcloud …`
# reaches the stand-in, and anything else (the app's cue) the real mise (REAL_MISE).
case "${2:-}" in
gcloud@*)
	while [ "$1" != "--" ]; do shift; done
	shift 2
	exec python3 "$(dirname "$0")/fake_gcloud.py" "$@"
	;;
esac
exec "$REAL_MISE" "$@"
