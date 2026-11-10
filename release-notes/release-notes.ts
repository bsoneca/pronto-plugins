// release-notes: after an app's release goes live, a GitHub Release on the app's repo, tagged
// <app>/<revision> on the released commit. pronto-plugins' release-notes/README.md says more. Run
// from the app's folder, where it is written:
//   deno run -A release-notes/release-notes.ts <app> publish [<revision>]   the newest live revision's Release (or the named one's)
//   deno run -A release-notes/release-notes.ts <app> backfill               every live revision's, oldest first
// --dry prints each Release's title and body and touches nothing on GitHub. A Release is made or,
// when its tag has one, edited: never deleted, no tag moved. The changes are the pull requests of the
// app's folder between the previous live release and this one (git log --first-parent), each in
// plain words from the app's model (Ollama by default, qwen3-coder:30b; Claude; or none), or from
// notes.js's rules when it cannot answer. The app's release_notes.cue (README.md) says where the live
// releases are read from, the time zone, the model and the audience; without one, release-cron's records
// under release.cue's GCP.name, Brasília, the local model and players. A pull request's words are kept in
// ~/.cache/pronto/release-notes/<app>/prs.json, so a re-run says the same.
import { answer, body, fallback, fromDeployments, fromTags, prNumbers, prompt, releases, tag, title } from "./notes.js";

const here = new URL("./", import.meta.url).pathname;
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
const sh = (cmd: string, args: string[], cwd?: string, env: Record<string, string> = {}) => {
  const o = new Deno.Command(cmd, { args, cwd, env, stdin: "null", stdout: "piped", stderr: "piped" }).outputSync();
  return { ok: o.success, out: decode(o.stdout).trim(), err: decode(o.stderr).trim() };
};
// The app's folder from the repository's root (apps/brawl-chess): the one this script was written
// into, the same in every checkout, the run's worktree too.
const top = sh("git", ["rev-parse", "--show-toplevel"], here).out;
const appDir = Deno.realPathSync(`${here}..`);
const appRel = appDir.slice(Deno.realPathSync(top).length + 1);
const flags = Deno.args.filter((a) => a.startsWith("--"));
const [app, verb = "publish", wanted] = Deno.args.filter((a) => !a.startsWith("--"));
const dry = flags.includes("--dry");
const usage = (m: string): never => { console.error(`release-notes: ${m}`); Deno.exit(2); };
if (!app) usage("name the app: release-notes.ts <app> publish [<revision>] | backfill [--dry]");
if (verb !== "publish" && verb !== "backfill") usage(`${verb}: publish or backfill`);
if (flags.some((f) => f !== "--dry")) usage(`unknown flag ${flags.find((f) => f !== "--dry")}`);
const home = Deno.env.get("HOME")!;
const jsonl = (f: string) => { try { return Deno.readTextFileSync(f).split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };

// What the app chose (release_notes.cue, held to #Notes with its defaults by release_notes_plugin.cue): the two
// files alone, as the whole package takes a minute to export. mise, as the shell finds it or the newest sayt has
// installed (which ./saytw installs), runs the app's own cue there (`mise exec -- cue`): pronto's runtime puts its
// memory-budget wrapper first, and called by the path `mise which cue` names it finds no real cue behind it. Without
// mise, cue on the PATH.
const newest = (dirs: string[]) => {
  const found: { dir: string; v: number[] }[] = [];
  for (const d of dirs) {
    try {
      for (const e of Deno.readDirSync(d)) {
        const m = e.name.match(/^mise-v(\d+(?:\.\d+)*)$/);
        if (m) { try { Deno.statSync(`${d}/${e.name}/mise`); found.push({ dir: `${d}/${e.name}/mise`, v: m[1].split(".").map(Number) }); } catch { /* not installed */ } }
      }
    } catch { /* no such folder */ }
  }
  found.sort((a, b) => { for (let i = 0; i < Math.max(a.v.length, b.v.length); i++) { const d = (b.v[i] ?? 0) - (a.v[i] ?? 0); if (d) return d; } return 0; });
  return found[0]?.dir ?? "";
};
const mise = sh("sh", ["-c", "command -v mise"]).out || newest([`${home}/Library/Caches/sayt`, `${home}/.cache/sayt`]);
const cueCmd: [string, string[]] = Deno.env.get("CUE") ? [Deno.env.get("CUE")!, []] : mise ? [mise, ["exec", "--", "cue"]] : ["cue", []];
const registry = Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1];
const cueOut = (args: string[], what: string) => {
  const r = sh(cueCmd[0], [...cueCmd[1], "export", ...args, "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {});
  if (!r.ok) usage(`${what} of ${appDir} unread: ${r.err.split("\n")[0]}`);
  return JSON.parse(r.out);
};
const ownFile = (f: string) => { try { Deno.statSync(`${appDir}/${f}`); return [f]; } catch { return []; } };
if (!ownFile("release_notes_plugin.cue").length) usage(`${appDir}/release_notes_plugin.cue is missing: run pronto-plugins' bin/pronto-release-notes on the app`);
const notes: {
  source: { kind: "release-cron"; name?: string } | { kind: "tags"; prefix: string } | { kind: "deployments"; environment: string };
  timeZone: string; zoneLabel: string; audience: string;
  model: { kind: "ollama"; name: string; url: string } | { kind: "claude"; name: string } | { kind: "none" };
} = cueOut([...ownFile("release_notes.cue"), "release_notes_plugin.cue", "-e", "releaseNotes"], "releaseNotes");
const { timeZone, zoneLabel, audience } = notes;

// The repository from origin's URL (git@github.com:o/n.git, https://github.com/o/n): no gh call, which
// would need a login before anything is read.
const origin = sh("git", ["remote", "get-url", "origin"], appDir);
const repo = origin.out.match(/github\.com[:/]([^/]+\/[^/]+?)(\.git)?\/?$/)?.[1] ?? "";
if (!repo) usage(`no GitHub repository in origin's URL (${origin.out || origin.err})`);

// The live release records of the source: release-cron's (named by the source, else release.cue's GCP.name),
// the git tags' or the GitHub deployments' (notes.js adapts the last two).
const records = (() => {
  const s = notes.source;
  if (s.kind === "tags") {
    const r = sh("git", ["for-each-ref", `--format=%(refname:lstrip=2)\t%(objectname)\t%(*objectname)\t%(creatordate:iso-strict)`, `refs/tags/${s.prefix}*`], top);
    if (!r.ok) usage(`git tags unread: ${r.err.split("\n")[0]}`);
    return fromTags(r.out.split("\n"), s.prefix);
  }
  if (s.kind === "deployments") {
    const list = sh("gh", ["api", `repos/${repo}/deployments?environment=${encodeURIComponent(s.environment)}&per_page=100`, "--paginate", "--jq", ".[] | @json"], appDir);
    if (!list.ok) usage(`deployments of ${s.environment} unread (gh api): ${list.err.split("\n")[0]}`);
    const deployments = list.out.split("\n").filter(Boolean).map((l) => JSON.parse(l)).map((d) => {
      const st = sh("gh", ["api", `repos/${repo}/deployments/${d.id}/statuses`, "--jq", "[.[] | {state, created_at}]"], appDir);
      return { ...d, statuses: st.ok ? JSON.parse(st.out || "[]") : [] };
    });
    return fromDeployments(deployments);
  }
  if (!s.name && !ownFile("release.cue").length) usage(`${appDir}/release.cue is missing: name the release-cron records in releaseNotes.source.name`);
  const name = s.name ?? cueOut(["release.cue", "-e", "GCP.name"], "GCP.name");
  return jsonl(`${home}/.cache/pronto/releases/${name}.jsonl`);
})();
// A pull request in plain words, once: the cache first, then the local model, then the rules.
const cacheFile = `${home}/.cache/pronto/release-notes/${app}/prs.json`;
const cache: Record<string, { summary: string; players: boolean }> = (() => { try { return JSON.parse(Deno.readTextFileSync(cacheFile)); } catch { return {}; } })();
// The model's name is the app's, RELEASE_NOTES_MODEL overriding it. Ollama answers at its url; Claude through the Messages
// API with ANTHROPIC_API_KEY from the environment (never printed: a missing key is no answer); none asks nothing.
const model = notes.model;
const modelName = model.kind === "none" ? "" : Deno.env.get("RELEASE_NOTES_MODEL") ?? model.name;
async function ask(pr: { title: string; body: string; files: { path: string }[] }) {
  try {
    if (model.kind === "none") return null;
    const content = prompt(pr, audience);
    if (model.kind === "claude") {
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) return null;
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: modelName, max_tokens: 400, messages: [{ role: "user", content }] }), signal: AbortSignal.timeout(180_000) });
      return answer((await r.json()).content[0].text);
    }
    const r = await fetch(`${model.url}/api/chat`, { method: "POST", body: JSON.stringify({ model: modelName, stream: false, format: "json", messages: [{ role: "user", content }] }), signal: AbortSignal.timeout(180_000) });
    return answer((await r.json()).message.content);
  } catch { return null; }
}
async function words(n: number) {
  if (model.kind !== "none" && cache[n]) return cache[n];
  const v = sh("gh", ["pr", "view", String(n), "-R", repo, "--json", "number,title,body,url,files"], appDir);
  if (!v.ok) { console.log(`#${n} unread (gh pr view): ${v.err.split("\n")[0]}`); return { summary: `Pull request #${n}`, players: true, unread: true }; }
  const pr = JSON.parse(v.out);
  const said = await ask(pr);
  const rules = fallback(pr, appRel);
  if (!said) return rules;
  // A player sees it only when both agree: the model reads the words, the rules the files (a pull request of tests and tooling alone never shows).
  said.players = said.players && rules.players;
  cache[n] = said;
  Deno.mkdirSync(cacheFile.replace(/\/[^/]*$/, ""), { recursive: true });
  Deno.writeTextFileSync(cacheFile, JSON.stringify(cache, null, 2) + "\n");
  return said;
}

// A commit this checkout has, fetched from origin when it has not.
const has = (c: string) => sh("git", ["cat-file", "-e", `${c}^{commit}`], top).ok;
const have = (c: string) => has(c) || (sh("git", ["fetch", "-q", "origin"], top), has(c));

// One Release: made, or edited when its tag has one. Returns what was done.
async function publish(rel: ReturnType<typeof releases>[number]) {
  const t = tag(app, rel.revision);
  if (!have(rel.first.commit) || (rel.base && !have(rel.base)) || !have(rel.last.commit)) { console.log(`${t}: skipped, a commit is not on origin`); return "skipped"; }
  const subjects = rel.base ? sh("git", ["log", "--first-parent", "--format=%s", `${rel.base}..${rel.last.commit}`, "--", appDir], top).out.split("\n").filter(Boolean) : [];
  const prs = [];
  for (const n of prNumbers(subjects)) prs.push({ number: n, ...await words(n) });
  const text = body({ app, repo, release: rel, prs, timeZone, zoneLabel, audience });
  const head = title(app, rel, timeZone, zoneLabel);
  if (dry) { console.log(`=== ${t}\n${head}\n\n${text}`); return "dry"; }
  const file = Deno.makeTempFileSync({ suffix: ".md" });
  try {
    Deno.writeTextFileSync(file, text);
    const exists = sh("gh", ["release", "view", t, "-R", repo]).ok;
    const r = exists
      ? sh("gh", ["release", "edit", t, "-R", repo, "--title", head, "--notes-file", file])
      : sh("gh", ["release", "create", t, "-R", repo, "--target", rel.first.commit, "--title", head, "--notes-file", file, "--latest=false"]);
    if (!r.ok) { console.log(`${t}: ${exists ? "not updated" : "not created"}: ${r.err.split("\n")[0]}`); return "failed"; }
    console.log(`${t}: ${exists ? "updated" : "created"}`);
    return exists ? "updated" : "created";
  } finally { Deno.removeSync(file); }
}

const all = releases(records);
const todo = verb === "backfill" ? all : wanted ? all.filter((r) => r.revision === wanted) : all.slice(-1);
if (!todo.length) usage(wanted ? `${wanted}: no live release record of it` : "no live release record yet");
const done: string[] = [];
for (const rel of todo) done.push(await publish(rel));
const n = (k: string) => done.filter((d) => d === k).length;
if (verb === "backfill") console.log(`release-notes: ${n("created")} created, ${n("updated")} updated, ${n("skipped") + n("failed")} skipped${dry ? ` (dry: ${n("dry")} shown)` : ""}`);
Deno.exit(verb === "publish" && (n("failed") || n("skipped")) ? 1 : 0);
