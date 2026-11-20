// The owner's machine calls, run as a process of their own (a unit run has no --allow-ffi): a root, a sleeper detached by a
// double fork and setsid, and whether the owner's table says the sleeper is the root's. Prints one JSON line.
import { ownSys, planReap } from "../../../harness/files/tests/slot.ts";
const tmp = Deno.args[0];
const sys = ownSys();
const out = { symbols: true, inherited: false, selfNotRoots: false };
const m = `${tmp}/m`;
const script = `perl -MPOSIX -e 'fork and exit; POSIX::setsid(); open F, ">$ENV{M}.tmp"; print F $$; close F; rename "$ENV{M}.tmp", $ENV{M}; exec "/bin/sleep", "300"'; exec /bin/sleep 300`;
const readPid = () => { try { return Number(Deno.readTextFileSync(m)) || 0; } catch { return 0; } };
const me = sys.row(Deno.pid);
let sleeper = 0, rootpid = 0, ended: (() => Promise<void>) | undefined;
try {
  if (sys.os === "darwin") {
    // The responsibility calls: a disclaimed root, and the sleeper has its responsible pid.
    rootpid = sys.spawn(["sh", "-c", script], { ...Deno.env.toObject(), M: m }, undefined, {});
    ended = async () => { Deno.kill(rootpid, "SIGKILL"); await sys.exited(rootpid).catch(() => {}); sys.reap(rootpid); };
  } else {
    // Linux: a subreaper and the run's marker; the sleeper is a member by what the table says of its environ.
    const root = await sys.root(["sh", "-c", script], { ...Deno.env.toObject(), M: m, PRONTO_RUN: `${Deno.pid}-${me.start}` }, undefined);
    rootpid = root.pid;
    ended = async () => { Deno.kill(root.cmd, "SIGKILL"); await root.end(); };
  }
  for (let i = 0; i < 300 && !readPid(); i++) await new Promise((r) => setTimeout(r, 50));
  sleeper = readPid();
  const t = sys.table();
  const ss = t.rows.find((r) => r.pid === sleeper);
  if (t.os === "darwin") {
    out.inherited = t.rows.find((r) => r.pid === rootpid)?.responsible === rootpid && ss?.responsible === rootpid && ss?.ppid === 1;
    out.selfNotRoots = t.rows.find((r) => r.pid === Deno.pid)?.responsible !== rootpid;
  } else {
    const record = { rootpid, rootstart: t.rows.find((r) => r.pid === rootpid)?.start ?? 0, superpid: Deno.pid, superstart: me.start ?? 0, uid: sys.uid, what: "spi", state: "running" as const };
    out.inherited = planReap(t, record, Date.now()).members.some((x) => x.pid === sleeper);
    out.selfNotRoots = !planReap(t, record, Date.now()).members.some((x) => x.pid === Deno.pid);
  }
} finally {
  if (sleeper) try { Deno.kill(sleeper, "SIGKILL"); } catch { /* gone */ }
  await ended?.();
}
console.log(JSON.stringify(out));
