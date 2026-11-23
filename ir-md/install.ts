// Adds or refreshes the ir.md step in a pronto app (bin/pronto-ir-md):
//   install.ts <app-dir>
// Writes pronto/ir_md.cue (the generate step) and ir-md/ir-md.ts (the writer it runs), each marked as
// this host's. The app's next generate writes ir.md beside ir.html.
const here = new URL(".", import.meta.url).pathname;
const [appArg] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir>");
const app = appArg.replace(/\/$/, "");

async function write(path: string, text: string) {
  const to = `${app}/${path}`;
  if ((await Deno.readTextFile(to).catch(() => null)) === text) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-ir-md: wrote ${path}`);
}

await write("pronto/ir_md.cue", await Deno.readTextFile(`${here}app/pronto_ir_md.cue`));
await write("ir-md/ir-md.ts", `// copied by pronto-ir-md from ir-md/ir-md.ts — do not edit\n${await Deno.readTextFile(`${here}ir-md.ts`)}`);
