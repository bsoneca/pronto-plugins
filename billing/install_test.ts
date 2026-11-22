// The installer writes an app's billing files in its own package, regenerates
// the host's on every run, and leaves the app's spec alone once written.
const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const install = async (app: string, ...args: string[]) => {
  const out = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, app, ...args] }).output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
};

Deno.test("an app gets billing in its own package, and keeps its spec", async () => {
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
  await install(app, "o".repeat(43));
  const plugin = await Deno.readTextFile(`${app}/billing_plugin.cue`);
  eq(plugin.split("\n")[1], "package shop", "the program's package");
  eq(plugin.includes("__PACKAGE__"), false, "no placeholder left");
  eq(plugin.includes("if _billingDoorFlag != \"\" {BILLING_DOOR_FLAG: _billingDoorFlag}"), true, "the door flag reaches the billing service's environment");
  const spec = await Deno.readTextFile(`${app}/billing_spec.cue`);
  eq(spec.includes(`owner:  "${"o".repeat(43)}"`), true, "the owner");
  eq(spec.includes(`_billingTrialMigration: "billing_03"`), true, "the trial's migration is named");
  for (const f of ["billing/service.ts", "billing/broker/main.ts", "billing/billing.nu", "pronto/billing.cue"]) await Deno.stat(`${app}/${f}`);
  // Every module the broker's main.ts reaches (static or dynamic import, not the vendored driver) is
  // installed and in the broker image's copy list, or the broker fails at start (store.ts, PRONTO-371).
  const reached = new Set<string>(), todo = ["billing/broker/main.ts"];
  for (let f = todo.pop(); f; f = todo.pop()) {
    // rules.ts is the app's generate's, from billing_rules.cue, not the installer's.
    if (reached.has(f) || f === "billing/rules.ts") continue;
    reached.add(f);
    const dir = f.replace(/[^/]+$/, "");
    for (const m of (await Deno.readTextFile(`${app}/${f}`)).matchAll(/(?:from|import\()\s*["'](\.{1,2}\/[^"']+\.ts)["']/g)) {
      todo.push(new URL(m[1], `file:///${dir}`).pathname.slice(1));
    }
  }
  for (const f of reached) {
    await Deno.stat(`${app}/${f}`);
    if (f.startsWith("billing/broker/")) eq(plugin.includes(`"${f}"`), true, `${f} is in the broker image's copy list`);
  }
  // store.ts imports the vendored postgres driver for a DATABASE_URL broker: a real file in the app
  // (the plugin's is a symlink) and in the broker image's srcs and copy list.
  const driver = await Deno.lstat(`${app}/billing/broker/vendor/postgres.js`);
  eq(driver.isFile && !driver.isSymlink && driver.size > 0, true, "the postgres driver is a real file in the app");
  eq(plugin.includes(`{srcs: ["billing/broker/vendor/postgres.js"], dst: "/app/billing/broker/vendor/"}`), true, "the driver is in the broker image's copy list");
  eq(plugin.includes(`"billing/broker/vendor/*.js"`), true, "the driver is in the broker target's srcs");
  await Deno.writeTextFile(`${app}/billing_spec.cue`, spec + "// the app's own\n");
  await Deno.writeTextFile(`${app}/billing_plugin.cue`, "edited\n");
  await install(app);
  eq((await Deno.readTextFile(`${app}/billing_spec.cue`)).endsWith("// the app's own\n"), true, "the spec is the app's");
  eq(await Deno.readTextFile(`${app}/billing_plugin.cue`), plugin, "the host's file regenerated");
  await Deno.remove(app, { recursive: true });
});

Deno.test("the installer writes the state lists as a spec package, never the broker's schema into the app, and removes the one an earlier install wrote", async () => {
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
  const dir = `${app}/services/database/migrations`;
  await Deno.mkdir(dir, { recursive: true });
  for (const n of ["005_tables.sql", "790_cutover.sql", "950_fixture.sql"]) await Deno.writeTextFile(`${dir}/${n}`, "-- app\n");
  // What the earlier install wrote, and an app's own file that merely shares the ending.
  await Deno.writeTextFile(`${dir}/960_billing_broker.sql`, await Deno.readTextFile(new URL("./broker/schema.sql", import.meta.url)));
  await Deno.writeTextFile(`${dir}/970_other_billing_broker.sql`, "-- the app's own\n");
  await install(app, "o".repeat(43));
  const rules = await Deno.readTextFile(`${app}/spec/billing_rules.cue`);
  eq(rules.includes("package spec") && rules.includes(`billingTrialStates: ["running", "cancelled", "converted", "ended", "failed"]`) && rules.includes(`billingClaimStates: ["claimed", "done"]`), true, "the lists, from rules.cue");
  eq([...Deno.readDirSync(dir)].map((e) => e.name).sort(), ["005_tables.sql", "790_cutover.sql", "950_fixture.sql", "970_other_billing_broker.sql"], "the broker's schema is not an app migration; the app's own files stay");
  await install(app);
  eq([...Deno.readDirSync(dir)].some((e) => /^9\d\d_billing_broker\.sql$/.test(e.name)), false, "a reinstall writes none");
  await Deno.remove(app, { recursive: true });
});

// PRONTO-1518: the grants name every grantee's account, so the flag that carries them is never one a page reads
// (flags_plugin.cue's `client`, which the door's OFREP serves alone). billing_plugin.cue imports bayt, which needs the
// module registry, so the test evaluates the plugin's own `flags: billing_grants` block with the flags plugin alone,
// the grants stubbed. cue comes from PATH, as the plugins tree pins it.
Deno.test("the flag billing_grants is not a client flag, and an app cannot make it one", async () => {
  const dec = new TextDecoder();
  const plugin = await Deno.readTextFile(new URL("./app/billing_plugin.cue", import.meta.url));
  eq(plugin.includes(`"origin"`), false, "_billingFlags has no origin: through the door billing's flags are not there");
  const from = plugin.indexOf("\tflags: billing_grants: {");
  const block = plugin.slice(from, plugin.indexOf("\n\t}\n", from) + 4);
  eq(from > 0 && block.includes("client: false"), true, "the plugin says billing_grants is not client");
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
  const flags = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("../flags/install.ts", import.meta.url).pathname, app] }).output();
  if (!flags.success) throw new Error(dec.decode(flags.stderr));
  const cue = async (extra: string) => {
    await Deno.writeTextFile(`${app}/flags_spec.cue`, `package shop\n_billingGrants: "[]"\n${block}\n${extra}\n`);
    return await new Deno.Command("cue", { args: ["export", `${app}/flags_plugin.cue`, `${app}/flags_spec.cue`, "-e", "flagd.document.flags.billing_grants", "--out", "json"], stdout: "piped", stderr: "piped" }).output();
  };
  try {
    const ok = await cue("");
    if (!ok.success) throw new Error(dec.decode(ok.stderr));
    eq(JSON.parse(dec.decode(ok.stdout)).metadata, undefined, "billing_grants is in no flag set, so no page reads it");
    eq((await cue("flags: billing_grants: client: true")).success, false, "client: true on billing_grants fails to unify");
  } finally {
    await Deno.remove(app, { recursive: true });
  }
});
