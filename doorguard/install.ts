// Adds or refreshes the door's Dapr guard in a pronto app (bin/pronto-doorguard):
//   install.ts <app-dir>
// Writes pronto/doorguard.cue (the generate step) and doorguard/guard.ts (the generator it runs),
// each marked as this host's. The app's next generate splices the block into docker/Caddyfile.
const here = new URL(".", import.meta.url).pathname;
const [appArg] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir>");
const app = appArg.replace(/\/$/, "");

async function write(path: string, text: string) {
  const to = `${app}/${path}`;
  if ((await Deno.readTextFile(to).catch(() => null)) === text) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-doorguard: wrote ${path}`);
}

await write("pronto/doorguard.cue", await Deno.readTextFile(`${here}app/pronto_doorguard.cue`));
await write("doorguard/guard.ts", `// copied by pronto-doorguard from doorguard/guard.ts — do not edit\n${await Deno.readTextFile(`${here}guard.ts`)}`);
