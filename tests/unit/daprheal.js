// node/host/dapr-heal.sh run by bash on a stand-in kubectl (tests/unit/daprheal.cue): the pods the node's API says, the
// injector's ready replicas, each ReplicaSet's owner and the rolls made earlier are given; what comes back is the exit code, what
// it said, and the workloads the script asked kubectl to roll. Nothing here touches a cluster.

const here = new URL('.', import.meta.url).pathname;
const script = `${here}../../node/host/dapr-heal.sh`;
// A uid as Kubernetes writes one (36 characters, hex and dashes), the same for a name every time.
const uidOf = (name) => { let h = 0n; for (const c of name) h = (h * 131n + BigInt(c.charCodeAt(0))) % (1n << 128n); const x = h.toString(16).padStart(32, '0'); return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`; };
const ATTEMPT = '20260101T000000Z-1';
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');

/**
 * Options: `pods`, [{ns, name, owner, containers, init, phase = Running, deleting, ageSec = 3600}]; `injector`, the injector's ready
 * replicas as kubectl prints them ("1", "" for none); `rs`, {"ns/replicaset": "Deployment/name"}; `marks`, {"ns.Deployment.name":
 * minutes since it was rolled}; `failRoll`, workloads whose roll fails; `args`; `cooldown`, `grace`; `namespaces`, the ones swept (aprende and bonk); `failRs`, every ReplicaSet read fails; `readonlyState`, the marks' folder cannot be written; `rollError`, what a failed restart says; `noStateDir`, there is none yet (`stateCreated` says whether the run made it); `attempt`, {"ns/Kind/name": the attempt id the workload's template carries, null for none} (default: `a1` for a workload with a mark, so the mark landed); `markPods`, {mark name: [names of the pods its attempt covered]} (default: every pod given); `failGrep`, the script's grep fails; `oldMarks`, {name: minutes} marks of the older format (empty); `markAttempt`, {name: the id its mark holds}; `markIsDir`, mark names that cannot be read (mode 000); `generation`, {"ns/Kind/name": the workload's generation (default 7)}; `markGeneration`, {mark name: the generation its mark acknowledges, null for none (default 7)}; `patchGeneration` (8), what a patch answers; `rollout`, {"ns/Kind/name": "pending" | "gone" | "unreadable"} for the status read that confirms recovery; `lockError`, flock fails for another reason; `lockHeld`, another sweep holds the lock (`syncs`, what the sweep flushed; `markAges`, minutes since each mark was last written); `uidMismatch`, workloads whose live uid is not the owner reference's; `noDaprTemplate`, workloads whose template does not ask for a sidecar; `failLive`, workload reads fail; `failSort`, sort fails; `extraOut`, raw text the first namespace's pod list ends with (a forged line); `injectorError`, the injector read fails; `live`, {"ns/Kind/name": the pods the workload's selector names when the recovery is confirmed, "phase|containers" lines (default: two Running ones with daprd) or "unreadable" or "expressions"}.
 */
export const run = ({ pods = [], injector = '1', rs = {}, marks = {}, failRoll = [], args = [], cooldown = 30, grace = 120, namespaces = ['aprende', 'bonk'], rollError = 'the server rejected our request', failRs = false, readonlyState = false, noStateDir = false, attempt = {}, markPods = {}, failGrep = false, oldMarks = {}, markAttempt = {}, markIsDir = [], lockHeld = false, lockError = false, generation = {}, markGeneration = {}, patchGeneration = '8', rollout = {}, uidMismatch = [], noDaprTemplate = [], failLive = false, failSort = false, injectorError = false, extraOut = '', live = {} } = {}) => {
  const dir = Deno.makeTempDirSync();
  try {
    const now = Date.now();
    const lines = pods.map((p) => [p.ns, p.name, p.phase ?? 'Running', p.deleting ? 'deleting' : '', (p.created ?? iso(now - (p.ageSec ?? 3600) * 1000)), (p.owner ? `${p.owner}@${p.ownerUid ?? uidOf(p.owner)}` : ''), [...(p.containers ?? ['app']), ...(p.init ?? [])].map((c) => `${c},`).join(''), uidOf(`pod:${p.name}`)].join('|'));
    Deno.writeTextFileSync(`${dir}/pods`, lines.map((l) => `${l}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/injector`, injector);
    if (injectorError) Deno.writeTextFileSync(`${dir}/injectorerror`, '');
    if (failLive) Deno.writeTextFileSync(`${dir}/faillive`, '');
    Deno.writeTextFileSync(`${dir}/extra`, extraOut);
    Deno.writeTextFileSync(`${dir}/firstns`, namespaces[0]);
    for (const p of pods) if (p.owner && !p.owner.startsWith('ReplicaSet/')) Deno.writeTextFileSync(`${dir}/uid.${p.owner.replaceAll('/', '.')}`, uidOf(p.owner));
    Deno.writeTextFileSync(`${dir}/uidmismatch`, uidMismatch.map((w) => `${w}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/nodapr`, noDaprTemplate.map((w) => `${w}\n`).join(''));
    for (const name of Object.keys(marks)) { const [n, kind, ...rest] = name.split('.'); const key = `${n}/${kind}/${rest.join('.')}`; if (!(key in attempt)) attempt[key] = markAttempt[name] ?? ATTEMPT; }
    for (const [w, n] of Object.entries(generation)) Deno.writeTextFileSync(`${dir}/gen.${w.replaceAll('/', '.')}`, String(n));
    for (const [w, st] of Object.entries(rollout)) Deno.writeTextFileSync(`${dir}/rollout.${w.replaceAll('/', '.')}`, st);
    for (const [w, v] of Object.entries(live)) Deno.writeTextFileSync(`${dir}/live.${w.replaceAll('/', '.')}`, Array.isArray(v) ? v.map((l) => `${l}\n`).join('') : v);
    Deno.writeTextFileSync(`${dir}/patchgen`, String(patchGeneration));
    for (const [w, id] of Object.entries(attempt)) Deno.writeTextFileSync(`${dir}/attempt.${w.replaceAll('/', '.')}`, id ?? '');
    Deno.writeTextFileSync(`${dir}/fail`, failRoll.map((f) => `${f}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/calls`, '');
    Deno.writeTextFileSync(`${dir}/rollerror`, rollError);
    if (failRs) Deno.writeTextFileSync(`${dir}/failrs`, '');
    for (const [k, v] of Object.entries(rs)) {
      Deno.writeTextFileSync(`${dir}/rs.${k.replace('/', '.')}`, `${uidOf(`ReplicaSet/${k.split('/')[1]}`)}|${v}@${uidOf(v)}`);
      Deno.writeTextFileSync(`${dir}/uid.${v.replaceAll('/', '.')}`, uidOf(v));
    }
    if (!noStateDir || Object.keys(marks).length) Deno.mkdirSync(`${dir}/state`);
    for (const [name, minutes] of Object.entries(marks)) {
      const at0 = now - minutes * 60000;
      const covered = (markPods[name] ?? pods.map((p) => p.name)).map((n) => uidOf(`pod:${n}`)).join(' ');
      Deno.writeTextFileSync(`${dir}/state/${name}`, `attempt=${markAttempt[name] ?? ATTEMPT}\npods=${covered}\ntime=${Math.floor(at0 / 1000)}\n${(markGeneration[name] === undefined ? '7' : markGeneration[name]) === null ? '' : `generation=${markGeneration[name] === undefined ? '7' : markGeneration[name]}\n`}`);
      const at = new Date(now - minutes * 60000);
      Deno.utimeSync(`${dir}/state/${name}`, at, at);
    }
    for (const [name, minutes] of Object.entries(oldMarks)) {
      if (!noStateDir) { try { Deno.mkdirSync(`${dir}/state`); } catch { /* there */ } }
      Deno.writeTextFileSync(`${dir}/state/${name}`, '');
      const at = new Date(now - minutes * 60000);
      Deno.utimeSync(`${dir}/state/${name}`, at, at);
    }
    for (const name of markIsDir) { try { Deno.mkdirSync(`${dir}/state`); } catch { /* there */ } Deno.writeTextFileSync(`${dir}/state/${name}`, 'attempt=x\npods=\n'); Deno.chmodSync(`${dir}/state/${name}`, 0o000); }
    Deno.writeTextFileSync(`${dir}/kubectl`, `#!/bin/bash
d=$(dirname "$0")
echo "$*" >>"$d/calls"
case "$*" in
  *"get pods -l "*) sel=$(echo "$*" | sed -E 's/.* -l ([^ ]+) .*/\\1/'); kk=$(echo "$sel" | sed -E 's/^app=//'); f="$d/live.$kk"
    if [ -e "$f" ]; then if [ "$(cat "$f")" = unreadable ]; then echo "the server is not answering" >&2; exit 1; fi; cat "$f"; else printf 'Running|app,daprd,\\nRunning|app,daprd,\\n'; fi ;;
  *"get pods"*) n=$(echo "$*" | sed -E 's/.*-n ([^ ]+) get pods.*/\\1/'); grep "^$n|" "$d/pods" || true; if [ "$n" = "$(cat "$d/firstns")" ]; then cat "$d/extra"; fi ;;
  *"-n dapr-system get deployment dapr-sidecar-injector"*) if [ -e "$d/injectorerror" ]; then echo "forbidden" >&2; exit 1; fi; printf '%s' "$(cat "$d/injector")" ;;
  *" get Deployment/"* | *" get StatefulSet/"* | *" get DaemonSet/"*)
    ns=$(echo "$*" | sed -E 's/.*-n ([^ ]+) get .*/\\1/'); w=$(echo "$*" | sed -E 's/.* get ([^ ]+) -o.*/\\1/'); key="$ns/$w"; kk=$(echo "$key" | tr / .)
    case "$*" in
      *matchLabels*) lf="$d/live.$kk"; if [ -e "$lf" ] && [ "$(cat "$lf")" = expressions ]; then printf "(expressions)"; else printf 'app=%s,' "$kk"; fi; exit 0 ;;
      *observedGeneration*)
        if [ -e "$d/rollout.$kk" ]; then
          case "$(cat "$d/rollout.$kk")" in
            gone) echo 'Error from server (NotFound): deployments.apps "x" not found' >&2; exit 1 ;;
            unreadable) echo 'Unable to connect to the server' >&2; exit 1 ;;
            pending) printf '7|6|2|1|1|||' ; exit 0 ;;
          esac
        fi
        printf '7|7|2|2|2|||'; exit 0 ;;
    esac
    if [ -e "$d/faillive" ]; then echo "the server is not answering" >&2; exit 1; fi
    uid=$(cat "$d/uid.$(echo "$w" | tr / .)" 2>/dev/null); if grep -qxF "$key" "$d/uidmismatch"; then uid=00000000-0000-0000-0000-000000000000; fi
    dapr=true; if grep -qxF "$key" "$d/nodapr"; then dapr=; fi
    r="$d/attempt.$kk"; if [ -e "$r" ]; then at=$(cat "$r"); else at=; fi
    g=7; if [ -e "$d/gen.$kk" ]; then g=$(cat "$d/gen.$kk"); fi
    printf '%s|%s|%s|%s' "$uid" "$dapr" "$at" "$g" ;;
  *" get replicaset/"*) if [ -e "$d/failrs" ]; then echo "the server is not answering" >&2; exit 1; fi; printf '%s' "$(cat "$d/rs.$(echo "$*" | sed -E 's#.*-n ([^ ]+) get replicaset/([^ ]+) .*#\\1.\\2#')" 2>/dev/null)" ;;
  *" patch "*) w=$(echo "$*" | sed -E 's/.*-n ([^ ]+) patch ([^ ]+) .*/\\1\\/\\2/'); id=$(echo "$*" | sed -E 's/.*dapr-heal-attempt":"([^"]*)".*/\\1/'); if grep -qxF "$w" "$d/fail"; then cat "$d/rollerror" >&2; exit 1; fi; echo "$w" >>"$d/rolled"; echo "$w $id" >>"$d/patched"; cat "$d/patchgen" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
`);
    Deno.chmodSync(`${dir}/kubectl`, 0o755);
    Deno.mkdirSync(`${dir}/bin`);
    Deno.writeTextFileSync(`${dir}/bin/sync`, `#!/bin/sh\necho "$*" >>${dir}/sync.log\n`); Deno.chmodSync(`${dir}/bin/sync`, 0o755);
    if (lockHeld || lockError) { Deno.writeTextFileSync(`${dir}/bin/flock`, `#!/bin/sh\nexit ${lockHeld ? 200 : 1}\n`); Deno.chmodSync(`${dir}/bin/flock`, 0o755); }
    if (failGrep) { Deno.writeTextFileSync(`${dir}/bin/grep`, '#!/bin/sh\ncase " $* " in *" -- "*|*" -c "*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n'); Deno.chmodSync(`${dir}/bin/grep`, 0o755); }
    if (failSort) { Deno.writeTextFileSync(`${dir}/bin/sort`, '#!/bin/sh\nexit 2\n'); Deno.chmodSync(`${dir}/bin/sort`, 0o755); }
    Deno.writeTextFileSync(`${dir}/env`, `KUBECTL='${dir}/kubectl'\nNAMESPACES='${namespaces.join(' ')}'\nGRACE_SECONDS=${grace}\nCOOLDOWN_MINUTES=${cooldown}\n`);
    if (readonlyState) Deno.chmodSync(`${dir}/state`, 0o555);
    const r = new Deno.Command('bash', {
      args: [script, ...args], stdout: 'piped', stderr: 'piped',
      env: { DAPR_HEAL_ENV: `${dir}/env`, DAPR_HEAL_STATE: `${dir}/state`, PATH: `${dir}/bin:/usr/bin:/bin` },
    }).outputSync();
    const dec = new TextDecoder();
    let rolled = [];
    try { rolled = Deno.readTextFileSync(`${dir}/rolled`).trim().split('\n'); } catch { /* none rolled */ }
    const ids = {};
    try { for (const l of Deno.readTextFileSync(`${dir}/patched`).trim().split('\n')) { const [w, id] = l.split(' '); ids[w] = id; } } catch { /* none */ }
    const markText = {};
    const marked = [];
    let syncs = [];
    try { syncs = Deno.readTextFileSync(`${dir}/sync.log`).trim().split('\n').map((l) => l.replace(dir, '<dir>')); } catch { /* none */ }
    for (const name of markIsDir) { try { Deno.chmodSync(`${dir}/state/${name}`, 0o600); } catch { /* gone */ } }
    if (readonlyState) Deno.chmodSync(`${dir}/state`, 0o755);
    let stateCreated = false;
    const markAges = {};
    try { Deno.statSync(`${dir}/state`); stateCreated = true; for (const e of Deno.readDirSync(`${dir}/state`)) { marked.push(e.name); try { markText[e.name] = Deno.readTextFileSync(`${dir}/state/${e.name}`); } catch { /* unreadable */ } markAges[e.name] = Math.round((Date.now() - Deno.statSync(`${dir}/state/${e.name}`).mtime.getTime()) / 60000); } } catch { /* none */ }
    return { acknowledged: Object.keys(markText).filter((n) => markText[n].includes('generation=')), markText, syncs, markAges, ids, stateCreated, code: r.code, out: dec.decode(r.stdout), err: dec.decode(r.stderr), rolled, marked: marked.sort() };
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
