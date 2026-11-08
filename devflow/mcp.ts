// The Plane MCP server (makeplane/plane-mcp-server) for a repository's board, so Claude Code reads and
// edits work items: started over stdio with the board's address and workspace from devflow/devflow.cue
// and its token from PLANE_TOKEN or Secret Manager, so a repository's .mcp.json names neither.
//   mcp.ts <repo>
import { devflowOf, tokenOf } from "./spec.ts";

const repo = Deno.args[0] ? await Deno.realPath(Deno.args[0]) : "";
const flow = repo ? await devflowOf(repo) : null;
if (!flow) {
  console.error(`devflow mcp: ${repo || "(no repo)"} has no devflow/devflow.cue`);
  Deno.exit(2);
}
const token = await tokenOf(flow);
if (!token) {
  console.error("devflow mcp: no board token (PLANE_TOKEN or Secret Manager): bin/pronto connect plane says how to make one");
  Deno.exit(2);
}
// The server's release pinned, as every tool is.
const server = "plane-mcp-server==0.3.4";
const p = new Deno.Command("uvx", {
  args: [server, "stdio"],
  env: { PLANE_API_KEY: token, PLANE_WORKSPACE_SLUG: flow.plane.workspace, PLANE_BASE_URL: `https://${flow.plane.host}` },
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
}).spawn();
Deno.exit((await p.status).code);
