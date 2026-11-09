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
export const changes = (model, edits) =>
  rules.diff(model, edit(model, edits)).map((c) => `${c.kind} ${c.field ? `${c.entity}.${c.field}` : c.index ? `${c.entity} ${c.index}` : c.entity}`);

export const plan = (model, edits, declared = {}, dropped = {}) => rules.plan(rules.diff(model, edit(model, edits)), declared, dropped);

// The SQL of each change the plan makes, in the order the migration runs them.
export const sql = (model, edits, declared = {}, dropped = {}) => plan(model, edits, declared, dropped).ops.map((o) => o.sql);
