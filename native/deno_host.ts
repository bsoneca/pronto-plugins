// The battery on the headless engine every host is compared with: Deno's, under the SES the phones load.
//   deno run --no-config --allow-read --allow-env native/deno_host.ts <battery.json>
// <battery.json> is `cue export ./native -e battery --out json`. Prints the runner's answers as JSON. It runs in a
// process of its own because lockdown() freezes the intrinsics of the realm it runs in.
import { memoryKv, run } from "./battery.js";
import * as passkeys from "../android/template/terminal/passkeys.js";

const ses = Deno.readTextFileSync(new URL("../android/template/app/src/main/assets/ses.umd.min.js", import.meta.url));
const cases = JSON.parse(Deno.readTextFileSync(Deno.args[0]));

const indirect = eval;
indirect(ses);
indirect('lockdown({ errorTaming: "unsafe" })');

const engine = {
  define(name: string, fn: unknown) {
    (globalThis as Record<string, unknown>)[name] = fn;
  },
  eval(source: string): string {
    return indirect(source) as string;
  },
};

// Deno has no sealed store: the headless engine's storage bridges are the contract's behaviour in memory.
for (const [name, fn] of Object.entries(memoryKv())) engine.define(name, fn);

console.log(JSON.stringify(run({ engine, passkeys, cases })));
