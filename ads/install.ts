// Adds or refreshes pronto-ads in a pronto app (bin/pronto-ads):
//   install.ts <app-dir> [<module-path>]
// Regenerated every time, marked as this host's: the page's module (ads.js), at
// <module-path> in the app, ads/ads.js unless named, for the app's page code to
// import; and the generate step giving the door /ads.txt (pronto/ads.cue,
// ads/ads.nu). Written once, then the app's own: its publisher (ads_spec.cue).
const here = new URL(".", import.meta.url).pathname;
const [appArg, at = "ads/ads.js"] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir> [<module-path>]");
const app = appArg.replace(/\/$/, "");
const program = await Deno.readTextFile(`${app}/program.cue`).catch(() => { throw new Error(`${app} has no program.cue: not a pronto app`); });
const pkg = /^package\s+([a-z][a-z0-9_]*)\s*$/m.exec(program)?.[1];
if (!pkg) throw new Error(`${app}/program.cue names no package`);
if (at.startsWith("/") || at.split("/").includes("..")) throw new Error(`${at}: a path inside the app`);

async function write(path: string, text: string, seed = false) {
  const to = `${app}/${path}`;
  const held = await Deno.readTextFile(to).catch(() => null);
  if (held !== null && (seed || held === text)) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-ads: wrote ${path}`);
}
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`)).replaceAll("__PACKAGE__", pkg);

await write(at, await template("ads.js"));
await write("pronto/ads.cue", await template("pronto_ads.cue"));
await write("ads/ads.nu", await template("ads.nu"));
await write("ads_spec.cue", await template("ads_spec.cue"), true);
