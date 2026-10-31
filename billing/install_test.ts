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
  const spec = await Deno.readTextFile(`${app}/billing_spec.cue`);
  eq(spec.includes(`owner:  "${"o".repeat(43)}"`), true, "the owner");
  for (const f of ["billing/service.ts", "billing/broker/main.ts", "billing/billing.nu", "pronto/billing.cue"]) await Deno.stat(`${app}/${f}`);
  await Deno.writeTextFile(`${app}/billing_spec.cue`, spec + "// the app's own\n");
  await Deno.writeTextFile(`${app}/billing_plugin.cue`, "edited\n");
  await install(app);
  eq((await Deno.readTextFile(`${app}/billing_spec.cue`)).endsWith("// the app's own\n"), true, "the spec is the app's");
  eq(await Deno.readTextFile(`${app}/billing_plugin.cue`), plugin, "the host's file regenerated");
  await Deno.remove(app, { recursive: true });
});
