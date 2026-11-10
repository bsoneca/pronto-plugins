// `connect plane` (docs/intents.md): the repository's board, from nothing to a board ready for its first sprint, each step
// checked and applied in order, stopping only where a person must act. With a cluster (devFlow.cluster)
// the intent installs Plane on the repository's node beside its apps: a CloudNativePG database, the
// node's gateway, the tunnel's hostname. With none, the board is one that exists (a hosted Plane, or
// one installed another way): the intent installs nothing and checks only that its host answers and
// the token signs in. Then the board itself, set up from devFlow: the project, the flow's states, a
// module per app, the chore label and GitHub's token (the first sprint is planning's, pronto-devflow next).
// The install steps are Plane's own; the rest goes through the Board interface (board/board.ts).
import { cmd } from "../intents/shell.ts";
import type { Step } from "../intents/run.ts";
import type { Board } from "./board/board.ts";
import { adapterOf, type DevFlow, exportFlow, tokenOf } from "./spec.ts";

const ok = (note = "") => ({ done: true as const, note });
const todo = (why: string) => ({ todo: why });
const gate = (why: string) => ({ gate: why });

async function must(c: string, args: string[], opts: { stdin?: string; cwd?: string } = {}) {
  const r = await cmd(c, args, opts);
  if (!r.ok) throw new Error(`${c} ${args.slice(0, 3).join(" ")}: ${(r.err || r.out).trim().split("\n").slice(-3).join(" ")}`);
  return r.out;
}

// A SOPS file's Secret, decrypted in memory: sops from PATH, else the one sayt keeps; the age key
// from SOPS_AGE_KEY, else (on a Mac) the Keychain item pronto-sops-age, as pronto's tools/secrets do.
async function sopsSecret(file: string): Promise<Record<string, string>> {
  const home = Deno.env.get("HOME") ?? "";
  const kept = [...(function* () {
    try {
      for (const e of Deno.readDirSync(`${home}/.cache/sayt/k8s/operators`)) if (e.name.startsWith("sops-")) yield `${home}/.cache/sayt/k8s/operators/${e.name}`;
    } catch { /* none kept */ }
  })()].sort();
  const bin = (await cmd("sh", ["-c", "command -v sops"])).out.trim() || kept.at(-1);
  if (!bin) throw new Error("no sops on PATH, nor one sayt keeps");
  const key = Deno.env.get("SOPS_AGE_KEY") ?? (await cmd("security", ["find-generic-password", "-s", "pronto-sops-age", "-w"])).out.trim();
  const r = await cmd(bin, ["-d", "--output-type", "json", file], { env: { ...Deno.env.toObject(), SOPS_AGE_KEY: key } });
  if (!r.ok) throw new Error(`sops -d ${file}: ${r.err.trim().split("\n").at(-1)}`);
  const s = JSON.parse(r.out);
  return { ...Object.fromEntries(Object.entries(s.data ?? {}).map(([k, v]) => [k, atob(String(v))])), ...(s.stringData ?? {}) };
}

// The Django program that holds Plane's instance configuration to `want` (key to value): it says
// which keys differ, and with `apply` writes them (encrypted where Plane keeps them encrypted).
// Run by `manage.py shell` with the values on its stdin, never in an argument.
const planeConfig = (want: Record<string, string>, apply: boolean) => `
import json
from plane.license.models import InstanceConfiguration
from plane.license.utils.encryption import encrypt_data, decrypt_data
from plane.utils.instance_config_variables import instance_config_variables
encrypted = {v["key"]: v.get("is_encrypted", False) for v in instance_config_variables}
want = json.loads(${JSON.stringify(JSON.stringify(want))})
differs = []
for key, value in want.items():
    row = InstanceConfiguration.objects.filter(key=key).first()
    now = None if row is None else (decrypt_data(row.value) if row.is_encrypted and row.value else row.value)
    if now == value:
        continue
    differs.append(key)
    if ${apply ? "True" : "False"}:
        row = row or InstanceConfiguration(key=key, category=key.split("_")[0])
        row.is_encrypted = encrypted.get(key, False)
        row.value = encrypt_data(value) if row.is_encrypted else value
        row.save()
print(json.dumps({"differs": differs}))
`;

const random = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");

export function steps(repo: string, flow: DevFlow): Step[] {
  const { cluster, board } = flow;
  const origin = `https://${board.host}`;
  const instance = async () => {
    const r = await fetch(`${origin}/api/instances/`).catch(() => null);
    if (!r?.ok) return null;
    return (await r.json().catch(() => null)) as { instance?: { is_setup_done?: boolean } } | null;
  };
  let client: Board | null = null;
  const signedIn = async () => {
    if (client) return client;
    const t = await tokenOf(flow);
    if (!t) return null;
    return (client = adapterOf(flow, t));
  };
  // A step past the token's: says what it waits on instead of failing on a missing board.
  const need = async () => {
    const p = await signedIn();
    if (!p) throw new Error("waits on the board's token (the step above)");
    return p;
  };
  const project = async (p: Board) => (await p.projects()).find((x) => x.identifier === board.project.identifier);
  // A module per app, and the infra modules an SRE builds (devFlow.infra).
  const apps = () => [...[...Deno.readDirSync(`${repo}/apps`)].filter((e) => e.isDirectory && !e.name.startsWith(".")).map((e) => e.name).sort(), ...flow.infra];

  // Plane on the node: only when the repository names a cluster.
  const install = (cluster: NonNullable<DevFlow["cluster"]>): Step[] => {
    const ns = cluster.namespace;
    const kc = (...a: string[]) => ["--context", cluster.context, ...a];
    const k = (...a: string[]) => cmd("kubectl", kc(...a));
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
          const route = await k("-n", ns, "get", "httproute", "plane-route", "-o", "jsonpath={.spec.rules[*].filters}");
          // The route as plane.cue has it now: telling Plane each request was https.
          return db.ok && route.ok && route.out.includes("X-Forwarded-Proto") ? ok() : todo("apply them");
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
        check: async () => (await instance())?.instance?.is_setup_done ? ok() : gate(`create Plane's admin (yourself): ${origin}/god-mode/`),
      },
      {
        name: `who gets in (sign-up ${board.access.signup ? "on" : "off"}${board.access.github ? ", GitHub's sign-in" : ""})`,
        ...(() => {
          // What Plane should hold; sign-up is written even while GitHub's App is still to be made.
          const want = async (): Promise<{ w: Record<string, string>; waiting: boolean }> => {
            const w: Record<string, string> = { ENABLE_SIGNUP: board.access.signup ? "1" : "0" };
            if (!board.access.github) return { w, waiting: false };
            const s = await sopsSecret(`${repo}/${board.access.github.secrets}`);
            if (!s.client_id || !s.client_secret || s.client_id === "unset" || s.client_secret === "unset") return { w, waiting: true };
            return { w: { ...w, IS_GITHUB_ENABLED: "1", GITHUB_CLIENT_ID: s.client_id, GITHUB_CLIENT_SECRET: s.client_secret }, waiting: false };
          };
          const shell = async (w: Record<string, string>, apply: boolean) => {
            const r = await must("kubectl", kc("-n", ns, "exec", "-i", "deploy/plane-api-wl", "--", "python", "manage.py", "shell"), { stdin: planeConfig(w, apply) });
            return JSON.parse(r.split("\n").filter((l) => l.startsWith("{")).at(-1) ?? "{}").differs as string[];
          };
          return {
            check: async () => {
              const { w, waiting } = await want();
              const differs = await shell(w, false);
              if (differs.length) return todo(`write ${differs.join(", ")}`);
              return waiting
                ? gate(`put GitHub's OAuth App's client_id and client_secret in ${board.access.github!.secrets} (sops set --value-stdin); make the App with this callback: ${origin}/auth/github/callback/`)
                : ok();
            },
            apply: async () => {
              await shell((await want()).w, true);
              // /api/instances/ answers from a cache for two hours.
              await must("kubectl", kc("-n", ns, "exec", "deploy/plane-api-wl", "--", "python", "manage.py", "clear_cache"));
            },
          };
        })(),
      },
    ];
  };
  // With no cluster the board exists already: its host must answer.
  const answers: Step = {
    name: `${board.host} answers`,
    check: async () => {
      const r = await fetch(origin).catch(() => null);
      return r && r.status < 500 ? ok(origin) : gate(`${origin} does not answer: check the board's host in devflow/devflow.cue`);
    },
  };
  const how = flow.token.kind === "env" ? `set ${flow.token.name} in the environment` : `keep it in Secret Manager: pbpaste | gcloud secrets create ${flow.token.secret} --project ${flow.token.project} --data-file=- (or versions add, to replace one)`;

  return [
    ...(cluster ? install(cluster) : [answers]),
    {
      name: `workspace ${board.workspace} and its API token`,
      check: async () => {
        const p = await signedIn();
        const make = `sign in at ${origin}/, ${cluster ? `create the workspace with the URL ${board.workspace}, then ` : ""}make a token in Profile settings → Personal access tokens and ${how}`;
        if (!p) return gate(make);
        try {
          await p.me();
          await p.projects();
          return ok();
        } catch (e) {
          client = null;
          return gate(`${(e as Error).message.split(":").slice(-1)[0].trim()}: ${make}`);
        }
      },
    },
    {
      name: `project ${board.project.identifier}`,
      check: async () => ((await project((await need()))) ? ok() : todo(`create ${board.project.name}`)),
      apply: async () => {
        const p = (await need());
        const made = await p.createProject(board.project.name, board.project.identifier);
        // Cycles and modules are features a project turns on.
        await p.enableFeatures(made.id);
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
        const backlog = (await p.states(pid)).find((s) => s.name === flow.roles.backlog);
        if (backlog) await p.setDefaultState(pid, backlog.id);
      },
    },
    {
      name: "a module per app, and infra",
      check: async () => {
        const p = (await need());
        const have = new Set((await p.modules((await project(p))!.id)).map((m) => m.name));
        const missing = apps().filter((a) => !have.has(a));
        return missing.length ? todo(missing.join(", ")) : ok(`${apps().length - flow.infra.length} apps, ${flow.infra.join(", ")}`);
      },
      apply: async () => {
        const p = (await need());
        const pid = (await project(p))!.id;
        const have = new Set((await p.modules(pid)).map((m) => m.name));
        for (const a of apps().filter((x) => !have.has(x))) await p.createModule(pid, a, flow.infra.includes(a) ? `${a}: an SRE's` : `apps/${a}`);
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
