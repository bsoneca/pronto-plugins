// Adds or refreshes the keys service in a pronto app (bin/pronto-keys):
//   install.ts <app-dir>
// Regenerated every time, each marked as this host's: the target and the door's env (keys_plugin.cue), the generate
// step (pronto/keys.cue), the service (keys/keys.ts, keys/main.ts, keys/vendor/postgres.js) and the generator of the
// door's routes (keys/route.ts). The app's own settings (keysGate, keysHook, keysDb) are CUE it adds beside them.
const here = new URL(".", import.meta.url).pathname;
const [appArg] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir>");
const app = appArg.replace(/\/$/, "");
const program = await Deno.readTextFile(`${app}/program.cue`);
const pkg = /^package\s+([a-z][a-z0-9_]*)\s*$/m.exec(program)?.[1];
if (!pkg) throw new Error(`${app}/program.cue names no package`);

async function write(path: string, text: string) {
  const to = `${app}/${path}`;
  if ((await Deno.readTextFile(to).catch(() => null)) === text) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-keys: wrote ${path}`);
}
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`)).replaceAll("__PACKAGE__", pkg);
const copy = async (name: string) => `// copied by pronto-keys from identity/keys/${name} — do not edit\n${await Deno.readTextFile(`${here}${name}`)}`;

await write("keys_plugin.cue", await template("keys_plugin.cue"));
await write("pronto/keys.cue", await template("pronto_keys.cue"));
for (const f of ["keys.ts", "main.ts", "route.ts"]) await write(`keys/${f}`, await copy(f));
// Deno reads the vendored client through the link in this repository; the app gets the file.
await write("keys/vendor/postgres.js", await Deno.readTextFile(`${here}vendor/postgres.js`));
