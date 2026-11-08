// `connect plane` (docs/intents.md): the repository's board, from nothing to a sprint, each step
// checked and applied in order, stopping only where a person must act. Plane runs on the repository's
// node (devFlow.cluster) beside its apps: a CloudNativePG database, the node's gateway, the tunnel's
// hostname; then the board itself, set up from devFlow: the project, the flow's states, a module per
// app, the chore label, today's sprint, and GitHub's token.
import { cmd } from "../intents/shell.ts";
import type { Step } from "../intents/run.ts";
import { sprintOf } from "./flow.js";
import { Plane } from "./plane.ts";
import { type DevFlow, exportFlow, tokenOf } from "./spec.ts";

const ok = (note = "") => ({ done: true as const, note });
const todo = (why: string) => ({ todo: why });
const gate = (why: string) => ({ gate: why });

async function must(c: string, args: string[], opts: { stdin?: string; cwd?: string } = {}) {
  const r = await cmd(c, args, opts);
  if (!r.ok) throw new Error(`${c} ${args.slice(0, 3).join(" ")}: ${(r.err || r.out).trim().split("\n").slice(-3).join(" ")}`);
  return r.out;
}

const random = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");

export function steps(repo: string, flow: DevFlow, now = new Date()): Step[] {
  const { cluster, plane: board } = flow;
  const ns = cluster.namespace;
  const kc = (...a: string[]) => ["--context", cluster.context, ...a];
  const k = (...a: string[]) => cmd("kubectl", kc(...a));
  const origin = `https://${board.host}`;
  const instance = async () => {
    const r = await fetch(`${origin}/api/instances/`).catch(() => null);
    if (!r?.ok) return null;
    return (await r.json().catch(() => null)) as { instance?: { is_setup_done?: boolean } } | null;
  };
  let client: Plane | null = null;
  const signedIn = async () => {
    if (client) return client;
    const t = await tokenOf(flow);
    if (!t) return null;
    return (client = new Plane(origin, board.workspace, t));
  };
  // A step past the token's: says what it waits on instead of failing on a missing board.
  const need = async () => {
    const p = await signedIn();
    if (!p) throw new Error("waits on the board's token (the step above)");
    return p;
  };
  const project = async (p: Plane) => (await p.projects()).find((x) => x.identifier === board.project.identifier);
  const apps = () => [...Deno.readDirSync(`${repo}/apps`)].filter((e) => e.isDirectory && !e.name.startsWith(".")).map((e) => e.name).sort();

  return [
    {
      name: `the node's API (${cluster.context})`,
      check: async () => ((await k("get", "ns", "default")).ok ? ok() : todo(`tunnel 127.0.0.1:${cluster.apiPort} to ${cluster.ssh}`)),
      apply: async () => {
        await must("ssh", ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-fN", "-L", `${cluster.apiPort}:127.0.0.1:6443`, cluster.ssh]);
        await new Promise((r) => setTimeout(r, 1500));
      },
    },
    {
      name: `namespace ${ns}`,
      check: async () => ((await k("get", "ns", ns)).ok ? ok() : todo(`create ${ns}`)),
      apply: async () => void (await must("kubectl", kc("create", "ns", ns))),
    },
    {
      name: "Plane's secret keys",
      check: async () => ((await k("-n", ns, "get", "secret", "plane-keys")).ok ? ok("kept in the cluster") : todo("make them")),
      apply: async () => void (await must("kubectl", kc("-n", ns, "create", "secret", "generic", "plane-keys", `--from-literal=secret_key=${random()}`, `--from-literal=live_server_secret_key=${random()}`))),
    },
    {
      name: "Plane's database and door (CloudNativePG, the gateway's route)",
      check: async () => {
        const db = await k("-n", ns, "get", "secret", "plane-db-app");
        const route = await k("-n", ns, "get", "httproute", "plane-route");
        return db.ok && route.ok ? ok() : todo("apply them");
      },
      apply: async () => {
        const objects = await exportFlow<unknown[]>(repo, "planeObjects");
        await must("kubectl", kc("apply", "-f", "-"), { stdin: JSON.stringify({ apiVersion: "v1", kind: "List", items: objects }) });
        // CloudNativePG writes plane-db-app once the database is up.
        for (let i = 0; i < 60 && !(await k("-n", ns, "get", "secret", "plane-db-app")).ok; i++) await new Promise((r) => setTimeout(r, 5000));
      },
    },
    {
      name: `Plane (plane-ce ${board.chart})`,
      check: async () => {
        const r = await cmd("helm", ["--kube-context", cluster.context, "-n", ns, "status", "plane", "-o", "json"]);
        if (!r.ok) return todo("install it");
        const s = JSON.parse(r.out);
        const chart = s.chart?.metadata?.version ?? (await cmd("helm", ["--kube-context", cluster.context, "-n", ns, "list", "-o", "json"]).then((l) => JSON.parse(l.out).find((x: { name: string }) => x.name === "plane")?.chart?.replace("plane-ce-", "")));
        return s.info?.status === "deployed" && chart === board.chart ? ok() : todo(`${s.info?.status ?? "not deployed"} ${chart ?? ""}: upgrade to ${board.chart}`);
      },
      apply: async () => {
        const secret = async (name: string, key: string) => atob(await must("kubectl", kc("-n", ns, "get", "secret", name, "-o", `jsonpath={.data.${key}}`)));
        const values = await exportFlow<Record<string, unknown>>(repo, "planeValues");
        const kept = { env: { secret_key: await secret("plane-keys", "secret_key"), live_server_secret_key: await secret("plane-keys", "live_server_secret_key"), pgdb_remote_url: await secret("plane-db-app", "uri") } };
        const dir = await Deno.makeTempDir();
        try {
          await Deno.writeTextFile(`${dir}/values.json`, JSON.stringify(values));
          await Deno.writeTextFile(`${dir}/kept.json`, JSON.stringify(kept), { mode: 0o600 });
          await must("helm", ["--kube-context", cluster.context, "-n", ns, "upgrade", "--install", "plane", "plane-ce", "--repo", "https://helm.plane.so", "--version", board.chart, "-f", `${dir}/values.json`, "-f", `${dir}/kept.json`, "--wait", "--timeout", "20m"]);
        } finally {
          await Deno.remove(dir, { recursive: true });
        }
      },
    },
    {
      name: `${board.host} on the tunnel`,
      // A DNS record is the person's to make, as minesweeper's was (docs/infra-opentofu.md), with
      // cloudflared's own login, until the zone is OpenTofu's.
      check: async () =>
        (await instance()) ? ok(origin) : gate(`point ${board.host} at the tunnel, then run this again: cloudflared tunnel route dns ${cluster.tunnel} ${board.host}`),
    },
    {
      name: "Plane's instance admin",
      check: async () =>
        (await instance())?.instance?.is_setup_done
          ? ok()
          : gate(`create Plane's admin (yourself), then in Authentication turn off sign-ups so only invited people join: ${origin}/god-mode/`),
    },
    {
      name: `workspace ${board.workspace} and its API token`,
      check: async () => {
        const p = await signedIn();
        const how = `sign in at ${origin}/, create the workspace with the URL ${board.workspace}, then make a token in Profile settings → Personal access tokens and keep it: ` +
          `pbpaste | gcloud secrets create ${flow.token.secret} --project ${flow.token.project} --data-file=- (or versions add, to replace one)`;
        if (!p) return gate(how);
        try {
          await p.me();
          await p.projects();
          return ok();
        } catch (e) {
          client = null;
          return gate(`${(e as Error).message.split(":").slice(-1)[0].trim()}: ${how}`);
        }
      },
    },
    {
      name: `project ${board.project.identifier}`,
      check: async () => ((await project((await need()))) ? ok() : todo(`create ${board.project.name}`)),
      apply: async () => {
        const p = (await need());
        const made = await p.createProject(board.project.name, board.project.identifier);
        // Cycles and modules are Plane features a project turns on.
        await p.updateProject(made.id, { cycle_view: true, module_view: true });
      },
    },
    {
      name: "the flow's states",
      check: async () => {
        const p = (await need());
        const have = new Map((await p.states((await project(p))!.id)).map((s) => [s.name, s.group]));
        const missing = flow.states.filter((s) => have.get(s.name) !== s.group).map((s) => s.name);
        return missing.length ? todo(missing.join(", ")) : ok(flow.states.map((s) => s.name).join(" → "));
      },
      apply: async () => {
        const p = (await need());
        const pid = (await project(p))!.id;
        const have = await p.states(pid);
        for (const s of flow.states) {
          const at = have.find((h) => h.name === s.name);
          if (!at) await p.createState(pid, { name: s.name, group: s.group, color: s.color, description: s.means });
          else if (at.group !== s.group) await p.updateState(pid, at.id, { group: s.group, color: s.color });
        }
        const backlog = (await p.states(pid)).find((s) => s.name === "Backlog");
        if (backlog) await p.updateState(pid, backlog.id, { default: true });
      },
    },
    {
      name: "a module per app",
      check: async () => {
        const p = (await need());
        const have = new Set((await p.modules((await project(p))!.id)).map((m) => m.name));
        const missing = apps().filter((a) => !have.has(a));
        return missing.length ? todo(missing.join(", ")) : ok(`${apps().length} apps`);
      },
      apply: async () => {
        const p = (await need());
        const pid = (await project(p))!.id;
        const have = new Set((await p.modules(pid)).map((m) => m.name));
        for (const a of apps().filter((x) => !have.has(x))) await p.createModule(pid, a, `apps/${a}`);
      },
    },
    {
      name: `label ${flow.chore}`,
      check: async () => {
        const p = (await need());
        return (await p.labels((await project(p))!.id)).some((l) => l.name === flow.chore) ? ok() : todo("create it");
      },
      apply: async () => {
        const p = (await need());
        await p.createLabel((await project(p))!.id, flow.chore, "#a3a3a3");
      },
    },
    {
      name: "today's sprint",
      check: async () => {
        const p = (await need());
        const day = sprintOf(now, flow.sprint.ends, flow.sprint.timeZone);
        return (await p.cycles((await project(p))!.id)).some((c) => c.name === day) ? ok(day) : todo(`cycle ${day}`);
      },
      apply: async () => {
        const p = (await need());
        const day = sprintOf(now, flow.sprint.ends, flow.sprint.timeZone);
        await p.createCycle((await project(p))!.id, day, day, day, (await p.me()).id);
      },
    },
    {
      name: "GitHub's token for the board (PLANE_TOKEN)",
      check: async () => {
        const r = await cmd("gh", ["secret", "list", "--json", "name", "-q", ".[].name"], { cwd: repo });
        if (!r.ok) throw new Error(`gh secret list: ${r.err.trim()}`);
        return r.out.split("\n").includes("PLANE_TOKEN") ? ok() : todo("set it from Secret Manager's");
      },
      apply: async () => {
        const t = await tokenOf(flow);
        await must("gh", ["secret", "set", "PLANE_TOKEN"], { cwd: repo, stdin: t! });
      },
    },
  ];
}
