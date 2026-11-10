// pronto-errors' reporter: a host-DOM hatch on every screen that reports what the page throws to
// the operator's GlitchTip, in the Sentry protocol, with no SDK. Written by pronto-errors;
// regenerated, do not edit.
//
// It reports uncaught errors, unhandled rejections and a script, link or image that failed to load
// (an error event does not bubble, so the capture phase of the window sees it). Each is one Sentry
// envelope, POSTed to the page's own origin (config.prefix: the app's door routes it to GlitchTip,
// so connect-src stays 'self'). An event holds the error's type, message and stack frames (without
// their query or hash) with the debug IDs of the bundles they run through (their source maps are
// GlitchTip's, sent at release, never the page's), the page's path (no query, no hash) and the release; no user, no cookie
// (the request omits them), no breadcrumb and nothing a reader typed.
//
// It reports only when the pronto-flags flag config.flag answers true, asked over OFREP on the
// page's own origin, as every other flag is. What is thrown before the flag answers is held, then
// sent or dropped. At most one report of each message, and twenty events a page load.

import config from "./config.js";

const MAX_EVENTS = 20;
const MAX_FRAMES = 50;
const MAX_TEXT = 1000;
const seen = new Set();
let taken = 0;
let held = [];
// pending until the flag and the release are known, then on or off for good.
let state = "pending";
let release = "unknown";
let started = false;

const hex = (bytes) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
const text = (value) => String(value ?? "").slice(0, MAX_TEXT);
// An address without its query or hash, where a token or an ad's parameters may be.
const bare = (address) => {
	try {
		const url = new URL(address, location.href);
		return url.origin === "null" ? text(address).split(/[?#]/)[0] : url.origin + url.pathname;
	} catch {
		return text(address).split(/[?#]/)[0];
	}
};

// The frames of an Error's stack, Chrome's ("    at fn (file:1:2)", "    at file:1:2") or Firefox's
// and Safari's ("fn@file:1:2"), the oldest call first as Sentry reads them.
const CHROME = /^\s*at (?:async )?(?:(.+?) \()?(.+?):(\d+):(\d+)\)?\s*$/;
const GECKO = /^\s*(.*?)@(.+?):(\d+):(\d+)\s*$/;
export const frames = (stack) => {
	const out = [];
	for (const line of String(stack ?? "").split("\n")) {
		const m = CHROME.exec(line) ?? GECKO.exec(line);
		if (m) {
			const file = bare(m[2]);
			out.push({ function: m[1] || "?", filename: file, abs_path: file, lineno: Number(m[3]), colno: Number(m[4]) });
		}
	}
	return out.reverse().slice(-MAX_FRAMES);
};

// The debug IDs of the bundles a stack runs through, as GlitchTip finds their source maps: each
// bundle built with one (errors/sourcemaps.ts inject) set globalThis._sentryDebugIds[its own stack] =
// its ID as it loaded, so the newest frame of that stack names the file it was loaded from.
export const debugImages = (stacktrace, ids = globalThis._sentryDebugIds) => {
	const used = new Set(stacktrace.map((f) => f.abs_path));
	const images = [];
	for (const [stack, id] of Object.entries(ids ?? {})) {
		const file = frames(stack).at(-1)?.abs_path;
		if (file && used.has(file)) images.push({ type: "sourcemap", code_file: file, debug_id: text(id) });
	}
	return images;
};

const send = (event) => {
	const body = [JSON.stringify({ event_id: event.event_id, sent_at: new Date().toISOString() }), JSON.stringify({ type: "event" }), JSON.stringify(event)].join("\n");
	fetch(`${config.prefix}/api/${config.project}/envelope/?sentry_key=${config.key}&sentry_version=7`, {
		method: "POST",
		body,
		keepalive: true,
		credentials: "omit",
		headers: { "content-type": "text/plain;charset=UTF-8" },
	}).catch(() => {});
};

const event = (type, value, stacktrace) => ({
	event_id: hex(16),
	timestamp: Date.now() / 1000,
	platform: "javascript",
	level: "error",
	release,
	environment: "production",
	exception: { values: [{ type, value, stacktrace: { frames: stacktrace } }] },
	debug_meta: { images: debugImages(stacktrace) },
	request: { url: location.origin + location.pathname },
	sdk: { name: "pronto-errors", version: "1" },
});

const report = (type, value, stacktrace) => {
	if (state === "off" || taken >= MAX_EVENTS) return;
	const key = `${type}: ${value}`;
	if (seen.has(key)) return;
	seen.add(key);
	taken++;
	const e = event(type, value, stacktrace);
	if (state === "pending") held.push(e);
	else send(e);
};

const settle = (next) => {
	state = next;
	if (next === "on") for (const e of held) send({ ...e, release });
	held = [];
};

const failed = new Set(["script", "link", "img"]);
const onError = (e) => {
	const target = e.target;
	if (target && target !== globalThis && failed.has(target.localName)) {
		report("LoadError", `Failed to load ${target.localName} ${bare(target.src || target.href)}`, []);
		return;
	}
	const error = e.error;
	if (error instanceof Error) report(text(error.name || "Error"), text(error.message), frames(error.stack));
	else report("Error", text(e.message), e.filename ? [{ function: "?", filename: bare(e.filename), abs_path: bare(e.filename), lineno: e.lineno, colno: e.colno }] : []);
};
const onRejection = (e) => {
	const reason = e.reason;
	if (reason instanceof Error) report(text(reason.name || "Error"), text(reason.message), frames(reason.stack));
	else report("UnhandledRejection", text(reason), []);
};

// The release this page runs: its entry's address map (`#pronto-assets`) names every file the page
// loads by its content address, so a digest of it changes with the release and with nothing else.
const releaseOf = async () => {
	try {
		const map = document.getElementById("pronto-assets")?.textContent;
		if (!map) return "unknown";
		const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(map));
		return [...new Uint8Array(digest).slice(0, 6)].map((b) => b.toString(16).padStart(2, "0")).join("");
	} catch {
		return "unknown";
	}
};

const flagOn = async () => {
	try {
		const res = await fetch(`/ofrep/v1/evaluate/flags/${config.flag}`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ context: {} }),
		});
		return res.ok && (await res.json())?.value === true;
	} catch {
		return false;
	}
};

// A host-DOM hatch is mounted on each screen and must answer with its cleanup. The reporter is the
// page's, not the screen's: it starts once and stays, so there is nothing to undo.
const nothing = () => {};

export default function mount() {
	if (started || !config.project || !config.key) return nothing;
	started = true;
	addEventListener("error", onError, true);
	addEventListener("unhandledrejection", onRejection);
	Promise.all([flagOn(), releaseOf()]).then(([on, id]) => {
		release = id;
		settle(on ? "on" : "off");
		// Whether it reports is the page's to show: a check waits for it before it throws.
		document.documentElement.dataset.errors = on ? "on" : "off";
	});
	return nothing;
}
