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

// The page's module says which commit of pronto-plugins it was generated from (the last to touch its
// template), so a reader of an app's diff sees generator output and not a hand edit. Left as the template
// has it where this is no git checkout.
async function stamped(text: string) {
  const out = await new Deno.Command("git", { args: ["-C", here, "log", "-1", "--format=%h", "--", "app/ads.js"], stdout: "piped", stderr: "null" }).output().catch(() => null);
  const sha = out?.success ? new TextDecoder().decode(out.stdout).trim() : "";
  return sha ? text.replace("// Written by pronto-ads; regenerated, do not edit.", `// Written by pronto-ads, generated from bsoneca/pronto-plugins@${sha} (ads/app/ads.js); regenerated, do not edit.`) : text;
}
await write(at, await stamped(await template("ads.js")));
await write("pronto/ads.cue", await template("pronto_ads.cue"));
await write("ads/ads.nu", await template("ads.nu"));
// One copy of the program's exports for all the plugins that read them (common/exports.nu).
await write("pronto/exports.nu", await Deno.readTextFile(`${here}../common/exports.nu`));
await write("ads_spec.cue", await template("ads_spec.cue"), true);
