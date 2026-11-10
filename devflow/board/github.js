// GitHub Projects (v2) in the board's words (board.ts): what github-projects.ts reads of the GraphQL
// API, turned into states, issues and cycles, and back. Pure, so the devflow unit cases hold it.
//
// A project's Status field (single select) holds the states: an option's id is the state's id, and
// its description keeps the state's group (and `default`, for the state new issues start in). A
// Priority field (single select) holds an issue's priority, a Module field (multi select) its apps,
// a Sprint field (iteration) its cycle. An issue's key, PRONTO-123, is issue #123 of the board's
// repository. A link is a comment carrying its address in a marker, since an issue has no links.

/** The fields the flow keeps on a project, by name. */
export const FIELDS = { status: "Status", priority: "Priority", module: "Module", sprint: "Sprint" };

/** Plane's priorities, which the flow's P0..P3 are written in (schema.cue, priorities). */
export const PRIORITIES = ["urgent", "high", "medium", "low", "none"];

/** GitHub's single-select colours, the nearest to a state's hex colour by hue. */
const COLORS = { GRAY: [163, 163, 163], BLUE: [59, 130, 246], GREEN: [34, 197, 94], YELLOW: [234, 179, 8], ORANGE: [249, 115, 22], RED: [239, 68, 68], PINK: [236, 72, 153], PURPLE: [168, 85, 247] };

/** The GitHub colour nearest a #rrggbb. */
export function colorOf(hex) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(hex ?? ""));
  if (!m) return "GRAY";
  const c = m.slice(1).map((h) => parseInt(h, 16));
  let best = "GRAY";
  let dist = Infinity;
  for (const [name, rgb] of Object.entries(COLORS)) {
    const d = rgb.reduce((s, v, i) => s + (v - c[i]) ** 2, 0);
    if (d < dist) [best, dist] = [name, d];
  }
  return best;
}

/** A Status option's description: the state's group, `default` when new issues start there, and what it means. */
export function describeState(group, isDefault, means = "") {
  return [`group:${group}`, ...(isDefault ? ["default"] : []), ...(means ? [means] : [])].join(" ");
}

/** A Status option as a state: {id, name, group, color, default}. An option devflow did not write is in no group: "unstarted". */
export function stateOf(option) {
  const d = option.description ?? "";
  const g = /(?:^|\s)group:([a-z]+)/.exec(d);
  return { id: option.id, name: option.name, group: g ? g[1] : "unstarted", color: option.color ?? "GRAY", default: /(?:^|\s)default(?:\s|$)/.test(d) };
}

/**
 * The Status options to write, keeping every existing option's id so the items keep their status:
 * `options` as they are, with `change` (by id) merged into one, or `add` appended.
 */
export function optionsWith(options, { change, add, defaultId } = {}) {
  const out = options.map((o) => {
    const s = stateOf(o);
    const c = change && change.id === o.id ? change.fields : {};
    const group = c.group ?? s.group;
    const means = c.description ?? (o.description ?? "").replace(/(?:^|\s)group:[a-z]+/, "").replace(/(?:^|\s)default(?=\s|$)/, "").trim();
    const isDefault = defaultId !== undefined ? o.id === defaultId : s.default;
    return { id: o.id, name: c.name ?? o.name, color: c.color ? colorOf(c.color) : o.color ?? "GRAY", description: describeState(group, isDefault, means) };
  });
  if (add) out.push({ name: add.name, color: colorOf(add.color), description: describeState(add.group, false, add.description ?? "") });
  return out;
}

/** An issue's key as its number in the board's repository: PRONTO-123 → 123; null when not the project's. */
export function numberOf(identifier, key) {
  const m = new RegExp(`^${identifier}-(\\d+)$`, "i").exec(String(key ?? "").trim());
  return m ? Number(m[1]) : null;
}

/** A project item's field values by field name: a single select's option id, a multi select's option names, an iteration's id. */
export function valuesOf(item) {
  const out = {};
  for (const v of item.fieldValues?.nodes ?? []) {
    const name = v?.field?.name;
    if (!name) continue;
    if (v.optionId !== undefined) out[name] = { id: v.optionId, name: v.name };
    else if (v.options !== undefined) out[name] = v.options.map((o) => o.name);
    else if (v.iterationId !== undefined) out[name] = { id: v.iterationId, title: v.title };
  }
  return out;
}

/**
 * A project item (an issue of the board's repository) as the board's Issue: its id the issue's node
 * id, its sequence its number, its state the Status option's id, its priority the option's name,
 * its modules the Module options' names. `item` is a ProjectV2Item with `content` an Issue.
 */
export function issueOf(item) {
  const c = item.content ?? {};
  const v = valuesOf(item);
  return {
    id: c.id,
    item: item.id,
    name: c.title,
    sequence_id: c.number,
    state: v[FIELDS.status]?.id ?? "",
    priority: v[FIELDS.priority]?.name ?? "none",
    description_html: c.body ?? "",
    modules: v[FIELDS.module] ?? [],
    cycle: v[FIELDS.sprint]?.id ?? null,
    labels: (c.labels?.nodes ?? []).map((l) => l.id),
  };
}

/** A day, YYYY-MM-DD, plus n days. */
export function addDays(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Whole days from one day to another, both counted: 2026-11-10 to 2026-11-10 is 1. */
export function daysFrom(start, end) {
  return Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86400000) + 1;
}

/** An iteration as a cycle: its end the last day it covers. */
export function cycleOf(it) {
  return { id: it.id, name: it.title, start_date: it.startDate ?? null, end_date: it.startDate ? addDays(it.startDate, Math.max(1, it.duration) - 1) : null };
}

/** The Sprint field's iterations to write, every existing one by its id (completed ones too), with one added. */
export function iterationsWith(iterations, add) {
  const keep = iterations.map((i) => ({ id: i.id, title: i.title, startDate: i.startDate, duration: i.duration }));
  return add ? [...keep, { title: add.name, startDate: add.start, duration: Math.max(1, daysFrom(add.start, add.end)) }] : keep;
}

const LINK = /<!-- devflow:link (\S+) -->/;

/** A comment that links an issue to an address. */
export function linkComment(url, title) {
  return `<!-- devflow:link ${url} -->\n<p>Linked: <a href="${url}">${String(title).replace(/&/g, "&amp;").replace(/</g, "&lt;")}</a></p>`;
}

/** The addresses an issue's comments link it to, in order, once each. */
export function linksOf(comments) {
  const urls = [];
  for (const c of comments) {
    const m = LINK.exec(c.body ?? "");
    if (m && !urls.includes(m[1])) urls.push(m[1]);
  }
  return urls.map((url) => ({ url }));
}
