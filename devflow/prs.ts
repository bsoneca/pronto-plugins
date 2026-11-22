// The hourly pull request watch (PRs left with no session driving them): gh reads each watched repository's
// open pull requests, flow.js forgottenPrs says which nobody is driving, and the line is what `status` and
// `pronto-devflow prs` print.
import { cmd } from "../intents/shell.ts";
import { forgottenLine, forgottenPrs } from "./flow.js";
import type { DevFlow } from "./spec.ts";

type Gh = (args: string[]) => Promise<{ ok: boolean; out: string; err: string }>;

/** A rollup entry as forgottenPrs reads it: a check run as it is, a commit status (`context`, `state`) in a check's words. */
// deno-lint-ignore no-explicit-any
const checkOf = (c: any) => ({
  name: c.name ?? c.context,
  conclusion: c.conclusion ?? (["FAILURE", "ERROR"].includes(c.state) ? "FAILURE" : c.state),
  completedAt: c.completedAt ?? c.startedAt,
});

/** The open pull requests of `repos` as forgottenPrs reads them. A gh failure throws, naming the call. */
export async function openPrs(repos: string[], gh: Gh = (a) => cmd("gh", a)) {
  const prs = [];
  for (const repo of repos) {
    const list = await gh(["pr", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", "number,isDraft"]);
    if (!list.ok) throw new Error(`gh pr list ${repo}: ${list.err.trim().split("\n")[0]}`);
    for (const p of JSON.parse(list.out) as { number: number; isDraft: boolean }[]) {
      if (p.isDraft) continue;
      const v = await gh(["pr", "view", String(p.number), "--repo", repo, "--json", "statusCheckRollup,commits,comments,reviews"]);
      if (!v.ok) throw new Error(`gh pr view ${repo}#${p.number}: ${v.err.trim().split("\n")[0]}`);
      const d = JSON.parse(v.out);
      prs.push({ repo, number: p.number, isDraft: false, commits: d.commits ?? [], comments: d.comments ?? [], reviews: d.reviews ?? [], checks: (d.statusCheckRollup ?? []).map(checkOf) });
    }
  }
  return prs;
}

/** The forgotten pull requests of the flow's `prs.repos`, and the line to print. */
export async function watchPrs(flow: DevFlow, now: Date, gh?: Gh) {
  const list = forgottenPrs(await openPrs(flow.prs.repos, gh), now, flow.prs.idleHours);
  return { list, line: forgottenLine(list) };
}
