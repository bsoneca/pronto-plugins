// release-notes: after an app's release goes live, a GitHub Release on the app's repo, tagged
// <app>/<revision> on the released commit. pronto-plugins' release-notes/README.md says more. Run
// from the app's folder, where it is written:
//   deno run -A release-notes/release-notes.ts <app> publish [<revision>]   the newest live revision's Release (or the named one's)
//   deno run -A release-notes/release-notes.ts <app> backfill               every live revision's, oldest first
// --dry prints each Release's title and body and touches nothing on GitHub. A Release is made or,
// when its tag has one, edited: never deleted, no tag moved. The changes are the pull requests of the
// app's folder between the previous live release and this one (git log --first-parent), each in
// plain words from the local model (Ollama, RELEASE_NOTES_MODEL, default qwen3-coder:30b), or from
// notes.js's rules when it cannot answer. A pull request's words are kept in
// ~/.cache/pronto/release-notes/<app>/prs.json, so a re-run says the same.
import { body, fallback, prNumbers, releases, tag, title } from "./notes.js";

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

// The app's release records are kept under the name its release.cue gives (GCP.name), read as
// release-cron reads it: the app's own cue, as mise finds it there.
const mise = sh("sh", ["-c", "command -v mise"]).out || `${home}/Library/Caches/sayt/mise-v2026.8.11/mise`;
const cue = Deno.env.get("CUE") || sh(mise, ["which", "cue"], appDir).out || "cue";
const registry = Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1];
const name = JSON.parse((() => {
  const r = sh(cue, ["export", "release.cue", "-e", "GCP.name", "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {});
  if (!r.ok) usage(`GCP.name of ${appDir}/release.cue unread: ${r.err.split("\n")[0]}`);
  return r.out;
})());
const records = jsonl(`${home}/.cache/pronto/releases/${name}.jsonl`);
// The repository from origin's URL (git@github.com:o/n.git, https://github.com/o/n): no gh call, which
// would need a login before anything is read.
const origin = sh("git", ["remote", "get-url", "origin"], appDir);
const repo = origin.out.match(/github\.com[:/]([^/]+\/[^/]+?)(\.git)?\/?$/)?.[1] ?? "";
if (!repo) usage(`no GitHub repository in origin's URL (${origin.out || origin.err})`);

// A pull request in plain words, once: the cache first, then the local model, then the rules.
const cacheFile = `${home}/.cache/pronto/release-notes/${app}/prs.json`;
const cache: Record<string, { summary: string; players: boolean }> = (() => { try { return JSON.parse(Deno.readTextFileSync(cacheFile)); } catch { return {}; } })();
const model = Deno.env.get("RELEASE_NOTES_MODEL") ?? "qwen3-coder:30b";
async function ask(pr: { title: string; body: string; files: { path: string }[] }) {
  const prompt = `A pull request to a game or web app. Say what it changes in ONE line of at most 20 words that a player or product reader understands: no file names, function names, PR numbers or commit jargon. Set players to true only if a person playing or using the product would notice the change on screen or in how it behaves (a new feature, a rule, a screen, a fix of something they hit, a price). Set it false for everything a player never notices: tests, docs, CI, how and when releases or deploys happen, release automation, rehearsals, analytics, tracking and telemetry, monitoring, build and test speed, flags or files the build needs, database internals and refactors. When unsure, false. Answer as JSON {"summary": string, "players": boolean}.\n\nTitle: ${pr.title}\n\nDescription:\n${(pr.body ?? "").slice(0, 3000)}\n\nFiles changed:\n${pr.files.slice(0, 40).map((f) => f.path).join("\n")}`;
  try {
    const r = await fetch("http://localhost:11434/api/chat", { method: "POST", body: JSON.stringify({ model, stream: false, format: "json", messages: [{ role: "user", content: prompt }] }), signal: AbortSignal.timeout(180_000) });
    const a = JSON.parse((await r.json()).message.content);
    const summary = String(a.summary ?? "").replace(/\s+/g, " ").trim().replace(/\.$/, "");
    return summary && typeof a.players === "boolean" ? { summary, players: a.players } : null;
  } catch { return null; }
}
async function words(n: number) {
  if (cache[n]) return cache[n];
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
  const text = body({ app, repo, release: rel, prs });
  const head = title(app, rel);
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
