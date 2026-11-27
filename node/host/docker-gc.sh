#!/usr/bin/env bash
# Written by pronto-plugins' node/host (bin/pronto-node --host), its settings in /etc/pronto/docker-gc.env — do not edit
# Docker's disk kept bounded. With --dry-run it only lists what it would remove.
set -euo pipefail
dry=0
failed=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "docker-gc: unknown argument $1 (only --dry-run)" >&2; exit 2 ;;
esac
env=${DOCKER_GC_ENV:-/etc/pronto/docker-gc.env}
# PATTERN (a bash ERE), MIN_AGE_HOURS, BUILD_CACHE_GB and CAP_GB: host.nu writes them from #Host's dockerGC.
# shellcheck disable=SC1090
. "$env"
: "${PATTERN:?docker-gc: PATTERN is not set in $env}" "${MIN_AGE_HOURS:?}" "${BUILD_CACHE_GB:?}" "${CAP_GB:?}"
pattern=$PATTERN
# A pattern bash cannot compile is status 2, which the loop below would read as "no tag matches" and keep every image: stop.
rc=0
# shellcheck disable=SC2319 # $? is the regex match's own status: 2 is an invalid pattern
if [[ "" =~ $pattern ]]; then :; else rc=$?; fi
if [ "$rc" = 2 ]; then echo "docker-gc: PATTERN is not a valid regular expression: $pattern" >&2; exit 1; fi
cutoff=$(($(date +%s) - MIN_AGE_HOURS * 3600))
stamp='^(20[0-9][0-9])-([0-9][0-9])-([0-9][0-9])[ T]([0-9][0-9]):([0-9][0-9]):([0-9][0-9])(\.[0-9]+)? ?(Z|([+-])([0-9][0-9]):?([0-9][0-9]))( [A-Za-z0-9+-]+)?$'

# A tag time (Go's or RFC 3339) as seconds since 1970; fails on anything else, the zero time too.
epoch() {
  [[ $1 =~ $stamp ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local s=$((10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]}))
  if [ -n "${BASH_REMATCH[9]}" ]; then s=$((s - ${BASH_REMATCH[9]}1 * (10#${BASH_REMATCH[10]} * 3600 + 10#${BASH_REMATCH[11]} * 60))); fi
  if [ "$m" -le 2 ]; then y=$((y - 1)); m=$((m + 9)); else m=$((m - 3)); fi
  echo $(((365 * y + y / 4 - y / 100 + y / 400 + (153 * m + 2) / 5 + d - 1 - 719468) * 86400 + s))
}

refs=$(docker image ls --format '{{.Repository}}:{{.Tag}}')
while IFS= read -r ref; do
  [[ $ref =~ $pattern ]] || continue
  case "$ref" in *"<none>"*) continue ;; esac
  tagged=$(docker image inspect --format '{{.Metadata.LastTagTime}}' "$ref" </dev/null) || tagged=
  if ! at=$(epoch "$tagged"); then echo "docker-gc: kept $ref, its tag time is unreadable: '$tagged'"; failed=1; continue; fi
  [ "$at" -lt "$cutoff" ] || continue
  if [ "$dry" = 1 ]; then echo "would remove $ref"; continue; fi
  docker image rm "$ref" </dev/null || echo "docker-gc: could not remove $ref"
done <<<"$refs"
if [ "$dry" = 1 ]; then echo "docker-gc: dry run, nothing removed (a real run also prunes dangling images and build cache past ${BUILD_CACHE_GB}GB)"; exit 0; fi

docker image prune -f || failed=1
docker builder prune -af --max-used-space "${BUILD_CACHE_GB}GB" || failed=1

# Docker's own account of what it holds (images, containers, volumes, build cache), in its decimal units.
sizes=$(docker system df --format '{{.Size}}')
used=$(awk '{ u = $1; n = u + 0; sub(/^[0-9.e+]+/, "", u)
    f = u == "B" ? 1 : u == "kB" ? 1e3 : u == "MB" ? 1e6 : u == "GB" ? 1e9 : u == "TB" ? 1e12 : 0
    if (f == 0) bad = 1; t += n * f }
  END { if (bad || NR == 0) exit 1; printf "%.0f", t }' <<<"$sizes") || { echo "docker-gc: cannot read Docker's use: $sizes" >&2; exit 1; }
if [ "$used" -gt $((CAP_GB * 1000000000)) ]; then
  echo "docker-gc: Docker holds $((used / 1000000000))GB, over the cap of ${CAP_GB}GB" >&2
  exit 1
fi
exit "$failed"
