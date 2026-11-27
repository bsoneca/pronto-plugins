// What an app's flags become: flagd's definitions, with the accounts a flag
// names targeted beside the hosts at hand; the live source a release hands
// flagd; and flagd itself serving them, the live source over the baked file.
// cue comes from PATH, as the plugins tree pins it; flagd from FLAGD, the
// binary an app's `http:flagd` installs, and its test is ignored without one; the door's route
// is tested in Caddy, from CADDY, the same way.
import { request } from "node:http";
const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const dec = new TextDecoder();

// Ports the kernel hands out, never a guess: a fixed range drawn at random sits inside the one outgoing
// connections take from, and a port found taken makes flagd exit at once.
function freePorts(n: number): number[] {
  const ls = Array.from({ length: n }, () => Deno.listen({ hostname: "127.0.0.1", port: 0 }));
  const ports = ls.map((l) => (l.addr as Deno.NetAddr).port);
  for (const l of ls) l.close();
  return ports;
}
// A child process with its stderr kept and its status read once. `died` says why it is gone (so a caller
// waiting on it fails with the child's own words, not with a connection refused); `stop` is safe on a child
// that exited already, which `kill` is not.
function launch(bin: string, args: string[], env: Record<string, string>) {
  const proc = new Deno.Command(bin, { args, env, stdout: "null", stderr: "piped" }).spawn();
  let err = "";
  let exit: Deno.CommandStatus | undefined;
  const reading = (async () => { for await (const c of proc.stderr) err += dec.decode(c, { stream: true }); })();
  const status = proc.status.then((s) => exit = s);
  return {
    died: () => exit && new Error(`${bin} exited ${exit.code} before the test was done: ${err.slice(-2000)}`),
    async stop() {
      if (!exit) { try { proc.kill(); } catch { /* it exited since the check */ } }
      await status;
      await reading;
    },
  };
}
// What an OFREP evaluation answers: one flag's value or error, or the bulk list.
type Body = { flags?: { key: string }[]; value?: unknown; errorCode?: string };

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
  premium: {default: false, local: true, accounts: ["acct-me"], client: true}
  banner: {default: "off", local: "on", client: true}
  quiet: {default: 3}
  secret: {default: "grantees", local: "grantees"}
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
  eq([doc.flags.premium.metadata, doc.flags.banner.metadata], [{ flagSetId: "client" }, { flagSetId: "client" }], "a client flag is in flagd's client flag set");
  eq([doc.flags.quiet.metadata, doc.flags.secret.metadata], [undefined, undefined], "a flag not marked client is in no flag set");
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

Deno.test("a mirror names the node by ssh or a kubeconfig file, one of them, each with its kubectl", async () => {
  const dir = await app(SPEC);
  const base = `namespace: "game", configMap: "game-flags"`;
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC}
flagsLive: mirrors: [{ssh: "ops@node.example", ${base}}, {kubeconfig: "/run/kc.yaml", ${base}, required: true}]
`);
  const m = await cue(dir, "flagsLive.mirrors");
  eq(m[0], { ssh: "ops@node.example", namespace: "game", configMap: "game-flags", key: "flags.json", required: false, kubectl: "sudo k3s kubectl" }, "an ssh mirror, as before");
  eq(m[1], { kubeconfig: "/run/kc.yaml", namespace: "game", configMap: "game-flags", key: "flags.json", required: true, kubectl: "kubectl" }, "a kubeconfig mirror runs kubectl here");
  for (const bad of [`{ssh: "ops@node.example", kubeconfig: "/run/kc.yaml", ${base}}`, `{${base}}`, `{kubeconfig: "", ${base}}`, `{kubeconfig: "/run/kc.yaml", kubectl: "./tools/x", ${base}}`]) {
    await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${SPEC}\nflagsLive: mirrors: [${bad}]\n`);
    let refused = false;
    try { await cue(dir, "flagsLive.mirrors"); } catch { refused = true; }
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
  const [port, p1, p2, p3] = freePorts(4);
  const proc = launch(flagd!, ["start", "--uri", `file:${dir}/baked.json`, "--port", `${p1}`, "--management-port", `${p2}`, "--sync-port", `${p3}`, "--ofrep-sse-enabled=false", "--context-from-header", "X-Pronto-Host=host"],
    { FLAGD_OFREP_PORT: `${port}`, FLAGD_SOURCES: JSON.stringify([{ uri: `${dir}/live.json`, provider: "file" }]) });
  const ask = async (host: string, account?: string) => {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/ofrep/v1/evaluate/flags/premium`, {
          method: "POST", headers: { "content-type": "application/json", "x-pronto-host": host },
          body: JSON.stringify({ context: account ? { targetingKey: account } : {} }),
        });
        return (await res.json()).value;
      } catch (e) { if (proc.died()) throw proc.died(); if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
    }
  };
  try {
    eq([await ask("shop.example", "acct-me"), await ask("shop.example", "acct-x"), await ask("shop.example"), await ask("localhost")], [true, false, false, true], "the live source's targeting");
    await Deno.writeTextFile(`${dir}/live.json`, JSON.stringify({ ...baked, flags: { ...baked.flags, premium: { ...baked.flags.premium, variants: { default: true, local: true } } } }));
    let after;
    for (let i = 0; i < 50 && after !== true; i++) { await new Promise((r) => setTimeout(r, 200)); after = await ask("shop.example", "acct-x"); }
    eq(after, true, "an edit to the live source, read with no restart");
  } finally {
    await proc.stop();
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
  const [ofrep, door, auth, p1, p2, p3] = freePorts(6);
  const authServer = Deno.serve({ port: auth, onListen() {} }, (req) => {
    const m = (req.headers.get("authorization") ?? "").match(/^Bearer tok-([a-z-]+)$/);
    return new Response(null, { status: 204, headers: m ? { "x-pronto-account": m[1] } : {} });
  });
  await Deno.writeTextFile(`${dir}/Caddyfile`, `{\n  admin off\n  auto_https off\n}\n:${door} {\n${route.join("\n")}\n  handle {\n    respond 404\n  }\n}\n`);
  const flagdProc = launch(flagd!, ["start", "--uri", `file:${dir}/flags.json`, "--port", `${p1}`, "--management-port", `${p2}`, "--sync-port", `${p3}`, "--ofrep-sse-enabled=false",
    "--context-from-header", "X-Pronto-Host=host", "--context-from-header", "X-Pronto-Account=targetingKey"],
    { FLAGD_OFREP_PORT: `${ofrep}` });
  const caddyProc = launch(caddy!, ["run", "--config", `${dir}/Caddyfile`, "--adapter", "caddyfile"],
    { PRONTO_UPSTREAM_FLAGD: `127.0.0.1:${ofrep}`, PRONTO_UPSTREAM_AUTH: `127.0.0.1:${auth}` });
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
      if (status === 0 || status === 502) { const d = flagdProc.died() ?? caddyProc.died(); if (d) throw d; }
      if ((status === 0 || status === 502) && i < 50) { await new Promise((r) => setTimeout(r, 100)); continue; }
      return [status, JSON.parse(text || "{}").value];
    }
  };
  // Any path, method and headers through the door: what a page that wants a server-only flag would try.
  const raw = async (path: string, headers: Record<string, string> = {}, body = "{}"): Promise<[number, Body]> => {
    for (let i = 0; ; i++) {
      const [status, text] = await new Promise<[number, string]>((resolve, reject) => {
        const req = request({ host: "127.0.0.1", port: door, path, method: "POST", headers: { "content-type": "application/json", host: "shop.example", ...headers } },
          (res) => { let t = ""; res.on("data", (c) => t += c); res.on("end", () => resolve([res.statusCode!, t])); });
        req.on("error", reject);
        req.end(body);
      }).catch(() => [0, ""] as [number, string]);
      if (status === 0 || status === 502) { const d = flagdProc.died() ?? caddyProc.died(); if (d) throw d; }
      if ((status === 0 || status === 502) && i < 50) { await new Promise((r) => setTimeout(r, 100)); continue; }
      return [status, JSON.parse(text || "{}")];
    }
  };
  try {
    // PRONTO-1518: a page reads the flags marked client and nothing else, whatever selector it sends.
    const keys = (b: Body) => (b.flags ?? []).map((f) => f.key).sort();
    eq((await raw("/ofrep/v1/evaluate/flags/secret"))[0], 404, "a server-only flag is not found through the door");
    for (const [what, path, headers, body] of [
      ["a selector header that names the default set", "/ofrep/v1/evaluate/flags/secret", { "flagd-selector": "flagSetId=" }, "{}"],
      ["an empty selector header", "/ofrep/v1/evaluate/flags/secret", { "flagd-selector": "" }, "{}"],
      ["a selector header for a flag source", "/ofrep/v1/evaluate/flags/secret", { "flagd-selector": "source=flags.json" }, "{}"],
      ["a selector in the query", "/ofrep/v1/evaluate/flags/secret?selector=flagSetId%3D", {}, "{}"],
      ["a selector in the body", "/ofrep/v1/evaluate/flags/secret", {}, JSON.stringify({ selector: "flagSetId=", context: {} })],
    ] as [string, string, Record<string, string>, string][]) {
      eq((await raw(path, headers, body))[0], 404, `${what}, for a server-only flag`);
    }
    for (const headers of [{}, { "flagd-selector": "flagSetId=" }, { "flagd-selector": "flagSetId=other" }] as Record<string, string>[]) {
      eq(keys((await raw("/ofrep/v1/evaluate/flags", headers))[1]), ["banner", "premium"], `bulk through the door lists the client flags alone (${JSON.stringify(headers)})`);
    }
    eq(keys((await raw("/ofrep/v1/evaluate/flags?selector=flagSetId%3D"))[1]), ["banner", "premium"], "bulk with a query selector lists the client flags alone");
    eq((await raw("/ofrep/v1/evaluate/flags/banner"))[0], 200, "a client flag is served");
    eq(await ask({ key: "acct-me" }), [200, false], "a page naming a tester in its body, with no session");
    eq(await ask({ key: "acct-me", claim: "acct-me" }), [200, false], "a page naming a tester in the header the door sets");
    eq(await ask({ key: "acct-me", token: "not-a-token" }), [200, false], "a page naming a tester with a token that verifies as no one");
    eq(await ask({ token: "tok-acct-me" }), [200, true], "a verified session of the tester");
    eq(await ask({ key: "acct-x", claim: "acct-x", token: "tok-acct-me" }), [200, true], "the tester's session, whoever the page says it is");
    eq(await ask({ key: "acct-me", token: "tok-acct-x" }), [200, false], "another account's session, naming the tester in the body");
    eq(await ask({}), [200, false], "a signed-out page still gets its flags");
    eq(await ask({ host: "localhost" }), [200, true], "the hosts at hand still read local");
  } finally {
    await caddyProc.stop(); await flagdProc.stop();
    await authServer.shutdown();
    await Deno.remove(dir, { recursive: true });
  }
} });

// What the door depends on: flagd's context from a header wins over the body's targetingKey, but
// only a header that is there and not empty does, which is why the door always sets one.
Deno.test({ name: "flagd's header context overrides the body's targetingKey unless the header is absent or empty", ignore: !flagd, async fn() {
  const dir = await app(SPEC);
  await Deno.writeTextFile(`${dir}/flags.json`, JSON.stringify(await cue(dir, "flagd.document")));
  const [port, p1, p2, p3] = freePorts(4);
  const proc = launch(flagd!, ["start", "--uri", `file:${dir}/flags.json`, "--port", `${p1}`, "--management-port", `${p2}`, "--sync-port", `${p3}`, "--ofrep-sse-enabled=false",
      "--context-from-header", "X-Pronto-Host=host", "--context-from-header", "X-Pronto-Account=targetingKey"],
    { FLAGD_OFREP_PORT: `${port}` });
  const ask = async (account: string | null, key: string) => {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/ofrep/v1/evaluate/flags/premium`, {
          method: "POST", headers: { "content-type": "application/json", "x-pronto-host": "shop.example", ...(account === null ? {} : { "x-pronto-account": account }) },
          body: JSON.stringify({ context: { targetingKey: key } }),
        });
        return (await res.json()).value;
      } catch (e) { if (proc.died()) throw proc.died(); if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
    }
  };
  try {
    eq([await ask("acct-x", "acct-me"), await ask("acct-me", "acct-x"), await ask("no session", "acct-me")], [false, true, false], "the header wins");
    eq([await ask(null, "acct-me"), await ask("", "acct-me")], [true, true], "an absent or empty header leaves the body's: the door always sets one");
  } finally {
    await proc.stop();
    await Deno.remove(dir, { recursive: true });
  }
} });

// PRONTO-1518, as flagd 0.18.0 answers it: the flags marked client are in the flag set "client", and the door's
// selector header reads that set alone. Billing reaches flagd over the dapr mesh with no selector, so it reads all.
Deno.test({ name: "flagd's flag sets: the client selector reads the client flags alone, no selector reads every flag, an empty one the default set", ignore: !flagd, async fn() {
  const dir = await app(SPEC);
  await Deno.writeTextFile(`${dir}/flags.json`, JSON.stringify(await cue(dir, "flagd.document")));
  const [port, p1, p2, p3] = freePorts(4);
  const proc = launch(flagd!, ["start", "--uri", `file:${dir}/flags.json`, "--port", `${p1}`, "--management-port", `${p2}`, "--sync-port", `${p3}`, "--ofrep-sse-enabled=false",
      "--context-from-header", "X-Pronto-Host=host", "--context-from-header", "X-Pronto-Account=targetingKey"],
    { FLAGD_OFREP_PORT: `${port}` });
  const ask = async (path: string, headers: Record<string, string> = {}, body: unknown = { context: {} }): Promise<[number, Body]> => {
    for (let i = 0; ; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/ofrep/v1/evaluate/flags${path}`, {
          method: "POST", headers: { "content-type": "application/json", "x-pronto-host": "shop.example", ...headers }, body: JSON.stringify(body),
        });
        return [res.status, await res.json()];
      } catch (e) { if (proc.died()) throw proc.died(); if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
    }
  };
  const keys = (b: Body) => (b.flags ?? []).map((f) => f.key).sort();
  const client = { "flagd-selector": "flagSetId=client" };
  try {
    eq(keys((await ask("", client))[1]), ["banner", "premium"], "bulk with the client selector: the client flags alone");
    const single = await ask("/secret", client);
    eq([single[0], single[1].errorCode], [404, "FLAG_NOT_FOUND"], "a server-only flag with the client selector: not found");
    eq((await ask("/premium", client))[0], 200, "a client flag with the client selector");
    // Billing's path: no selector.
    eq(keys((await ask(""))[1]), ["banner", "premium", "quiet", "secret"], "bulk with no selector: every flag");
    const open = await ask("/secret");
    eq([open[0], open[1].value], [200, "grantees"], "a server-only flag with no selector: read");
    // What the door must never leave to a page: an empty selector is the default set, which holds the server-only flags.
    const empty = await ask("/secret", { "flagd-selector": "flagSetId=" });
    eq([empty[0], empty[1].value], [200, "grantees"], "an empty flagSetId selector reads the default set, so the door always sets the selector");
    eq(keys((await ask("", { "flagd-selector": "flagSetId=" }))[1]), ["quiet", "secret"], "bulk with an empty flagSetId selector: the default set");
    // A selector anywhere but the header is not one.
    const query = await ask("/secret?selector=flagSetId%3Dclient");
    eq([query[0], query[1].value], [200, "grantees"], "a query selector is ignored");
    const inBody = await ask("/secret", {}, { selector: "flagSetId=client", context: {} });
    eq([inBody[0], inBody[1].value], [200, "grantees"], "a body selector is ignored");
  } finally {
    await proc.stop();
    await Deno.remove(dir, { recursive: true });
  }
} });
