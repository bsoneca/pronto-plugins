// The installer writes the page's module where the app asks, and the generate
// step, again over an edit, and the app's spec once; it refuses a directory that
// is no pronto app, and a path out of the app.
const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const install = (...args: string[]) => new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, ...args] }).output();
const module = await Deno.readTextFile(new URL("./app/ads.js", import.meta.url));

Deno.test("an app gets the module, at ads/ads.js or where it names, regenerated", async () => {
  const app = await Deno.makeTempDir();
  await Deno.writeTextFile(`${app}/program.cue`, "package shop\n");
  eq((await install(app)).success, true, "installed");
  eq(await Deno.readTextFile(`${app}/ads/ads.js`), module, "the module");
  await Deno.writeTextFile(`${app}/ads/ads.js`, "edited\n");
  await install(app);
  eq(await Deno.readTextFile(`${app}/ads/ads.js`), module, "the host's file regenerated");
  await install(app, "web/src/ads.js");
  eq(await Deno.readTextFile(`${app}/web/src/ads.js`), module, "where the app names");
  for (const f of ["pronto/ads.cue", "ads/ads.nu", "pronto/exports.nu"]) await Deno.stat(`${app}/${f}`);
  const spec = await Deno.readTextFile(`${app}/ads_spec.cue`);
  eq(spec.split("\n")[0], "package shop", "the spec in the program's package");
  await Deno.writeTextFile(`${app}/ads_spec.cue`, spec + "// the app's own\n");
  await install(app);
  eq((await Deno.readTextFile(`${app}/ads_spec.cue`)).endsWith("// the app's own\n"), true, "the spec is the app's");
  await Deno.remove(app, { recursive: true });
});

Deno.test("no pronto app, or a path out of it, is refused", async () => {
  const dir = await Deno.makeTempDir();
  eq((await install(dir)).success, false, "no program.cue");
  await Deno.writeTextFile(`${dir}/program.cue`, "package shop\n");
  eq((await install(dir, "../x.js")).success, false, "out of the app");
  await Deno.writeTextFile(`${dir}/program.cue`, "// nothing\n");
  eq((await install(dir)).success, false, "a program that names no package");
  await Deno.writeTextFile(`${dir}/program.cue`, "package shop\n");
  eq((await install(dir, "/tmp/x.js")).success, false, "an absolute path");
  await Deno.remove(dir, { recursive: true });
});

Deno.test("a provider that fails settles none, reported, and never rejects", async () => {
  const g = globalThis as any;
  const reported: unknown[] = [];
  const dialog = { dataset: {}, style: {}, append() {}, setAttribute() {}, addEventListener() {}, remove() {}, close() {}, showModal() { throw new Error("provider down"); } };
  g.document = { createElement: () => ({ ...dialog, showModal: dialog.showModal }), body: { append() {} } };
  g.reportError = (e: unknown) => reported.push(e);
  const { rewarded } = await import(new URL("./app/ads.js", import.meta.url).href);
  eq(await rewarded(), "none", "the failure is none, not a rejection");
  eq(rewarded.reason, "provider down", "its reason");
  eq(reported.length, 1, "reported once");
  eq((reported[0] as Error).message, "provider down", "the error reported");
  eq(await rewarded(), "none", "the next ask tries again, it is not stuck on the failure");
  eq(reported.length, 2, "and reports again");
  delete g.document; delete g.reportError;
});
