// pronto-api's generator (api/generate.ts) and its lint (api/lint.ts) on a stand-in app: the
// fixture (tests/unit/api-fixture/, two entities) copied to a folder of its own with the plugin's
// api_plugin.cue beside it, as an install would leave it, then edited, generated, released and
// held to its release, step by step. cue and buf are the ones on PATH, or CUE and BUF.
import { breaking as bufBreaking, generate } from '../../api/generate.ts';
import { named } from '../../api/lint.ts';
import { serve } from '../../api/service.ts';

const here = new URL('.', import.meta.url).pathname;

/** A fresh copy of the fixture app, its path. */
export async function app() {
  const dir = await Deno.makeTempDir({ prefix: 'api-app-' });
  for await (const e of Deno.readDir(`${here}api-fixture`)) await Deno.copyFile(`${here}api-fixture/${e.name}`, `${dir}/${e.name}`);
  const plugin = await Deno.readTextFile(`${here}../../api/app/api_plugin.cue`);
  await Deno.writeTextFile(`${dir}/api_plugin.cue`, plugin.replaceAll('__PACKAGE__', 'fixture'));
  return dir;
}

/** `from` replaced by `to` in the app's `file` (it must be there); the app's path. */
export async function edit(dir, file, from, to) {
  const text = await Deno.readTextFile(`${dir}/${file}`);
  if (!text.includes(from)) throw new Error(`${file} has no ${JSON.stringify(from)}`);
  await Deno.writeTextFile(`${dir}/${file}`, text.replace(from, to));
  return dir;
}

/** The contract generated in the app: the .proto's text, the routes and the lock. */
export const generated = (dir) => generate(dir);

/** The descriptor set generated last, frozen as the release's; the app's path. */
export async function release(dir) {
  await Deno.copyFile(`${dir}/api/v1/descriptor.binpb`, `${dir}/api/v1/released.binpb`);
  return dir;
}

/** Whether `buf breaking` holds the generated descriptor set to the release, and what it said. */
export const breaking = (dir) => bufBreaking(dir);

/** The generated descriptor set and routes, served by the service as an app would (each of the
 * services' methods given a stand-in): "served" once it started on them. */
export async function served(dir) {
  const routes = JSON.parse(await Deno.readTextFile(`${dir}/api/v1/routes.json`));
  const impl = {};
  for (const r of routes) {
    const [svc, method] = r.rpc.split('/');
    (impl[svc] ??= {})[method[0].toLowerCase() + method.slice(1)] = () => ({});
  }
  const s = await serve({ descriptors: await Deno.readFile(`${dir}/api/v1/descriptor.binpb`), routes, impl, flag: () => Promise.resolve(true) });
  await s.close();
  return 'served';
}

/** The plugin's api/ (or a copy with `planted` written into a file of its own) held to the lint. */
export async function linted(words, planted) {
  const api = `${here}../../api`;
  if (planted === undefined) return await named(api, words);
  const dir = await Deno.makeTempDir({ prefix: 'api-lint-' });
  await new Deno.Command('cp', { args: ['-R', `${api}/.`, dir] }).output();
  await Deno.writeTextFile(`${dir}/planted.ts`, `export const table = "${planted}";\n`);
  return await named(dir, words);
}
