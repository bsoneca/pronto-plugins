// The billing suite's measures: a plan name vetted against the very `name:` line of
// billing/app/billing_plugin.cue (with billing/rules.cue as _billingRules), through the `cue` on the PATH,
// so the broker's parsePublished and the CUE spec are tried on the same inputs.
const root = new URL('../../billing/', import.meta.url).pathname;

/** Whether the app's CUE spec accepts `name` as a plan's name. */
export async function cueAccepts(name) {
  const plugin = await Deno.readTextFile(`${root}app/billing_plugin.cue`);
  const line = /^\s*name:\s+((?:=~|strings\.).*)$/m.exec(plugin);
  if (line === null) throw new Error('no plan name constraint in billing_plugin.cue');
  const dir = await Deno.makeTempDir({ prefix: 'billing-name-' });
  try {
    const rules = (await Deno.readTextFile(`${root}rules.cue`)).replace(/^package billing$/m, 'package billing\n\nimport "strings"\n');
    await Deno.writeTextFile(`${dir}/rules.cue`, `${rules}\n_billingRules: rules\n#Name: ${line[1]}\nname: #Name\nname: ${JSON.stringify(name)}\n`);
    const out = await new Deno.Command('cue', { args: ['vet', `${dir}/rules.cue`], stdout: 'null', stderr: 'null' }).output();
    return out.success;
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

/** Whether the broker accepts `name` as a plan's name in a published document. */
export async function brokerAccepts(name) {
  const { parsePublished } = await import('../../billing/broker/core.ts');
  const r = parsePublished({ owner: 'o'.repeat(43), plans: { a: { name, interval: 'month', prices: { usd: 499 } } } });
  return r.ok;
}

/** Both accept (true), both refuse (false), or they disagree (throws). */
export async function accepted(name) {
  const [cue, broker] = [await cueAccepts(name), await brokerAccepts(name)];
  if (cue !== broker) throw new Error(`cue ${cue ? 'accepts' : 'refuses'} but the broker ${broker ? 'accepts' : 'refuses'} ${JSON.stringify(name)}`);
  return cue;
}

/** A plan name as the broker keeps it. */
export async function kept(name) {
  const { parsePublished } = await import('../../billing/broker/core.ts');
  const r = parsePublished({ owner: 'o'.repeat(43), plans: { a: { name, interval: 'month', prices: { usd: 499 } } } });
  return r.ok ? r.published.plans.a.name : null;
}
