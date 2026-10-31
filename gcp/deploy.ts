// `deploy gcp` and `release` (docs/intents.md): a pronto app that keeps rows on a server goes
// online where its release.cue says, on Cloud Run (GCP, its own service and Cloud SQL database in a
// Google Cloud project, as pronto's release@gcp makes them) or on a Kubernetes cluster (App, pronto's
// release@k8s). An app with no release target is given one on Cloud Run in the project it is told
// (release_target.ts), never one by default; its plan is rendered before anything is made, the
// app's own checks run, and only then, asked for, does it go out. Each step is checked, applied
// where it is the program's, and a gate where only a person can act; what it touches is passed in
// (Deps).
import { inShared, needsCloud, releaseCue, withTarget } from "./release_target.ts";
import type { Step } from "../intents/run.ts";

/** Where an app's release.cue releases it: Cloud Run (GCP), a Kubernetes cluster (App), or
 * nowhere yet. */
export function releasedTo(release: string): "gcp" | "k8s" | null {
  if (/^GCP:\s*schema\.#Release\b/m.test(release)) return "gcp";
  if (/^App:\s*schema\.#ReleaseSpec\b/m.test(release)) return "k8s";
  return null;
}

/** Whether the app's .say.yaml has a release rule for `target` (release@<target>). */
export const hasReleaseRule = (sayYaml: string, target: string) =>
  new RegExp(`^ {2}release:\\n(?: {4,}.*\\n)*? +platform: ${target}\\s*$`, "m").test(sayYaml);

/** What the release's plan says of it: release@gcp's (gcp/schema's #Build plan), or a Kubernetes
 * release's name and the address its gateway answers at (origin). */
export interface Plan {
  target: "gcp" | "k8s";
  service: string;
  project?: string;
  region?: string;
  readSecrets?: string[];
  origin?: string;
}

export interface Deps {
  /** The app's folder, and its name (the folder's). */
  dir: string;
  app: string;
  read(path: string): Promise<string | null>;
  write(path: string, text: string): Promise<void>;
  /** The app's own CUE sources. */
  cues(): Promise<string[]>;
  /** A sayt verb in the app's folder: whether it passed, the end of what it said, and all of it. */
  saytw(verb: string, env?: Record<string, string>): Promise<{ ok: boolean; out: string; full?: string }>;
  /** The release's plan, rendered as its release renders it (gcpRelease.plan, a cluster's
   * manifests), which is the dry run: nothing is made. */
  plan(target: "gcp" | "k8s"): Promise<{ plan: Plan } | { error: string }>;
  /** Where the release answers, null where it is not out yet. */
  address(p: Plan): Promise<string | null>;
  fetch: typeof fetch;
}

export interface Options {
  /** The project and region a new release target names: the project has no default, and an app
   * with no release.cue waits for it. */
  project?: string;
  region: string;
  /** Whether to release: without it the intent stops at a gate, every check passed. */
  release?: boolean;
  /** A project shared with other apps, as a host that releases apps (a hosted builder) names it: a
   * release there goes out without a warm preview, only with a pronto that keeps each app's
   * secrets its own, and only from that host. None by default. */
  shared?: string;
  /** Whether that host releases: an app in its shared project goes out from it alone. */
  studio?: boolean;
}

const RELEASE = "release.cue";

export function steps(d: Deps, o: Options): Step[] {
  const program = async () => (await d.read(`${d.dir}/program.cue`)) ?? "";
  const cloud = { project: o.project ?? "", region: o.region };
  const sharedCloud = o.shared ? { project: o.shared, region: o.region } : null;
  let planned: Plan | null = null;
  let released = false;
  let target: "gcp" | "k8s" = "gcp";
  return [
    {
      name: "keeps rows on a server",
      check: async () =>
        needsCloud((await d.cues()).join("\n"))
          ? { done: true }
          : { gate: `${d.app} keeps nothing on a server, so it needs no Cloud Run: it goes online as a web app (release@pages).` },
    },
    {
      name: "a release target",
      check: async () => {
        const rel = await d.read(`${d.dir}/${RELEASE}`);
        if (rel === null && !o.project) return { gate: `${RELEASE} names no release yet: say the Google Cloud project of yours to release it to, --project <id>` };
        if (rel === null) return { todo: `${RELEASE} names no release yet: Cloud Run in ${o.project}` };
        const to = releasedTo(rel);
        if (to === null) return { gate: `${RELEASE} declares no GCP or Kubernetes release, and it is the author's file: add one (pronto's docs/release-targets.md).` };
        target = to;
        if (to === "k8s") return { done: true, note: "a Kubernetes cluster" };
        const listed = (await d.cues()).some((c) => /targets:\s*\[[^\]]*"gcp"/.test(c));
        return listed ? { done: true, note: /project:\s*"([^"]+)"/.exec(rel)?.[1] ?? "" } : { todo: `the program lists no "gcp" among its targets` };
      },
      apply: async () => {
        // As a hosted builder writes it too: gcp among the program's targets where it lists
        // them, else in release.cue; an existing release.cue only gains the target.
        const src = await program();
        const listed = withTarget(src, "gcp");
        const rel = await d.read(`${d.dir}/${RELEASE}`);
        const extra = listed === null ? `\ncode: meta: targets: ["gcp"]\n` : "";
        await d.write(`${d.dir}/${RELEASE}`, (rel ?? releaseCue(src, d.app, cloud)) + (rel !== null && listed !== null ? "" : extra));
        if (listed !== null && listed !== src) await d.write(`${d.dir}/program.cue`, listed);
      },
    },
    {
      name: "generated with its release rule",
      check: async () =>
        hasReleaseRule((await d.read(`${d.dir}/.say.yaml`)) ?? "", target) ? { done: true } : { todo: `the app has no release@${target} rule yet` },
      apply: async () => {
        const r = await d.saytw("generate");
        if (!r.ok) throw new Error(`./saytw generate: ${r.out}`);
      },
    },
    {
      name: "the release's plan",
      check: async () => {
        const r = await d.plan(target);
        if ("error" in r) return { gate: `release@${target}'s plan does not render: ${r.error}` };
        planned = r.plan;
        if (r.plan.target === "k8s") return { done: true, note: `${r.plan.service} at ${r.plan.origin}` };
        // Beside other apps, only a pronto that grants an app its own secrets alone (its plan's
        // readSecrets): an older one grants them on the whole project.
        if (sharedCloud && r.plan.project === sharedCloud.project && !r.plan.readSecrets) {
          return { gate: `${d.app}'s pronto would let it read the other apps' secrets in ${r.plan.project}: update its pronto (mise.toml), then run again.` };
        }
        return { done: true, note: `service ${r.plan.service} in ${r.plan.project}, ${r.plan.region}` };
      },
    },
    {
      name: "linted and tested",
      check: async () => {
        for (const verb of ["lint", "test"]) {
          const r = await d.saytw(verb);
          if (!r.ok) return { gate: `./saytw ${verb} fails, so nothing goes out:\n${r.out}` };
        }
        return { done: true };
      },
    },
    {
      name: "released",
      check: async () => {
        if (released) return { done: true };
        const at = planned && await d.address(planned);
        if (o.release && !o.studio && o.shared && planned?.project === o.shared) {
          return { gate: `${d.app} runs in ${o.shared}, beside the builder's apps: release it from the builder.` };
        }
        if (o.release) return { todo: at ? `a new version of ${at}` : "its first release" };
        if (at) return { done: true, note: `${at} (--release puts out a new version)` };
        return { gate: `every check passed: run again with --release to make its service and database${o.shared ? `, or release it from the builder when it is one of the builder's apps` : ""}.` };
      },
      apply: async () => {
        const rel = (await d.read(`${d.dir}/${RELEASE}`)) ?? "";
        // An app in the shared project goes out without the warm preview a release otherwise tests
        // first, as a hosted builder releases it.
        const r = await d.saytw(`release@${target}`, target === "gcp" && inShared(rel, sharedCloud) ? { SAY_RELEASE_ARGS_NO_GATE: "true" } : {});
        if (!r.ok) throw new Error(`./saytw release@${target}: ${r.out}`);
        released = true;
      },
    },
    {
      name: "answers",
      check: async () => {
        const at = planned && await d.address(planned);
        if (!at) return { todo: "no address yet" };
        const res = await d.fetch(at, { redirect: "manual" }).catch((e) => ({ status: 0, statusText: (e as Error).message, body: null }) as unknown as Response);
        await res.body?.cancel();
        return res.status > 0 && res.status < 500 ? { done: true, note: at } : { gate: `${at} answers ${res.status || res.statusText}: its logs are in ${target === "gcp" ? "Cloud Run's console" : "the cluster (kubectl logs)"}.` };
      },
    },
  ];
}
