// A repository's dev flow: its devflow/devflow.cue read with this plugin's schema, and the board's
// token. Absent (a repository with no dev flow), devflowOf says null and every hook does nothing.
import { cmd } from "../intents/shell.ts";
import { Plane } from "./plane.ts";

// The schema and Plane's manifests, read beside this file: on disk from a checkout, or fetched when
// a hook runs from its raw GitHub address (release-cron's copy in an app runs it so).
let schemaDir: string | null = null;
async function schema(): Promise<string> {
  if (schemaDir) return schemaDir;
  const here = new URL(".", import.meta.url);
  if (here.protocol === "file:") return (schemaDir = here.pathname);
  const dir = await Deno.makeTempDir({ prefix: "devflow-" });
  for (const f of ["schema.cue", "plane.cue"]) {
    const r = await fetch(new URL(f, here));
    if (!r.ok) throw new Error(`devflow: ${f}: ${r.status}`);
    await Deno.writeTextFile(`${dir}/${f}`, await r.text());
  }
  return (schemaDir = `${dir}/`);
}

export interface DevFlow {
  plane: { host: string; workspace: string; project: { name: string; identifier: string }; chart: string };
  /** Absent in a repository that only reports to a board set up from another (schema.cue). */
  cluster?: { context: string; ssh: string; namespace: string; tunnel: string; apiPort: number };
  token: { project: string; secret: string };
  team: { engineers: number; sre: number; product: number };
  infra: string[];
  sprint: { timeZone: string; perPerson: number };
  chore: string;
  states: { name: string; group: string; color: string; means: string }[];
  priorities: Record<string, { plane: string; does: string }>;
}

/** The CUE this plugin evaluates with: $CUE, else cue on PATH. */
export const cueBin = () => Deno.env.get("CUE") ?? "cue";

/** An expression of the repository's flow, with the plugin's schema and Plane's manifests. */
export async function exportFlow<T>(repo: string, expr: string): Promise<T> {
  const here = await schema();
  const r = await cmd(cueBin(), ["export", `${here}schema.cue`, `${here}plane.cue`, `${repo}/devflow/devflow.cue`, "-e", expr, "--out", "json"]);
  if (!r.ok) throw new Error(`cue export ${expr}: ${r.err.trim()}`);
  return JSON.parse(r.out) as T;
}

/** The repository's flow, or null when it has none. */
export async function devflowOf(repo: string): Promise<DevFlow | null> {
  try {
    Deno.statSync(`${repo}/devflow/devflow.cue`);
  } catch {
    return null;
  }
  return await exportFlow<DevFlow>(repo, "devFlow");
}

/** The board's token: PLANE_TOKEN, else Secret Manager with the reader's own gcloud; null when
 * neither has one. */
export async function tokenOf(flow: DevFlow): Promise<string | null> {
  const env = Deno.env.get("PLANE_TOKEN");
  if (env) return env.trim();
  const r = await cmd("gcloud", ["secrets", "versions", "access", "latest", `--secret=${flow.token.secret}`, `--project=${flow.token.project}`]).catch(() => ({ ok: false, out: "" }));
  return r.ok && r.out.trim() ? r.out.trim() : null;
}

/** The board, signed in, and the project's id; null when there is no token yet. */
export async function boardOf(flow: DevFlow): Promise<{ plane: Plane; project: string } | null> {
  const token = await tokenOf(flow);
  if (!token) return null;
  const plane = new Plane(`https://${flow.plane.host}`, flow.plane.workspace, token);
  const p = (await plane.projects()).find((x) => x.identifier === flow.plane.project.identifier);
  if (!p) throw new Error(`no project ${flow.plane.project.identifier} in ${flow.plane.workspace}: run bin/pronto connect plane`);
  return { plane, project: p.id };
}
