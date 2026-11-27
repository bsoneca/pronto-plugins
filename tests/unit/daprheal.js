// node/host/dapr-heal.sh run by bash on a stand-in kubectl (tests/unit/daprheal.cue): the pods the node's API says, the
// injector's ready replicas, each ReplicaSet's owner and the rolls made earlier are given; what comes back is the exit code, what
// it said, and the workloads the script asked kubectl to roll. Nothing here touches a cluster.

const here = new URL('.', import.meta.url).pathname;
const script = `${here}../../node/host/dapr-heal.sh`;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');

/**
 * Options: `pods`, [{ns, name, owner, containers, phase = Running, deleting, ageSec = 3600}]; `injector`, the injector's ready
 * replicas as kubectl prints them ("1", "" for none); `rs`, {"ns/replicaset": "Deployment/name"}; `marks`, {"ns.Deployment.name":
 * minutes since it was rolled}; `failRoll`, workloads whose roll fails; `args`; `cooldown`, `grace`.
 */
export const run = ({ pods = [], injector = '1', rs = {}, marks = {}, failRoll = [], args = [], cooldown = 30, grace = 120 } = {}) => {
  const dir = Deno.makeTempDirSync();
  try {
    const now = Date.now();
    const lines = pods.map((p) => [p.ns, p.name, p.phase ?? 'Running', p.deleting ? 'deleting' : '', iso(now - (p.ageSec ?? 3600) * 1000), p.owner ?? '', (p.containers ?? ['app']).map((c) => `${c},`).join('')].join('|'));
    Deno.writeTextFileSync(`${dir}/pods`, lines.map((l) => `${l}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/injector`, injector);
    Deno.writeTextFileSync(`${dir}/fail`, failRoll.map((f) => `${f}\n`).join(''));
    Deno.writeTextFileSync(`${dir}/calls`, '');
    for (const [k, v] of Object.entries(rs)) Deno.writeTextFileSync(`${dir}/rs.${k.replace('/', '.')}`, v);
    Deno.mkdirSync(`${dir}/state`);
    for (const [name, minutes] of Object.entries(marks)) {
      Deno.writeTextFileSync(`${dir}/state/${name}`, '');
      const at = new Date(now - minutes * 60000);
      Deno.utimeSync(`${dir}/state/${name}`, at, at);
    }
    Deno.writeTextFileSync(`${dir}/kubectl`, `#!/bin/bash
d=$(dirname "$0")
echo "$*" >>"$d/calls"
case "$*" in
  *"get pods -A"*) cat "$d/pods" ;;
  *"-n dapr-system get deployment dapr-sidecar-injector"*) printf '%s' "$(cat "$d/injector")" ;;
  *"get replicaset "*) printf '%s' "$(cat "$d/rs.$(echo "$*" | sed -E 's/.*-n ([^ ]+) get replicaset ([^ ]+) .*/\\1.\\2/')" 2>/dev/null)" ;;
  *"rollout restart "*) w=$(echo "$*" | sed -E 's/.*-n ([^ ]+) rollout restart (.*)/\\1\\/\\2/'); if grep -qxF "$w" "$d/fail"; then exit 1; fi; echo "$w" >>"$d/rolled" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
`);
    Deno.chmodSync(`${dir}/kubectl`, 0o755);
    Deno.writeTextFileSync(`${dir}/env`, `KUBECTL='${dir}/kubectl'\nGRACE_SECONDS=${grace}\nCOOLDOWN_MINUTES=${cooldown}\n`);
    const r = new Deno.Command('bash', {
      args: [script, ...args], stdout: 'piped', stderr: 'piped',
      env: { DAPR_HEAL_ENV: `${dir}/env`, DAPR_HEAL_STATE: `${dir}/state`, PATH: '/usr/bin:/bin' },
    }).outputSync();
    const dec = new TextDecoder();
    let rolled = [];
    try { rolled = Deno.readTextFileSync(`${dir}/rolled`).trim().split('\n'); } catch { /* none rolled */ }
    const marked = [];
    for (const e of Deno.readDirSync(`${dir}/state`)) marked.push(e.name);
    return { code: r.code, out: dec.decode(r.stdout), err: dec.decode(r.stderr), rolled, marked: marked.sort() };
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
