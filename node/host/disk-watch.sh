#!/usr/bin/env bash
# Written by pronto-plugins' node/host (bin/pronto-node --host), its settings in /etc/pronto/disk-watch.env — do not edit
# Tells the operator when a filesystem of the node is filling. It runs on the host, so an eviction of every pod, a dead
# cluster or a down tunnel cannot silence it. With --dry-run it only says what it would post.
# MOUNTS (space separated), THRESHOLD_PERCENT, RENOTIFY_MINUTES and NOTIFY_URL come from the environment: the unit's EnvironmentFile
# is the file host.nu writes from #Host's diskWatch (mode 600, read by systemd as root, so this runs as no one). By hand:
#   systemd-run --pipe --wait -p EnvironmentFile=/etc/pronto/disk-watch.env bash /usr/local/lib/pronto/disk-watch.sh --dry-run
set -euo pipefail
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "disk-watch: unknown argument $1 (only --dry-run)" >&2; exit 2 ;;
esac
# The unit's StateDirectory.
state=${STATE_DIRECTORY:-${DISK_WATCH_STATE:-/var/lib/pronto/disk-watch}}
: "${MOUNTS:?disk-watch: MOUNTS is not set (set by the unit EnvironmentFile)}" "${THRESHOLD_PERCENT:?}" "${RENOTIFY_MINUTES:?}" "${NOTIFY_URL:?}"
# A mark is dropped once the use falls this far under the threshold, so a disk hovering at the line is one crossing.
hysteresis=3
now=$(date +%s)
failed=0
seen=" "
[ "$dry" = 1 ] || mkdir -p "$state"

for path in $MOUNTS; do
  # POSIX df: the last line's fifth field is the use ("76%"), the sixth the mount point. A path df cannot read is an error,
  # never "fine": the watcher must not go quiet on a mount that moved.
  if ! line=$(df -P "$path" | tail -n 1); then echo "disk-watch: cannot read $path" >&2; failed=1; continue; fi
  read -r _ _ _ _ use mount <<<"$line"
  use=${use%\%}
  if ! [[ $use =~ ^[0-9]+$ ]]; then echo "disk-watch: cannot read the use of $path: '$line'" >&2; failed=1; continue; fi
  # Two paths on one filesystem are one disk.
  case "$seen" in *" $mount "*) continue ;; esac
  seen="$seen$mount "
  mark="$state/$(printf '%s' "$mount" | tr -c 'A-Za-z0-9' '_')"
  if [ "$use" -lt $((THRESHOLD_PERCENT - hysteresis)) ]; then
    [ "$dry" = 1 ] || rm -f "$mark"
    continue
  fi
  [ "$use" -ge "$THRESHOLD_PERCENT" ] || continue
  if [ -e "$mark" ]; then
    last=$(cat "$mark")
    if ! [[ $last =~ ^[0-9]+$ ]]; then last=0; fi
    [ $((now - last)) -ge $((RENOTIFY_MINUTES * 60)) ] || continue
  fi
  msg="$(uname -n): $mount is ${use}% full (alert at ${THRESHOLD_PERCENT}%)"
  if [ "$dry" = 1 ]; then echo "would post: $msg"; continue; fi
  # The URL is the channel's key: curl reads it from its config on stdin, never from its arguments (ps and /proc show those).
  # The mark is written only once the post succeeded, so a failed post is tried again at the next run.
  if printf 'url = "%s"\n' "$NOTIFY_URL" | curl -fsS --max-time 20 -K - -H "Title: node disk" -H "Priority: high" -d "$msg" >/dev/null; then
    echo "disk-watch: posted: $msg"
    # A mark that cannot be written means the next run posts again; say so, and fail the run.
    if ! { printf '%s\n' "$now" >"$mark.new" && mv -f "$mark.new" "$mark"; }; then
      echo "disk-watch: posted, but could not write the mark $mark: the next run posts again" >&2
      failed=1
    fi
  else
    echo "disk-watch: could not post: $msg" >&2
    failed=1
  fi
done
exit "$failed"
