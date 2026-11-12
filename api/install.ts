// Adds or refreshes pronto-api in a pronto app (bin/pronto-api):
//   install.ts <app-dir>
// Regenerated every time, each marked as this host's: the spec's schema and the contract
// (api_plugin.cue), the generator (api/generate.ts) and the generate steps that run it
// (pronto/api.cue). Written once, then the app's own: its spec (api_spec.cue). The app lists
// api/v1/api_v1.sql among its raw migrations, after its flags' SQL, and declares the spec's flag
// in flags_spec.cue.
const here = new URL(".", import.meta.url).pathname;
const [appArg] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir>");
const app = appArg.replace(/\/$/, "");
const program = await Deno.readTextFile(`${app}/program.cue`);
const pkg = /^package\s+([a-z][a-z0-9_]*)\s*$/m.exec(program)?.[1];
if (!pkg) throw new Error(`${app}/program.cue names no package`);

async function write(path: string, text: string, seed = false) {
  const to = `${app}/${path}`;
  const held = await Deno.readTextFile(to).catch(() => null);
  if (held !== null && (seed || held === text)) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-api: wrote ${path}`);
}
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`)).replaceAll("__PACKAGE__", pkg);

await write("api_plugin.cue", await template("api_plugin.cue"));
await write("pronto/api.cue", await template("pronto_api.cue"));
await write("api/generate.ts", `// copied by pronto-api from api/generate.ts — do not edit\n${await Deno.readTextFile(`${here}generate.ts`)}`);
await write("api_spec.cue", await template("api_spec.cue"), true);
