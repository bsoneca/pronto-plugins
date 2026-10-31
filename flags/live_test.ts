// What an app's flags become: flagd's definitions, with the accounts a flag
// names targeted beside the hosts at hand; the live source a release hands
// flagd; and flagd itself serving them, the live source over the baked file.
// cue comes from PATH, as the plugins tree pins it; flagd from FLAGD, the
// binary an app's `http:flagd` installs, and its test is ignored without one.
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
