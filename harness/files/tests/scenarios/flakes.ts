// Files a flake on the board (tests/scenarios.ts, schema.cue's `flakes`). A flake is filed only for a scenario that
// stays failed, so the run already exits 1 and nothing is hidden from the gate; but a flake that is never filed is
// lost (no marker, no record, filed again only if the scenario flakes again), so a board that refuses (or is missing)
// is said first, with its whole error and a GitHub warning, and then thrown. The runner collects what filing throws and
// throws it once its selection commit and report are done (scenarios.ts), so the throw cuts nothing short. No marker is
// written then, so the next run tries again. A filed flake whose marker cannot be written is thrown too: an unwritten
// marker would file the same flake every run.
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
}): Promise<{ filed: true; said: string }> {
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
    throw new Error(`flake ${o.id} not filed: the board said: ${error}`);
  }
  const said = out.stdout.trim().split("\n").at(-1) ?? "";
  say(`  filed: ${said}`);
  await Deno.mkdir(o.marks, { recursive: true });
  await Deno.writeTextFile(`${o.marks}/${o.id}`, said);
  return { filed: true, said };
}
