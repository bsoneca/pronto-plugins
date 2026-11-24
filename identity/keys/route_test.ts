// The keys routes in the door's Caddyfile, and the installer that gives an app the service.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { BEGIN, END, ROUTES, ROUTES_BEGIN, ROUTES_END, route, routed } from "./route.ts";

const caddy = `(app) {
  encode zstd gzip
  # doorguard:begin — x
  @daprapi path_regexp daprapi ^/crud
  # doorguard:end
  # Chromium probes /favicon.ico.
  handle /favicon.ico {
    respond 204
  }
  handle /auth/* {
    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}
  }
}
`;

Deno.test("the block is the first lines of the app's own handle /auth/*, and the app's reverse_proxy to auth answers the rest", () => {
  const out = routed(caddy).split("\n");
  const at = out.indexOf("  handle /auth/* {");
  assertEquals(out[at + 1], ROUTES_BEGIN);
  assertEquals(out.slice(at + 2, at + 2 + ROUTES.length), ROUTES);
  assertEquals(out[at + 2 + ROUTES.length], ROUTES_END);
  assertEquals(out[at + 3 + ROUTES.length], "    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}");
  // Nothing else is added: the other handles and the comments are where they were.
  assertEquals(out.filter((_, i) => i <= at || i > at + 2 + ROUTES.length), caddy.split("\n"));
});

Deno.test("it guards /auth/* with forward_auth inside that handle, ahead of the keys paths, and has no handle of its own beside the app's", () => {
  const text = ROUTES.join("\n");
  const via = "header_up dapr-app-id keys";
  assert(text.startsWith(`    forward_auth {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n      uri /auth/keyguard\n      ${via}\n      import bounded-auth\n    }\n`), text);
  assert(text.includes(`    @keysroutes path /auth/keys* /auth/key\n    handle @keysroutes {\n      reverse_proxy {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n        ${via}\n        import bounded-auth\n      }\n    }`));
  assert(text.indexOf("forward_auth") < text.indexOf("handle @keysroutes"));
  // A matcher on forward_auth, or a handle at the door's top level, is sorted in with the app's own and reorders them.
  assert(!ROUTES.some((l) => /^ {0,3}(forward_auth|handle|@)/.test(l)), text);
});

Deno.test("both set the Dapr app id with header_up, which replaces a client's own, and none passes it through", () => {
  const lines = ROUTES.filter((l) => l.includes("dapr-app-id"));
  assertEquals(lines.map((l) => l.trim()), Array(2).fill("header_up dapr-app-id keys"));
  assertEquals(ROUTES.filter((l) => l.includes("import bounded-auth")).length, 2);
  // `header_up +` adds beside a client's value and `-` deletes: only the bare form replaces it.
  assert(!ROUTES.some((l) => /header_up\s+[+\-?]/.test(l)));
  assert(!ROUTES.some((l) => /copy_headers|header_down|trusted_proxies/.test(l)));
});

Deno.test("it is idempotent, and replaces an earlier block, the first version's top-level guard too", () => {
  assertEquals(routed(routed(caddy)), routed(caddy));
  const first = caddy.replace("  # Chromium", [BEGIN, "  @keysauth path /auth/*", "  forward_auth @keysauth keys:8702 {", "  }", END, "  # Chromium"].join("\n"));
  assertEquals(routed(first), routed(caddy));
  // What the second version (#523) wrote: its own marker and nested handle, and the guard at the top level.
  const second = caddy.replace("  # Chromium", [BEGIN, "  @keysauth path /auth/*", "  forward_auth @keysauth {$PRONTO_UPSTREAM_KEYS:keys:8702} {", "    uri /auth/keyguard", "  }", END, "  # Chromium"].join("\n")).replace("  handle /auth/* {\n", [
    "  handle /auth/* {", "    # keys-routes:begin — /auth/keys* and /auth/key, ahead of the auth service (PRONTO-740)", "    @keysroutes path /auth/keys* /auth/key",
    "    handle @keysroutes {", "      reverse_proxy {$PRONTO_UPSTREAM_KEYS:keys:8702} {", "        header_up dapr-app-id keys", "        import bounded-auth", "      }", "    }", "    # keys-routes:end", "",
  ].join("\n"));
  assertEquals(routed(second), routed(caddy));
  const older = routed(caddy).replace(ROUTES_BEGIN, `${ROUTES_BEGIN}\n    # an older routes block`);
  assertEquals(routed(older), routed(caddy));
});

Deno.test("a Caddyfile with no top-level handle /auth/* throws", () => {
  assertThrows(() => routed(caddy.replace("handle /auth/*", "handle /other/*")), Error, "handle /auth/*");
});

Deno.test("route writes the file once", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.mkdir(`${dir}/docker`);
    await Deno.writeTextFile(`${dir}/docker/Caddyfile`, caddy);
    await route(dir);
    const once = await Deno.readTextFile(`${dir}/docker/Caddyfile`);
    assertEquals(once, routed(caddy));
    await route(dir);
    assertEquals(await Deno.readTextFile(`${dir}/docker/Caddyfile`), once);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

const install = async (app: string) => {
  const out = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, app] }).output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
};

Deno.test("an app gets the target, the door's env, the generate step and the service, regenerated each time", async () => {
  const app = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
    await install(app);
    const plugin = await Deno.readTextFile(`${app}/keys_plugin.cue`);
    assertEquals(plugin.split("\n")[1], "package shop");
    assert(!plugin.includes("__PACKAGE__"));
    assert(plugin.includes('keysDb: *"shop" | string'));
    assert(plugin.includes('PRONTO_UPSTREAM_KEYS: {peer: "keys", port: "http"}'));
    assert(plugin.includes('expose: http: {port: 8702, env: "KEYS_PORT"}'));
    assert(plugin.includes('AUTH_API_KEYS:    "true"'));
    assert(plugin.includes("if keysGate != \"\" {AUTH_API_KEYS_GATE: keysGate}"));
    assert(plugin.includes("if keysHook != \"\" {AUTH_KEY_EXCHANGED_HOOK: keysHook}"));
    const step = await Deno.readTextFile(`${app}/pronto/keys.cue`);
    assertEquals(step.split("\n")[1], "package prontoproject");
    assert(step.includes('"keys-route": {"priority":6') && step.includes("keys/route.ts route ."));
    for (const f of ["keys/keys.ts", "keys/main.ts", "keys/route.ts", "keys/vendor/postgres.js"]) assert((await Deno.stat(`${app}/${f}`)).size > 0, f);
    assert((await Deno.readTextFile(`${app}/keys/main.ts`)).includes('import("./vendor/postgres.js")'));
    await Deno.writeTextFile(`${app}/keys_plugin.cue`, "edited\n");
    await install(app);
    assertEquals(await Deno.readTextFile(`${app}/keys_plugin.cue`), plugin);
  } finally {
    await Deno.remove(app, { recursive: true });
  }
});

Deno.test("an app whose program names no package is refused", async () => {
  const app = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${app}/program.cue`, "// nothing\n");
    let refused = false;
    try {
      await install(app);
    } catch {
      refused = true;
    }
    assert(refused);
  } finally {
    await Deno.remove(app, { recursive: true });
  }
});

// Bonk Chess's door (apps/brawl-chess/docker/Caddyfile), cut down to the handles that Caddy 2.11.7 reorders when a route
// is added to them, imported into the three site blocks it has: the unnamed one, `localhost` and `caddy`. A
// `forward_auth @matcher` at the door's top level and two top-level path handles each moved /health, /img/* and /auth/*
// ahead of the others in some of the blocks, and in the full door rmloc ahead of /manifest.* and rmen/rmloc ahead of
// rmtoday: /armies in es came back English, /puzzle/today and /pt-br/puzzle/today 404.
const door = `(bounded-auth) {
  transport http {
    dial_timeout 2s
  }
}
(app) {
  handle /signal/* {
    respond 200
  }
  handle /electric/* {
    respond 200
  }
  handle /telemetry {
    respond 200
  }
  handle /perf {
    respond 200
  }
  handle /a/s.js {
    respond 200
  }
  handle /a/e {
    respond 200
  }
  handle /.well-known/pronto-billing.json {
    respond 200
  }
  handle /billing/* {
    respond 200
  }
  handle /e/api/* {
    respond 200
  }
  handle /api/v1/* {
    respond 200
  }
  handle /ofrep/* {
    respond 200
  }
  handle /ads.txt {
    respond 200
  }
  handle /notify/drain {
    respond 200
  }
  handle /pace/* {
    respond 200
  }
  @rmes {
    path_regexp rmes ^/(armies|rules)/?$
    header_regexp lang Accept-Language (?i)^\\s*es\\b
  }
  handle @rmes {
    respond 200
  }
  @rmptbr {
    path_regexp rmptbr ^/(armies|rules)/?$
    header_regexp lang Accept-Language (?i)^\\s*pt\\b
  }
  handle @rmptbr {
    respond 200
  }
  @readingMoreEn path_regexp rmen ^/(armies|rules)/?$
  handle @readingMoreEn {
    respond 200
  }
  @readingMoreLoc path_regexp rmloc ^/(es|pt-br)/(armies|rules)/?$
  handle @readingMoreLoc {
    respond 200
  }
  handle /reading-more-sitemap.xml {
    respond 200
  }
  handle /auth/* {
    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}
  }
  handle /img/* {
    respond 200
  }
  handle /health {
    respond 200
  }
  handle /.well-known/* {
    respond 200
  }
  handle /omnishell/* {
    respond 200
  }
}
:8080 {
  import app
}
https://localhost:8443 {
  tls internal
  import app
}
https://caddy:8443 {
  tls internal
  import app
}
`;

/** The matchers of every route Caddy runs, in order and nested as it nests them, for each server its site blocks make:
 * the keys block's own routes (inside the app's /auth/* route) are not walked into. */
// deno-lint-ignore no-explicit-any
const sequence = (routes: any[], depth = 0): string[] => (routes ?? []).flatMap((r: any) => {
  const own = " ".repeat(depth) + JSON.stringify(r.match ?? []);
  if (JSON.stringify(r.match) === '[{"path":["/auth/*"]}]') return [own];
  // deno-lint-ignore no-explicit-any
  return [own, ...(r.handle ?? []).flatMap((h: any) => h.routes ? sequence(h.routes, depth + 1) : [])];
});

async function order(caddy: string, text: string): Promise<string[][]> {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/Caddyfile`, text);
    const env = { PRONTO_UPSTREAM_KEYS: "keys:8702", PRONTO_UPSTREAM_AUTH: "auth:9999" };
    const out = await new Deno.Command(caddy, { args: ["adapt", "--config", `${dir}/Caddyfile`, "--adapter", "caddyfile"], env, stderr: "null" }).output();
    assert(out.success, `caddy adapt failed on:\n${text}`);
    // deno-lint-ignore no-explicit-any
    const servers = Object.values<any>(JSON.parse(new TextDecoder().decode(out.stdout)).apps.http.servers);
    return servers.map((s) => sequence(s.routes));
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

const caddyBin = Deno.env.get("CADDY");
Deno.test({
  name: "adding the keys routes leaves the sequence of the door's routes as Caddy ran it, in every site block",
  ignore: !caddyBin,
  async fn() {
    const without = await order(caddyBin!, door);
    assertEquals(without.length, 2, "the unnamed site and the two https ones make two servers");
    assert(without.every((s) => s.some((l) => l.includes('"/health"'))));
    assertEquals(await order(caddyBin!, routed(door)), without);
  },
});
