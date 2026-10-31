// What an intent's command line runs on the machine: a command, and the app's own sayt verbs.

/** A command run to its end: whether it passed, and what it said. */
export async function cmd(c: string, args: string[], opts: { cwd?: string; stdin?: string; env?: Record<string, string> } = {}) {
  const p = new Deno.Command(c, { args, cwd: opts.cwd, ...(opts.env ? { env: opts.env, clearEnv: true } : {}), stdin: opts.stdin === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
  if (opts.stdin !== undefined) {
    const w = p.stdin.getWriter();
    await w.write(new TextEncoder().encode(opts.stdin));
    await w.close();
  }
  const o = await p.output();
  const text = (b: Uint8Array) => new TextDecoder().decode(b);
  return { ok: o.success, out: text(o.stdout), err: text(o.stderr) };
}

/** A sayt verb in the app's folder, with the app's own toolchain: this runs under the plugins'
 * saytw, whose SAYT_VERSION and mise state would otherwise pin the app's saytw to the plugins'
 * sayt. What it says is what went wrong, not mise's echo of each command it ran; `full` is all of
 * it, for a verb whose output is read (a release prints its address). */
export async function appSaytw(dir: string, verb: string, env: Record<string, string> = {}) {
  const own = Object.fromEntries(Object.entries(Deno.env.toObject()).filter(([k]) => !k.startsWith("SAYT_") && !/^MISE_(?!TRUSTED_CONFIG_PATHS$)/.test(k) && !k.startsWith("__MISE")));
  const r = await cmd("./saytw", [verb], { cwd: dir, env: { ...own, ...env } });
  const said = (r.out + r.err).split("\n").filter((l) => l.trim() && !/mise (tool-stub|exec)|^echo \|/.test(l));
  return { ok: r.ok, out: said.filter((l) => /error|Error|✗|conflict|failed/.test(l)).slice(0, 6).join("\n") || said.slice(-6).join("\n"), full: r.out + r.err };
}

/** The flags after an intent's app folder, `--name value` each; a flag followed by another flag,
 * or by nothing, is a switch, "true". */
export function flagsOf(rest: readonly string[]): Record<string, string> {
  const flags: Record<string, string> = {};
  for (let i = 0; i < rest.length; i++) {
    if (!rest[i].startsWith("--")) throw new Error(`a flag and its value: ${rest[i]}`);
    const next = rest[i + 1];
    flags[rest[i].slice(2)] = next === undefined || next.startsWith("--") ? "true" : (i++, next);
  }
  return flags;
}
