// The scenarios of an app, as CUE exports them: the one place that finds tests/scenarios/*.cue, runs `cue export` on
// them and reads the result, for the runner (tests/scenarios.ts) and for a caller that plans from the same set (a
// rehearsal's order of pass 1), so none copies it.
export type Step = Record<string, any> & { by?: string; timeout?: number; why?: string };
export type ActorDef = { name: string; device?: string; locale?: string } & Record<string, any>;
export type Scenario = { id: string; slow?: true; accepts: string[]; actors: Record<string, ActorDef>; steps: Step[]; flags?: string[]; production?: true; standin?: true };
export type Screen = { viewport?: { width: number; height: number }; device?: string };
export type Spec = {
  parallel: number;
  deployedParallel: number;
  flakes: { app?: string; priority: string; file: string[]; retry: boolean };
  screen: Screen;
  screens?: Record<string, Screen>;
  locale: string;
  messages: string;
  loaded: { screen?: string; adopted: boolean };
  select: { client: string[]; derived: string[]; inert: string[]; live: string[]; outside: string[] };
  database?: string;
  signIn?: { open: string[]; passkey: string };
  scenarios: Record<string, Scenario>;
};

// The CUE files of a scenarios folder, from the names it holds: those ending in .cue, each as the folder's path and
// its name, sorted. `dir` ends in a slash or is given without one.
export const scenarioFiles = (dir: string, names: string[]): string[] => {
  const base = dir.endsWith("/") ? dir : dir + "/";
  return names.filter((n) => n.endsWith(".cue")).map((n) => base + n).sort();
};

// `cue export` of the folder's scenarios (the binary CUE names, else cue on the PATH), parsed. An aborted signal or an
// elapsed timeoutMs kills the cue child and rejects, saying so.
export const loadScenarios = async (dir: string, opts: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<Spec> => {
  const files = scenarioFiles(dir, [...Deno.readDirSync(dir)].map((f) => f.name));
  const signals = [opts.signal, opts.timeoutMs === undefined ? undefined : AbortSignal.timeout(opts.timeoutMs)].filter((s): s is AbortSignal => !!s);
  const signal = signals.length ? AbortSignal.any(signals) : undefined;
  const stopped = () => new Error(`the scenarios export was stopped (${opts.signal?.aborted ? "aborted" : `no answer in ${opts.timeoutMs} ms`}), cue was killed`);
  let exported;
  try {
    exported = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["export", ...files, "--out", "json"], stdout: "piped", stderr: "piped", signal }).output();
  } catch (e) {
    if (signal?.aborted) throw stopped();
    throw e;
  }
  // A killed child may come back as a failed exit, not a throw.
  if (signal?.aborted) throw stopped();
  if (!exported.success) throw new Error("the scenarios do not export: " + new TextDecoder().decode(exported.stderr));
  return JSON.parse(new TextDecoder().decode(exported.stdout)) as Spec;
};
