// pronto-ads in the page: a rewarded ad, which the player chooses to watch for something the app
// gives in return, never one that interrupts them. rewarded() shows it and resolves "viewed" once
// it played to its end, "dismissed" when it was closed before, "none" when there was no ad to
// show, and "none" too when the provider failed: that is an expected outcome of an ad, so the
// failure is reported (reportError, which error tracking sees) and kept in rewarded.reason, and the
// promise never rejects. Here it is a stand-in that plays at a press, as billing's stand-in Stripe pays at one;
// Google's ads (the Ad Placement API, H5 Games Ads) take its place once the app names its AdSense
// publisher and the door admits Google's scripts. Only the page sees an ad: Google's ads for the
// web tell no server one was watched, so what a reward gives away the app's database bounds.
// Written by pronto-ads; regenerated, do not edit.

let showing = null;

export function rewarded({ seconds = 5 } = {}) {
  if (showing) return showing;
  rewarded.reason = '';
  showing = new Promise((settle) => {
    let ad = null, timer = null;
    // A provider that fails: the dialog is cleared away, the failure reported, and the ad is "none".
    const fail = (error) => {
      clearInterval(timer); ad?.remove();
      // Cleared once `showing` has been assigned: a failure here is synchronous, before the assignment.
      queueMicrotask(() => { showing = null; });
      rewarded.reason = String(error?.message ?? error);
      reportError(error);
      settle('none');
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
      const finish = (how) => { clearInterval(timer); ad.close(); ad.remove(); showing = null; settle(how); };
      close.onclick = () => finish(reward.hidden ? 'dismissed' : 'viewed');
      reward.onclick = () => finish('viewed');
      ad.addEventListener('cancel', (e) => { e.preventDefault(); close.click(); });
      document.body.append(ad);
      ad.showModal();
      tick();
      timer = setInterval(tick, 1000);
    } catch (error) { fail(error); }
  });
  return showing;
}
rewarded.reason = '';
