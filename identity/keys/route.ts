// The door's routes to the keys service (PRONTO-740): blocks spliced into the app's docker/Caddyfile, the first
// lines of its top-level `handle /auth/*` and the scope guard, the first directive of each of its `handle /crud/*`,
// `/api/v1/*`, `/blob-claim/*` and `/blobs/*`, an earlier copy of each taken out first (idempotent).
//   route.ts [route] <app-dir>
// bin/pronto-keys copies this file into the app, where its generate step runs it after pronto's writer.
// The marker text is #523's, unchanged: an app generated with that version has its block taken out by it.
export const ROUTES_BEGIN = "    # keys-routes:begin — /auth/keys* and /auth/key, ahead of the auth service (PRONTO-740)";
export const ROUTES_END = "    # keys-routes:end";
// The first version put the guard before the app's first top-level `handle`; it is taken out where an app still has it.
export const BEGIN = "  # keys:begin — API keys and the door's session check, on the keys service (PRONTO-740)";
export const END = "  # keys:end";
export const SCOPE_BEGIN = "    # keys-scope:begin — a key's token is held to its scopes on this path, by the keys service (PRONTO-740)";
export const SCOPE_END = "    # keys-scope:end";
/** The handles that carry the app's data, where a key's token is held to its scopes. */
export const SCOPED = ["/crud/*", "/api/v1/*", "/blob-claim/*", "/blobs/*"];
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

// The scope guard is the same form: a `forward_auth` as the first directive inside the handle, never at the top level
// (see above). forward_auth runs ahead of the handle's `route` and `reverse_proxy`, and after its `uri` and `rewrite`
// (directive order; the guard reads only the method), and a handle runs only after the door's own guard of the Dapr API
// (doorguard's `handle @daprapi`, a handle of its own that Caddy runs first and answers 404), so a path the guard
// shuts never reaches it. forward_auth sends the original method as `X-Forwarded-Method`: the keys service refuses a
// key's token without `read` on a GET, HEAD or OPTIONS and without `write` on any other method, and passes any
// request that is not a key's.
export const SCOPE = [
  `    forward_auth ${UPSTREAM} {`,
  "      uri /auth/keyscope",
  "      header_up dapr-app-id keys",
  "      import bounded-auth",
  "    }",
];

/** The Caddyfile with the keys block as the first lines of its `handle /auth/*` and the scope guard in each of the
 * data handles it has; an earlier copy of either is taken out first. */
export function routed(caddyfile: string): string {
  let lines = caddyfile.split("\n");
  for (const [begin, end] of [[BEGIN, END], [ROUTES_BEGIN, ROUTES_END], [SCOPE_BEGIN, SCOPE_END]]) {
    for (let from = lines.indexOf(begin), to = lines.indexOf(end); from >= 0 && to > from; from = lines.indexOf(begin), to = lines.indexOf(end)) {
      lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
    }
  }
  const auth = lines.findIndex((l) => /^ {2}handle \/auth\/\* \{$/.test(l));
  if (auth < 0) throw new Error("keys: docker/Caddyfile has no top-level `handle /auth/* {` to place the keys routes in");
  lines = [...lines.slice(0, auth + 1), ROUTES_BEGIN, ...ROUTES, ROUTES_END, ...lines.slice(auth + 1)];
  let scoped = 0;
  for (const path of SCOPED) {
    const at = lines.findIndex((l) => l === `  handle ${path} {`);
    if (at < 0) continue;
    lines = [...lines.slice(0, at + 1), SCOPE_BEGIN, ...SCOPE, SCOPE_END, ...lines.slice(at + 1)];
    scoped++;
  }
  if (scoped === 0) throw new Error(`keys: docker/Caddyfile has none of ${SCOPED.map((p) => `\`handle ${p} {\``).join(", ")} to hold a key's scopes in`);
  return lines.join("\n");
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
