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
