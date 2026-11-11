// release-notes' rules, apart from what they act on (release-notes.ts runs git, gh and the model):
// the release records each source makes (release-cron's, git tags, GitHub deployments), which of them
// count, how they fold into Releases, which pull requests a Release holds, how a pull request is asked
// about, grouped and summed up when the model cannot, and the Release's title and body. Pure, so the
// cases (tests/unit/notes.cue) hold them. What an app chooses (source, time zone, model, audience) is
// the app's CUE (schema.cue), never written here.

// The records a git tag source makes, from `git for-each-ref --format='%(refname:lstrip=2)\t%(objectname)\t%(*objectname)\t%(creatordate:iso-strict)'`
// lines of the tags `<prefix>*`: the version is the tag without the prefix, the commit the tag's own (an annotated
// tag's *objectname, else its objectname), ended the tagger's or committer's date in UTC, started the same.
export const fromTags = (lines, prefix) =>
  lines.filter(Boolean).map((l) => l.split("\t")).filter(([ref]) => ref.startsWith(prefix) && ref.length > prefix.length)
    .map(([ref, obj, deref, date]) => {
      const ended = new Date(date).toISOString().replace(".000Z", "Z");
      return { outcome: "live", revision: ref.slice(prefix.length), commit: deref || obj, started: ended, ended };
    });

// The records a GitHub deployments source makes, from the deployments of one environment, each as the API gives it
// ({sha, ref, created_at}) with its `statuses` (newest first, {state, created_at}): those whose latest status is
// success. The version is the deployment's ref, else its sha; the commit its sha; ended the success status's time,
// started the deployment's.
export const fromDeployments = (deployments) =>
  deployments.flatMap((d) => {
    const latest = [...(d.statuses ?? [])].sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0))[0];
    return latest?.state === "success"
      ? [{ outcome: "live", revision: d.ref || d.sha, commit: d.sha, started: d.created_at, ended: latest.created_at }]
      : [];
  });

// release-cron's own runs (~/.cache/pronto/release-cron/<app>/runs.jsonl) as records: a run that
// released is a revision made live, from its commit, between its start and end. An app releasing to a
// command target (no Cloud Run, no pronto release records) has these alone (PRONTO-205).
export const fromCronRuns = (runs) =>
  runs.filter((r) => r.outcome === "released" && r.revision && r.commit)
    .map((r) => ({ outcome: "live", revision: r.revision, commit: r.commit, started: r.started, ended: r.ended }));

// The records that made a revision live in production, oldest first by their end: outcome live, no
// preview, a revision. (Pronto's release records, ~/.cache/pronto/releases/<name>.jsonl.)
export const live = (records) =>
  records.filter((r) => r.outcome === "live" && (r.preview ?? "") === "" && r.revision)
    .sort((a, b) => (a.ended < b.ended ? -1 : a.ended > b.ended ? 1 : 0));

// One Release per revision, oldest first. A release that kept the same image makes another record
// of the same revision: it folds in. `first` is the record that made the revision live (its facts),
// `last` the newest record of it. `base` is the commit the changes are counted from: that of the
// record live just before the first, always of another revision; null for the very first record.
export const releases = (records) => {
  const l = live(records), out = new Map();
  l.forEach((r, i) => {
    const o = out.get(r.revision);
    if (o) o.last = r;
    else out.set(r.revision, { revision: r.revision, first: r, last: r, base: i ? l[i - 1].commit : null });
  });
  return [...out.values()];
};

// The git tag, and so the Release, of an app's revision.
export const tag = (app, revision) => `${app}/${revision}`;

// The pull requests of `git log --first-parent --format=%s` subjects: "Merge pull request #N from …"
// and a squash's "… (#N)", each once, ascending.
export const prNumbers = (subjects) => {
  const found = subjects.map((s) => (s.match(/^Merge pull request #(\d+) /) ?? s.match(/\(#(\d+)\)\s*$/))?.[1]).filter(Boolean).map(Number);
  return [...new Set(found)].sort((a, b) => a - b);
};

// Whether a path (from the app's folder) is behind the scenes: tests, docs, the release tools, CI,
// a markdown file or a file only the toolchain or the release reads. Anything else can reach a player.
const hidden = /^(tests|docs|release-cron|release-notes|\.github)\//;
const toolchain = /^(\.mise\.toml|mise\.lock|saytw|saytw\.ps1|\.gitignore|\.gitattributes|release\.cue|release_cron(_plugin)?\.cue|release_notes(_plugin)?\.cue|prod_watch\.cue|compose\.yaml)$/;
export const behind = (path) => hidden.test(path) || toolchain.test(path) || /\.md$/.test(path);

// A pull request's group from its changed files (paths from the repository's root), looked at
// under the app's folder `appRel`: a player can see it unless every file there is behind the scenes.
export const players = (files, appRel) => {
  const own = files.filter((f) => f.startsWith(`${appRel}/`)).map((f) => f.slice(appRel.length + 1));
  return own.some((f) => !behind(f));
};

// A pull request's title as a summary: conventional prefixes ("feat(x):", "fix:", "brawl-chess:")
// and a trailing "(#N)" taken off, the first letter capitalised.
export const plain = (title) => {
  let t = title.trim();
  for (let p = null; p !== t;) { p = t; t = t.replace(/^[a-z][a-z0-9_-]*(\([^)]*\))?!?:\s+/, ""); }
  t = t.replace(/\s*\(#\d+\)\s*$/, "");
  return t.charAt(0).toUpperCase() + t.slice(1);
};

// What the rules say of a pull request (gh pr view --json title,files) when the model cannot.
export const fallback = (pr, appRel) => ({ summary: plain(pr.title), players: players((pr.files ?? []).map((f) => f.path ?? f), appRel) });

// A time a person reads, in the app's time zone: 2026-11-04 08:51 BRT, from an ISO time in UTC, the zone
// (an IANA name, "America/Sao_Paulo") and the label written after it ("BRT").
export const stamp = (iso, timeZone, label) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(Date.parse(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute} ${label}`;
};

// Minutes between two ISO times, one decimal: "35.3".
export const minutes = (started, ended) => (Math.round((Date.parse(ended) - Date.parse(started)) / 6000) / 10).toFixed(1);

// What a model is asked of a pull request (gh pr view --json title,body,files), for an audience ("player"): one
// plain line, and whether that audience would notice the change. The answer's key stays `players`.
export const prompt = (pr, audience) => {
  const a = /^[aeiou]/i.test(audience) ? "an" : "a";
  return `A pull request to a game or web app. Say what it changes in ONE line of at most 20 words that ${a} ${audience} or product reader understands: no file names, function names, PR numbers or commit jargon. Set players to true only if a person playing or using the product would notice the change on screen or in how it behaves (a new feature, a rule, a screen, a fix of something they hit, a price). Set it false for everything a player never notices: tests, docs, CI, how and when releases or deploys happen, release automation, rehearsals, analytics, tracking and telemetry, monitoring, build and test speed, flags or files the build needs, database internals and refactors. When unsure, false. Answer as JSON {"summary": string, "players": boolean}.\n\nTitle: ${pr.title}\n\nDescription:\n${(pr.body ?? "").slice(0, 3000)}\n\nFiles changed:\n${pr.files.slice(0, 40).map((f) => f.path).join("\n")}`;
};

// A model's answer as the words of a pull request: {summary, players}, or null when it is not one. The JSON
// may be wrapped in other text (a model without a JSON mode); the summary is one line without its final dot.
export const answer = (text) => {
  for (const t of [text, text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)]) {
    try {
      const a = JSON.parse(t);
      const summary = String(a.summary ?? "").replace(/\s+/g, " ").trim().replace(/\.$/, "");
      return summary && typeof a.players === "boolean" ? { summary, players: a.players } : null;
    } catch { /* the next try */ }
  }
  return null;
};

// The Release's title: the app, when its revision went live, the revision.
export const title = (app, release, timeZone, label) => `${app} · ${stamp(release.first.ended, timeZone, label)} · ${release.revision}`;

// The Release's body. `prs` are the pull requests of the Release's range, ascending, each
// {number, summary, players}; `repo` is owner/name; `audience` heads the first section ("What players see").
// Sections hold the bullets, an empty one is left out; the first release recorded has no base and lists none.
export const body = ({ app, repo, release, prs, timeZone, zoneLabel, audience }) => {
  const f = release.first, url = `https://github.com/${repo}`;
  const bullets = (ps) => ps.map((p) => `- ${p.summary} ([#${p.number}](${url}/pull/${p.number}))`).join("\n");
  const seen = prs.filter((p) => p.players), inside = prs.filter((p) => !p.players);
  const changes = release.base === null
    ? ["This is the first release recorded; the changes before it are not listed."]
    : prs.length === 0
    ? [`No changes to ${app} since the last release.`]
    : [seen.length ? `## What ${audience}s see\n\n${bullets(seen)}` : "", inside.length ? `## Behind the scenes\n\n${bullets(inside)}` : ""].filter(Boolean);
  const table = [
    "| | |",
    "|---|---|",
    `| Revision | \`${release.revision}\` |`,
    `| Commit | [\`${f.commit.slice(0, 8)}\`](${url}/commit/${f.commit}) |`,
    `| Pronto version | ${f.pronto ?? ""} |`,
    `| Went live | ${stamp(f.ended, timeZone, zoneLabel)} |`,
    `| Release took | ${minutes(f.started, f.ended)} min |`,
  ].join("\n");
  return `${changes.join("\n\n")}\n\n## The release\n\n${table}\n\n<!-- release-notes app=${app} revision=${release.revision} commit=${f.commit} -->\n`;
};
