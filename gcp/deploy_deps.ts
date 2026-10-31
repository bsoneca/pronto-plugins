// What `deploy` and `release` touch on the machine (deploy.ts's Deps): the app's files, its sayt
// verbs, its release's plan rendered with its own cue, and where the release answers.
import { basename, join } from "jsr:@std/path@1.1.2";
import { appSaytw, cmd } from "../intents/shell.ts";
import type { Deps, Plan } from "./deploy.ts";

export function deployDeps(dir: string): Deps {
  // The app's own cue, as its release runs it.
  const cue = async (expr: string, out: "json" | "text") => {
    const r = await cmd("./saytw", ["--script", "tools.nu", "mise", "exec", "--", "cue", "export", ".", "-e", expr, "--out", out], { cwd: dir });
    return r.ok ? { ok: true as const, out: r.out } : { ok: false as const, out: r.err.split("\n").filter((l) => l.trim() && !/mise (tool-stub|exec)/.test(l)).slice(0, 4).join("\n") };
  };
  return {
    dir,
    app: basename(dir),
    read: (p) => Deno.readTextFile(p).catch(() => null),
    write: (p, t) => Deno.writeTextFile(p, t),
    cues: async () => {
      const out: string[] = [];
      for await (const e of Deno.readDir(dir)) if (e.isFile && e.name.endsWith(".cue")) out.push(await Deno.readTextFile(join(dir, e.name)));
      return out;
    },
    saytw: (verb, env) => appSaytw(dir, verb, env),
    plan: async (target) => {
      if (target === "gcp") {
        const r = await cue("gcpRelease.plan", "json");
        return r.ok ? { plan: { target, ...JSON.parse(r.out) } as Plan } : { error: r.out };
      }
      // A cluster's release renders its manifests from the app's metal environment (release.cue's
      // metalManifests), which is its dry run; it answers at its gateway's host.
      const manifests = await cue("metalManifests", "text");
      if (!manifests.ok) return { error: manifests.out };
      const app = await cue("{name: App.name, host: App.gateway.host}", "json");
      if (!app.ok) return { error: app.out };
      const { name, host } = JSON.parse(app.out) as { name: string; host: string };
      return { plan: { target, service: name, origin: `https://${host}` } };
    },
    address: async (p) => {
      if (p.target === "k8s") {
        // Out where its gateway answers with its door (caddy), not a 404 of the tunnel's.
        const res = await fetch(p.origin!, { method: "HEAD" }).catch(() => null);
        return res && /caddy/i.test(res.headers.get("via") ?? res.headers.get("server") ?? "") ? p.origin! : null;
      }
      const r = await cmd("gcloud", ["--quiet", "run", "services", "describe", p.service, "--project", p.project!, "--region", p.region!, "--format", "value(status.url)"]);
      if (r.ok) return r.out.trim() || null;
      if (/NOT_FOUND|cannot find|could not be found|does not exist/i.test(r.err)) return null;
      throw new Error(`gcloud run services describe ${p.service}: ${r.err.trim()}`);
    },
    fetch,
  };
}
