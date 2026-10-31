// The phone's screen: written once by pronto-android and then the app's own.
// Pronto does not compile shell/screens for Android yet, so this draws a
// DivKit card from the rows: __shell is the program's shell.json, __handlers
// its handler sources, each caged with `new Compartment().evaluate(source)`.
// A tap arrives at onAction(url, {now, key}) as the pronto://event/<type>?from=<id>
// its action names, with the host's clock and a freshly minted key. host.js
// keeps `rows` (each table, `device` ones unsealed from the phone's store) and
// writes them only through commit(table, updates), which refuses what the
// schema refuses and persists `device` rows; reduce(name, state, event) and
// settle(fold, table, reads) run handlers caged. __signers(package) is the
// installed app's certificate digests, comma-joined, or "". This starter lists the
// tables; replace it with the screens.
lockdown({ errorTaming: "unsafe" });

const text = (value, size, extra = {}) => ({
  type: "text", text: value, font_size: size, text_color: "#1D1B20", text_alignment_horizontal: "center", ...extra,
});

const card = () => JSON.stringify({
  log_id: "screen",
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
        text(__shell.app, 34, { font_weight: "bold", margins: { bottom: 16 } }),
        ...Object.entries(rows).map(([t, rs]) => text(`${t}: ${rs.length} row${rs.length === 1 ? "" : "s"}`, 18)),
        text(`handlers: ${Object.keys(__handlers).join(", ") || "none"}`, 14, { text_color: "#79747E", margins: { top: 16 } }),
      ],
    },
  }],
});

emitUiAst(card());
onAction(() => emitUiAst(card()));
