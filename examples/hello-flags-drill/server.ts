// The drill's shop: /, /cart and /checkout. /checkout asks flagd (OFREP) for drill_break_checkout
// on every request and answers 500 while it is true. One JSON line a request on stdout, with the
// flag value it read.
//   PORT=8787 FLAGD_URL=http://127.0.0.1:8016 deno run -A server.ts
const port = Number(Deno.env.get("PORT") ?? 8787);
const flagd = Deno.env.get("FLAGD_URL") ?? "http://127.0.0.1:8016";

// The flag's value; false when flagd does not answer, as a page with no flags would read it.
async function broken(): Promise<{ value: boolean; error?: string }> {
  try {
    const res = await fetch(`${flagd}/ofrep/v1/evaluate/flags/drill_break_checkout`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ context: {} }),
      signal: AbortSignal.timeout(2000),
    });
    const body = await res.json();
    return { value: body.value === true };
  } catch (e) {
    return { value: false, error: String(e) };
  }
}

Deno.serve({ port, hostname: "127.0.0.1" }, async (req) => {
  const { pathname } = new URL(req.url);
  let status = 200;
  let body = "";
  let flag: boolean | undefined;
  let error: string | undefined;
  if (pathname === "/") body = "hello-flags-drill shop";
  else if (pathname === "/cart" && req.method === "POST") body = JSON.stringify({ cart: "ok" });
  else if (pathname === "/checkout" && req.method === "POST") {
    ({ value: flag, error } = await broken());
    if (flag) {
      status = 500;
      body = "checkout broken by drill";
    } else body = JSON.stringify({ order: "placed" });
  } else {
    status = 404;
    body = "not found";
  }
  console.log(JSON.stringify({ at: new Date().toISOString(), method: req.method, path: pathname, status, drill_break_checkout: flag ?? null, error }));
  return new Response(body, { status });
});
