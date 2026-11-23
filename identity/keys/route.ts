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
// On k8s the upstream is the door's Dapr sidecar, which routes by `dapr-app-id`: each of the three sets it with `header_up`,
// which replaces a client's own value, so a client cannot steer the guard or the keys paths to another app.
export const BLOCK = [
  "  @keysauth path /auth/*",
  `  forward_auth @keysauth ${UPSTREAM} {`,
  "    uri /auth/keyguard",
  "    header_up dapr-app-id keys",
  "    import bounded-auth",
  "  }",
  "  handle /auth/keys* {",
  `    reverse_proxy ${UPSTREAM} {`,
  "      header_up dapr-app-id keys",
  "      import bounded-auth",
  "    }",
  "  }",
  "  handle /auth/key {",
  `    reverse_proxy ${UPSTREAM} {`,
  "      header_up dapr-app-id keys",
  "      import bounded-auth",
  "    }",
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
  // The first handle may be another host's own (doorguard's `handle @daprapi`), inside its begin and end markers: the
  // block goes after its end, so that host's next run does not take it out.
  const open = lines.slice(0, at).findLastIndex((l) => /^\s*# [a-z-]+:begin\b/.test(l));
  const inside = open >= 0 && !lines.slice(open, at).some((l) => /^\s*# [a-z-]+:end$/.test(l));
  const close = inside ? lines.findIndex((l, i) => i >= at && /^\s*# [a-z-]+:end$/.test(l)) : -1;
  let start = close >= 0 ? close + 1 : at;
  if (close < 0) while (start > 0 && /^\s*#/.test(lines[start - 1]) && !lines[start - 1].endsWith(":end")) start--;
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
