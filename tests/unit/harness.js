// The harness's flake filing (harness/files/tests/scenarios/flakes.ts) on a fake board: one that
// refuses, one that is missing, one that files. Each call is one filing into a fresh marks folder.
import { fileFlake } from "../../harness/files/tests/scenarios/flakes.ts";
// The scenario selector's rule for files outside the app (select.ts), called by the cases as harness.outsideConcerns.
import { outsideConcerns, outsideKeys as keys } from "../../harness/files/tests/scenarios/select.ts";
export { outsideConcerns };
// outsideKeys with a hash that is the file's name, so a case can name what it keys.
export const outsideKeys = (files, reads) => keys(files, (f) => `h:${f}`, reads);

async function filing(run, github = false) {
  const marks = await Deno.makeTempDir();
  const said = [];
  try {
    const r = await fileFlake({ id: "demo", cmd: "board", args: [], marks, run, github, say: (l) => said.push(l) }).then((r) => ({ threw: false, filed: r.filed, error: null }), (e) => ({ threw: true, filed: null, error: e.message }));
    const marker = await Deno.readTextFile(`${marks}/demo`).catch(() => null);
    return { ...r, marker, said };
  } finally { await Deno.remove(marks, { recursive: true }); }
}
export const refused = (github) => filing(() => Promise.resolve({ success: false, stdout: "", stderr: "Error: board said no\n    at async board.ts:19:21\n" }), github);
export const missing = () => filing(() => Promise.reject(new Deno.errors.NotFound("board: command not found")));
export const accepted = () => filing(() => Promise.resolve({ success: true, stdout: "noise\nPRONTO-700 https://board/PRONTO-700\n", stderr: "" }));
// A board that files, but a marks folder that cannot be made (a file stands where it would go).
export async function unmarked() {
  const blocker = await Deno.makeTempFile();
  const said = [];
  try {
    return await fileFlake({ id: "demo", cmd: "board", args: [], marks: `${blocker}/marks`, say: (l) => said.push(l), run: () => Promise.resolve({ success: true, stdout: "PRONTO-700\n", stderr: "" }) })
      .then((r) => ({ threw: false, filed: r.filed, said: said.length }), () => ({ threw: true, said: said.length }));
  } finally { await Deno.remove(blocker); }
}
