// A stand-in for GlitchTip's ingest on a host launch, written by pronto-errors: it takes what the
// page reports so the reporter and the door can be exercised with no database and no container.
// POST /api/<project>/envelope/ keeps the envelope's event in memory (as GlitchTip would answer,
// 200 and the event's id; 401 with no sentry_key, 400 for what is no envelope); GET /events says
// what it holds, as a JSON array, for the checks. The door reaches it as /e/api/events too, since a
// check asks through the door: GET /api/events. Nothing is kept past the process.
const port = Number(Deno.env.get("ERRORS_PORT") ?? "3000");
const events: unknown[] = [];

Deno.serve({ hostname: "127.0.0.1", port }, async (req) => {
	const url = new URL(req.url);
	if (req.method === "GET" && (url.pathname === "/events" || url.pathname === "/api/events")) return Response.json(events);
	if (req.method === "POST" && /^\/api\/[0-9]+\/envelope\/$/.test(url.pathname)) {
		if (!url.searchParams.get("sentry_key")) return new Response("no key", { status: 401 });
		// An envelope: its header, then each item's header and payload, a line each.
		const lines = (await req.text()).split("\n");
		let id = "";
		try {
			id = JSON.parse(lines[0]).event_id ?? "";
			for (let i = 1; i + 1 < lines.length; i += 2) {
				if (JSON.parse(lines[i]).type === "event") events.push(JSON.parse(lines[i + 1]));
			}
		} catch {
			return new Response("bad envelope", { status: 400 });
		}
		return Response.json({ id });
	}
	return new Response("not found", { status: 404 });
});
