// What the journeys tests share: cue run as a process, and the two asserts.

export const assertEquals = (actual: unknown, expected: unknown, context = "") => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}${context ? `\n${context}` : ""}`);
  }
};

export const assertStringIncludes = (actual: string, expected: string) => {
  if (!actual.includes(expected)) throw new Error(`expected ${JSON.stringify(expected)} in:\n${actual}`);
};

// stdout when cue succeeds, stderr when it refuses.
export async function cue(args: string[], stdin?: string): Promise<{ ok: boolean; out: string }> {
  const child = new Deno.Command("cue", { args, stdin: stdin === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
  if (stdin !== undefined) {
    const writer = child.stdin.getWriter();
    await writer.write(new TextEncoder().encode(stdin));
    await writer.close();
  }
  const result = await child.output();
  const decode = (b: Uint8Array) => new TextDecoder().decode(b);
  return { ok: result.success, out: result.success ? decode(result.stdout) : decode(result.stderr) };
}
