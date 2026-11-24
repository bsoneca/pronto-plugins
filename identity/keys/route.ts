// The door's routes to the keys service (PRONTO-740): one block spliced into the app's docker/Caddyfile, the first
// lines of its top-level `handle /auth/*`, an earlier copy taken out first (idempotent).
//   route.ts [route] <app-dir>
// bin/pronto-keys copies this file into the app, where its generate step runs it after pronto's writer.
// The marker text is #523's, unchanged: an app generated with that version has its block taken out by it.
export const ROUTES_BEGIN = "    # keys-routes:begin — /auth/keys* and /auth/key, ahead of the auth service (PRONTO-740)";
export const ROUTES_END = "    # keys-routes:end";
// The first version put the guard before the app's first top-level `handle`; it is taken out where an app still has it.
export const BEGIN = "  # keys:begin — API keys and the door's session check, on the keys service (PRONTO-740)";
export const END = "  # keys:end";
export const UPSTREAM = "{$PRONTO_UPSTREAM_KEYS:keys:8702}";

// Everything stays inside the app's own `handle /auth/*`, never beside its top-level handles: Caddy sorts those with a
// path matcher (its comparison is not transitive) and sorts a `forward_auth @matcher` route in with them, so one more
// of either reorders the app's other handles, per site block, and the reading-more ones that run in source order (a
// regexp matcher each) answer in another order (Bonk Chess: /armies in es came back English, /puzzle/today 404).
// forward_auth runs before the `handle`s nested here and before the handle's own `reverse_proxy` (directive order), so
// the guard covers each `/auth/*` path the handle takes: 0.32's auth accepts a key's token as a session, and its rename
// answers a session with no `kid`, so a key could make keys of its own that outlive it. It answers 403 for a key's
// token and 204 for anything else. A path the nested handle does not match falls through to the auth service.
// On k8s the upstream is the door's Dapr sidecar, which routes by `dapr-app-id`: both set it with `header_up`, which
// replaces a client's own value, so a client cannot steer the guard or the keys paths to another app.
export const ROUTES = [
  `    forward_auth ${UPSTREAM} {`,
  "      uri /auth/keyguard",
  "      header_up dapr-app-id keys",
  "      import bounded-auth",
  "    }",
  "    @keysroutes path /auth/keys* /auth/key",
  "    handle @keysroutes {",
  `      reverse_proxy ${UPSTREAM} {`,
  "        header_up dapr-app-id keys",
  "        import bounded-auth",
  "      }",
  "    }",
];

/** The Caddyfile with the keys block as the first lines of its `handle /auth/*`; an earlier copy is taken out first. */
export function routed(caddyfile: string): string {
  let lines = caddyfile.split("\n");
  for (const [begin, end] of [[BEGIN, END], [ROUTES_BEGIN, ROUTES_END]]) {
    const from = lines.indexOf(begin), to = lines.indexOf(end);
    if (from >= 0 && to > from) lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
  }
  const auth = lines.findIndex((l) => /^ {2}handle \/auth\/\* \{$/.test(l));
  if (auth < 0) throw new Error("keys: docker/Caddyfile has no top-level `handle /auth/* {` to place the keys routes in");
  return [...lines.slice(0, auth + 1), ROUTES_BEGIN, ...ROUTES, ROUTES_END, ...lines.slice(auth + 1)].join("\n");
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
