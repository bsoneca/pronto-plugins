// runners' rules, pure: what applying a setup's plan does, given what runners.ts found in the cluster.
// runners.ts observes, asks these, then runs the steps in order; the cases are suite `runners`
// (tests/unit/runners.cue).

/**
 * The steps of an apply, in order. `seen`: whether the setup's Colima VM runs (a Colima setup's
 * only), the scale set releases already in the runners' namespace, whether the secret is there.
 * Without the secret it stops after BuildKit: no scale set registers without it.
 */
export function steps(plan, seen) {
  const out = [];
  if (plan.colima && !seen.vm) out.push({ do: 'start-vm' });
  out.push({ do: 'controller' }, { do: 'buildkit' }, { do: 'namespace' });
  if (!seen.secret) return [...out, { do: 'need-secret' }];
  const wanted = Object.keys(plan.scaleSets).sort();
  for (const name of wanted) out.push({ do: 'scale-set', name });
  // A scale set the setup no longer names: its runners would keep taking jobs.
  for (const name of [...seen.releases].sort()) if (!wanted.includes(name)) out.push({ do: 'remove', name });
  return out;
}

/** How a person creates the setup's secret: its values come from them, never from the setup. */
export function secretHelp(plan) {
  const repos = [...new Set(Object.values(plan.scaleSets).map((s) => s.githubConfigUrl.replace('https://github.com/', '')))];
  const create = `kubectl --context ${plan.context} -n ${plan.runnerNamespace} create secret generic ${plan.secret.name}`;
  if (plan.secret.kind === 'app') {
    return [
      `A GitHub App installed on ${repos.join(', ')} with Administration: read and write (repository) or Self-hosted runners: read and write (organization), then:`,
      `${create} --from-literal=github_app_id=<id> --from-literal=github_app_installation_id=<installation> --from-file=github_app_private_key=<key.pem>`,
    ];
  }
  return [
    `A fine-grained token for ${repos.join(', ')} with Administration: read and write (an organization's: Self-hosted runners: read and write), then:`,
    `read -rs t && ${create} --from-literal=github_token="$t"; unset t`,
  ];
}

/**
 * A host setup's apply, in order, runner by runner (by name): `seen[name]` says whether its folder
 * holds the runner (`installed`), its `registration` (registration() below), and whether its
 * launchd agent is the plan's and loaded (`agent`). A stale registration is undone first, since
 * config.sh refuses a registered folder, and the agent reloaded after, onto the new one.
 */
export function hostSteps(plan, seen) {
  const out = [];
  for (const name of Object.keys(plan.host).sort()) {
    const s = seen[name] ?? {};
    if (!s.installed) out.push({ do: 'install', name });
    if (s.registration === 'stale') out.push({ do: 'unregister', name });
    if (s.registration !== 'current') out.push({ do: 'register', name });
    if (!s.agent || s.registration !== 'current') out.push({ do: 'agent', name });
  }
  return out;
}

/**
 * A host runner's registration, from what runners.ts found: its .runner file (`runner`, parsed, or
 * null), its .path (`path`) and the labels GitHub holds for it (`labels`, null when gh can't say).
 * `none`, `current` (what the plan registers), or `stale` (registered otherwise: another repository,
 * name, work folder, PATH or labels).
 */
export function registration(plan, name, found) {
  const r = plan.host[name];
  if (!found.runner) return 'none';
  const f = Object.fromEntries(Object.entries(found.runner).map(([k, v]) => [k.toLowerCase(), v]));
  const same = f.agentname === name && f.githuburl === r.url && f.workfolder === r.work && (found.path ?? '').trim() === r.path;
  const labels = found.labels === null || r.labels.every((l) => found.labels.includes(l));
  return same && labels ? 'current' : 'stale';
}

/** config.sh's arguments for a host runner, the token left out: runners.ts adds it, never a file. */
export function registerArgs(plan, name) {
  const r = plan.host[name];
  return ['--unattended', '--url', r.url, '--name', name, '--labels', r.labels.join(','), '--work', r.work, '--replace'];
}

/** What a person runs when gh can't fetch the registration token (no admin on the repository). */
export function registerHelp(plan, name) {
  const r = plan.host[name];
  return [
    `A registration token for ${r.url.replace('https://github.com/', '')} needs admin on it. With a gh login that has it:`,
    `cd ${r.dir} && ./config.sh ${registerArgs(plan, name).join(' ')} --token "$(gh api -X POST ${r.api}/registration-token --jq .token)"`,
  ];
}
