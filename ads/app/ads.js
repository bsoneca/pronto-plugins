// pronto-ads in the page: a rewarded ad, which the player chooses to watch for something the app
// gives in return, never one that interrupts them. rewarded() shows it and resolves "viewed" once
// it played to its end, "dismissed" when it was closed before, "none" when there was no ad to
// show. An unexpected failure is none of them: it rejects, after the failed ad is cleared away, so the
// next ask starts again; a real provider's adapter maps its no-fill and network failures to "none".
// Off the app's own origin (ads_site.js: a preview, ci, a developer's machine, or an app that names
// no publisher) it is a stand-in that plays at a press, as billing's stand-in Stripe pays at one.
// On it, Google's ads (H5 Games Ads) play in a document of their own, at another origin, in a frame
// this page makes (prepare()) and talks to by postMessage: no Google script ever runs in this page.
// `?ads=google-test` on the app's origin asks Google for test ads, which pay nothing and count for
// nothing. Only the page sees an ad: Google's ads for the web tell no server one was watched, so
// what a reward gives away the app's database bounds.
// Written by pronto-ads; regenerated, do not edit.
import { frame as FRAME, site as SITE } from './ads_site.js';

const TYPE = 'pronto-ads';
const EVENTS = ['beforeReward', 'beforeAd', 'afterAd', 'adViewed', 'adDismissed', 'done'];
const NAMES = ['purse', 'review'];
// Once the ad has started, how long Google's API may take to end it.
const CAP_SECONDS = 180;
const SANDBOX = 'allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox';
// Off screen until an ad plays, then the whole viewport: an ad's overlay covers only its own frame.
const HIDDEN = 'position:fixed;left:-9999px;top:0;width:0;height:0;border:0';
const SHOWN = 'position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483647';

/** Which ads play: "stand-in" off the app's origin or with no ad document named, else "google",
 * and "google-test" with `?ads=google-test` in `search`. */
export function mode({ site, frame, origin, search }) {
  if (!site || !frame || frame === site || origin !== site) return 'stand-in';
  return new URLSearchParams(search).get('ads') === 'google-test' ? 'google-test' : 'google';
}

/** The ad document's address: test ads (`?test=on`) only in the test mode. */
export function frameUrl(frame, test) {
  return `${frame}/break${test ? '?test=on' : ''}`;
}

/** The adapter, on its environment: the app's `site` and `frame`, and the page's `location`,
 * `document`, `window`, timers and ids, each the page's own unless a test gives it. */
export function adapter(env = {}) {
  const site = () => env.site ?? SITE;
  const frame = () => env.frame ?? FRAME;
  const loc = () => env.location ?? globalThis.location;
  const doc = () => env.document ?? globalThis.document;
  const win = () => env.window ?? globalThis;
  const later = (f, seconds) => (env.setTimeout ?? globalThis.setTimeout.bind(globalThis))(f, seconds * 1000);
  const unlater = (h) => (env.clearTimeout ?? globalThis.clearTimeout.bind(globalThis))(h);
  const newId = () => (env.newId ?? (() => globalThis.crypto.randomUUID()))();
  const modeNow = () => mode({ site: site(), frame: frame(), origin: loc()?.origin, search: loc()?.search ?? '' });

  let showing = null;
  // The ad document's frame, whether its bridge said it is ready, and the break in flight.
  let box = null, ready = false, call = null;

  const shape = (css) => { if (box) box.style.cssText = css; };

  // The ad document's frame, made once: nothing is asked of Google before an app that allows ads says so.
  function prepare() {
    const m = modeNow();
    if (m === 'stand-in' || box) return;
    const d = doc();
    const f = d.createElement('iframe');
    f.src = frameUrl(frame(), m === 'google-test');
    f.title = 'Ad';
    f.setAttribute('sandbox', SANDBOX);
    f.setAttribute('allow', 'autoplay');
    f.style.cssText = HIDDEN;
    win().addEventListener('message', onMessage);
    d.body.append(f);
    box = f;
  }

  // The page tells the frame, and only the frame's origin.
  const tell = (m) => box.contentWindow.postMessage({ type: TYPE, v: 1, ...m }, frame());

  function onMessage(e) {
    const d = e.data;
    // Only the ad document's own frame, in this exact shape; Google's own messages, and anyone else's, are dropped.
    if (!box || e.origin !== frame() || e.source !== box.contentWindow) return;
    if (!d || typeof d !== 'object' || d.type !== TYPE || d.v !== 1) return;
    if (d.breakStatus !== undefined && (typeof d.breakStatus !== 'string' || d.breakStatus.length > 32)) return;
    if (d.event === 'ready') {
      if (d.id !== null) return;
      ready = true;
      if (call && !call.sent) sendBreak(call);
      return;
    }
    // Only the break in flight, and only an event of the contract: a late one, a stale one, any other is ignored.
    if (!call || d.id !== call.id || !EVENTS.includes(d.event)) return;
    const c = call;
    try {
      if (d.event === 'beforeReward') {
        if (c.started) return;
        c.started = true;
        unlater(c.waitTimer);
        c.capTimer = later(() => c.settle('none'), CAP_SECONDS);
        shape(SHOWN);
        // The ad plays once the frame covers the page, never before.
        tell({ op: 'show', id: c.id });
      } else if (d.event === 'done') {
        c.settle(c.result ?? (d.breakStatus === 'viewed' ? 'viewed' : d.breakStatus === 'dismissed' ? 'dismissed' : 'none'));
      } else if (!c.started) {
        // An event of an ad that never started is none of the contract's order.
      } else if (d.event === 'beforeAd') {
        if (!c.muted) { c.muted = true; c.onStart?.(); }
      } else if (d.event === 'afterAd') {
        c.unmute();
      } else if (d.event === 'adViewed') {
        c.result ??= 'viewed';
      } else if (d.event === 'adDismissed') {
        c.result ??= 'dismissed';
      }
    } catch (error) { c.fail(error); }
  }

  function sendBreak(c) {
    c.sent = true;
    tell({ op: 'break', id: c.id, name: c.name });
  }

  function google({ wait = 15, name = 'purse', onStart, onEnd }) {
    if (!NAMES.includes(name)) return Promise.reject(new TypeError(`rewarded: name is one of ${NAMES.join(', ')}`));
    let resolve, reject;
    // `showing` is set before anything can fail, so a failure clears it after.
    showing = new Promise((yes, no) => { resolve = yes; reject = no; });
    const c = { id: newId(), name, started: false, sent: false, muted: false, result: null, onStart, waitTimer: null, capTimer: null };
    // The frame is cleared away, the sound given back, and the next ask starts again.
    const end = () => {
      if (call !== c) return false;
      call = null;
      unlater(c.waitTimer); unlater(c.capTimer);
      shape(HIDDEN);
      showing = null;
      return true;
    };
    c.unmute = () => { if (c.muted) { c.muted = false; onEnd?.(); } };
    c.settle = (how) => {
      if (!end()) return;
      try { c.unmute(); } catch (error) { reject(error); return; }
      resolve(how);
    };
    c.fail = (error) => {
      if (!end()) return;
      try { c.unmute(); } catch { /* the first failure is the one to say */ }
      reject(error);
    };
    const p = showing;
    try {
      prepare();
      call = c;
      // Only the time before the ad starts is waited for.
      c.waitTimer = later(() => c.settle('none'), wait);
      if (ready) sendBreak(c);
    } catch (error) { call = c; c.fail(error); }
    return p;
  }

  // The stand-in: a dialog that plays at a press. `wait` bounds only the time before an ad starts, and the
  // stand-in starts at once, so it has none to bound; `onStart` and `onEnd` bracket it as they bracket a Google ad.
  function standIn({ seconds = 5, onStart, onEnd } = {}) {
    showing = new Promise((settle) => {
      let ad = null, timer = null;
      // An unexpected failure clears the failed ad away and propagates: the promise rejects.
      // `showing` is cleared once it has been assigned (a failure here is synchronous, before the assignment).
      const fail = (error) => {
        clearInterval(timer); ad?.remove();
        queueMicrotask(() => { showing = null; });
        throw error;
      };
      try {
        ad = document.createElement('dialog');
        ad.dataset.prontoAd = 'stand-in';
        ad.setAttribute('aria-label', 'Ad (stand-in)');
        ad.style.cssText = 'max-width:22rem;padding:20px;border:2px solid #222;border-radius:14px;background:#fff;color:#222;font:600 16px system-ui,sans-serif;text-align:center';
        const line = (text, css = '') => { const p = document.createElement('p'); p.textContent = text; p.style.cssText = 'margin:0 0 12px;' + css; return p; };
        const left = line('', 'font-size:28px;font-weight:800');
        const button = (name, text) => { const b = document.createElement('button'); b.type = 'button'; b.dataset.ad = name; b.textContent = text; b.style.cssText = 'margin:4px;min-height:44px;padding:0 16px;font:inherit;cursor:pointer'; return b; };
        const close = button('close', 'Close ad'), reward = button('reward', 'Get reward');
        reward.hidden = true;
        ad.append(line('Ad · stand-in', 'font-size:13px;text-transform:uppercase;letter-spacing:.08em;opacity:.7'), line('A real ad plays here where the app is released.'), left, close, reward);
        let n = Math.max(0, Math.round(seconds));
        const tick = () => {
          left.textContent = n > 0 ? String(n) : '✓';
          if (n === 0) { clearInterval(timer); reward.hidden = false; reward.focus(); }
          n--;
        };
        const finish = (how) => {
          clearInterval(timer); ad.close(); ad.remove(); showing = null;
          try { onEnd?.(); } finally { settle(how); }
        };
        close.onclick = () => finish(reward.hidden ? 'dismissed' : 'viewed');
        reward.onclick = () => finish('viewed');
        ad.addEventListener('cancel', (e) => { e.preventDefault(); close.click(); });
        document.body.append(ad);
        ad.showModal();
        onStart?.();
        tick();
        timer = setInterval(tick, 1000);
      } catch (error) { fail(error); }
    });
    return showing;
  }

  function rewarded(options = {}) {
    if (showing) return showing;
    if (modeNow() === 'stand-in') return standIn(options);
    return google(options);
  }

  return { rewarded, prepare };
}

export const { rewarded, prepare } = adapter();
