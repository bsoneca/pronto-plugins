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

# One line a pod that asks for the sidecar: namespace|name|phase|deleting|created|owner kind/name@uid|containers,
# each container (init containers too: a native sidecar is one) with a comma after it. Only the listed namespaces are read.
pods=""
for n in $NAMESPACES; do
  pods="$pods$(k -n "$n" get pods -o go-template='{{range .items}}{{$a := .metadata.annotations}}{{if $a}}{{if eq (index $a "dapr.io/enabled") "true"}}{{.metadata.namespace}}|{{.metadata.name}}|{{.status.phase}}|{{if .metadata.deletionTimestamp}}deleting{{end}}|{{.metadata.creationTimestamp}}|{{range .metadata.ownerReferences}}{{if .controller}}{{.kind}}/{{.name}}@{{.uid}}{{end}}{{end}}|{{range .spec.containers}}{{.name}},{{end}}{{range .spec.initContainers}}{{.name}},{{end}}{{"\n"}}{{end}}{{end}}{{end}}')"$'\n'
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
  # A mark that cannot be removed would be read as the previous incident by the next outage and block its repair: say so and fail.
  if [ "$dry" != 1 ] && ! rm -f "$state"/*; then
    echo "dapr-heal: every pod runs its sidecar, but the marks of earlier incidents could not be removed from $state" >&2
    exit 1
  fi
  echo "dapr-heal: every pod that asks for a Dapr sidecar runs one"
  exit 0
fi

# Rolling a Deployment while the injector is down would only make new bare pods: say so and fail the run, so a node whose
# injector stays down shows in `node/host/host.nu apply --check` as a job that failed its last run.
judged=$(grep -c '|0$' <<<"$bare" || true)
if [ "${judged:-0}" -gt 0 ]; then
  # Only a pod old enough to roll asks: a failed read is its own error, not an injector that has no replica.
  if ! ready=$(k -n dapr-system get deployment dapr-sidecar-injector -o jsonpath='{.status.readyReplicas}'); then
    echo "dapr-heal: pods without their Dapr sidecar, but the injector (dapr-system/dapr-sidecar-injector) could not be read: not rolling" >&2
    exit 1
  fi
  if [ "${ready:-0}" -lt 1 ]; then
    echo "dapr-heal: pods without their Dapr sidecar, but the injector (dapr-system/dapr-sidecar-injector) has no ready replica: not rolling:" >&2
    grep '|0$' <<<"$bare" | cut -d'|' -f1,2 | sed 's/^/  /' >&2
    exit 1
  fi
fi

# The workload that owns each bare pod: a ReplicaSet's owner is its Deployment; a StatefulSet and a DaemonSet own the pod. The owner
# reference is the pod's, written by whoever created it, so it is checked against the live workload below (uid, and that its template asks
# for the sidecar). Anything else (a Job, a pod of its own) is not rolled. `present` is every workload with a bare pod, a young one too,
# and `targets` the ones with a pod old enough to be judged.
present=""
targets=""
incomplete=0
while IFS='|' read -r ns name owner young; do
  [ -n "$name" ] || continue
  case "$owner" in
    ReplicaSet/*)
      # A lookup that failed leaves the inventory incomplete: nothing is pruned below, so a live rollout's mark survives the outage of the API.
      rsname=${owner#ReplicaSet/}
      rsname=${rsname%@*}
      if ! owner=$(k -n "$ns" get replicaset "$rsname" -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}/{.metadata.ownerReferences[?(@.controller==true)].name}@{.metadata.ownerReferences[?(@.controller==true)].uid}'); then
        echo "dapr-heal: $ns/$name: its ReplicaSet could not be read: not pruning marks" >&2
        failed=1; incomplete=1; continue
      fi
      case "$owner" in Deployment/?*) ;; *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: its ReplicaSet has no Deployment: not rolled" >&2; failed=1; }; continue ;; esac ;;
    StatefulSet/?* | DaemonSet/?*) ;;
    *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: owned by '${owner:-nothing}': not rolled" >&2; failed=1; }; continue ;;
  esac
  ouid=${owner##*@}
  owner=${owner%@*}
  present="$present$ns.${owner//\//.}"$'\n'
  [ "$young" = 1 ] || targets="$targets$ns|$owner|$ouid"$'\n'
done <<<"$bare"

# A mark's time, as seconds since 1970 (GNU stat, else BSD's).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# The sorted targets are read into a variable first: a sort that failed must not look like a workload-free sweep.
if ! sorted=$(sort -u <<<"$targets"); then
  echo "dapr-heal: the workloads to roll could not be sorted: nothing rolled" >&2
  exit 1
fi
[ "$dry" = 1 ] || mkdir -p "$state"
while IFS='|' read -r ns owner ouid; do
  [ -n "$ns" ] || continue
  # What the pods' text said is checked again where it is used: a name with a newline in it can forge a line of that inventory, so the namespace
  # must be one that is swept, and the owner and its uid what Kubernetes writes, before anything is asked of the API.
  case " $NAMESPACES " in *" $ns "*) ;; *) echo "dapr-heal: '$ns' is not a swept namespace: not rolled" >&2; failed=1; continue ;; esac
  if ! [[ $owner =~ ^(Deployment|StatefulSet|DaemonSet)/[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || ! [[ $ouid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "dapr-heal: $ns: an owner or uid that is not a workload's name and a uid: not rolled" >&2; failed=1; continue
  fi
  mark="$state/$ns.${owner//\//.}"
  # The live workload, not the pod's word for it: its uid is the owner reference's, its template asks for the sidecar, and when it was last
  # restarted (the annotation `rollout restart` writes).
  if ! info=$(k -n "$ns" get "$owner" -o jsonpath='{.metadata.uid}|{.spec.template.metadata.annotations.dapr\.io/enabled}|{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'); then
    echo "dapr-heal: $ns/$owner could not be read: not rolled" >&2
    failed=1
    continue
  fi
  IFS='|' read -r luid ldapr lrestarted <<<"$info"
  if [ -z "$luid" ] || [ "$luid" != "$ouid" ]; then
    echo "dapr-heal: $ns/$owner is not the workload the pod's owner reference names (uid $luid, not $ouid): not rolled" >&2
    failed=1
    continue
  fi
  if [ "$ldapr" != true ]; then
    echo "dapr-heal: $ns/$owner's pod template does not ask for a Dapr sidecar: not rolled" >&2
    failed=1
    continue
  fi
  if [ -e "$mark" ]; then
    # A mark is made before the restart is asked for. It is honoured only when the restart landed: the workload's restartedAt is at or after the
    # mark. A node that rebooted between the two, or a request that timed out before the API applied it, left a mark with no restart behind it:
    # the mark is dropped and the workload rolled once, whatever the cooldown says.
    if ! { r=$(epoch "$lrestarted") && [ "$r" -ge "$(mtime "$mark")" ]; }; then
      echo "dapr-heal: $ns/$owner has a mark but no restart at or after it (restartedAt '${lrestarted:-none}'): the roll never landed; the mark is dropped and it is rolled once"
      if [ "$dry" != 1 ] && ! rm -f "$mark"; then echo "dapr-heal: the mark $mark could not be removed" >&2; failed=1; continue; fi
    else
      # A roll replaces its pods one by one, and the old ones stay until the new are ready: not rolled again within the cooldown.
      if [ -n "$(find "$mark" -mmin "-$COOLDOWN_MINUTES" 2>/dev/null)" ]; then
        echo "dapr-heal: $ns/$owner was rolled less than $COOLDOWN_MINUTES minutes ago and a pod of it is still without its sidecar: waiting"
        continue
      fi
      # Past the cooldown, a pod of it is still bare (the marks of healthy workloads are removed below, so this one is from this
      # incident): the roll landed and did not fix it, whatever the pod's age (the injector injects nothing for it, or the rollout is stuck:
      # OnDelete, paused, an ordered StatefulSet, a Pending pod). Another roll would not either: it is said and the run fails
      # until someone looks, and the mark stays so the next run says it again.
      echo "dapr-heal: $ns/$owner was rolled and, past the cooldown of $COOLDOWN_MINUTES minutes, a pod of it is still without its sidecar: not rolled again" >&2
      failed=1
      continue
    fi
  fi
  if [ "$dry" = 1 ]; then echo "dapr-heal: would roll $ns/$owner"; continue; fi
  # The mark is made before the restart is asked for: a state folder that cannot be written must not leave a restart nothing remembers
  # (every sweep would send it again). Whether the restart landed is read back from the workload on the next sweep, never guessed from an error.
  if ! touch "$mark"; then
    echo "dapr-heal: $ns/$owner: the mark $mark cannot be written: not rolled" >&2
    failed=1
    continue
  fi
  if err=$(k -n "$ns" rollout restart "$owner" 2>&1 >/dev/null); then
    echo "dapr-heal: rolled $ns/$owner: a pod of it ran without its Dapr sidecar"
  else
    echo "dapr-heal: rolling $ns/$owner failed: $err" >&2
    failed=1
  fi
done <<<"$sorted"

# The marks of the workloads with no bare pod: their incident is over. Only a complete inventory prunes (an owner that could not be
# read may be a workload with a mark), and a mark that cannot be removed fails the run.
if [ "$dry" != 1 ] && [ "$incomplete" = 0 ]; then
  for mark in "$state"/*; do
    [ -e "$mark" ] || continue
    # grep reads a here-string, not a pipe: a match that ends it early cannot make the status a SIGPIPE.
    grep -qxF -- "${mark##*/}" <<<"$present" && continue
    rm -f "$mark" || { echo "dapr-heal: the mark $mark of a workload with no bare pod could not be removed" >&2; failed=1; }
  done
fi
exit "$failed"
