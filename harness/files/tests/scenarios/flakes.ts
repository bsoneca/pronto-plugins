// Files a flake on the board (tests/scenarios.ts, schema.cue's `flakes`). Filing is bookkeeping (PRONTO-649, the
// owner's call): a flake is filed only for a scenario that stays failed, so every run that gets here already exits 1
// and nothing is hidden from the gate. A board that refuses (or is missing), or a marker that cannot be written, is
// therefore said, with its whole error and a GitHub warning, and never thrown: a throw only cut the run's report and
// its selection commit short. No marker is written then, so the next run tries again.
export type Spawned = { success: boolean; stdout: string; stderr: string };
export type Spawn = (cmd: string, args: string[], env: Record<string, string>) => Promise<Spawned>;

export const spawn: Spawn = async (cmd, args, env) => {
  const o = await new Deno.Command(cmd, { args, env, stdout: "piped", stderr: "piped" }).output();
  return { success: o.success, stdout: new TextDecoder().decode(o.stdout), stderr: new TextDecoder().decode(o.stderr) };
};

// GitHub's workflow-command escapes for an annotation's message.
const escape = (s: string) => s.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");

export async function fileFlake(o: {
  id: string; cmd: string; args: string[]; marks: string; env?: Record<string, string>;
  run?: Spawn; say?: (line: string) => void; github?: boolean;
}): Promise<{ filed: true; said: string } | { filed: false; error: string }> {
  const say = o.say ?? console.log;
  let out: Spawned;
  try {
    out = await (o.run ?? spawn)(o.cmd, o.args, o.env ?? {});
  } catch (e) {
    out = { success: false, stdout: "", stderr: e instanceof Error ? e.message : String(e) };
  }
  if (!out.success) {
    const error = out.stderr.trim() || "(no error output)";
    say(`  ⚠ flake ${o.id} not filed: the board said:\n${error.split("\n").map((l) => `    | ${l}`).join("\n")}`);
    if (o.github) say(`::warning title=flake not filed::${escape(`flake ${o.id} not filed: the board said: ${error}`)}`);
    return { filed: false, error };
  }
  const said = out.stdout.trim().split("\n").at(-1) ?? "";
  try {
    await Deno.mkdir(o.marks, { recursive: true });
    await Deno.writeTextFile(`${o.marks}/${o.id}`, said);
  } catch (e) {
    const error = e instanceof Error ? e.message : String(e);
    say(`  filed: ${said}, but its marker was not written (${error}): the next run files it again`);
    if (o.github) say(`::warning title=flake marker not written::${escape(`flake ${o.id} filed as ${said}, marker not written: ${error}`)}`);
    return { filed: true, said };
  }
  say(`  filed: ${said}`);
  return { filed: true, said };
}
