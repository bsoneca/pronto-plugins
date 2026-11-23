// The keys routes in the door's Caddyfile, and the installer that gives an app the service.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { BEGIN, BLOCK, END, route, routed } from "./route.ts";

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
  assert(without.includes(BEGIN) && without.includes("  handle /auth/keys* {"));
});

Deno.test("it guards every /auth/* path and sends the keys paths to the service, one path to a handle", () => {
  const text = BLOCK.join("\n");
  assert(text.includes("@keysauth path /auth/*"));
  const via = "header_up dapr-app-id keys\n";
  assert(text.includes(`forward_auth @keysauth {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n    uri /auth/keyguard\n    ${via}    import bounded-auth\n  }`));
  assert(text.includes(`handle /auth/keys* {\n    reverse_proxy {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n      ${via}      import bounded-auth\n    }\n  }`));
  assert(text.includes(`handle /auth/key {\n    reverse_proxy {$PRONTO_UPSTREAM_KEYS:keys:8702} {\n      ${via}      import bounded-auth\n    }\n  }`));
  // The guard comes first: forward_auth runs before every handle.
  assert(text.indexOf("forward_auth") < text.indexOf("handle /auth/keys*"));
});

Deno.test("all three set the Dapr app id with header_up, which replaces a client's own, and none passes it through", () => {
  const lines = BLOCK.filter((l) => l.includes("dapr-app-id"));
  assertEquals(lines.map((l) => l.trim()), Array(3).fill("header_up dapr-app-id keys"));
  assertEquals(BLOCK.filter((l) => l.includes("import bounded-auth")).length, 3);
  // `header_up +` adds beside a client's value and `-` deletes: only the bare form replaces it.
  assert(!BLOCK.some((l) => /header_up\s+[+\-?]/.test(l)));
  assert(!BLOCK.some((l) => /copy_headers|header_down|trusted_proxies/.test(l)));
});

Deno.test("it is idempotent, and replaces an earlier block", () => {
  assertEquals(routed(routed(caddy)), routed(caddy));
  const old = caddy.replace("  # Chromium", [BEGIN, "  # an older block", END, "  # Chromium"].join("\n"));
  const out = routed(old);
  assert(!out.includes("an older block") && out.split("\n").filter((l) => l === BEGIN).length === 1);
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
