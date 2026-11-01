// pronto-ads in the page: a rewarded ad, which the player chooses to watch for something the app
// gives in return, never one that interrupts them. rewarded() shows it and resolves "viewed" once
// it played to its end, "dismissed" when it was closed before, "none" when there was no ad to
// show. With the app's AdSense publisher named (ads_spec.cue, written beside this module as
// ads_spec.js by the generate step) it is Google's (the Ad Placement API, H5 Games Ads), whose
// script loads at the first call or at prepare(), never before, so a page that never offers an ad
// never loads it; in test mode on a developer's machine. With none, it is a stand-in that plays at
// a press, as billing's stand-in Stripe pays at one. Only the page sees an ad: Google's ads for
// the web tell no server one was watched, so what a reward gives away the app's database bounds.
// Written by pronto-ads; regenerated, do not edit.
import { publisher } from './ads_spec.js';

let showing = null;

export function rewarded({ seconds = 5, name = 'reward' } = {}) {
  showing ??= (publisher ? google(name) : standIn(seconds)).finally(() => { showing = null; });
  return showing;
}

// Loads Google's script ahead of the first ad, where the page knows one may be offered soon (a
// player without a plan), so an ad is preloaded by the time they ask. A no-op for the stand-in.
export function prepare() {
  if (publisher) api().catch(() => {});
}

// Google's ad break: "viewed" or "dismissed" as the player's ad ended, "none" for every other
// status (notReady, timeout, noAdPreloaded, frequencyCapped, error, other) and where the script
// was refused or never answered (an ad blocker, a policy that does not admit Google).
const developer = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname) || location.hostname.endsWith('.localhost');
let loading = null;
function api() {
  loading ??= new Promise((ready, fail) => {
    const src = `https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-${publisher}`;
    const push = (o) => (globalThis.adsbygoogle ??= []).push(o);
    const script = document.createElement('script');
    script.async = true;
    script.crossOrigin = 'anonymous';
    if (developer) script.dataset.adbreakTest = 'on';
    script.onerror = () => fail(new Error('pronto-ads: the ad script was refused'));
    const late = setTimeout(() => fail(new Error('pronto-ads: the ad script never answered')), 10000);
    push({ preloadAdBreaks: 'on', onReady: () => { clearTimeout(late); ready(push); } });
    try {
      script.src = globalThis.trustedTypes
        ? trustedTypes.createPolicy('pronto-ads', { createScriptURL: (url) => { if (url !== src) throw new TypeError(`pronto-ads: ${url}`); return url; } }).createScriptURL(src)
        : src;
    } catch (e) { clearTimeout(late); fail(e); return; }
    document.head.append(script);
  }).catch((e) => { loading = null; throw e; });
  return loading;
}
async function google(name) {
  let push;
  try { push = await api(); } catch (e) { console.warn(e); return 'none'; }
  return new Promise((settle) => {
    let how = null;
    push({
      type: 'reward',
      name,
      // The player asked for the ad already: the app's own button is the reward prompt.
      beforeReward: (show) => show(),
      adViewed: () => { how = 'viewed'; },
      adDismissed: () => { how = 'dismissed'; },
      adBreakDone: (info) => settle(how ?? (['viewed', 'dismissed'].includes(info?.breakStatus) ? info.breakStatus : 'none')),
    });
  });
}

function standIn(seconds) {
  return new Promise((settle) => {
    const ad = document.createElement('dialog');
    ad.dataset.prontoAd = 'stand-in';
    ad.setAttribute('aria-label', 'Ad (stand-in)');
    ad.style.cssText = 'max-width:22rem;padding:20px;border:2px solid #222;border-radius:14px;background:#fff;color:#222;font:600 16px system-ui,sans-serif;text-align:center';
    const line = (text, css = '') => { const p = document.createElement('p'); p.textContent = text; p.style.cssText = 'margin:0 0 12px;' + css; return p; };
    const left = line('', 'font-size:28px;font-weight:800');
    const button = (name, text) => { const b = document.createElement('button'); b.type = 'button'; b.dataset.ad = name; b.textContent = text; b.style.cssText = 'margin:4px;min-height:44px;padding:0 16px;font:inherit;cursor:pointer'; return b; };
    const close = button('close', 'Close ad'), reward = button('reward', 'Get reward');
    reward.hidden = true;
    ad.append(line('Ad · stand-in', 'font-size:13px;text-transform:uppercase;letter-spacing:.08em;opacity:.7'), line('A real ad plays here once the app names its AdSense publisher.'), left, close, reward);
    let n = Math.max(0, Math.round(seconds)), timer = null;
    const tick = () => {
      left.textContent = n > 0 ? String(n) : '✓';
      if (n === 0) { clearInterval(timer); reward.hidden = false; reward.focus(); }
      n--;
    };
    const finish = (how) => { clearInterval(timer); ad.close(); ad.remove(); settle(how); };
    close.onclick = () => finish(reward.hidden ? 'dismissed' : 'viewed');
    reward.onclick = () => finish('viewed');
    ad.addEventListener('cancel', (e) => { e.preventDefault(); close.click(); });
    document.body.append(ad);
    ad.showModal();
    tick();
    timer = setInterval(tick, 1000);
  });
}
