// node/host/dapr-heal.sh run by bash on a stand-in kubectl (tests/unit/daprheal.cue): the pods the node's API says, the
// injector's ready replicas, each ReplicaSet's owner and the rolls made earlier are given; what comes back is the exit code, what
// it said, and the workloads the script asked kubectl to roll. Nothing here touches a cluster.

const here = new URL('.', import.meta.url).pathname;
const script = `${here}../../node/host/dapr-heal.sh`;
// A uid as Kubernetes writes one (36 characters, hex and dashes), the same for a name every time.
const uidOf = (name) => { let h = 0n; for (const c of name) h = (h * 131n + BigInt(c.charCodeAt(0))) % (1n << 128n); const x = h.toString(16).padStart(32, '0'); return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`; };
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');

/**
 * Options: `pods`, [{ns, name, owner, containers, init, phase = Running, deleting, ageSec = 3600}]; `injector`, the injector's ready
 * replicas as kubectl prints them ("1", "" for none); `rs`, {"ns/replicaset": "Deployment/name"}; `marks`, {"ns.Deployment.name":
 * minutes since it was rolled}; `failRoll`, workloads whose roll fails; `args`; `cooldown`, `grace`; `namespaces`, the ones swept (aprende and bonk); `failRs`, every ReplicaSet read fails; `readonlyState`, the marks' folder cannot be written; `rollError`, what a failed restart says; `noStateDir`, there is none yet (`stateCreated` says whether the run made it); `restartedAt`, {"ns/Kind/name": minutes since its restart annotation, null for none} (default: just now, so a mark is honoured); `uidMismatch`, workloads whose live uid is not the owner reference's; `noDaprTemplate`, workloads whose template does not ask for a sidecar; `failLive`, workload reads fail; `failSort`, sort fails; `extraOut`, raw text the first namespace's pod list ends with (a forged line); `injectorError`, the injector read fails.
 */
export const run = ({ pods = [], injector = '1', rs = {}, marks = {}, failRoll = [], args = [], cooldown = 30, grace = 120, namespaces = ['aprende', 'bonk'], rollError = 'the server rejected our request', failRs = false, readonlyState = false, noStateDir = false, restartedAt = {}, uidMismatch = [], noDaprTemplate = [], failLive = false, failSort = false, injectorError = false, extraOut = '' } = {}) => {
  const dir = Deno.makeTempDirSync();
  try {
    const now = Date.now();
    const lines = pods.map((p) => [p.ns, p.name, p.phase ?? 'Running', p.deleting ? 'deleting' : '', iso(now - (p.ageSec ?? 3600) * 1000), (p.owner ? `${p.owner}@${uidOf(p.owner)}` : ''), [...(p.containers ?? ['app']), ...(p.init ?? [])].map((c) => `${c},`).join('')].join('|'));
    Deno.writeTextFileSync(`${dir}/pods`, lines.map((l) => `${l}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/injector`, injector);
    if (injectorError) Deno.writeTextFileSync(`${dir}/injectorerror`, '');
    if (failLive) Deno.writeTextFileSync(`${dir}/faillive`, '');
    Deno.writeTextFileSync(`${dir}/extra`, extraOut);
    Deno.writeTextFileSync(`${dir}/firstns`, namespaces[0]);
    for (const p of pods) if (p.owner && !p.owner.startsWith('ReplicaSet/')) Deno.writeTextFileSync(`${dir}/uid.${p.owner.replaceAll('/', '.')}`, uidOf(p.owner));
    Deno.writeTextFileSync(`${dir}/uidmismatch`, uidMismatch.map((w) => `${w}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/nodapr`, noDaprTemplate.map((w) => `${w}\n`).join(''));
    for (const [w, minutes] of Object.entries(restartedAt)) Deno.writeTextFileSync(`${dir}/restarted.${w.replaceAll('/', '.')}`, minutes === null ? '' : iso(now - minutes * 60000));
    Deno.writeTextFileSync(`${dir}/fail`, failRoll.map((f) => `${f}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/calls`, '');
    Deno.writeTextFileSync(`${dir}/rollerror`, rollError);
    if (failRs) Deno.writeTextFileSync(`${dir}/failrs`, '');
    for (const [k, v] of Object.entries(rs)) {
      Deno.writeTextFileSync(`${dir}/rs.${k.replace('/', '.')}`, `${v}@${uidOf(v)}`);
      Deno.writeTextFileSync(`${dir}/uid.${v.replaceAll('/', '.')}`, uidOf(v));
    }
    if (!noStateDir || Object.keys(marks).length) Deno.mkdirSync(`${dir}/state`);
    for (const [name, minutes] of Object.entries(marks)) {
      Deno.writeTextFileSync(`${dir}/state/${name}`, '');
      const at = new Date(now - minutes * 60000);
      Deno.utimeSync(`${dir}/state/${name}`, at, at);
    }
    Deno.writeTextFileSync(`${dir}/kubectl`, `#!/bin/bash
d=$(dirname "$0")
echo "$*" >>"$d/calls"
case "$*" in
  *"get pods"*) n=$(echo "$*" | sed -E 's/.*-n ([^ ]+) get pods.*/\\1/'); grep "^$n|" "$d/pods" || true; if [ "$n" = "$(cat "$d/firstns")" ]; then cat "$d/extra"; fi ;;
  *"-n dapr-system get deployment dapr-sidecar-injector"*) if [ -e "$d/injectorerror" ]; then echo "forbidden" >&2; exit 1; fi; printf '%s' "$(cat "$d/injector")" ;;
  *" get Deployment/"* | *" get StatefulSet/"* | *" get DaemonSet/"*)
    if [ -e "$d/faillive" ]; then echo "the server is not answering" >&2; exit 1; fi
    ns=$(echo "$*" | sed -E 's/.*-n ([^ ]+) get .*/\\1/'); w=$(echo "$*" | sed -E 's/.* get ([^ ]+) -o.*/\\1/'); key="$ns/$w"
    uid=$(cat "$d/uid.$(echo "$w" | tr / .)" 2>/dev/null); if grep -qxF "$key" "$d/uidmismatch"; then uid=00000000-0000-0000-0000-000000000000; fi
    dapr=true; if grep -qxF "$key" "$d/nodapr"; then dapr=; fi
    r="$d/restarted.$(echo "$key" | tr / .)"; if [ -e "$r" ]; then at=$(cat "$r"); else at=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi
    printf '%s|%s|%s' "$uid" "$dapr" "$at" ;;
  *"get replicaset "*) if [ -e "$d/failrs" ]; then echo "the server is not answering" >&2; exit 1; fi; printf '%s' "$(cat "$d/rs.$(echo "$*" | sed -E 's/.*-n ([^ ]+) get replicaset ([^ ]+) .*/\\1.\\2/')" 2>/dev/null)" ;;
  *"rollout restart "*) w=$(echo "$*" | sed -E 's/.*-n ([^ ]+) rollout restart (.*)/\\1\\/\\2/'); if grep -qxF "$w" "$d/fail"; then cat "$d/rollerror" >&2; exit 1; fi; echo "$w" >>"$d/rolled" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
`);
    Deno.chmodSync(`${dir}/kubectl`, 0o755);
    Deno.mkdirSync(`${dir}/bin`);
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
    const marked = [];
    if (readonlyState) Deno.chmodSync(`${dir}/state`, 0o755);
    let stateCreated = false;
    try { Deno.statSync(`${dir}/state`); stateCreated = true; for (const e of Deno.readDirSync(`${dir}/state`)) marked.push(e.name); } catch { /* none */ }
    return { stateCreated, code: r.code, out: dec.decode(r.stdout), err: dec.decode(r.stderr), rolled, marked: marked.sort() };
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
