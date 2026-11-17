// The harness's flake filing (harness/files/tests/scenarios/flakes.ts) on a fake board: one that
// refuses, one that is missing, one that files. Each call is one filing into a fresh marks folder.
import { fileFlake } from "../../harness/files/tests/scenarios/flakes.ts";

async function filing(run, github = false) {
  const marks = await Deno.makeTempDir();
  const said = [];
  try {
    const threw = await fileFlake({ id: "demo", cmd: "board", args: [], marks, run, github, say: (l) => said.push(l) }).then(() => false, () => true);
    const result = await fileFlake({ id: "demo", cmd: "board", args: [], marks, run, github, say: () => {} });
    const marker = await Deno.readTextFile(`${marks}/demo`).catch(() => null);
    return { threw, filed: result.filed, marker, said };
  } finally { await Deno.remove(marks, { recursive: true }); }
}
export const refused = (github) => filing(() => Promise.resolve({ success: false, stdout: "", stderr: "Error: board said no\n    at async board.ts:19:21\n" }), github);
export const missing = () => filing(() => Promise.reject(new Deno.errors.NotFound("board: command not found")));
export const accepted = () => filing(() => Promise.resolve({ success: true, stdout: "noise\nPRONTO-700 https://board/PRONTO-700\n", stderr: "" }));
