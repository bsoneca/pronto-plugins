// What an app's flags become: flagd's definitions, with the accounts a flag
// names targeted beside the hosts at hand; the live source a release hands
// flagd; and flagd itself serving them, the live source over the baked file.
// cue comes from PATH, as the plugins tree pins it; flagd from FLAGD, the
// binary an app's `http:flagd` installs, and its test is ignored without one; the door's route
// is tested in Caddy, from CADDY, the same way.
import { request } from "node:http";
const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const dec = new TextDecoder();

async function app(spec: string): Promise<string> {
  const dir = await Deno.makeTempDir();
  await Deno.writeTextFile(`${dir}/program.cue`, "package shop\n");
  const out = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, dir] }).output();
  if (!out.success) throw new Error(dec.decode(out.stderr));
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${spec}`);
  return dir;
}
async function cue(dir: string, expr: string) {
  const out = await new Deno.Command("cue", { args: ["export", `${dir}/flags_plugin.cue`, `${dir}/flags_spec.cue`, "-e", expr, "--out", "json"] }).output();
  if (!out.success) throw new Error(`cue export -e ${expr}: ${dec.decode(out.stderr)}`);
  return JSON.parse(dec.decode(out.stdout));
}
const SPEC = `
flags: {
  premium: {default: false, local: true, accounts: ["acct-me"]}
  banner: {default: "off", local: "on"}
  quiet: {default: 3}
}
flagsLive: {project: "shop-prod", bucket: "shop-prod-flags"}
`;

Deno.test("a flag's accounts read its local value beside the hosts at hand; others are as before", async () => {
  const dir = await app(SPEC);
  const doc = await cue(dir, "flagd.document");
  const local = { in: [{ var: "host" }, ["localhost", "127.0.0.1", "caddy"]] };
  eq(doc.flags.premium.targeting, { if: [local, "local", { in: [{ var: "targetingKey" }, ["acct-me"]] }, "local", "default"] }, "premium's targeting");
  eq(doc.flags.banner.targeting, { if: [local, "local", "default"] }, "a flag without accounts");
  eq(doc.flags.quiet.targeting, undefined, "a flag with one value everywhere");
  eq(await cue(dir, "flagsLive.sources"), '[{"uri":"gs://shop-prod-flags/flags.json","provider":"gcs"}]', "the live source");
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC.replace(/flagsLive: \{.*\}/, 'flagsLive: {dir: "flagstore"}')}`);
  eq(await cue(dir, "flagsLive.sources"), '[{"uri":"flagstore/flags.json","provider":"file"}]', "a directory store is a file source");
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC}`);
  const entry = await cue(dir, "cluster.surface.targets.flagd.entrypoint");
  eq(entry.do.includes("--ofrep-port"), false, "a host launch takes the OFREP port it is handed");
  eq(entry.dockerfile.do.includes("--ofrep-port 8693"), true, "the image keeps 8693");
  await Deno.remove(dir, { recursive: true });
});

Deno.test("accounts need a local value, and an account id is a token's sub", async () => {
  for (const bad of [`flags: x: {default: false, accounts: ["a"]}`, `flags: x: {default: false, local: true, accounts: ["no spaces"]}`]) {
    const dir = await app(bad);
    let refused = false;
    try { await cue(dir, "flagd.document"); } catch { refused = true; }
    eq(refused, true, bad);
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("a flip's cases: the production address and the commands are checked; a spec with none exports as before", async () => {
  const dir = await app(SPEC);
  const before = await cue(dir, "flagd.document");
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC}
flagsLive: {url: "https://shop.example", testers: ["tester-1"]}
flagsCases: {live: "sh live.sh"}
`);
  eq(await cue(dir, "flagd.document"), before, "the flags' document is the same");
  eq(await cue(dir, "flagsLive.testers"), ["tester-1"], "testers an app still says evaluate (no longer read, PRONTO-284)");
  eq(await cue(dir, "flagsCases"), { live: "sh live.sh" }, "the command");
  for (const bad of [`flagsLive: testers: ["no spaces"]`, `flagsLive: url: "http://insecure.example"`, `flagsCases: other: "x"`, `flagsCases: local: "x"`]) {
    await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC}\n${bad}\n`);
    let refused = false;
    try { await cue(dir, "flagd.document"); await cue(dir, "flagsCases"); } catch { refused = true; }
    eq(refused, true, bad);
  }
  await Deno.remove(dir, { recursive: true });
});

const flagd = Deno.env.get("FLAGD");
Deno.test({ name: "flagd serves the live source over the baked file, by account and host, and follows its edits", ignore: !flagd, async fn() {
  const dir = await app(SPEC);
  const baked = await cue(dir, "flagd.document");
  await Deno.writeTextFile(`${dir}/baked.json`, JSON.stringify({ ...baked, flags: { ...baked.flags, premium: { ...baked.flags.premium, targeting: undefined } } }));
  await Deno.writeTextFile(`${dir}/live.json`, JSON.stringify(baked));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const proc = new Deno.Command(flagd!, {
    args: ["start", "--uri", `file:${dir}/baked.json`, "--port", `${port + 1}`, "--management-port", `${port + 2}`, "--sync-port", `${port + 3}`, "--ofrep-sse-enabled=false", "--context-from-header", "X-Pronto-Host=host"],
    env: { FLAGD_OFREP_PORT: `${port}`, FLAGD_SOURCES: JSON.stringify([{ uri: `${dir}/live.json`, provider: "file" }]) },
    stdout: "null", stderr: "null",
  }).spawn();
  const ask = async (host: string, account?: string) => {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/ofrep/v1/evaluate/flags/premium`, {
          method: "POST", headers: { "content-type": "application/json", "x-pronto-host": host },
          body: JSON.stringify({ context: account ? { targetingKey: account } : {} }),
        });
        return (await res.json()).value;
      } catch (e) { if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
    }
  };
  try {
    eq([await ask("shop.example", "acct-me"), await ask("shop.example", "acct-x"), await ask("shop.example"), await ask("localhost")], [true, false, false, true], "the live source's targeting");
    await Deno.writeTextFile(`${dir}/live.json`, JSON.stringify({ ...baked, flags: { ...baked.flags, premium: { ...baked.flags.premium, variants: { default: true, local: true } } } }));
    let after;
    for (let i = 0; i < 50 && after !== true; i++) { await new Promise((r) => setTimeout(r, 200)); after = await ask("shop.example", "acct-x"); }
    eq(after, true, "an edit to the live source, read with no restart");
  } finally {
    proc.kill();
    await proc.status;
    await Deno.remove(dir, { recursive: true });
  }
} });

// The door's flags route, as flags/app/flags.nu writes it (its quoted lines, read from the script so
// the test runs the route itself), in front of a real flagd, with a stand-in for the auth service's
// /auth/door: 204 and X-Pronto-Account for the token "tok-<account>", 204 without it for any other.
const caddy = Deno.env.get("CADDY");
Deno.test({ name: "the door gives flagd the account of the verified session, never the page's", ignore: !flagd || !caddy, async fn() {
  const dir = await app(SPEC);
  const baked = await cue(dir, "flagd.document");
  await Deno.writeTextFile(`${dir}/flags.json`, JSON.stringify(baked));
  const nu = await Deno.readTextFile(new URL("./app/flags.nu", import.meta.url));
  const route = nu.slice(nu.indexOf("let route = ["), nu.indexOf("\n\t]\n", nu.indexOf("let route = ["))).split("\n")
    .flatMap((l) => { const m = l.match(/^\t\t"(.*)"$/); return m ? [m[1].replaceAll('\\"', '"')] : []; })
    .filter((l) => !l.startsWith("  # pronto-flags"));
  eq(route.some((l) => l.includes("forward_auth")), true, "the route asks the auth service");
  const base = 20000 + Math.floor(Math.random() * 20000);
  const [ofrep, door, auth] = [base, base + 4, base + 5];
  const authServer = Deno.serve({ port: auth, onListen() {} }, (req) => {
    const m = (req.headers.get("authorization") ?? "").match(/^Bearer tok-([a-z-]+)$/);
    return new Response(null, { status: 204, headers: m ? { "x-pronto-account": m[1] } : {} });
  });
  await Deno.writeTextFile(`${dir}/Caddyfile`, `{\n  admin off\n  auto_https off\n}\n:${door} {\n${route.join("\n")}\n  handle {\n    respond 404\n  }\n}\n`);
  const flagdProc = new Deno.Command(flagd!, {
    args: ["start", "--uri", `file:${dir}/flags.json`, "--port", `${base + 1}`, "--management-port", `${base + 2}`, "--sync-port", `${base + 3}`, "--ofrep-sse-enabled=false",
      "--context-from-header", "X-Pronto-Host=host", "--context-from-header", "X-Pronto-Account=targetingKey"],
    env: { FLAGD_OFREP_PORT: `${ofrep}` }, stdout: "null", stderr: "null",
  }).spawn();
  const caddyProc = new Deno.Command(caddy!, {
    args: ["run", "--config", `${dir}/Caddyfile`, "--adapter", "caddyfile"],
    env: { PRONTO_UPSTREAM_FLAGD: `127.0.0.1:${ofrep}`, PRONTO_UPSTREAM_AUTH: `127.0.0.1:${auth}` }, stdout: "null", stderr: "null",
  }).spawn();
  // A request through the door, as a page at host `host` sends it: its body's targetingKey, a header it made up, its token.
  // node's http, since fetch drops a Host header: the door says which host it was reached at from it.
  const ask = async (opts: { host?: string; key?: string; claim?: string; token?: string }): Promise<[number, unknown]> => {
    const body = JSON.stringify({ context: opts.key ? { targetingKey: opts.key } : {} });
    for (let i = 0; ; i++) {
      const [status, text] = await new Promise<[number, string]>((resolve, reject) => {
        const req = request({ host: "127.0.0.1", port: door, path: "/ofrep/v1/evaluate/flags/premium", method: "POST", headers: {
          "content-type": "application/json", host: opts.host ?? "shop.example", ...(opts.claim ? { "x-pronto-account": opts.claim } : {}), ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}) } },
        (res) => { let t = ""; res.on("data", (c) => t += c); res.on("end", () => resolve([res.statusCode!, t])); });
        req.on("error", reject);
        req.end(body);
      }).catch(() => [0, ""] as [number, string]);
      if ((status === 0 || status === 502) && i < 50) { await new Promise((r) => setTimeout(r, 100)); continue; }
      return [status, JSON.parse(text || "{}").value];
    }
  };
  try {
    eq(await ask({ key: "acct-me" }), [200, false], "a page naming a tester in its body, with no session");
    eq(await ask({ key: "acct-me", claim: "acct-me" }), [200, false], "a page naming a tester in the header the door sets");
    eq(await ask({ key: "acct-me", token: "not-a-token" }), [200, false], "a page naming a tester with a token that verifies as no one");
    eq(await ask({ token: "tok-acct-me" }), [200, true], "a verified session of the tester");
    eq(await ask({ key: "acct-x", claim: "acct-x", token: "tok-acct-me" }), [200, true], "the tester's session, whoever the page says it is");
    eq(await ask({ key: "acct-me", token: "tok-acct-x" }), [200, false], "another account's session, naming the tester in the body");
    eq(await ask({}), [200, false], "a signed-out page still gets its flags");
    eq(await ask({ host: "localhost" }), [200, true], "the hosts at hand still read local");
  } finally {
    caddyProc.kill(); flagdProc.kill();
    await caddyProc.status; await flagdProc.status;
    await authServer.shutdown();
    await Deno.remove(dir, { recursive: true });
  }
} });

// What the door depends on: flagd's context from a header wins over the body's targetingKey, but
// only a header that is there and not empty does, which is why the door always sets one.
Deno.test({ name: "flagd's header context overrides the body's targetingKey unless the header is absent or empty", ignore: !flagd, async fn() {
  const dir = await app(SPEC);
  await Deno.writeTextFile(`${dir}/flags.json`, JSON.stringify(await cue(dir, "flagd.document")));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const proc = new Deno.Command(flagd!, {
    args: ["start", "--uri", `file:${dir}/flags.json`, "--port", `${port + 1}`, "--management-port", `${port + 2}`, "--sync-port", `${port + 3}`, "--ofrep-sse-enabled=false",
      "--context-from-header", "X-Pronto-Host=host", "--context-from-header", "X-Pronto-Account=targetingKey"],
    env: { FLAGD_OFREP_PORT: `${port}` }, stdout: "null", stderr: "null",
  }).spawn();
  const ask = async (account: string | null, key: string) => {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/ofrep/v1/evaluate/flags/premium`, {
          method: "POST", headers: { "content-type": "application/json", "x-pronto-host": "shop.example", ...(account === null ? {} : { "x-pronto-account": account }) },
          body: JSON.stringify({ context: { targetingKey: key } }),
        });
        return (await res.json()).value;
      } catch (e) { if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
    }
  };
  try {
    eq([await ask("acct-x", "acct-me"), await ask("acct-me", "acct-x"), await ask("no session", "acct-me")], [false, true, false], "the header wins");
    eq([await ask(null, "acct-me"), await ask("", "acct-me")], [true, true], "an absent or empty header leaves the body's: the door always sets one");
  } finally {
    proc.kill();
    await proc.status;
    await Deno.remove(dir, { recursive: true });
  }
} });
