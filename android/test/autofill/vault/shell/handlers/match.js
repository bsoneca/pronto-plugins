// A fold: which logins fill the probe. Kinds must agree, or an app packaged as
// paypal.com would collect the site's login. An app fills on its exact package; a site
// on its domain or any parent of it, so example.com fills login.example.com and
// never notexample.com; an app login pinned to a signing certificate fills only
// that package signed by it. Both hosts' autofill ask this file, nothing else.
// Recompute absolutely, write differentially: an unchanged answer writes nothing.
// A public or shared suffix is many owners' parent: a login saved for co.uk or
// github.io fills only that exact name, never everyone's site beneath it. The
// list is the commonest of the Public Suffix List, not all of it.
(state, event) => {
  const SHARED = ["github.io", "gitlab.io", "herokuapp.com", "appspot.com", "blogspot.com", "netlify.app",
    "vercel.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net",
    "cloudfront.net", "s3.amazonaws.com", "glitch.me", "fly.dev", "onrender.com", "repl.co"];
  const shared = (t) => SHARED.includes(t) || /^(co|com|org|net|gov|edu|ac|ne|or)\.[a-z]{2}$/.test(t);
  if (event.type === "refused") throw new Error(`store refused ${event.entity} (${event.kind})`);
  const probe = (state.rows.probe ?? [])[0];
  const target = probe === undefined ? "" : String(probe.target).toLowerCase();
  const fills = (login) => {
    const t = String(login.target).toLowerCase();
    if (target === "" || t === "" || login.kind !== probe.kind) return false;
    // A pinned app login fills only an app signed as it was: a package name is
    // anyone's to claim on a phone the real app is not installed on.
    if (probe.kind === "app") return t === target && (login.signer === "" || String(probe.signers).split(",").includes(login.signer));
    if (t === target) return true;
    return probe.kind === "web" && !shared(t) && target.endsWith("." + t);
  };
  const want = new Map((state.rows.login ?? []).filter(fills)
    .map((l) => [l.id, { title: l.title, username: l.username }]));
  const have = new Map((state.rows.candidate ?? []).map((c) => [c.id, c]));
  const drops = [...have.keys()].filter((id) => !want.has(id))
    .map((id) => ({ op: "delete", entity: "candidate", id }));
  const puts = [...want].filter(([id, row]) => {
    const c = have.get(id);
    return c === undefined || c.title !== row.title || c.username !== row.username;
  }).map(([id, row]) => ({ op: "put", entity: "candidate", id, row }));
  return { updates: [...drops, ...puts] };
}
