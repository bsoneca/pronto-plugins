// The installer writes an app's flags files in its own package, regenerates
// the host's on every run, and leaves the app's spec alone once written.
const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const install = async (app: string) => {
  const out = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, app] }).output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
};

Deno.test("an app gets flags in its own package, and keeps its spec", async () => {
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
  await install(app);
  const plugin = await Deno.readTextFile(`${app}/flags_plugin.cue`);
  eq(plugin.split("\n")[1], "package shop", "the program's package");
  eq(plugin.includes("__PACKAGE__"), false, "no placeholder left");
  const spec = await Deno.readTextFile(`${app}/flags_spec.cue`);
  eq(spec.split("\n")[0], "package shop", "the spec's package");
  for (const f of ["flags/flags.nu", "pronto/flags.cue"]) await Deno.stat(`${app}/${f}`);
  await Deno.writeTextFile(`${app}/flags_spec.cue`, spec + "// the app's own\n");
  await Deno.writeTextFile(`${app}/flags_plugin.cue`, "edited\n");
  await install(app);
  eq((await Deno.readTextFile(`${app}/flags_spec.cue`)).endsWith("// the app's own\n"), true, "the spec is the app's");
  eq(await Deno.readTextFile(`${app}/flags_plugin.cue`), plugin, "the host's file regenerated");
  await Deno.remove(app, { recursive: true });
});

Deno.test("an app whose program names no package is refused", async () => {
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "// nothing\n");
  let refused = false;
  try { await install(app); } catch { refused = true; }
  eq(refused, true, "refused");
  await Deno.remove(app, { recursive: true });
});
