// A repository's dev flow: its devflow/devflow.cue read with this plugin's schema, and the board's
// token. Absent (a repository with no dev flow), devflowOf says null and every hook does nothing.
import { cmd } from "../intents/shell.ts";
import type { Board } from "./board/board.ts";
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

export type Role = "backlog" | "refine" | "ready" | "implementing" | "review" | "merged" | "live" | "done" | "cancelled";

export interface DevFlow {
  board: { kind: "plane" | "github-projects"; host: string; workspace: string; project: { name: string; identifier: string }; chart: string; access: { signup: boolean; github?: { secrets: string } } };
  /** Absent in a repository that only reports to a board set up from another (schema.cue). */
  cluster?: { context: string; ssh: string; namespace: string; tunnel: string; apiPort: number };
  token: { kind: "secret-manager"; project: string; secret: string } | { kind: "env"; name: string };
  team: { engineers: number; sre: number; product: number };
  infra: string[];
  sprint: { timeZone: string; perPerson: number };
  chore: string;
  states: { name: string; group: string; color: string; means: string }[];
  /** The repository's name for the state that plays each role (flow.js reasons in roles). */
  roles: Record<Role, string>;
  /** P0..P3 as the board's priority word, and what each does. */
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

/** The board's token: PLANE_TOKEN wins for every kind; else by the token's kind, Secret Manager
 * with the reader's own gcloud or the environment variable it names; null when none has one. */
export async function tokenOf(flow: DevFlow): Promise<string | null> {
  const env = Deno.env.get("PLANE_TOKEN");
  if (env) return env.trim();
  if (flow.token.kind === "env") return Deno.env.get(flow.token.name)?.trim() || null;
  const r = await cmd("gcloud", ["secrets", "versions", "access", "latest", `--secret=${flow.token.secret}`, `--project=${flow.token.project}`]).catch(() => ({ ok: false, out: "" }));
  return r.ok && r.out.trim() ? r.out.trim() : null;
}

/** The adapter for the flow's board kind, signed in with `token`. */
export function adapterOf(flow: DevFlow, token: string): Board {
  switch (flow.board.kind) {
    case "plane":
      return new Plane(`https://${flow.board.host}`, flow.board.workspace, token);
    default:
      throw new Error(`board kind ${flow.board.kind}: not yet (PRONTO-207)`);
  }
}

/** The board, signed in, and the project's id; null when there is no token yet. */
export async function boardOf(flow: DevFlow): Promise<{ board: Board; project: string } | null> {
  const token = await tokenOf(flow);
  if (!token) return null;
  const board = adapterOf(flow, token);
  const p = (await board.projects()).find((x) => x.identifier === flow.board.project.identifier);
  if (!p) throw new Error(`no project ${flow.board.project.identifier} in ${flow.board.workspace}: run bin/pronto connect plane`);
  return { board, project: p.id };
}
