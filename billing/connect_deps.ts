// What `connect stripe` and `release` touch on the machine (connect.ts's Deps): the app's files,
// pronto-billing's installer, its sayt verbs, and Secret Manager (or a file, for a trial) holding the
// author's secret, which is never printed.
import { basename, join } from "jsr:@std/path@1.1.2";
import { appSaytw, cmd } from "../intents/shell.ts";
import type { Deps } from "./connect.ts";

const here = new URL(".", import.meta.url).pathname;

// Secrets in a file of their own, never committed: a trial's, on a developer's machine.
function fileSecrets(path: string): Deps["secrets"] {
  const all = async () => JSON.parse(await Deno.readTextFile(path).catch(() => "{}")) as Record<string, string>;
  return {
    get: async (name) => (await all())[name] ?? null,
    put: async (name, value) => await Deno.writeTextFile(path, JSON.stringify({ ...(await all()), [name]: value }), { mode: 0o600 }),
  };
}

// Secret Manager over its API, as the machine's own service account (Studio's builder, on Cloud
// Run, which has no gcloud) or else the operator's gcloud login.
async function token(): Promise<string> {
  const meta = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", { headers: { "Metadata-Flavor": "Google" }, signal: AbortSignal.timeout(1000) }).catch(() => null);
  if (meta?.ok) return (await meta.json()).access_token;
  await meta?.body?.cancel();
  const r = await cmd("gcloud", ["auth", "print-access-token"]);
  if (!r.ok) throw new Error(`no Google login to reach Secret Manager with: ${r.err.trim()}`);
  return r.out.trim();
}

function secretManager(project: string): Deps["secrets"] {
  const api = `https://secretmanager.googleapis.com/v1/projects/${project}/secrets`;
  const call = async (path: string, body?: unknown) =>
    await fetch(`${api}${path}`, { method: body ? "POST" : "GET", headers: { authorization: `Bearer ${await token()}`, "content-type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
  const why = async (res: Response) => `${res.status} ${(await res.text()).slice(0, 200)}`;
  return {
    get: async (name) => {
      const res = await call(`/${name}/versions/latest:access`);
      if (res.status === 404) return (await res.body?.cancel(), null);
      if (!res.ok) throw new Error(`Secret Manager ${name}: ${await why(res)}`);
      const { payload } = await res.json();
      return new TextDecoder().decode(Uint8Array.from(atob(payload.data), (c) => c.charCodeAt(0)));
    },
    put: async (name, value) => {
      const made = await call(`?secretId=${name}`, { replication: { automatic: {} } });
      if (!made.ok && made.status !== 409) throw new Error(`Secret Manager ${name}: ${await why(made)}`);
      await made.body?.cancel();
      const data = btoa(String.fromCharCode(...new TextEncoder().encode(value)));
      const added = await call(`/${name}:addVersion`, { payload: { data } });
      if (!added.ok) throw new Error(`Secret Manager ${name}: ${await why(added)}`);
      await added.body?.cancel();
    },
  };
}

// Neither a project nor a file named: the secret has nowhere to be kept, and there is no default.
function unnamedSecrets(): Deps["secrets"] {
  const none = () => Promise.reject(new Error("say where the author's payout secret is kept: --project <your Google Cloud project> (Secret Manager), billingSecretsProject: \"<project>\" in the app's release.cue, or --secrets-file <path>"));
  return { get: none, put: none };
}

export function stripeDeps(dir: string, o: { project?: string; secretsFile?: string }): Deps {
  return {
    dir,
    app: basename(dir),
    read: (p) => Deno.readTextFile(p).catch(() => null),
    write: (p, t) => Deno.writeTextFile(p, t),
    cues: async () => {
      const out: string[] = [];
      for await (const e of Deno.readDir(dir)) if (e.isFile && e.name.endsWith(".cue")) out.push(await Deno.readTextFile(join(dir, e.name)));
      return out;
    },
    install: async () => {
      const r = await cmd(Deno.execPath(), ["run", "--no-config", "--allow-read", "--allow-write", join(here, "install.ts"), dir]);
      if (!r.ok) throw new Error(`install.ts: ${r.err.trim()}`);
    },
    saytw: (verb) => appSaytw(dir, verb),
    secrets: o.secretsFile ? fileSecrets(o.secretsFile) : o.project ? secretManager(o.project) : unnamedSecrets(),
    fetch,
  };
}
