// Small measures the cases read a value through (tests/unit/*.cue).

/** Whether a text holds a part. */
export const includes = (text, part) => String(text ?? '').includes(part);
/** Whether a text holds each part, as a list of whether it does. */
export const holdsEach = (text, parts) => parts.map((p) => String(text ?? '').includes(p));
/** The elements of a list from an index on. */
export const from = (list, i) => list.slice(i);
/** The last element of a list. */
export const last = (list) => list.at(-1);
/** Whether every element of a list is the value. */
export const every = (list, v) => list.every((x) => x === v);
/** A text's length. */
export const length = (text) => String(text ?? '').length;
/** Whether two values are the same. */
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** A text with a pattern replaced. */
export const replaced = (text, pattern, by) => String(text).replace(new RegExp(pattern, 'm'), by);
/** A text repeated. */
export const repeat = (text, n) => String(text).repeat(n);
