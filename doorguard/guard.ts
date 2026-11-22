// The door's Dapr guard (PRONTO-1307): no public prefix reaches a Dapr API path of its sidecar.
//   guard.ts [route] <app-dir>
// Splices a marked block into the app's docker/Caddyfile, before the first top-level `handle` of
// the site, an earlier copy of it taken out first (idempotent). Throws where there is no anchor.
// bin/pronto-doorguard copies this file into the app, where its generate step runs it.
export const BEGIN = "  # doorguard:begin — no public prefix reaches a Dapr API path of its sidecar (PRONTO-1307)";
export const END = "  # doorguard:end";
/** What the engine looks for in a Caddyfile before it builds the door's image. */
export const MARKER = "# PRONTO-1307: no public prefix reaches a Dapr API path of its sidecar";

// Caddy matches path_regexp on the decoded path, so `/img%2Fv1.0/...` is `/img/v1.0/...` here.
export const BLOCK = [
  `  ${MARKER}`,
  "  @daprapi path_regexp daprapi ^/(crud|img|blobs|electric)/v1\\.0(-alpha1)?(/|$)",
  "  handle @daprapi {",
  "    respond 404",
  "  }",
];

/** The Caddyfile with the guard before its first top-level `handle`, and the comments that
 * belong to it; an earlier guard is taken out first. */
export function guarded(caddyfile: string): string {
  let lines = caddyfile.split("\n");
  const from = lines.indexOf(BEGIN), to = lines.indexOf(END);
  if (from >= 0 && to > from) lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
  const at = lines.findIndex((l) => /^\s*handle (\/|@)/.test(l));
  if (at < 0) throw new Error("doorguard: docker/Caddyfile has no top-level `handle /…` or `handle @…` to place the Dapr guard before");
  let start = at;
  while (start > 0 && /^\s*#/.test(lines[start - 1]) && !lines[start - 1].endsWith(":end")) start--;
  return [...lines.slice(0, start), BEGIN, ...BLOCK, END, ...lines.slice(start)].join("\n");
}

/** Whether a Caddyfile carries the guard. */
export const has = (caddyfile: string) => caddyfile.includes(MARKER);

/** Puts the guard into the app's docker/Caddyfile, written only when its text changes. */
export async function route(app: string) {
  const path = `${app}/docker/Caddyfile`;
  const held = await Deno.readTextFile(path);
  const text = guarded(held);
  if (text !== held) await Deno.writeTextFile(path, text);
}

if (import.meta.main) {
  const args = Deno.args.filter((a) => a !== "route");
  if (args.length !== 1) throw new Error("usage: guard.ts [route] <app-dir>");
  await route(args[0].replace(/\/$/, ""));
}
