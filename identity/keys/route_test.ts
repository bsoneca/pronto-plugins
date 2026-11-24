// The keys routes in the door's Caddyfile, and the installer that gives an app the service.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { BEGIN, BLOCK, END, ROUTES, ROUTES_BEGIN, ROUTES_END, route, routed } from "./route.ts";

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

Deno.test("the block goes before the first top-level handle and its comment, after another host's block", () => {
  const out = routed(caddy).split("\n");
  const begin = out.indexOf(BEGIN);
  assert(begin > out.indexOf("  # doorguard:end"), out.join("\n"));
  assert(out.indexOf(END) < out.indexOf("  # Chromium probes /favicon.ico."));
  assert(out.indexOf("  handle /favicon.ico {") > out.indexOf(END));
});

// doorguard's block as it writes it: its own `handle @daprapi` is the first handle of the file.
const guarded = caddy.replace("  # doorguard:begin — x\n  @daprapi path_regexp daprapi ^/crud\n  # doorguard:end\n", [
  "  # doorguard:begin — x", "  # PRONTO-1307: the guard", "  @daprapi path_regexp daprapi ^/crud", "  handle @daprapi {", "    respond 404", "  }", "  # doorguard:end", "",
].join("\n"));

Deno.test("the block goes after the end of a host whose own handle is the first, never inside its markers", () => {
  const out = routed(guarded).split("\n");
  assert(out.indexOf(BEGIN) > out.indexOf("  # doorguard:end"), out.join("\n"));
  assert(out.indexOf("  handle @daprapi {") < out.indexOf("  # doorguard:end"));
  assertEquals(routed(routed(guarded)), routed(guarded));
  // That host's own run takes out what is between its markers: none of ours.
  const without = out.slice(0, out.indexOf("  # doorguard:begin — x")).concat(out.slice(out.indexOf("  # doorguard:end") + 1));
  assert(without.includes(BEGIN) && without.includes(ROUTES_BEGIN));
});

Deno.test("it guards every /auth/* path and sends the keys paths to the service from inside the app's /auth/* handle", () => {
  const text = BLOCK.join("\n");
  assert(text.includes("@keysauth path /auth/*"));
  const via = "header_up dapr-app-id keys\n";
  assert(text.includes(`forward_auth @keysauth {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n    uri /auth/keyguard\n    ${via}    import bounded-auth\n  }`));
  assert(!text.includes("handle"), "a top-level handle of its own reorders the app's other handles");
  const keys = ROUTES.join("\n");
  assert(keys.includes("@keysroutes path /auth/keys* /auth/key\n    handle @keysroutes {\n      reverse_proxy {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n        " + via.trim() + "\n        import bounded-auth\n      }\n    }"));
  // The routes are the first lines of the app's own handle, so its reverse_proxy to auth answers what they do not match.
  const out = routed(caddy).split("\n");
  const at = out.indexOf("  handle /auth/* {");
  assertEquals(out[at + 1], ROUTES_BEGIN);
  assertEquals(out.indexOf(ROUTES_END), at + 1 + ROUTES.length + 1);
  assertEquals(out[at + ROUTES.length + 3], "    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}");
  // The guard comes first: forward_auth runs before every handle.
  assert(out.indexOf("  forward_auth @keysauth {$PRONTO_UPSTREAM_KEYS:keys:8702} {") < at);
});

Deno.test("both set the Dapr app id with header_up, which replaces a client's own, and none passes it through", () => {
  const all = [...BLOCK, ...ROUTES];
  const lines = all.filter((l) => l.includes("dapr-app-id"));
  assertEquals(lines.map((l) => l.trim()), Array(2).fill("header_up dapr-app-id keys"));
  assertEquals(all.filter((l) => l.includes("import bounded-auth")).length, 2);
  // `header_up +` adds beside a client's value and `-` deletes: only the bare form replaces it.
  assert(!all.some((l) => /header_up\s+[+\-?]/.test(l)));
  assert(!all.some((l) => /copy_headers|header_down|trusted_proxies/.test(l)));
});

Deno.test("it is idempotent, and replaces an earlier block", () => {
  assertEquals(routed(routed(caddy)), routed(caddy));
  const old = caddy.replace("  # Chromium", [BEGIN, "  # an older block", END, "  # Chromium"].join("\n"));
  const out = routed(old);
  assert(!out.includes("an older block") && out.split("\n").filter((l) => l === BEGIN).length === 1);
  const older = routed(caddy).replace(ROUTES_BEGIN, `${ROUTES_BEGIN}\n    # an older routes block`);
  assertEquals(routed(older), routed(caddy));
});

Deno.test("a Caddyfile with no top-level handle /auth/* throws", () => {
  assertThrows(() => routed(caddy.replace("handle /auth/*", "handle /other/*")), Error, "handle /auth/*");
});

Deno.test("a Caddyfile with no handle throws", () => {
  assertThrows(() => routed("(app) {\n  encode gzip\n}\n"), Error, "no top-level `handle");
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

// Bonk Chess's door, cut down to the handles that Caddy 2.11.7 reorders when one more path handle joins them (the
// keys paths as top-level handles of their own moved /llms-full.txt, /.well-known/* and the rest ahead of the others,
// and in the full door rmen and rmloc ahead of rmtoday: /armies in es came back English, /puzzle/today 404).
const door = `(bounded-auth) {
  transport http {
    dial_timeout 2s
  }
}
(app) {
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
  @rmtoday path_regexp rmtoday ^/(es/|pt-br/)?puzzle/today/?$
  handle @rmtoday {
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
  @rmen path_regexp rmen ^/(armies|rules)/?$
  handle @rmen {
    respond 200
  }
  @rmloc path_regexp rmloc ^/(es|pt-br)/(armies|rules)/?$
  handle @rmloc {
    respond 200
  }
  handle /auth/* {
    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}
  }
  handle /blobs/* {
    respond 200
  }
  handle /img/* {
    respond 200
  }
  handle /health {
    respond 200
  }
  handle /robots.txt {
    respond 200
  }
  handle /sitemap.xml {
    respond 200
  }
  handle /llms.txt {
    respond 200
  }
  handle /llms-full.txt {
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
`;

/** The matchers of the app's routes in the order Caddy runs them, without the keys guard (a route of its own). */
async function order(caddy: string, text: string): Promise<string[]> {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/Caddyfile`, text);
    const env = { PRONTO_UPSTREAM_KEYS: "keys:8702", PRONTO_UPSTREAM_AUTH: "auth:9999" };
    const out = await new Deno.Command(caddy, { args: ["adapt", "--config", `${dir}/Caddyfile`, "--adapter", "caddyfile"], env, stderr: "null" }).output();
    assert(out.success, `caddy adapt failed on:\n${text}`);
    // deno-lint-ignore no-explicit-any
    const routes = (rs: any[]): any[] => rs.some((r) => JSON.stringify(r.match ?? "").includes("/health")) ? rs : rs.flatMap((r) => (r.handle ?? []).flatMap((h: any) => (h.routes ? [routes(h.routes)] : [])).filter((x: any[]) => x.length)).at(0) ?? [];
    // deno-lint-ignore no-explicit-any
    const servers = Object.values<any>(JSON.parse(new TextDecoder().decode(out.stdout)).apps.http.servers);
    // deno-lint-ignore no-explicit-any
    return routes(servers[0].routes).filter((r: any) => !JSON.stringify(r).includes("keyguard")).map((r: any) => JSON.stringify(r.match ?? []));
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

const caddyBin = Deno.env.get("CADDY");
Deno.test({
  name: "adding the keys routes leaves the order of the app's other routes as Caddy ran it, whatever it reorders",
  ignore: !caddyBin,
  async fn() {
    const without = await order(caddyBin!, door);
    assertEquals(without.length, 23);
    assertEquals(await order(caddyBin!, routed(door)), without);
  },
});
