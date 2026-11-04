// release-notes' rules, apart from what they act on (release-notes.ts runs git, gh and the local
// model): which release records count, how they fold into Releases, which pull requests a Release
// holds, how a pull request is grouped and summed up when the model cannot, and the Release's
// title and body. Pure, so the cases (tests/unit/notes.cue) hold them.

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
const toolchain = /^(\.mise\.toml|mise\.lock|saytw|saytw\.ps1|\.gitignore|\.gitattributes|release\.cue|release_cron(_plugin)?\.cue|prod_watch\.cue|compose\.yaml)$/;
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

// A time a person reads, in Brasília: 2026-11-04 08:51 BRT, from an ISO time in UTC.
export const brt = (iso) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(Date.parse(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute} BRT`;
};

// Minutes between two ISO times, one decimal: "35.3".
export const minutes = (started, ended) => (Math.round((Date.parse(ended) - Date.parse(started)) / 6000) / 10).toFixed(1);

// The Release's title: the app, when its revision went live, the revision.
export const title = (app, release) => `${app} · ${brt(release.first.ended)} · ${release.revision}`;

// The Release's body. `prs` are the pull requests of the Release's range, ascending, each
// {number, summary, players}; `repo` is owner/name. Sections hold the bullets, an empty one is left
// out; the first release recorded has no base and lists none.
export const body = ({ app, repo, release, prs }) => {
  const f = release.first, url = `https://github.com/${repo}`;
  const bullets = (ps) => ps.map((p) => `- ${p.summary} ([#${p.number}](${url}/pull/${p.number}))`).join("\n");
  const seen = prs.filter((p) => p.players), inside = prs.filter((p) => !p.players);
  const changes = release.base === null
    ? ["This is the first release recorded; the changes before it are not listed."]
    : prs.length === 0
    ? [`No changes to ${app} since the last release.`]
    : [seen.length ? `## What players see\n\n${bullets(seen)}` : "", inside.length ? `## Behind the scenes\n\n${bullets(inside)}` : ""].filter(Boolean);
  const table = [
    "| | |",
    "|---|---|",
    `| Revision | \`${release.revision}\` |`,
    `| Commit | [\`${f.commit.slice(0, 8)}\`](${url}/commit/${f.commit}) |`,
    `| Pronto version | ${f.pronto ?? ""} |`,
    `| Went live | ${brt(f.ended)} |`,
    `| Release took | ${minutes(f.started, f.ended)} min |`,
  ].join("\n");
  return `${changes.join("\n\n")}\n\n## The release\n\n${table}\n\n<!-- release-notes app=${app} revision=${release.revision} commit=${f.commit} -->\n`;
};
