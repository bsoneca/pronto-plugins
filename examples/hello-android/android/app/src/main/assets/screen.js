// The counter on the phone: rows in from the program's seed, its count.js
// caged by SES, updates applied, a DivKit card out. Nothing here reads a
// clock or a random.
lockdown({ errorTaming: "unsafe" });
const reduce = new Compartment().evaluate(__handlers.count);
// The seed pronto emits into shell.json, copied so the tab row starts there.
const rows = { counter: __shell.seed.counter.map((r) => ({ ...r })) };

const button = (label, from) => ({
  type: "text",
  text: label,
  font_size: 40,
  font_weight: "bold",
  text_color: "#21005D",
  text_alignment_horizontal: "center",
  width: { type: "fixed", value: 96 },
  paddings: { top: 12, bottom: 12 },
  margins: { left: 12, right: 12 },
  border: { corner_radius: 16 },
  background: [{ type: "solid", color: "#E8DEF8" }],
  actions: [{ log_id: from, url: "pronto://event/click?from=" + from }],
});

const card = () => JSON.stringify({
  log_id: "hello",
  states: [{
    state_id: 0,
    div: {
      type: "container",
      orientation: "vertical",
      content_alignment_horizontal: "center",
      content_alignment_vertical: "center",
      height: { type: "match_parent" },
      background: [{ type: "solid", color: "#FEF7FF" }],
      items: [
        { type: "text", text: "Hello, world", font_size: 34, font_weight: "bold", text_color: "#1D1B20", text_alignment_horizontal: "center", margins: { bottom: 8 } },
        { type: "text", text: "QuickJS + SES + DivKit, no WebView", font_size: 14, text_color: "#79747E", text_alignment_horizontal: "center", margins: { bottom: 32 } },
        { type: "text", text: "Count: " + rows.counter[0].n, font_size: 48, text_color: "#1D1B20", text_alignment_horizontal: "center", margins: { bottom: 32 } },
        { type: "container", orientation: "horizontal", width: { type: "wrap_content" }, alignment_horizontal: "center", items: [button("−", "dec"), button("+", "inc")] },
      ],
    },
  }],
});

emitUiAst(card());
onAction((url) => {
  const from = url.split("from=")[1];
  const { updates } = reduce({ items: rows.counter }, { type: "click", from });
  for (const u of updates) Object.assign(rows.counter.find((r) => r.id === u.id), u.row);
  emitUiAst(card());
});
