// pronto-identity's installer (bin/pronto-identity) on a stand-in app in a folder of its own: what
// it says, and its exit, before it writes anything.
const bin = new URL('../../bin/pronto-identity', import.meta.url).pathname;

/** The installer's run on an app named `package shop`, with `args`; `signin` its identity_signin.cue
 * from an earlier run, where it has one. */
export async function installed(args = [], signin = null) {
  const dir = await Deno.makeTempDir({ prefix: 'pronto-identity-' });
  await Deno.writeTextFile(`${dir}/program.cue`, 'package shop\n');
  if (signin !== null) await Deno.writeTextFile(`${dir}/identity_signin.cue`, signin);
  const out = await new Deno.Command('sh', { args: [bin, dir, ...args], stdout: 'piped', stderr: 'piped' }).output();
  const files = [];
  for await (const e of Deno.readDir(dir)) files.push(e.name);
  await Deno.remove(dir, { recursive: true });
  return { exit: out.code, said: new TextDecoder().decode(out.stderr), files: files.sort() };
}
