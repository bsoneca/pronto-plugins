#!/usr/bin/env bash
# Written by pronto-plugins' node/host (bin/pronto-node --host), its settings in /etc/pronto/dapr-heal.env — do not edit
# Rolls the owner of every pod that asks for a Dapr sidecar (annotation dapr.io/enabled=true) and runs no daprd container,
# so the injector adds it: a pod created while the injector was down (2026-11-27, PRONTO-2191) never gets one by itself,
# and every call to its app's Dapr port is refused. With --dry-run it only says what it would roll.
set -euo pipefail
dry=0
failed=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "dapr-heal: unknown argument $1 (only --dry-run)" >&2; exit 2 ;;
esac
env=${DAPR_HEAL_ENV:-/etc/pronto/dapr-heal.env}
state=${DAPR_HEAL_STATE:-/var/lib/pronto/dapr-heal}
# KUBECTL (the words that run kubectl on the node), NAMESPACES (the operator's, space separated: only these are swept, never a
# tenant's, dapr-system or kube-system), GRACE_SECONDS, COOLDOWN_MINUTES: host.nu writes them from #Host's daprHeal.
# shellcheck disable=SC1090
. "$env"
: "${KUBECTL:?dapr-heal: KUBECTL is not set in $env}" "${NAMESPACES:?dapr-heal: NAMESPACES is not set in $env}" "${GRACE_SECONDS:?}" "${COOLDOWN_MINUTES:?}"

# shellcheck disable=SC2086 # KUBECTL is words: "k3s kubectl"
k() { $KUBECTL --request-timeout=30s "$@"; }

stamp='^(20[0-9][0-9])-([0-9][0-9])-([0-9][0-9])[ T]([0-9][0-9]):([0-9][0-9]):([0-9][0-9])(\.[0-9]+)? ?(Z|([+-])([0-9][0-9]):?([0-9][0-9]))$'
# A creation time (RFC 3339) as seconds since 1970; fails on anything else.
epoch() {
  [[ $1 =~ $stamp ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local s=$((10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]}))
  if [ -n "${BASH_REMATCH[9]}" ]; then s=$((s - ${BASH_REMATCH[9]}1 * (10#${BASH_REMATCH[10]} * 3600 + 10#${BASH_REMATCH[11]} * 60))); fi
  if [ "$m" -le 2 ]; then y=$((y - 1)); m=$((m + 9)); else m=$((m - 3)); fi
  echo $(((365 * y + y / 4 - y / 100 + y / 400 + (153 * m + 2) / 5 + d - 1 - 719468) * 86400 + s))
}

# One line a pod that asks for the sidecar: namespace|name|phase|deleting|created|owner kind/name|containers,
# each container (init containers too: a native sidecar is one) with a comma after it. Only the listed namespaces are read.
pods=""
for n in $NAMESPACES; do
  pods="$pods$(k -n "$n" get pods -o go-template='{{range .items}}{{$a := .metadata.annotations}}{{if $a}}{{if eq (index $a "dapr.io/enabled") "true"}}{{.metadata.namespace}}|{{.metadata.name}}|{{.status.phase}}|{{if .metadata.deletionTimestamp}}deleting{{end}}|{{.metadata.creationTimestamp}}|{{range .metadata.ownerReferences}}{{.kind}}/{{.name}}{{end}}|{{range .spec.containers}}{{.name}},{{end}}{{range .spec.initContainers}}{{.name}},{{end}}{{"\n"}}{{end}}{{end}}{{end}}')"$'\n'
done

now=$(date +%s)
bare=""
while IFS='|' read -r ns name phase deleting created owner containers; do
  [ -n "$name" ] || continue
  [ -z "$deleting" ] || continue
  case "$phase" in Succeeded | Failed) continue ;; esac
  case ",$containers" in *,daprd,*) continue ;; esac
  # The injector adds the sidecar when the pod is admitted, so a bare pod stays bare; the grace is only for a pod whose
  # creation time cannot be told from one being created this second: it is not judged, but its workload is still not healthy
  # (its mark, below, stays).
  young=0
  if at=$(epoch "$created") && [ $((now - at)) -lt "$GRACE_SECONDS" ]; then young=1; fi
  bare="$bare$ns|$name|$owner|$young"$'\n'
done <<<"$pods"

# A mark says a workload was rolled for a bare pod. One whose pods all run their sidecar has done its work: a later outage is a new
# incident, so the marks of every workload with no bare pod are removed (a dry run removes nothing).
if [ -z "$bare" ]; then
  [ "$dry" = 1 ] || rm -f "$state"/* 2>/dev/null || true
  echo "dapr-heal: every pod that asks for a Dapr sidecar runs one"
  exit 0
fi

# Rolling a Deployment while the injector is down would only make new bare pods: say so and fail the run, so a node whose
# injector stays down shows in `node/host/host.nu apply --check` as a job that failed its last run.
judged=$(grep -c '|0$' <<<"$bare" || true)
ready=$(k -n dapr-system get deployment dapr-sidecar-injector -o jsonpath='{.status.readyReplicas}' || true)
if [ "${judged:-0}" -gt 0 ] && [ "${ready:-0}" -lt 1 ]; then
  echo "dapr-heal: pods without their Dapr sidecar, but the injector (dapr-system/dapr-sidecar-injector) has no ready replica: not rolling:" >&2
  grep '|0$' <<<"$bare" | cut -d'|' -f1,2 | sed 's/^/  /' >&2
  exit 1
fi

# The workload that owns each bare pod: a ReplicaSet's owner is its Deployment; a StatefulSet and a DaemonSet own the pod.
# Anything else (a Job, a pod of its own) is not rolled. `present` is every workload with a bare pod, a young one too, and
# `targets` the ones with a pod old enough to be judged.
present=""
targets=""
while IFS='|' read -r ns name owner young; do
  [ -n "$name" ] || continue
  case "$owner" in
    ReplicaSet/*)
      owner=$(k -n "$ns" get replicaset "${owner#ReplicaSet/}" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' || true)
      case "$owner" in Deployment/?*) ;; *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: its ReplicaSet has no Deployment: not rolled" >&2; failed=1; }; continue ;; esac ;;
    StatefulSet/?* | DaemonSet/?*) ;;
    *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: owned by '${owner:-nothing}': not rolled" >&2; failed=1; }; continue ;;
  esac
  present="$present$ns.${owner//\//.}"$'\n'
  [ "$young" = 1 ] || targets="$targets$ns|$owner"$'\n'
done <<<"$bare"

mkdir -p "$state"
while IFS='|' read -r ns owner; do
  [ -n "$ns" ] || continue
  mark="$state/$ns.${owner//\//.}"
  if [ -e "$mark" ]; then
    # A roll replaces its pods one by one, and the old ones stay until the new are ready: not rolled again within the cooldown.
    if [ -n "$(find "$mark" -mmin "-$COOLDOWN_MINUTES" 2>/dev/null)" ]; then
      echo "dapr-heal: $ns/$owner was rolled less than $COOLDOWN_MINUTES minutes ago and a pod of it is still without its sidecar: waiting"
      continue
    fi
    # Past the cooldown, a pod of it is still bare (the marks of healthy workloads are removed below, so this one is from this
    # incident): the roll did not fix it, whatever the pod's age (the injector injects nothing for it, or the rollout is stuck:
    # OnDelete, paused, an ordered StatefulSet, a Pending pod). Another roll would not either: it is said and the run fails
    # until someone looks, and the mark stays so the next run says it again.
    echo "dapr-heal: $ns/$owner was rolled and, past the cooldown of $COOLDOWN_MINUTES minutes, a pod of it is still without its sidecar: not rolled again" >&2
    failed=1
    continue
  fi
  if [ "$dry" = 1 ]; then echo "dapr-heal: would roll $ns/$owner"; continue; fi
  if k -n "$ns" rollout restart "$owner" >/dev/null; then
    touch "$mark"
    echo "dapr-heal: rolled $ns/$owner: a pod of it ran without its Dapr sidecar"
  else
    echo "dapr-heal: rolling $ns/$owner failed" >&2
    failed=1
  fi
done < <(sort -u <<<"$targets")

# The marks of the workloads with no bare pod: their incident is over.
if [ "$dry" != 1 ]; then
  for mark in "$state"/*; do
    [ -e "$mark" ] || continue
    printf '%s\n' "$present" | grep -qxF "${mark##*/}" || rm -f "$mark"
  done
fi
exit "$failed"
