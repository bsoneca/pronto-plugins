// Adds or refreshes pronto-flags in a pronto app (bin/pronto-flags):
//   install.ts <app-dir>
// Regenerated every time, each marked as this host's: the flags' schema, flagd's
// definitions and its target (flags_plugin.cue), flagd's tool and the generate
// step (pronto/flags.cue, flags/flags.nu). Written once, then the app's own: its
// flags (flags_spec.cue).
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
  console.log(`pronto-flags: wrote ${path}`);
}
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`)).replaceAll("__PACKAGE__", pkg);

await write("flags_plugin.cue", await template("flags_plugin.cue"));
await write("pronto/flags.cue", await template("pronto_flags.cue"));
await write("flags/flags.nu", await template("flags.nu"));
await write("flags_spec.cue", await template("flags_spec.cue"), true);
