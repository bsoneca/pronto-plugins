// The door's Dapr guard (PRONTO-1307): no public prefix reaches a Dapr API path of its sidecar.
//   guard.ts [route] <app-dir>
// Splices a marked block into the app's docker/Caddyfile, before the first top-level `handle` of
// the site, an earlier copy of it taken out first (idempotent). Throws where there is no anchor.
// bin/pronto-doorguard copies this file into the app, where its generate step runs it.
export const BEGIN = "  # doorguard:begin — no public prefix reaches a Dapr API path of its sidecar (PRONTO-1307)";
export const END = "  # doorguard:end";
/** What the engine looks for in a Caddyfile before it builds the door's image. */
export const MARKER = "# PRONTO-1307: no public prefix reaches a Dapr API path of its sidecar";

// Caddy matches path_regexp on the decoded path, so `/img%2Fv1.0/...` is `/img/v1.0/...` here. The regexp is case-INsensitive:
// Go's regexp is case-sensitive, but Caddy's `handle /crud/*` matcher and its strip_prefix ignore case, so `/CRUD/v1.0/metadata`
// missed the guard and reached daprd as `/v1.0/metadata` (PRONTO-916).
export const GUARD = "  @daprapi path_regexp daprapi (?i)^/(crud|img|blobs|electric)/v1\\.0(-alpha1)?(/|$)";
export const BLOCK = [
  `  ${MARKER}`,
  GUARD,
  "  handle @daprapi {",
  "    respond 404",
  "  }",
];

/** The Caddyfile without any earlier guard: the marked block (whatever its content, so a case-sensitive one an adopter carries is
 * replaced, not kept), and a block that has the marker comment but not the begin/end lines (taken out through the `}` that closes its
 * `handle @daprapi`). */
function without(lines: string[]): string[] {
  const from = lines.indexOf(BEGIN), to = lines.indexOf(END);
  if (from >= 0 && to > from) lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
  const m = lines.findIndex((l) => l.trim() === MARKER);
  if (m >= 0) {
    let end = m + 1;
    while (end < lines.length && !/^\s*handle @daprapi \{/.test(lines[end]) && /^\s*(@daprapi |#)/.test(lines[end])) end++;
    if (end < lines.length && /^\s*handle @daprapi \{/.test(lines[end])) {
      while (end < lines.length && lines[end] !== "  }") end++;
      lines = [...lines.slice(0, m), ...lines.slice(end + 1)];
    }
  }
  return lines;
}

/** The Caddyfile with the guard before its first top-level `handle`, and the comments that
 * belong to it; an earlier guard is taken out first. */
export function guarded(caddyfile: string): string {
  const lines = without(caddyfile.split("\n"));
  const at = lines.findIndex((l) => /^\s*handle (\/|@)/.test(l));
  if (at < 0) throw new Error("doorguard: docker/Caddyfile has no top-level `handle /…` or `handle @…` to place the Dapr guard before");
  let start = at;
  while (start > 0 && /^\s*#/.test(lines[start - 1]) && !lines[start - 1].endsWith(":end")) start--;
  return [...lines.slice(0, start), BEGIN, ...BLOCK, END, ...lines.slice(start)].join("\n");
}

/** Whether a Caddyfile carries the guard as it is now written: a case-sensitive guard is a bypass and does not count. */
export const has = (caddyfile: string) => caddyfile.includes(MARKER) && caddyfile.includes(GUARD);

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
