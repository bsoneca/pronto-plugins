// bound.js, the Android terminal's hatch driver, over linkedom (the terminal's own DOM): a bound hatch's view
// drawn into its screen, a gesture's submit carried out within the binding, a refused outcome kept out.
import { parseHTML } from "npm:linkedom@0.18.4";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { bindingOf, bound, checkView } from "../template/terminal/bound.js";

const binding = {
  generated: "test",
  module: "unity/hatches/probe/probe.js",
  reads: { rows: { select: "[data-rows] [data-row]", attrs: ["data-row", "data-n"] } },
  submits: ["form[data-intent]"],
  clicks: [],
};

// A counter: shows the screen's rows, and a tap on "add" asks the screen to add one.
const probe = {
  init: () => ({ taps: 0 }),
  view: (state: { taps: number }, reads: { rows: { attrs: Record<string, string> }[] }) => ({
    tag: "div", key: "root", children: [
      { tag: "p", key: "count", attrs: { id: "count", "data-taps": state.taps }, text: String(reads.rows.length) },
      { tag: "button", key: "add", attrs: { id: "add" }, text: "Add" },
      { tag: "button", key: "rogue", attrs: { id: "rogue" }, text: "Rogue" },
    ],
  }),
  gesture: (state: { taps: number }, _reads: unknown, event: { key: string }) =>
    event.key === "add"
      ? { state: { taps: state.taps + 1 }, submit: { form: "form[data-intent]", values: { kind: "add" } }, say: "added" }
      : { state: { taps: 99 }, submit: { form: "form[data-other]", values: {} } },
};

function screenOf() {
  // deno-lint-ignore no-explicit-any
  const { document, CustomEvent }: any = parseHTML(
    `<!doctype html><html lang="en"><body><section data-screen><ul data-rows></ul>
     <form data-intent><input name="kind"></form><form data-other></form></section></body></html>`,
  );
  const screen = document.querySelector("[data-screen]")!;
  const submitted: string[] = [];
  const form = screen.querySelector("form[data-intent]")!;
  // The terminal's browser.js gives forms requestSubmit; here the screen's fold is a row added.
  form.requestSubmit = () => {
    submitted.push(form.querySelector("[name=kind]").value);
    const li = document.createElement("li");
    li.setAttribute("data-row", String(submitted.length));
    screen.querySelector("[data-rows]").appendChild(li);
  };
  screen.querySelector("form[data-other]").requestSubmit = () => submitted.push("other");
  return { document, screen, submitted, tap: (id: string) => screen.querySelector(`#${id}`).dispatchEvent(new CustomEvent("click", { bubbles: true, cancelable: true })) };
}

const quiet = () => {
  const said: string[] = [];
  return { said, log: { error: (m: string) => said.push(m), log: (m: string) => said.push(m) } };
};
const settle = () => new Promise((ok) => setTimeout(ok, 5));

Deno.test("the view is drawn into the screen as div#hatch-<name>, keyed", async () => {
  const { screen } = screenOf();
  const stop = bound("probe", binding, probe, quiet())(screen, {});
  const mount = screen.querySelector("#hatch-probe")!;
  assert(mount, "the mount is under the screen");
  assertEquals(mount.querySelector("#count").getAttribute("data-hatch-key"), "count");
  assertEquals(mount.querySelector("#count").textContent, "0");
  stop();
  assertEquals(screen.querySelector("#hatch-probe"), null, "stopped, the hatch leaves the screen");
  await settle();
});

Deno.test("a gesture's submit fills the bound form and the next view reads the screen's answer", async () => {
  const { screen, submitted, tap } = screenOf();
  const q = quiet();
  const stop = bound("probe", binding, probe, q)(screen, {});
  tap("add");
  assertEquals(submitted, ["add"]);
  await settle();
  const count = screen.querySelector("#hatch-probe #count");
  assertEquals(count.textContent, "1", "the row the fold wrote is read");
  assertEquals(count.getAttribute("data-taps"), "1", "the state the gesture returned is kept");
  assert(q.said.includes("PRONTO HATCH probe: added"));
  stop();
});

Deno.test("an outcome outside the binding is a fault: nothing submitted, the state kept", async () => {
  const { screen, submitted, tap } = screenOf();
  const q = quiet();
  const stop = bound("probe", binding, probe, q)(screen, {});
  tap("add");
  tap("rogue");
  await settle();
  assertEquals(submitted, ["add"], "form[data-other] is not one of submits");
  assertEquals(screen.querySelector("#hatch-probe #count").getAttribute("data-taps"), "1");
  assert(q.said.some((m) => m.startsWith("PRONTO FAULT hatch probe: outcome: submit.form form[data-other]")));
  stop();
});

Deno.test("a binding and a view are held to the contract's shape", () => {
  assertThrows(() => bindingOf({ ...binding, extra: 1 }), Error, "unknown field extra");
  assertThrows(() => bindingOf({ ...binding, tick: { hz: 0 } }), Error, "tick is {hz: 1..240}");
  assertThrows(() => checkView({ tag: "div", key: "a", children: [{ tag: "p", key: "a" }] }), Error, "not unique");
  assertThrows(() => checkView({ tag: "div", key: "a", style: { color: "red" } }), Error, "style.color");
});

Deno.test("a v3 scene stays in the DOM, drawn (not hidden), its attributes readable", async () => {
  const { screen } = screenOf();
  const scened = { ...probe, view: () => ({ tag: "div", key: "root", children: [{ tag: "scene", key: "scene", attrs: { id: "scene", "data-fight": "slap" }, children: [{ tag: "model", key: "m", attrs: { shape: "cube" } }] }] }) };
  const stop = bound("probe", binding, scened, quiet())(screen, {});
  const scene = screen.querySelector("#scene");
  assertEquals(scene.getAttribute("data-fight"), "slap");
  assert(!scene.hasAttribute("hidden"));
  assertEquals(scene.querySelectorAll("model").length, 1);
  stop();
  await settle();
});

Deno.test("a redraw keeps each keyed element, so a tap aimed at one still lands", async () => {
  const { screen, tap } = screenOf();
  const stop = bound("probe", binding, probe, quiet())(screen, {});
  const add = screen.querySelector("#hatch-probe #add");
  tap("add");
  await settle();
  assertEquals(screen.querySelector("#hatch-probe #add"), add, "the same element after the gesture's redraw");
  assertEquals(screen.querySelector("#hatch-probe #count").textContent, "1");
  stop();
});

Deno.test("a bound hatch's stylesheet is linked while it is mounted", async () => {
  const { document, screen } = screenOf();
  const stop = bound("probe", binding, probe, { ...quiet(), css: "/shell/modules/hatches/probe/probe.css" })(screen, {});
  assertEquals(document.querySelector("link[data-hatch-css=probe]").getAttribute("href"), "/shell/modules/hatches/probe/probe.css");
  stop();
  assertEquals(document.querySelector("link[data-hatch-css=probe]"), null);
  await settle();
});
