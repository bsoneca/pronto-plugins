// What the migrations cases (migrations.cue) run the rules on (../../migrations/plan.js): a model
// edited along dotted paths, so a case names only what changed, and the changes or the plan from the
// model to its edit.
import * as rules from '../../migrations/plan.js';

// The model with each [path, value] applied: "Order.fields.3.name"; a null value removes the key.
export function edit(model, edits) {
  const out = structuredClone(model);
  for (const [path, value] of edits) {
    const keys = path.split('.');
    let o = out;
    for (const k of keys.slice(0, -1)) o = o[k] ??= {};
    if (value === null) delete o[keys.at(-1)];
    else o[keys.at(-1)] = value;
  }
  return out;
}

// The changes from the model to its edit, each "<kind> <where>".
export const changes = (model, edits) => rules.diff(model, edit(model, edits)).map((c) => `${c.kind} ${rules.where(c)}`);

export const plan = (model, edits, declared = {}, dropped = {}) => rules.plan(rules.diff(model, edit(model, edits)), declared, dropped);

// The SQL of each change the plan makes, in the order the migration runs them.
export const sql = (model, edits, declared = {}, dropped = {}) => plan(model, edits, declared, dropped).ops.map((o) => o.sql);

// The names the migration the plan makes drops for good, as droppedBy reads them from its file.
export const dropped = (model, edits, declared = {}) => rules.droppedBy([{ name: "m", json: rules.migration(plan(model, edits, declared).ops) }]);

// The names the plan's ops say they drop for good (dropped and not built again), after an earlier
// migration that dropped the constraints `prior`, and those droppedBy reads from both migrations.
export const names = (model, edits, declared = {}, prior = []) => {
  const ops = plan(model, edits, declared).ops;
  const said = new Set([...prior, ...ops.flatMap((o) => o.drops)]);
  for (const o of ops) for (const b of o.builds) said.delete(b);
  const before = prior.length ? [{ name: "a", json: { operations: [{ sql: { up: prior.map((n) => `ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS ${rules.ident(n)};`).join("\n") } }] } }] : [];
  return { said: [...said].sort(), read: Object.keys(rules.droppedBy([...before, { name: "m", json: rules.migration(ops) }])).sort() };
};

// A snapshot of `format` holding the model with `edits`, carried to this plugin's format against the
// model itself, as the model at the commit it was taken at.
export const upgrade = (model, edits, format = 1) => rules.upgrade(JSON.stringify({ format, model: edit(model, edits) }), model);
