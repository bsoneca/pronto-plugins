// The keys routes in the door's Caddyfile, and the installer that gives an app the service.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { BEGIN, END, GUARD, GUARD_BEGIN, GUARD_END, GUARDED, ROUTES, ROUTES_BEGIN, ROUTES_END, route, routed, SCOPE, SCOPE_BEGIN, SCOPE_END, SCOPED } from "./route.ts";
import { type Config, type Db, keys, sign, STACK_ISSUER } from "./keys.ts";

const caddy = `(app) {
  encode zstd gzip
  # doorguard:begin — x
  @daprapi path_regexp daprapi ^/crud
  # doorguard:end
  # Chromium probes /favicon.ico.
  handle /favicon.ico {
    respond 204
  }
  handle /crud/* {
    uri strip_prefix /crud
    reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000}
  }
  handle /api/v1/* {
    reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000}
  }
  handle /blob-claim/* {
    route {
      reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000}
    }
  }
  handle /blobs/* {
    route {
      reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000}
    }
  }
  handle /billing/* {
    request_body {
      max_size 16KB
    }
    reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000}
  }
  handle /auth/* {
    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}
  }
}
`;

/** The lines without the keys blocks (each from its begin marker to its end), as the app wrote them. */
const without = (lines: string[], pairs: string[][]): string[] => {
  const out: string[] = [];
  let ends: string | null = null;
  for (const l of lines) {
    if (ends) { if (l === ends) ends = null; continue; }
    const pair = pairs.find(([b]) => b === l);
    if (pair) ends = pair[1]; else out.push(l);
  }
  return out;
};
const ours = [[ROUTES_BEGIN, ROUTES_END], [SCOPE_BEGIN, SCOPE_END], [GUARD_BEGIN, GUARD_END]];

Deno.test("the block is the first lines of the app's own handle /auth/*, and the app's reverse_proxy to auth answers the rest", () => {
  const out = routed(caddy).split("\n");
  const at = out.indexOf("  handle /auth/* {");
  assertEquals(out[at + 1], ROUTES_BEGIN);
  assertEquals(out.slice(at + 2, at + 2 + ROUTES.length), ROUTES);
  assertEquals(out[at + 2 + ROUTES.length], ROUTES_END);
  assertEquals(out[at + 3 + ROUTES.length], "    reverse_proxy {$PRONTO_UPSTREAM_AUTH:auth:9999}");
  // Nothing else is added: the other handles and the comments are where they were.
  assertEquals(without(out, ours), caddy.split("\n"));
});

Deno.test("the scope guard is the first directive of each data handle, never a top-level directive, and the handles' own lines follow", () => {
  const out = routed(caddy).split("\n");
  for (const path of SCOPED) {
    const at = out.indexOf(`  handle ${path} {`);
    assert(at >= 0, path);
    assertEquals(out.slice(at + 1, at + 3 + SCOPE.length), [SCOPE_BEGIN, ...SCOPE, SCOPE_END]);
  }
  assertEquals(out[out.indexOf("  handle /crud/* {") + 3 + SCOPE.length], "    uri strip_prefix /crud");
  assert(SCOPE.join("\n").includes("forward_auth {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n      uri /auth/keyscope\n      header_up dapr-app-id keys\n      import bounded-auth\n    }"));
  // Every forward_auth the block adds is inside a handle (four spaces in), none at the door's top level.
  assert(out.filter((l) => l.includes("forward_auth")).every((l) => l.startsWith("    ")));
  assertEquals(out.filter((l) => l === SCOPE_BEGIN).length, SCOPED.length);
});

Deno.test("the key refusal is the /auth/* guard again, the first directive of the billing handle, in the same form and nowhere else", () => {
  const out = routed(caddy).split("\n");
  assertEquals(GUARD, ROUTES.slice(0, GUARD.length));
  for (const path of GUARDED) {
    const at = out.indexOf(`  handle ${path} {`);
    assert(at >= 0, path);
    assertEquals(out.slice(at + 1, at + 3 + GUARD.length), [GUARD_BEGIN, ...GUARD, GUARD_END]);
  }
  assertEquals(out[out.indexOf("  handle /billing/* {") + 3 + GUARD.length], "    request_body {");
  assertEquals(out.filter((l) => l === GUARD_BEGIN).length, GUARDED.length);
  assert(GUARD.join("\n").includes("forward_auth {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n      uri /auth/keyguard\n      header_up dapr-app-id keys\n      import bounded-auth\n    }"));
  // No data handle gets the refusal (a key reads and writes there by its scopes), and billing gets no scope guard.
  for (const path of SCOPED) assert(!GUARDED.includes(path));
  assertEquals(out.slice(out.indexOf("  handle /billing/* {"), out.indexOf("  handle /auth/* {")).filter((l) => l === SCOPE_BEGIN).length, 0);
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
  // An app generated with #526: the /auth/* block alone, no scope guard, no billing refusal. It gains one in each data handle and no second /auth/* block.
  const third = without(routed(caddy).split("\n"), [[SCOPE_BEGIN, SCOPE_END], [GUARD_BEGIN, GUARD_END]]).join("\n");
  assertEquals(third.split("\n").filter((l) => l === ROUTES_BEGIN).length, 1);
  assertEquals(routed(third), routed(caddy));
  assertEquals(routed(routed(third)), routed(caddy));
  // A data handle the app has dropped since loses its guard, and the others keep theirs.
  const dropped = routed(caddy).replace("  handle /blob-claim/* {\n", "  handle /gone/* {\n");
  assertEquals(dropped.split("\n").filter((l) => l === SCOPE_BEGIN).length, SCOPED.length);
  assertEquals(routed(dropped).split("\n").filter((l) => l === SCOPE_BEGIN).length, SCOPED.length - 1);
  const older = routed(caddy).replace(ROUTES_BEGIN, `${ROUTES_BEGIN}\n    # an older routes block`);
  assertEquals(routed(older), routed(caddy));
});

Deno.test("a Caddyfile with pronto-billing's block but not its handle line throws, one with no billing block does not", () => {
  const billed = caddy.replace("  handle /billing/* {", "  # pronto-billing:begin\n  handle /billing/*  {");
  assertThrows(() => routed(billed), Error, "pronto-billing's block");
  assertEquals(routed(billed.replace("# pronto-billing:begin", "# other")).includes(GUARD_BEGIN), false);
  assert(routed(caddy.replace(/ {2}handle \/billing\/\* \{[\s\S]*?\n {2}\}\n/, "")).split("\n").every((l) => l !== GUARD_BEGIN));
});

Deno.test("a Caddyfile with none of the data handles throws", () => {
  const bare = "(app) {\n  handle /auth/* {\n    respond 200\n  }\n}\n";
  assertThrows(() => routed(bare), Error, "handle /crud/*");
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
 * the keys blocks' own routes (inside the app's /auth/*, /crud/*, /api/v1/* and /blob-claim/* routes) are not walked into. */
// deno-lint-ignore no-explicit-any
const sequence = (routes: any[], depth = 0): string[] => (routes ?? []).flatMap((r: any) => {
  const own = " ".repeat(depth) + JSON.stringify(r.match ?? []);
  if (["/auth/*", ...SCOPED, ...GUARDED].some((p) => JSON.stringify(r.match) === `[{"path":["${p}"]}]`)) return [own];
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

// The door as Caddy runs it, with the keys block spliced in, in front of the real keys handler and stand-ins for the
// data and the auth service: what a key's token may do on /crud, /api/v1 and /blob-claim, by its scopes and the method.
Deno.test({
  name: "a read-only key reads through the door and is refused a write, a write-only key is refused a read, and the sessions and the Dapr guard are as before",
  ignore: !caddyBin,
  async fn() {
    const secret = "door-secret";
    const cfg: Config = { secret, keysOn: true, gate: null, hook: null, appSchema: "public", mechaSchema: "mecha" };
    const handler = keys(cfg, null as unknown as Db); // the guards read no row
    const base = 20000 + Math.floor(Math.random() * 20000);
    const [doorPort, keysPort, crud, auth] = [base, base + 1, base + 2, base + 3];
    const servers = [
      Deno.serve({ port: keysPort, onListen() {} }, handler),
      Deno.serve({ port: crud, onListen() {} }, (req) => new Response(`crud ${req.method} ${new URL(req.url).pathname}`)),
      Deno.serve({ port: auth, onListen() {} }, (req) => new Response(`auth ${new URL(req.url).pathname}`)),
    ];
    const dir = await Deno.makeTempDir();
    // The small door above with doorguard's handle on the Dapr API of /crud, and a site block of this test's port.
    const guarded = caddy.replace("  @daprapi path_regexp daprapi ^/crud\n", "  @daprapi path_regexp daprapi (?i)^/crud/v1\\.0(/|$)\n  handle @daprapi {\n    respond 404\n  }\n");
    const sites = routed(guarded);
    const text = `{\n  admin off\n  auto_https off\n}\n(bounded-auth) {\n  transport http {\n    dial_timeout 2s\n  }\n}\n${sites}\n:${doorPort} {\n  import app\n}\n`;
    await Deno.writeTextFile(`${dir}/Caddyfile`, text);
    const proc = new Deno.Command(caddyBin!, {
      args: ["run", "--config", `${dir}/Caddyfile`, "--adapter", "caddyfile"],
      env: { PRONTO_UPSTREAM_KEYS: `127.0.0.1:${keysPort}`, PRONTO_UPSTREAM_CRUD: `127.0.0.1:${crud}`, PRONTO_UPSTREAM_AUTH: `127.0.0.1:${auth}` },
      stdout: "null", stderr: "null",
    }).spawn();
    try {
      const exp = Math.floor(Date.now() / 1000) + 3600;
      const claims = { role: "app_user", iss: STACK_ISSUER, sub: "0a000000-0000-4000-8000-000000000001", exp };
      const key = (scp: string[]) => sign(secret, { ...claims, kid: crypto.randomUUID(), scp });
      const ask = async (method: string, path: string, token?: string): Promise<[number, string]> => {
        for (let i = 0; ; i++) {
          try {
            const r = await fetch(`http://127.0.0.1:${doorPort}${path}`, { method, headers: token ? { authorization: `Bearer ${token}` } : {} });
            const body = await r.text();
            if (r.status !== 502 || i >= 50) return [r.status, body];
          } catch (e) {
            if (i >= 50) throw e;
          }
          await new Promise((r) => setTimeout(r, 100));
        }
      };
      const [readOnly, writeOnly, both, session] = [await key(["read"]), await key(["write", "machines:bot_1"]), await key(["read", "write"]), await sign(secret, claims)];
      // A request reaches the data stand-in unchanged: the path is stripped of /crud and the method is the client's.
      assertEquals(await ask("GET", "/crud/t", readOnly), [200, "crud GET /t"]);
      assertEquals(await ask("GET", "/api/v1/t", readOnly), [200, "crud GET /api/v1/t"]);
      assertEquals(await ask("GET", "/blob-claim/x", both), [200, "crud GET /blob-claim/x"]);
      assertEquals((await ask("HEAD", "/crud/t", readOnly))[0], 200);
      for (const path of ["/crud/t", "/api/v1/t", "/blob-claim/x", "/blobs/x"]) {
        assertEquals((await ask("POST", path, readOnly))[0], 403, `a read-only key's POST ${path}`);
        assertEquals((await ask("DELETE", path, readOnly))[0], 403, `a read-only key's DELETE ${path}`);
        assertEquals((await ask("GET", path, writeOnly))[0], 403, `a write-only key's GET ${path}`);
        for (const token of [session, undefined]) assertEquals((await ask("GET", path, token))[0], 200, `GET ${path}`);
      }
      assertEquals((await ask("POST", "/crud/t", writeOnly))[0], 200);
      assertEquals((await ask("POST", "/api/v1/t", writeOnly))[0], 200);
      assertEquals((await ask("POST", "/blob-claim/x", writeOnly))[0], 200);
      assertEquals((await ask("PUT", "/blobs/x", writeOnly))[0], 200);
      assertEquals([(await ask("PUT", "/blobs/x", readOnly))[0], (await ask("GET", "/blobs/x", readOnly))[0]], [403, 200]);
      for (const m of ["GET", "POST"]) for (const path of ["/crud/t", "/api/v1/t"]) assertEquals((await ask(m, path, both))[0], 200);
      for (const token of [session, undefined]) assertEquals((await ask("POST", "/crud/t", token))[0], 200, "a session's write");
      // What the data service reads as a key's token and the guard might not (PostgREST takes the scheme in any case, extra white space,
      // a first token before a comma and a token up to its clock skew past exp) is refused at the door, never passed to a write.
      const lapsed = await sign(secret, { ...claims, kid: crypto.randomUUID(), scp: ["read"], exp: Math.floor(Date.now() / 1000) - 10 });
      for (const h of [`bearer ${readOnly}`, `BEARER ${readOnly}`, `Bearer  ${readOnly}`, `Bearer ${readOnly}, x`, `Bearer ${lapsed}`]) {
        for (const path of ["/crud/t", "/api/v1/t", "/blobs/x"]) {
          const r = await fetch(`http://127.0.0.1:${doorPort}${path}`, { method: "POST", headers: { authorization: h } });
          assert([401, 403].includes(r.status), `${h.slice(0, 14)} POST ${path}: ${r.status}`);
          await r.body?.cancel();
        }
      }
      // The door's own guard of the Dapr API answers before the scope guard: a key's token gets its 404, not a 403.
      for (const token of [readOnly, writeOnly, undefined]) for (const m of ["GET", "POST"]) assertEquals((await ask(m, "/crud/v1.0/metadata", token))[0], 404, `${m} /crud/v1.0/metadata`);
      // Billing takes a token as the account: a key's token, whatever its scopes, gets 403 on every path of it, a session passes.
      for (const tok of [readOnly, writeOnly, both, await key(["machines:bot_1"])]) {
        for (const [m, path] of [["POST", "/billing/portal"], ["GET", "/billing/me"], ["POST", "/billing/checkout"]]) assertEquals((await ask(m, path, tok))[0], 403, `a key's ${m} ${path}`);
      }
      assertEquals(await ask("POST", "/billing/portal", session), [200, "crud POST /billing/portal"]);
      assertEquals((await ask("GET", "/billing/me", undefined))[0], 200);
      for (const h of [`bearer ${readOnly}`, `BEARER ${writeOnly}`, `Bearer  ${readOnly}`, `Bearer ${readOnly}, x`, `Bearer ${lapsed}`]) {
        const r = await fetch(`http://127.0.0.1:${doorPort}/billing/portal`, { method: "POST", headers: { authorization: h } });
        assertEquals(r.status, 403, `${h.slice(0, 14)} POST /billing/portal`);
        await r.body?.cancel();
      }
      // The /auth/* guard of #526 is as it was: a key's token is refused there, and a session reaches the auth service.
      assertEquals((await ask("GET", "/auth/session", readOnly))[0], 403);
      assertEquals(await ask("GET", "/auth/session", session), [200, "auth /auth/session"]);
    } finally {
      proc.kill();
      await proc.status;
      for (const s of servers) await s.shutdown();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
