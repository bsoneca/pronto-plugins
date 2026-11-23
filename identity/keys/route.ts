// The door's routes to the keys service (PRONTO-740): a block spliced into the app's docker/Caddyfile,
// before its first top-level `handle`, an earlier copy taken out first (idempotent).
//   route.ts [route] <app-dir>
// bin/pronto-keys copies this file into the app, where its generate step runs it after pronto's writer.
export const BEGIN = "  # keys:begin — API keys and the door's session check, on the keys service (PRONTO-740)";
export const END = "  # keys:end";
export const UPSTREAM = "{$PRONTO_UPSTREAM_KEYS:keys:8702}";

// forward_auth runs before every `handle`, so the guard covers each `/auth/*` path whichever handle takes it: 0.32's
// auth accepts a key's token as a session, and its rename answers a session with no `kid`, so a key could make keys of
// its own that outlive it. The guard answers 403 for a key's token and 204 for anything else.
export const BLOCK = [
  "  @keysauth path /auth/*",
  `  forward_auth @keysauth ${UPSTREAM} {`,
  "    uri /auth/keyguard",
  "  }",
  "  handle /auth/keys* {",
  `    reverse_proxy ${UPSTREAM}`,
  "  }",
  "  handle /auth/key {",
  `    reverse_proxy ${UPSTREAM}`,
  "  }",
];

/** The Caddyfile with the block before its first top-level `handle` and the comments that belong to it; an
 * earlier block is taken out first. Another host's block ends with its `:end` marker, which is no comment of
 * the handle's. */
export function routed(caddyfile: string): string {
  let lines = caddyfile.split("\n");
  const from = lines.indexOf(BEGIN), to = lines.indexOf(END);
  if (from >= 0 && to > from) lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
  const at = lines.findIndex((l) => /^\s*handle (\/|@)/.test(l));
  if (at < 0) throw new Error("keys: docker/Caddyfile has no top-level `handle /…` or `handle @…` to place the keys routes before");
  let start = at;
  while (start > 0 && /^\s*#/.test(lines[start - 1]) && !lines[start - 1].endsWith(":end")) start--;
  return [...lines.slice(0, start), BEGIN, ...BLOCK, END, ...lines.slice(start)].join("\n");
}

/** Puts the block into the app's docker/Caddyfile, written only when its text changes. */
export async function route(app: string) {
  const path = `${app}/docker/Caddyfile`;
  const held = await Deno.readTextFile(path);
  const text = routed(held);
  if (text !== held) await Deno.writeTextFile(path, text);
}

if (import.meta.main) {
  const args = Deno.args.filter((a) => a !== "route");
  if (args.length !== 1) throw new Error("usage: route.ts [route] <app-dir>");
  await route(args[0].replace(/\/$/, ""));
}
