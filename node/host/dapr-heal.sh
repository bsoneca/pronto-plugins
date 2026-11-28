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

# One live sweep at a time, on a lock file beside the state folder (a file inside it would be read as a mark): a sweep that starts while another
# runs ends at once, clean. Where flock is not installed (a laptop) there is none.
if [ "$dry" != 1 ] && command -v flock >/dev/null 2>&1; then
  mkdir -p "$(dirname "$state")"
  exec 9>"$state.lock"
  rc=0
  flock -n -E 200 9 || rc=$?
  case $rc in
    0) ;;
    200) echo "dapr-heal: another sweep holds $state.lock: nothing to do"; exit 0 ;;
    *) echo "dapr-heal: flock on $state.lock failed ($rc): no sweep" >&2; exit 1 ;;
  esac
fi

# A mark's time, as seconds since 1970 (GNU stat, else BSD's).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# What was written is on the disk before a name points at it, and the name is, before the sweep says it rolled: coreutils' sync takes files and
# a folder; elsewhere a plain sync does.
flush() { sync "$@" 2>/dev/null || sync; }

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

# One line a pod that asks for the sidecar: namespace|name|phase|deleting|created|owner kind/name@uid|containers|uid,
# each container (init containers too: a native sidecar is one) with a comma after it. Only the listed namespaces are read.
pods=""
for n in $NAMESPACES; do
  pods="$pods$(k -n "$n" get pods -o go-template='{{range .items}}{{$a := .metadata.annotations}}{{if $a}}{{if eq (index $a "dapr.io/enabled") "true"}}{{.metadata.namespace}}|{{.metadata.name}}|{{.status.phase}}|{{if .metadata.deletionTimestamp}}deleting{{end}}|{{.metadata.creationTimestamp}}|{{range .metadata.ownerReferences}}{{if .controller}}{{.kind}}/{{.name}}@{{.uid}}{{end}}{{end}}|{{range .spec.containers}}{{.name}},{{end}}{{range .spec.initContainers}}{{.name}},{{end}}|{{.metadata.uid}}{{"\n"}}{{end}}{{end}}{{end}}')"$'\n'
done

# grep's three answers kept apart: 0 a match, 1 none, anything else (it could not read its input, or run) stops the sweep before a workload is
# rolled or a mark deleted. `has TEXT LIST` is whether a line of LIST is TEXT; the input is a here-string, so a match that ends grep early
# cannot be a SIGPIPE.
has() {
  local rc=0
  grep -qxF -- "$1" <<<"$2" || rc=$?
  case $rc in 0) return 0 ;; 1) return 1 ;; *) echo "dapr-heal: grep failed ($rc): the sweep stops before it rolls or deletes anything" >&2; exit 1 ;; esac
}

# live_recovered NS OWNER WANT: whether the pods the workload's selector names, read now, are WANT live ones (not terminating, not finished) and each
# runs a daprd container. Anything else (fewer, a bare one, only terminating ones, a selector that cannot be used) keeps the mark; a read that
# fails also fails the run.
live_recovered() {
  local ns=$1 owner=$2 want=$3 sel wuid out phase containers powner nlive=0 nbare=0 kind=${2%%/*}
  if ! sel=$(k -n "$ns" get "$owner" -o go-template='{{.metadata.uid}}|{{if .spec.selector.matchExpressions}}(expressions){{else}}{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}{{end}}'); then
    echo "dapr-heal: $ns/$owner's selector could not be read to confirm it recovered: its mark stays" >&2; failed=1; return 1
  fi
  wuid=${sel%%|*}
  sel=${sel#*|}
  sel=${sel%,}
  if ! [[ $sel =~ ^[A-Za-z0-9_./=,-]+$ ]]; then
    echo "dapr-heal: $ns/$owner's selector '$sel' cannot be turned into a pod list: its mark stays" >&2; failed=1; return 1
  fi
  if ! out=$(k -n "$ns" get pods -l "$sel" -o go-template='{{range .items}}{{if .metadata.deletionTimestamp}}deleting{{else}}{{.status.phase}}{{end}}|{{range .spec.containers}}{{.name}},{{end}}{{range .spec.initContainers}}{{.name}},{{end}}|{{range .metadata.ownerReferences}}{{if .controller}}{{.kind}}@{{.uid}}{{end}}{{end}}{{"\n"}}{{end}}'); then
    echo "dapr-heal: the pods of $ns/$owner could not be read to confirm it recovered: its mark stays" >&2; failed=1; return 1
  fi
  while IFS='|' read -r phase containers powner; do
    [ -n "$phase" ] || continue
    case "$phase" in deleting | Succeeded | Failed) continue ;; esac
    # Only the pods this workload owns: a StatefulSet's and a DaemonSet's by the controller reference's uid, a Deployment's by a ReplicaSet owner
    # (the ReplicaSets' own Deployment is not read here: more of them than wanted is an error below). A pod of another workload whose labels
    # the selector also matches is not counted.
    if [ "$kind" = Deployment ]; then case "$powner" in ReplicaSet@*) ;; *) continue ;; esac
    elif [ "$powner" != "$kind@$wuid" ]; then continue; fi
    nlive=$((nlive + 1))
    case ",$containers" in *,daprd,*) ;; *) nbare=$((nbare + 1)) ;; esac
  done <<<"$out"
  if [ "$nlive" -gt "$want" ]; then
    echo "dapr-heal: $ns/$owner has $nlive live pod(s) its selector names, $want wanted (another workload with an overlapping selector, or a rollout that has not ended): its mark stays and the run fails" >&2
    failed=1
    return 1
  fi
  if [ "$nlive" != "$want" ] || [ "$nbare" != 0 ]; then
    echo "dapr-heal: $ns/$owner has $nlive live pod(s) of $want wanted, $nbare without daprd, in the pods read now: its mark stays"
    return 1
  fi
}

# A mark is removed when its workload is confirmed recovered or gone, never because a sweep saw no bare pod of it: during a Recreate rollout the
# old pod is terminating (not counted) and its replacement does not exist yet. `prune_marks PRESENT` goes over the marks of workloads not in
# PRESENT (the ones with a bare pod): a workload that has rolled out its template (observed generation current, ready and updated replicas as
# wanted) or is NotFound loses its mark; one still rolling, or that cannot be read, keeps it (the latter fails the run).
prune_marks() {
  local present=${1:-} mark f ns rest kind name owner out rc errf
  errf="$state.err.$$"
  for mark in "$state"/*; do
    [ -e "$mark" ] || continue
    f=${mark##*/}
    if [ -n "$present" ] && has "$f" "$present"; then continue; fi
    ns=${f%%.*}; rest=${f#*.}; kind=${rest%%.*}; name=${rest#*.}
    case "$kind" in
      Deployment | StatefulSet | DaemonSet) ;;
      *) echo "dapr-heal: the mark $mark is not a workload's: left" >&2; failed=1; continue ;;
    esac
    owner="$kind/$name"
    rc=0
    out=$(k -n "$ns" get "$owner" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.readyReplicas}|{.status.updatedReplicas}|{.status.desiredNumberScheduled}|{.status.numberReady}|{.status.updatedNumberScheduled}|{.status.replicas}|{.status.currentNumberScheduled}' 2>"$errf") || rc=$?
    if [ "$rc" -ne 0 ]; then
      if ! grep -q NotFound "$errf"; then
        echo "dapr-heal: $ns/$owner could not be read to confirm it recovered: its mark stays" >&2
        failed=1
        continue
      fi
    else
      local gen obs want ready upd desired nready updsched total cur
      IFS='|' read -r gen obs want ready upd desired nready updsched total cur <<<"$out"
      if [ "$kind" = DaemonSet ]; then want=${desired:-0}; ready=${nready:-0}; upd=${updsched:-0}; total=${cur:-0}; fi
      # status.replicas counts the old pods too: a surge (3 of 2 wanted) is a rollout still going, though ready and updated are as wanted.
      if [ "${obs:-}" != "${gen:-}" ] || [ "${ready:-0}" != "${want:-0}" ] || [ "${upd:-0}" != "${want:-0}" ] || [ "${total:-0}" != "${want:-0}" ]; then
        echo "dapr-heal: $ns/$owner has no bare pod now but is still rolling out (generation ${gen:-?}, observed ${obs:-?}, ready ${ready:-0} of ${want:-0}): its mark stays"
        continue
      fi
      # The controller's counts and the pod list come from separate reads, and a replacement can be Ready with no daprd that the earlier list did
      # not hold: the mark goes only when the workload's own pods, read now, are exactly the wanted number of live ones and all run daprd.
      if ! live_recovered "$ns" "$owner" "${want:-0}"; then continue; fi
    fi
    rm -f "$mark" || { echo "dapr-heal: the mark $mark of $ns/$owner could not be removed" >&2; failed=1; }
  done
  rm -f "$errf"
}

now=$(date +%s)
bare=""
pod_errors=0
while IFS='|' read -r ns name phase deleting created owner containers puid; do
  [ -n "$name" ] || continue
  [ -z "$deleting" ] || continue
  case "$phase" in Succeeded | Failed) continue ;; esac
  case ",$containers" in *,daprd,*) continue ;; esac
  # The injector adds the sidecar when the pod is admitted, so a bare pod stays bare; the grace is only for a pod whose
  # creation time cannot be told from one being created this second: it is not judged, but its workload is still not healthy
  # (its mark, below, stays).
  # A creation time that cannot be read is no age: the sweep fails naming the pod, and prunes nothing.
  if ! at=$(epoch "$created"); then
    echo "dapr-heal: $ns/$name: its creation time '$created' cannot be read: not judged, no mark pruned" >&2
    failed=1; pod_errors=1; continue
  fi
  young=0
  if [ $((now - at)) -lt "$GRACE_SECONDS" ]; then young=1; fi
  bare="$bare$ns|$name|$owner|$young|$puid|$at"$'\n'
done <<<"$pods"

# A mark says a workload was rolled for bare pods. With no bare pod anywhere its marks are looked at one by one (prune_marks): a workload that
# has recovered or is gone loses its mark, one still rolling out keeps it. A dry run changes nothing.
if [ -z "$bare" ]; then
  if [ "$pod_errors" = 1 ]; then echo "dapr-heal: a pod could not be judged: no mark pruned" >&2; exit 1; fi
  if [ "$dry" != 1 ]; then prune_marks ""; fi
  [ "$failed" = 0 ] || exit 1
  echo "dapr-heal: every pod that asks for a Dapr sidecar runs one"
  exit 0
fi

# Rolling a Deployment while the injector is down would only make new bare pods: say so and fail the run, so a node whose
# injector stays down shows in `node/host/host.nu apply --check` as a job that failed its last run.
judged_re='^[^|]*\|[^|]*\|[^|]*\|0\|'
rc=0
judged=$(grep -c -E "$judged_re" <<<"$bare") || rc=$?
case $rc in 0 | 1) ;; *) echo "dapr-heal: grep failed ($rc) counting the pods to judge: nothing rolled" >&2; exit 1 ;; esac
if [ "${judged:-0}" -gt 0 ]; then
  # Only a pod old enough to roll asks: a failed read is its own error, not an injector that has no replica.
  if ! ready=$(k -n dapr-system get deployment dapr-sidecar-injector -o jsonpath='{.status.readyReplicas}'); then
    echo "dapr-heal: pods without their Dapr sidecar, but the injector (dapr-system/dapr-sidecar-injector) could not be read: not rolling" >&2
    exit 1
  fi
  if [ "${ready:-0}" -lt 1 ]; then
    echo "dapr-heal: pods without their Dapr sidecar, but the injector (dapr-system/dapr-sidecar-injector) has no ready replica: not rolling:" >&2
    { grep -E "$judged_re" <<<"$bare" || true; } | cut -d'|' -f1,2 | sed 's/^/  /' >&2
    exit 1
  fi
fi

# The workload that owns each bare pod: a ReplicaSet's owner is its Deployment; a StatefulSet and a DaemonSet own the pod. The owner
# reference is the pod's, written by whoever created it, so it is checked against the live workload below (uid, and that its template asks
# for the sidecar). Anything else (a Job, a pod of its own) is not rolled. `present` is every workload with a bare pod, a young one too,
# and `targets` the ones with a pod old enough to be judged, one line a pod.
present=""
targets=""
incomplete=$pod_errors
while IFS='|' read -r ns name owner young puid created_at; do
  [ -n "$name" ] || continue
  case "$owner" in
    ReplicaSet/*)
      # A lookup that failed leaves the inventory incomplete: nothing is pruned below, so a live rollout's mark survives the outage of the API.
      rsname=${owner#ReplicaSet/}
      rsuid=${rsname##*@}
      rsname=${rsname%@*}
      # The name is a pod writer's text: it is a ReplicaSet's name before it is an argument, in a namespace that is swept, and the ReplicaSet found
      # is the one the pod names (its uid), not whichever has that name now.
      case " $NAMESPACES " in *" $ns "*) ;; *) echo "dapr-heal: $ns/$name: '$ns' is not a swept namespace: not looked up" >&2; failed=1; incomplete=1; continue ;; esac
      if ! [[ $rsname =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
        echo "dapr-heal: $ns/$name: its ReplicaSet name is not a name: not looked up" >&2
        failed=1; incomplete=1; continue
      fi
      if ! owner=$(k -n "$ns" get "replicaset/$rsname" -o jsonpath='{.metadata.uid}|{.metadata.ownerReferences[?(@.controller==true)].kind}/{.metadata.ownerReferences[?(@.controller==true)].name}@{.metadata.ownerReferences[?(@.controller==true)].uid}'); then
        echo "dapr-heal: $ns/$name: its ReplicaSet could not be read: not pruning marks" >&2
        failed=1; incomplete=1; continue
      fi
      if [ "${owner%%|*}" != "$rsuid" ]; then
        echo "dapr-heal: $ns/$name: the ReplicaSet now named $rsname is not the one the pod names: not rolled" >&2
        failed=1; incomplete=1; continue
      fi
      owner=${owner#*|}
      case "$owner" in Deployment/?*) ;; *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: its ReplicaSet has no Deployment: not rolled" >&2; failed=1; }; continue ;; esac ;;
    StatefulSet/?* | DaemonSet/?*) ;;
    *) [ "$young" = 1 ] || { echo "dapr-heal: $ns/$name: owned by '${owner:-nothing}': not rolled" >&2; failed=1; }; continue ;;
  esac
  ouid=${owner##*@}
  owner=${owner%@*}
  present="$present$ns.${owner//\//.}"$'\n'
  [ "$young" = 1 ] || targets="$targets$ns|$owner|$ouid|$puid|$created_at"$'\n'
done <<<"$bare"

# The sorted targets are read into a variable first: a sort that failed must not look like a workload-free sweep.
if ! sorted=$(sort -u <<<"$targets"); then
  echo "dapr-heal: the workloads to roll could not be sorted: nothing rolled" >&2
  exit 1
fi
if ! workloads=$(cut -d'|' -f1-3 <<<"$sorted" | sort -u); then
  echo "dapr-heal: the workloads to roll could not be listed: nothing rolled" >&2
  exit 1
fi

# One attempt at a workload: an id, written into its mark with the uids of the bare pods it covers and the time it was made, and patched onto the
# workload's pod template as the annotation pronto.dev/dapr-heal-attempt (a changed template is a rolling restart). The patch answers with the
# workload's generation, which the mark then holds: that is the attempt acknowledged. A later change to the template (a release, a rollback, another
# rollout) moves the generation on, which is how a bare pod of a later revision is told from the roll's own replacements; the time is only the
# cooldown's. Whether the attempt landed is read back by comparing the annotation with the mark's id, never by a clock, and the same patch can be
# sent again, since the same id changes nothing.
attempt_note='pronto.dev/dapr-heal-attempt'
patch_id() { # ns owner id: the generation after the patch, on stdout
  k -n "$1" patch "$2" --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$attempt_note\":\"$3\"}}}}}" -o 'jsonpath={.metadata.generation}'
}
# write_mark ID PODS TIME GEN ATTEMPTS: the mark of the workload being handled ($mark), to a dot-named temporary no workload can have, flushed, renamed over
# the mark and the folder flushed: a power cut must not leave a mark that is empty or half there. GEN is empty until the attempt is acknowledged. ATTEMPTS is how many rolls this
# incident has had (the same generation, no prune between): the run fails instead of rolling a third time.
write_mark() {
  local tmp="$state/.tmp.$$"
  # Every write must succeed: the optional generation line is joined with &&, so a failed first printf is the group's status, never the empty test.
  if { printf 'attempt=%s\npods=%s\ntime=%s\nattempts=%s\n' "$1" "$2" "$3" "${5:-1}" && { [ -z "$4" ] || printf 'generation=%s\n' "$4"; }; } >"$tmp" && flush "$tmp" && mv -f "$tmp" "$mark" && flush "$state"; then return 0; fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

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
  # The live workload, not the pod's word for it: its uid is the owner reference's, its template asks for the sidecar, and which attempt of ours
  # it last carried.
  if ! info=$(k -n "$ns" get "$owner" -o jsonpath='{.metadata.uid}|{.spec.template.metadata.annotations.dapr\.io/enabled}|{.spec.template.metadata.annotations.pronto\.dev/dapr-heal-attempt}|{.metadata.generation}'); then
    echo "dapr-heal: $ns/$owner could not be read: not rolled" >&2
    failed=1
    continue
  fi
  IFS='|' read -r luid ldapr lattempt lgen <<<"$info"
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
  # This workload's bare pods now: uid and creation time (seconds), one a line.
  if ! podlist=$(awk -F'|' -v k="$ns|$owner|$ouid" '$1 "|" $2 "|" $3 == k { print $4 " " $5 }' <<<"$sorted" | sort -u); then
    echo "dapr-heal: the bare pods of $ns/$owner could not be listed: not rolled" >&2
    failed=1
    continue
  fi
  uids=$(while read -r u _; do printf '%s ' "$u"; done <<<"$podlist")
  attempts=1
  if [ -e "$mark" ]; then
    # A mark that cannot be read is no mark that can be dropped: the workload is left alone and the run fails.
    if ! mid=$(sed -n 's/^attempt=//p' "$mark") || ! mpods=$(sed -n 's/^pods=//p' "$mark") || ! mgen=$(sed -n 's/^generation=//p' "$mark") || ! mtimev=$(sed -n 's/^time=//p' "$mark") || ! mattempts=$(sed -n 's/^attempts=//p' "$mark"); then
      echo "dapr-heal: the mark $mark of $ns/$owner could not be read: not rolled" >&2
      failed=1
      continue
    fi
    # How many rolls the incident has had; a mark of an older format has had one.
    mattempts=${mattempts:-1}
    if ! [[ $mattempts =~ ^[0-9]+$ ]]; then
      echo "dapr-heal: the mark $mark of $ns/$owner holds an attempt count that is not a number ('$mattempts'): not rolled" >&2
      failed=1
      continue
    fi
    # The mark's own time, else (an older mark) its file's.
    if ! [[ $mtimev =~ ^[0-9]+$ ]] && ! mtimev=$(mtime "$mark"); then
      echo "dapr-heal: the time of the mark $mark could not be read: not rolled" >&2
      failed=1
      continue
    fi
    cooldown_end=$((mtimev + COOLDOWN_MINUTES * 60))
    if [ "$now" -lt "$cooldown_end" ]; then within=1; else within=0; fi
    if [ -z "$mid" ]; then
      # A mark with no attempt in it (an older one): nothing says what it did, but its time is when the workload was last rolled. Within the
      # cooldown the workload waits; after it, it is dropped and the workload gets an attempt of its own.
      if [ "$within" = 1 ]; then
        echo "dapr-heal: $ns/$owner has an older mark, rolled less than $COOLDOWN_MINUTES minutes ago: waiting"
        continue
      fi
      echo "dapr-heal: $ns/$owner has an older mark with no attempt in it, past the cooldown: dropped"
      if [ "$dry" != 1 ] && ! rm -f "$mark"; then echo "dapr-heal: the mark $mark could not be removed" >&2; failed=1; continue; fi
    elif ! [[ $mid =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
      echo "dapr-heal: the mark $mark of $ns/$owner holds an attempt id that is not one of ours ('$mid'): not rolled" >&2
      failed=1
      continue
    elif [ -z "$mgen" ] && [ "$lattempt" != "$mid" ]; then
      # An attempt that was never acknowledged (the mark has no generation) and is not on the workload: a reboot or a lost request came between the
      # mark and the patch. The same patch is sent again, with the same id, whatever the cooldown says; its answer acknowledges it.
      if [ "$dry" = 1 ]; then echo "dapr-heal: would send $ns/$owner's attempt $mid again (it is not on the workload)"; continue; fi
      if gen=$(patch_id "$ns" "$owner" "$mid" 2>"$state.err.$$"); then
        if write_mark "$mid" "$mpods" "$now" "$gen" "$mattempts"; then
          echo "dapr-heal: rolled $ns/$owner: attempt $mid had not landed and was sent again"
        else
          echo "dapr-heal: attempt $mid was sent again to $ns/$owner, but its mark $mark could not be written" >&2
          failed=1
        fi
      else
        echo "dapr-heal: sending attempt $mid to $ns/$owner again failed: $(cat "$state.err.$$")" >&2
        failed=1
      fi
      rm -f "$state.err.$$"
      continue
    else
      # The attempt is on the workload, or was acknowledged. One that landed unacknowledged (the sweep that sent it did not live to write the
      # generation) is acknowledged now, at the generation the workload has.
      if [ -z "$mgen" ]; then
        mgen=$lgen
        if [ "$dry" != 1 ] && ! write_mark "$mid" "$mpods" "$mtimev" "$mgen" "$mattempts"; then
          echo "dapr-heal: the attempt $mid of $ns/$owner landed, but its mark $mark could not be written: not rolled" >&2
          failed=1
          continue
        fi
      fi
      if [ "$within" = 1 ]; then
        echo "dapr-heal: $ns/$owner was rolled less than $COOLDOWN_MINUTES minutes ago and a pod of it is still without its sidecar: waiting"
        continue
      fi
      if [ "$lgen" != "$mgen" ]; then
        # The workload's template has changed since the attempt (a release, a rollback, a later rollout): the bare pods are of a later revision,
        # not the roll's replacements, so they are a new incident whatever their age and annotation, and get an attempt.
        echo "dapr-heal: $ns/$owner's template changed since its last attempt (generation $mgen, now $lgen): its bare pods are a new incident"
      else
        # Same template, past the cooldown. A bare pod the attempt covered is still bare: the roll landed and did not fix it (the injector injects
        # nothing for it, or the rollout is stuck: OnDelete, paused, an ordered StatefulSet, a Pending pod). Another roll would not either: it is
        # said and the run fails until someone looks, and the mark stays. Any other bare pod is one the injector missed after the attempt (the
        # injector is ready: it was read above), a repaired pod's replacement or a roll's own: the cooldown only bounds how often a workload is
        # restarted, never a pod's age against a fixed time, so it gets an attempt of its own.
        persists=0
        while read -r u _; do
          [ -n "$u" ] || continue
          case " $mpods " in *" $u "*) persists=1 ;; esac
        done <<<"$podlist"
        if [ "$persists" = 1 ]; then
          echo "dapr-heal: $ns/$owner was rolled and, past the cooldown of $COOLDOWN_MINUTES minutes, a pod it covered is still without its sidecar: not rolled again" >&2
          failed=1
          continue
        fi
        # The roll's own replacements are not in the mark (it lists the pods that existed before the patch), so an injector that is ready and
        # still injects nothing (a webhook or certificate broken, failurePolicy Ignore) would be rolled every cooldown for ever: a second roll of
        # one incident is the last, and the third is an error until someone looks.
        if [ "$mattempts" -ge 2 ]; then
          echo "dapr-heal: $ns/$owner was rolled $mattempts times for this incident (generation $mgen) and a pod of it is still without its sidecar: not rolled again" >&2
          failed=1
          continue
        fi
        attempts=$((mattempts + 1))
        echo "dapr-heal: $ns/$owner has bare pods its last attempt did not cover, and its cooldown is over: attempt $attempts"
      fi
    fi
  fi
  if [ "$dry" = 1 ]; then echo "dapr-heal: would roll $ns/$owner"; continue; fi
  # The mark is written before the patch is sent: a state folder that cannot be written must not leave a restart nothing remembers (every sweep
  # would send it again). The patch's answer then acknowledges it.
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if ! write_mark "$id" "$uids" "$now" "" "$attempts"; then
    echo "dapr-heal: $ns/$owner: the mark $mark cannot be written: not rolled" >&2
    failed=1
    continue
  fi
  if gen=$(patch_id "$ns" "$owner" "$id" 2>"$state.err.$$"); then
    echo "dapr-heal: rolled $ns/$owner: a pod of it ran without its Dapr sidecar (attempt $id)"
    if ! write_mark "$id" "$uids" "$now" "$gen" "$attempts"; then
      echo "dapr-heal: the attempt $id was sent to $ns/$owner, but its acknowledgement could not be written to $mark: the next sweep acknowledges it" >&2
      failed=1
    fi
  else
    echo "dapr-heal: rolling $ns/$owner failed: $(cat "$state.err.$$")" >&2
    failed=1
  fi
  rm -f "$state.err.$$"
done <<<"$workloads"

# The marks of the workloads with no bare pod are looked at (prune_marks): a recovered or removed workload loses its mark, one still rolling out
# keeps it. Only a complete inventory prunes (an owner that could not be read may be a workload with a mark).
if [ "$dry" != 1 ] && [ "$incomplete" = 0 ]; then prune_marks "$present"; fi
exit "$failed"
