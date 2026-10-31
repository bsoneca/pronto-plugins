// pronto-perf's reporter: a host-DOM hatch on every screen that measures how
// the app runs on this device, for the perf collector to turn into metrics.
// Written by pronto-perf; regenerated, do not edit.
//
// It knows nothing of what draws the page. While a canvas is on it, each
// frame's time is bucketed; long animation frames are counted by the script
// that held the main thread (a hatch's, the shell's, or another); interactions,
// the largest paint and layout shift are read from the browser's own entries;
// a WebGL context lost anywhere on the page is reported at once. A game may add
// what only it knows by dispatching, on its screen, once a frame:
//
//	screen.dispatchEvent(new CustomEvent("pronto:perf", {detail: {drawCalls, gpuMs, tier}}))
//
// What leaves the page is counts in buckets and the device's kind — a GPU
// family, a browser, an OS, mobile or desktop — never a renderer string, an
// address, or anything a reader typed. A browser that asks not to be tracked
// (Global Privacy Control, Do Not Track) reports nothing. `?perf=overlay` shows
// the same numbers on the page, sent or not.

import config from "./config.js";

const ENDPOINT = "__ENDPOINT__";
// Reports go this often, and when the page hides or a screen unmounts.
const PERIOD_MS = 30000;
// A frame this long is a visible hitch at any refresh rate.
const LONG_FRAME_MS = 50;
// A gap this long is the page throttled or stalled, not a frame drawn.
const STALL_MS = 1000;

const hex = (bytes) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
const kept = (key, mint) => {
	try {
		const value = sessionStorage.getItem(key);
		if (value !== null) return value;
		const minted = mint();
		sessionStorage.setItem(key, minted);
		return minted;
	} catch {
		return mint();
	}
};

const optedOut = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1";
// Decided once per tab, so a sampled session reports whole.
const sampled = kept("pronto-perf.sampled", () => (Math.random() < config.sample ? "1" : "0")) === "1";
const session = kept("pronto-perf.session", () => hex(16));
const overlay = new URLSearchParams(location.search).get("perf") === "overlay";
let reporting = !optedOut && sampled && kept("pronto-perf.refused", () => "0") === "0";

// The device's kind, read once.
const family = (renderer) => {
	const r = renderer.toLowerCase();
	if (r === "") return "none";
	if (/swiftshader|llvmpipe|software|basic render/.test(r)) return "software";
	if (/powervr|imagination/.test(r)) return "powervr";
	if (/adreno/.test(r)) return "adreno";
	if (/mali/.test(r)) return "mali";
	if (/apple/.test(r)) return "apple";
	if (/nvidia|geforce|quadro|rtx/.test(r)) return "nvidia";
	if (/amd|radeon/.test(r)) return "amd";
	if (/intel/.test(r)) return "intel";
	return "other";
};
const renderer = () => {
	try {
		const canvas = document.createElement("canvas");
		const gl = canvas.getContext("webgl2") ?? canvas.getContext("webgl");
		if (!gl) return "";
		const info = gl.getExtension("WEBGL_debug_renderer_info");
		const name = String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER));
		gl.getExtension("WEBGL_lose_context")?.loseContext();
		return name;
	} catch {
		return "";
	}
};
const browser = () => {
	const brands = (navigator.userAgentData?.brands ?? []).map((b) => b.brand);
	const ua = navigator.userAgent;
	if (brands.includes("Microsoft Edge") || /Edg(A|iOS)?\//.test(ua)) return "edge";
	if (brands.includes("Samsung Internet") || /SamsungBrowser\//.test(ua)) return "samsung";
	if (/Firefox\/|FxiOS\//.test(ua)) return "firefox";
	if (brands.includes("Google Chrome") || brands.includes("Chromium") || /Chrome\/|CriOS\//.test(ua)) return "chrome";
	if (/Safari\//.test(ua)) return "safari";
	return "other";
};
const os = () => {
	const ua = navigator.userAgent;
	if (/Android/.test(ua)) return "android";
	if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "ios";
	if (/CrOS/.test(ua)) return "chromeos";
	if (/Windows/.test(ua)) return "windows";
	if (/Mac OS X|Macintosh/.test(ua)) return "macos";
	if (/Linux/.test(ua)) return "linux";
	return "other";
};
let device;
const deviceOf = () => {
	device ??= {
		gpu: family(renderer()),
		browser: browser(),
		os: os(),
		form: matchMedia("(pointer: coarse)").matches ? "mobile" : "desktop",
	};
	return device;
};

// A histogram over one of the collector's boundary lists: a count per bucket,
// the last past every boundary, and the sum of what was added.
const histogram = (bounds) => ({
	bounds,
	counts: new Array(bounds.length + 1).fill(0),
	sum: 0,
	n: 0,
	add(v) {
		let i = 0;
		while (i < bounds.length && v > bounds[i]) i++;
		this.counts[i]++;
		this.sum += v;
		this.n++;
	},
	take() {
		const out = { counts: this.counts, sum: Math.round(this.sum * 1e6) / 1e6 };
		this.counts = new Array(bounds.length + 1).fill(0);
		this.sum = 0;
		this.n = 0;
		return out;
	},
});
const B = config.buckets;

// What each screen has measured since its last report.
const screens = new Map();
const recordOf = (name) => {
	let r = screens.get(name);
	if (!r) {
		r = {
			frame: histogram(B.frame),
			gpu: histogram(B.gpu),
			draws: histogram(B.draws),
			interaction: histogram(B.interaction),
			lcp: histogram(B.lcp),
			cls: histogram(B.cls),
			long: 0,
			loaf: new Map(),
			tier: undefined,
		};
		screens.set(name, r);
	}
	return r;
};
let current = "other";

let queue = [];
const push = (event) => queue.push({ id: hex(8), session, ...deviceOf(), ...event });
const send = (beacon) => {
	if (queue.length === 0) return;
	const body = JSON.stringify(queue);
	queue = [];
	if (!reporting) return;
	try {
		if (beacon && navigator.sendBeacon?.(ENDPOINT, body)) return;
		// A fetch, where it can wait, so a door with no collector behind it is
		// heard: the tab stops posting rather than failing every 30 seconds.
		fetch(ENDPOINT, { method: "POST", body, keepalive: true, headers: { "content-type": "application/json" } })
			.then((r) => {
				if (r.status === 404 || r.status >= 500) {
					reporting = false;
					try {
						sessionStorage.setItem("pronto-perf.refused", "1");
					} catch {}
				}
			})
			.catch(() => {});
	} catch {
		// Reporting never breaks what it reports on.
	}
};
const report = (beacon = false) => {
	for (const [name, r] of screens) {
		const tier = r.tier;
		for (const metric of ["frame", "gpu", "draws", "interaction", "lcp", "cls"]) {
			if (r[metric].n > 0) push({ type: "perf.hist", metric, screen: name, ...(tier ? { tier } : {}), ...r[metric].take() });
		}
		if (r.long > 0) push({ type: "perf.long", screen: name, ...(tier ? { tier } : {}), count: r.long });
		r.long = 0;
		for (const [source, l] of r.loaf) push({ type: "perf.loaf", screen: name, source, count: l.count, ms: Math.round(l.ms) });
		r.loaf.clear();
	}
	send(beacon);
};

// Once per page: the session's device, the browser's own entries, lost
// contexts, and the reports' clock.
if (!globalThis.__prontoPerf) {
	globalThis.__prontoPerf = true;
	const idle = globalThis.requestIdleCallback ?? ((f) => setTimeout(f, 2000));
	idle(() => {
		deviceOf();
		if (kept("pronto-perf.device", () => "0") === "0") {
			push({ type: "perf.device" });
			try {
				sessionStorage.setItem("pronto-perf.device", "1");
			} catch {}
			send(false);
		}
	});

	// A lost context is a blank game: reported at once, with its GPU's family,
	// from whatever canvas lost it. The event does not bubble; capture sees it.
	const context = (event) => () => {
		push({ type: "perf.context", event, screen: current });
		send(true);
	};
	addEventListener("webglcontextlost", context("lost"), true);
	addEventListener("webglcontextrestored", context("restored"), true);

	// A game's own numbers, from any screen.
	document.addEventListener(
		"pronto:perf",
		(e) => {
			const d = e.detail ?? {};
			const r = recordOf(current);
			if (Number.isFinite(d.drawCalls) && d.drawCalls >= 0) r.draws.add(d.drawCalls);
			if (Number.isFinite(d.gpuMs) && d.gpuMs >= 0) r.gpu.add(d.gpuMs / 1000);
			if (typeof d.tier === "string" && /^[a-z0-9-]{1,16}$/.test(d.tier)) r.tier = d.tier;
		},
		true,
	);

	const observe = (type, fn, opts = {}) => {
		try {
			if (!PerformanceObserver.supportedEntryTypes?.includes(type)) return;
			new PerformanceObserver((list) => list.getEntries().forEach(fn)).observe({ type, buffered: true, ...opts });
		} catch {}
	};
	// Long animation frames (Chromium): by the script that ran longest in it, or
	// `render` where no script did.
	const sourceOf = (entry) => {
		const top = [...(entry.scripts ?? [])].sort((a, b) => b.duration - a.duration)[0];
		if (!top) return "render";
		const url = top.sourceURL || "";
		const hatch = url.match(/\/hatches\/([a-z0-9_-]{1,32})\//);
		if (hatch) return `hatch-${hatch[1]}`;
		try {
			return new URL(url, location.href).origin === location.origin ? "shell" : "other";
		} catch {
			return "other";
		}
	};
	observe("long-animation-frame", (entry) => {
		const loaf = recordOf(current).loaf;
		const source = sourceOf(entry);
		const l = loaf.get(source) ?? { count: 0, ms: 0 };
		l.count++;
		l.ms += entry.blockingDuration ?? Math.max(0, entry.duration - 50);
		loaf.set(source, l);
	});
	// An interaction is its longest event (INP's measure).
	const interactions = new Map();
	observe(
		"event",
		(entry) => {
			if (!entry.interactionId) return;
			interactions.set(entry.interactionId, Math.max(interactions.get(entry.interactionId) ?? 0, entry.duration));
		},
		{ durationThreshold: 16 },
	);
	const takeInteractions = () => {
		for (const ms of interactions.values()) recordOf(current).interaction.add(ms / 1000);
		interactions.clear();
	};
	let lcp;
	let lcpScreen;
	observe("largest-contentful-paint", (entry) => {
		lcp = entry.startTime;
		lcpScreen ??= current;
	});
	let cls = 0;
	observe("layout-shift", (entry) => {
		if (!entry.hadRecentInput) cls += entry.value;
	});
	// The paint and the shift are the page's, counted once when it first hides.
	let pageCounted = false;
	const countPage = () => {
		if (pageCounted) return;
		pageCounted = true;
		if (lcp !== undefined) recordOf(lcpScreen).lcp.add(lcp / 1000);
		recordOf(current).cls.add(cls);
	};

	setInterval(() => {
		takeInteractions();
		report(false);
	}, PERIOD_MS);
	const leave = () => {
		takeInteractions();
		countPage();
		report(true);
	};
	document.addEventListener("visibilitychange", () => {
		if (document.visibilityState === "hidden") leave();
	});
	addEventListener("pagehide", leave);
}

// The on-page numbers, for whoever asked for them.
const overlayOf = () => {
	let el = document.getElementById("pronto-perf-overlay");
	if (!el) {
		el = document.createElement("pre");
		el.id = "pronto-perf-overlay";
		el.style.cssText =
			"position:fixed;top:4px;left:4px;z-index:2147483647;margin:0;padding:4px 6px;font:11px/1.3 ui-monospace,monospace;color:#0f0;background:rgba(0,0,0,.7);pointer-events:none;white-space:pre";
		document.body.append(el);
	}
	return el;
};

export default function mount(screen, { signal }) {
	const name = screen.dataset.screen ?? "other";
	current = name;
	const r = recordOf(name);

	// Frames, only while a canvas is on the page and the page is seen: a frame
	// loop on a still page would keep the device from idling.
	let raf = 0;
	let last;
	const recent = [];
	let lastDetail = {};
	const onDetail = (e) => {
		lastDetail = e.detail ?? {};
	};
	if (overlay) document.addEventListener("pronto:perf", onDetail, { capture: true, signal });
	const frame = (now) => {
		if (last !== undefined) {
			const ms = now - last;
			if (ms < STALL_MS) {
				r.frame.add(ms / 1000);
				if (ms > LONG_FRAME_MS) r.long++;
				if (overlay) {
					recent.push(ms);
					if (recent.length > 120) recent.shift();
				}
			}
		}
		last = now;
		raf = requestAnimationFrame(frame);
	};
	const watch = () => {
		const drawing = document.visibilityState === "visible" && document.querySelector("canvas") !== null;
		if (drawing && raf === 0) {
			last = undefined;
			raf = requestAnimationFrame(frame);
		} else if (!drawing && raf !== 0) {
			cancelAnimationFrame(raf);
			raf = 0;
		}
	};
	watch();
	const poll = setInterval(watch, 1000);
	document.addEventListener("visibilitychange", watch, { signal });

	const draw = overlay
		? setInterval(() => {
				const sorted = [...recent].sort((a, b) => a - b);
				const p = (q) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))].toFixed(1) : "–");
				const avg = recent.length ? recent.reduce((a, b) => a + b, 0) / recent.length : 0;
				const d = deviceOf();
				overlayOf().textContent = [
					`${avg ? (1000 / avg).toFixed(0) : "–"} fps  p50 ${p(0.5)}  p95 ${p(0.95)} ms`,
					`long ${r.long}  draws ${lastDetail.drawCalls ?? "–"}  gpu ${Number.isFinite(lastDetail.gpuMs) ? lastDetail.gpuMs.toFixed(1) : "–"} ms`,
					`${d.gpu} · ${d.browser} · ${d.os} · ${d.form}${lastDetail.tier ? ` · ${lastDetail.tier}` : ""}${reporting ? "" : "  (not sent)"}`,
				].join("\n");
			}, 500)
		: 0;

	return () => {
		clearInterval(poll);
		clearInterval(draw);
		if (raf !== 0) cancelAnimationFrame(raf);
		raf = 0;
		report(false);
	};
}
