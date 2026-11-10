// pronto-errors' source maps (PRONTO-198): what lets GlitchTip show a page's error at its original file,
// function and line. Written by pronto-errors; regenerated, do not edit.
//
//   deno run -A errors/sourcemaps.ts inject [<file.js>...]
//     Gives each bundle its debug ID, as the app's build runs it, so the committed bundle carries it: a UUID
//     from the bundle's own SHA-256 (the same bundle, the same ID, wherever it is built), set by a snippet
//     appended at its end (Sentry's: globalThis._sentryDebugIds, keyed by the stack of the snippet's Error,
//     which names the file the page loaded it from) and named by a last `//# debugId=` line. Appended, so no
//     line of the bundle moves and its map stays true. A sibling `<file>.js.map` gets the ID too. A bundle
//     that has one already is left as it is. Without files, the bundles errors_spec.cue lists.
//
//   deno run -A errors/sourcemaps.ts upload
//     After a release, in the app's folder of the tree released (release-cron's step): reads what
//     errors_spec.cue says of the maps (errors/sourcemaps.json, which generate writes), builds the app's
//     bundles again with hidden maps into a scratch folder (`build`, told the folder by ERRORS_MAPS_OUT,
//     each file at its path from the app's root there),
//     injects them, and refuses unless each is byte-identical to the bundle the release served (`files`).
//     Then sends the maps to GlitchTip as a debug-ID artifact bundle with sentry-cli, signed by the
//     uploader's token, which ERRORS_UPLOAD_TOKEN holds or the `token` command prints (its output is never
//     shown). The maps are never served and never committed.

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const MARK = "\n//# debugId=";

// A version-4-shaped UUID from the first 16 bytes of the SHA-256 of the bundle as built.
export const debugId = async (code: string): Promise<string> => {
	const b = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(code))).slice(0, 16);
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
	return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};

// Sentry's snippet, as sentry-cli writes it: the page's stack for this line names the file the page loaded.
export const snippet = (id: string): string =>
	`;!function(){try{var e="undefined"!=typeof window?window:"undefined"!=typeof global?global:"undefined"!=typeof globalThis?globalThis:"undefined"!=typeof self?self:{},n=(new e.Error).stack;n&&(e._sentryDebugIds=e._sentryDebugIds||{},e._sentryDebugIds[n]="${id}",e._sentryDebugIdIdentifier="sentry-dbid-${id}")}catch(e){}}();`;

export const existing = (code: string): string | null => {
	const at = code.lastIndexOf(MARK);
	return at < 0 ? null : code.slice(at + MARK.length).trim();
};

export const injected = async (code: string): Promise<{ code: string; id: string }> => {
	const had = existing(code);
	if (had) return { code, id: had };
	const id = await debugId(code);
	const body = code.endsWith("\n") ? code : code + "\n";
	return { code: `${body}${snippet(id)}${MARK}${id}\n`, id };
};

export const inject = async (files: string[]) => {
	for (const file of files) {
		const code = await Deno.readTextFile(file);
		const out = await injected(code);
		if (out.code !== code) await Deno.writeTextFile(file, out.code);
		const map = `${file}.map`;
		try {
			const m = JSON.parse(await Deno.readTextFile(map));
			if (m.debug_id !== out.id || m.debugId !== out.id) await Deno.writeTextFile(map, JSON.stringify({ ...m, debug_id: out.id, debugId: out.id }));
		} catch (e) {
			if (!(e instanceof Deno.errors.NotFound)) throw e;
		}
		console.log(`${file}: debug ID ${out.id}`);
	}
};

const run = async (cmd: string[], env: Record<string, string> = {}) => {
	const o = await new Deno.Command(cmd[0], { args: cmd.slice(1), env, stdin: "null", stdout: "piped", stderr: "piped" }).output();
	return { ok: o.success, out: decoder.decode(o.stdout), err: decoder.decode(o.stderr) };
};

type Spec = { upstream: string; org: string; slug: string; files: string[]; build: string; token: string };

const spec = async (): Promise<Spec> => JSON.parse(await Deno.readTextFile("errors/sourcemaps.json"));

export const upload = async () => {
	const s = await spec();
	if (!s.files.length || !s.slug) return console.log("errors: no bundles to map");
	const out = await Deno.makeTempDir({ prefix: "errors-maps-" });
	try {
		// The deno running this is on the build's PATH, which a launchd or CI shell may lack.
		const path = `${Deno.execPath().replace(/\/[^/]+$/, "")}:${Deno.env.get("PATH") ?? ""}`;
		const built = await run(["sh", "-c", s.build], { ERRORS_MAPS_OUT: out, PATH: path });
		if (!built.ok) throw new Error(`errors: the maps' build failed: ${built.err.slice(-2000)}`);
		const files: string[] = [];
		for (const f of s.files) {
			const copy = `${out}/${f}`;
			await inject([copy]);
			const [a, b] = [await Deno.readFile(copy), await Deno.readFile(f)];
			if (a.length !== b.length || a.some((x, i) => x !== b[i])) throw new Error(`errors: ${f} built again is not the bundle released; its map would lie`);
			files.push(copy, `${copy}.map`);
		}
		const token = Deno.env.get("ERRORS_UPLOAD_TOKEN") ?? (s.token ? (await run(["sh", "-c", s.token])).out.trim() : "");
		if (!token) throw new Error("errors: no uploader's token");
		const sent = await run(
			// sentry-cli from npm: its platform package carries the binary, so no install step runs.
			[Deno.execPath(), "run", "-A", "--no-config", "--quiet", "npm:@sentry/cli@2.58.2", "sourcemaps", "upload", "--org", s.org, "--project", s.slug, ...files],
			{ SENTRY_URL: s.upstream, SENTRY_AUTH_TOKEN: token, SENTRY_LOAD_DOTENV: "0", SENTRYCLI_SKIP_DOWNLOAD: "1" },
		);
		if (!sent.ok) throw new Error(`errors: sentry-cli upload: ${sent.err.slice(-2000)}`);
		console.log(`errors: maps of ${s.files.join(", ")} sent to ${s.upstream} (${s.org}/${s.slug})`);
	} finally {
		await Deno.remove(out, { recursive: true });
	}
};

if (import.meta.main) {
	const [verb, ...rest] = Deno.args;
	if (verb === "inject") await inject(rest.length ? rest : (await spec()).files);
	else if (verb === "upload") await upload();
	else {
		console.error("usage: sourcemaps.ts inject <file.js>... | upload");
		Deno.exit(2);
	}
}
