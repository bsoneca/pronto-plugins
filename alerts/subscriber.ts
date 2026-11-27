// pronto-alerts' driver (README.md): reads each app's Pub/Sub subscription of Cloud Monitoring incidents
// (observability/alerts.subscriber.json) and keeps them in a local inbox the lead tails. Its rules are
// inbox.js's, pure; this file is the network and the disk.
//   deno run -A alerts/subscriber.ts [run] <app-dir>...     read the subscriptions until stopped
//   deno run -A alerts/subscriber.ts install <app-dir>...   the launchd job that runs the above, from its own worktree at origin/main
//   deno run -A alerts/subscriber.ts uninstall
// The access token is the `pronto` gcloud configuration's, fetched when needed, fetched again when
// Pub/Sub answers 401, and held in memory only.
import { ackRequest, entryOf, expired, isDuplicate, jobEnv, lineOf, ntfyRequest, parseInbox, plist, pullRequest, pushes, rotatedName, subscriptionPath, tailOf } from "./inbox.js";

export type Subscription = {
  app: string;
  project: string;
  subscription: string;
  push: string[];
  ntfy?: { url: string; topic: string };
};

type Message = { ackId: string; message: { messageId?: string; data?: string } };

export type Options = {
  api: string;
  sub: Subscription;
  // The access token; `refresh` asks for a new one (the last was refused).
  token: (refresh?: boolean) => Promise<string>;
  // The inbox folder: <app>.jsonl, rotated <app>.<day>.jsonl, and the app's <app>.heartbeat.
  dir: string;
  // The phone's bearer token, when the ntfy topic wants one.
  ntfyToken?: () => Promise<string | undefined>;
  fetch?: typeof fetch;
  say?: (s: string) => void;
  now?: () => Date;
  timeoutMs?: number;
};

const day = (d: Date) => d.toISOString().slice(0, 10);
// Only a path that is not there (or whose parent is no directory) is missing: any other error (permissions, I/O) is the caller's to see.
export const exists = (p: string) => {
  try {
    Deno.statSync(p);
    return true;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound || e instanceof Deno.errors.NotADirectory) return false;
    throw e;
  }
};

// The previous day's inbox is renamed for its day, and rotated files past seven days are removed. A day's
// file that is already there (the job restarted across midnight, the clock went back) is never replaced:
// the inbox is appended to it, flushed, and only then removed.
function rotate(dir: string, app: string, today: string) {
  const path = `${dir}/${app}.jsonl`;
  try {
    const was = day(Deno.statSync(path).mtime ?? new Date());
    if (was !== today) {
      const to = `${dir}/${rotatedName(app, was)}`;
      if (!exists(to)) Deno.renameSync(path, to);
      else {
        const file = Deno.openSync(to, { append: true });
        try {
          file.writeSync(Deno.readFileSync(path));
          file.syncSync();
        } finally {
          file.close();
        }
        Deno.removeSync(path);
      }
    }
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
  for (const n of expired([...Deno.readDirSync(dir)].map((f) => f.name), today)) Deno.removeSync(`${dir}/${n}`);
}

// One pull: what it returned is written to the inbox and flushed to disk, and only then acknowledged, so a
// crash between the two redelivers and never loses; a notification that meets the phone's severities is
// then sent. Returns what it did, for the log and the cases.
export async function pollOnce(o: Options): Promise<{ pulled: number; written: number; acked: number; pushed: number; dropped: number }> {
  const f = o.fetch ?? fetch;
  const say = o.say ?? (() => {});
  const now = (o.now ?? (() => new Date()))();
  Deno.mkdirSync(o.dir, { recursive: true });
  rotate(o.dir, o.sub.app, day(now));

  const sub = subscriptionPath(o.sub.project, o.sub.subscription);
  const call = async (r: { url: string; body: unknown }, ms: number) => {
    for (let attempt = 0; ; attempt++) {
      const res = await f(r.url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${await o.token(attempt > 0)}` },
        body: JSON.stringify(r.body),
        signal: AbortSignal.timeout(ms),
      });
      if (res.status === 401 && attempt === 0) {
        await res.body?.cancel();
        continue;
      }
      if (!res.ok) throw new Error(`${new URL(r.url).pathname}: ${res.status} ${(await res.text()).slice(0, 200)}`);
      return res.json();
    }
  };

  const got = await call(pullRequest(o.api, sub), o.timeoutMs ?? 120_000);
  // The heartbeat is the app's own, written only once Pub/Sub has answered this pull 2xx (a refused or
  // unreachable pull throws before it): the lead trusts the inbox only while it is fresh.
  Deno.writeTextFileSync(`${o.dir}/${o.sub.app}.heartbeat`, now.toISOString() + "\n");
  const messages: Message[] = got.receivedMessages ?? [];
  if (!messages.length) return { pulled: 0, written: 0, acked: 0, pushed: 0, dropped: 0 };

  const path = `${o.dir}/${o.sub.app}.jsonl`;
  const before = (() => {
    try {
      return parseInbox(Deno.readTextFileSync(path));
    } catch (e) {
      if (e instanceof Deno.errors.NotFound) return [];
      throw e;
    }
  })();
  const seen = before.map((e: { id: string; state: string }) => `${e.id}:${e.state}`);
  const fresh: ReturnType<typeof entryOf>[] = [];
  let dropped = 0;
  for (const m of messages) {
    const e = entryOf(m.message, o.sub.app);
    if (!e) {
      dropped++;
      say(`${o.sub.app}: message ${m.message?.messageId ?? "?"} is no incident, acknowledged and dropped`);
      continue;
    }
    fresh.push(e);
  }
  if (fresh.length) {
    const file = Deno.openSync(path, { create: true, append: true });
    try {
      file.writeSync(new TextEncoder().encode(fresh.map((e) => lineOf(e!)).join("")));
      file.syncSync();
    } finally {
      file.close();
    }
  }
  await call(ackRequest(o.api, sub, messages.map((m) => m.ackId)), 30_000);

  let pushed = 0;
  for (const e of fresh) {
    const dup = isDuplicate(seen, e!);
    seen.push(`${e!.id}:${e!.state}`);
    if (dup || !o.sub.ntfy || !pushes(e!, o.sub.push)) continue;
    try {
      const r = ntfyRequest(e!, o.sub.ntfy, await o.ntfyToken?.());
      const res = await f(r.url, { method: r.method, headers: r.headers, body: r.body, signal: AbortSignal.timeout(15_000) });
      await res.body?.cancel();
      if (res.ok) pushed++;
      else say(`${o.sub.app}: the phone answered ${res.status}`);
    } catch (err) {
      say(`${o.sub.app}: the phone was not told: ${(err as Error).message}`);
    }
  }
  return { pulled: messages.length, written: fresh.length, acked: messages.length, pushed, dropped };
}

// --- The driver. ---
const out = (cmd: string, args: string[], env: Record<string, string> = {}) => {
  const r = new Deno.Command(cmd, { args, env, stdout: "piped", stderr: "piped" }).outputSync();
  return { ok: r.success, text: new TextDecoder().decode(r.stdout).trim() };
};

// The `pronto` gcloud configuration's token, never the default one (the owner's other work), held here only.
function gcloudToken() {
  let held = "";
  return async (refresh = false) => {
    if (!held || refresh) {
      const r = await new Deno.Command(Deno.env.get("ALERTS_GCLOUD") ?? "gcloud", { args: ["auth", "print-access-token", "--verbosity=error"], env: { CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto" }, stdout: "piped", stderr: "piped" }).output();
      const token = new TextDecoder().decode(r.stdout).trim();
      if (!r.success || !token) throw new Error(`gcloud printed no access token for the pronto configuration (exit ${r.code}): ${tailOf(new TextDecoder().decode(r.stderr))}`);
      held = token;
    }
    return held;
  };
}

// The phone's token: ALERTS_NTFY_TOKEN, else the login Keychain's `pronto-ntfy-token`, else none (an open topic).
const ntfyToken = (): Promise<string | undefined> => {
  const env = Deno.env.get("ALERTS_NTFY_TOKEN");
  if (env) return Promise.resolve(env);
  if (Deno.build.os !== "darwin") return Promise.resolve(undefined);
  const r = out("/usr/bin/security", ["find-generic-password", "-s", "pronto-ntfy-token", "-w"]);
  return Promise.resolve(r.ok && r.text ? r.text : undefined);
};

const read = (app: string): Subscription => {
  const j = JSON.parse(Deno.readTextFileSync(`${app}/observability/alerts.subscriber.json`));
  return { app: j.app, project: j.project, subscription: j.subscription, push: j.push, ntfy: j.ntfy };
};

const label = "dev.pronto.alerts-inbox";

if (import.meta.main) {
  const home = Deno.env.get("HOME")!;
  const [first, ...rest] = Deno.args;
  const verb = ["run", "install", "uninstall"].includes(first) ? first : "run";
  const apps = (verb === first ? rest : Deno.args).map((a) => Deno.realPathSync(a));
  const agent = `${home}/Library/LaunchAgents/${label}.plist`;
  if (verb === "uninstall") {
    out("launchctl", ["bootout", `gui/${Deno.uid()}/${label}`]);
    try { Deno.removeSync(agent); } catch { /* not installed */ }
    console.log(`${label}: removed`);
  } else if (verb === "install") {
    if (!apps.length) throw new Error("name the apps' folders");
    const sh = (cmd: string, args: string[], cwd?: string) => {
      const r = new Deno.Command(cmd, { args, cwd, stdout: "piped", stderr: "piped" }).outputSync();
      if (!r.success) throw new Error(`${cmd} ${args.join(" ")}${cwd ? ` (in ${cwd})` : ""}: ${new TextDecoder().decode(r.stderr).trim()}`);
      return new TextDecoder().decode(r.stdout).trim();
    };
    // The job runs a worktree of its own at origin/main, as release-cron's run does (release-cron.ts worktree()):
    // never a checkout a person or a session works in, whose files could be anything. Installing again moves it to main.
    const top = Deno.realPathSync(sh("git", ["rev-parse", "--show-toplevel"], apps[0]));
    const rels = apps.map((a) => {
      if (!a.startsWith(top + "/")) throw new Error(`${a} is not in the repository of ${apps[0]}`);
      return a.slice(top.length + 1);
    });
    const repo = sh("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], apps[0]);
    const cache = `${home}/.cache/pronto/alerts`;
    const wt = `${cache}/wt`;
    // Everything that can fail without changing anything comes first: a failed install must not move the code of the job
    // that is running (its worktree), nor its plist.
    // gcloud by its real absolute path, found now: the job's PATH names none, and a mise shim is the mise binary itself,
    // which finds the tool by the working directory (`mise which`, not the shim, names the one the shim would run).
    const found = (Deno.env.get("PATH") ?? "").split(":").map((d) => `${d}/gcloud`).find((p) => p.startsWith("/") && exists(p));
    if (!found) throw new Error("gcloud is not on the PATH: the job cannot fetch a token");
    let gcloudAt = Deno.realPathSync(found);
    if (gcloudAt.split("/").pop() === "mise") gcloudAt = Deno.realPathSync(sh(gcloudAt, ["which", "gcloud"], apps[0]));
    if (gcloudAt.split("/").pop() === "mise") throw new Error(`${found} is a mise shim that names no gcloud: install it, or put the real one on the PATH`);
    const env = jobEnv({ env: Deno.env.toObject(), os: Deno.build.os, home, gcloud: gcloudAt });
    // One token, fetched with the job's exact environment before the job is installed: a job that cannot fetch one
    // would only fail in its log, long after. The token is dropped unread; what is said of a failure is gcloud's
    // last lines of stderr.
    {
      const r = new Deno.Command(gcloudAt, { args: ["auth", "print-access-token", "--verbosity=error"], clearEnv: true, env, stdout: "piped", stderr: "piped" }).outputSync();
      if (!r.success || !new TextDecoder().decode(r.stdout).trim()) throw new Error(`gcloud cannot print an access token with the job's environment (exit ${r.code}): ${tailOf(new TextDecoder().decode(r.stderr))}`);
    }
    // origin/main is fetched (which moves no worktree) and the apps' files are read from it before the worktree is.
    sh("git", ["--git-dir", repo, "fetch", "-q", "origin"]);
    const hosts = new Set(["pubsub.googleapis.com"]);
    for (const r of rels) {
      for (const f of ["alerts/subscriber.ts", "observability/alerts.subscriber.json"]) {
        const at = `origin/main:${r}/${f}`;
        if (!new Deno.Command("git", { args: ["--git-dir", repo, "cat-file", "-e", at], stdout: "null", stderr: "null" }).outputSync().success) throw new Error(`${r}/${f} is not on origin/main yet: merge the app's alerts first`);
      }
      const ntfy = JSON.parse(sh("git", ["--git-dir", repo, "show", `origin/main:${r}/observability/alerts.subscriber.json`])).ntfy;
      if (ntfy) hosts.add(new URL(ntfy.url).host);
    }
    Deno.mkdirSync(cache, { recursive: true });
    if (!exists(`${wt}/.git`)) sh("git", ["--git-dir", repo, "worktree", "add", "-q", "--detach", wt, "origin/main"]);
    sh("git", ["checkout", "-q", "--detach", "-f", "origin/main"], wt);
    sh("git", ["clean", "-ffdq"], wt);
    const logs = `${home}/Library/Logs/pronto`;
    Deno.mkdirSync(logs, { recursive: true });
    Deno.mkdirSync(`${home}/Library/LaunchAgents`, { recursive: true });
    // A fixed bare PATH, and only the permissions the driver uses.
    const flags = [
      `--allow-net=${[...hosts].join(",")}`,
      `--allow-read=${wt},${cache}`,
      `--allow-write=${cache}`,
      // The inbox folder holds the worktree: the job writes the inbox, never the code it runs.
      `--deny-write=${wt}`,
      `--allow-run=/usr/bin/security,${gcloudAt}`,
      "--allow-env=HOME,ALERTS_DIR,ALERTS_NTFY_TOKEN,ALERTS_GCLOUD",
    ];
    const args = ["run", ...flags, `${wt}/${rels[0]}/alerts/subscriber.ts`, "run", ...rels.map((r) => `${wt}/${r}`)];
    const previous = exists(agent) ? Deno.readTextFileSync(agent) : null;
    Deno.writeTextFileSync(agent, plist({ label, program: Deno.execPath(), args, log: `${logs}/alerts-inbox.log`, env }));
    const bootstrap = async () => {
      // bootout returns before the job is gone: bootstrap again until it takes.
      for (let i = 0; i < 5; i++) {
        if (out("launchctl", ["bootstrap", `gui/${Deno.uid()}`, agent]).ok) return true;
        await new Promise((r) => setTimeout(r, 1000));
      }
      return false;
    };
    out("launchctl", ["bootout", `gui/${Deno.uid()}/${label}`]);
    if (!await bootstrap() || !out("launchctl", ["print", `gui/${Deno.uid()}/${label}`]).ok) {
      // The old job was booted out: put its plist back and start it again, or, with none before, take the new one away.
      if (previous !== null) {
        Deno.writeTextFileSync(agent, previous);
        out("launchctl", ["bootout", `gui/${Deno.uid()}/${label}`]);
        await bootstrap();
      } else {
        out("launchctl", ["bootout", `gui/${Deno.uid()}/${label}`]);
        Deno.removeSync(agent);
      }
      throw new Error(`${label} did not load; ${previous !== null ? "the previous job is back" : "nothing is installed"}`);
    }
    console.log(`${label}: reading ${apps.length} subscription(s) from ${wt} (origin/main ${sh("git", ["rev-parse", "--short", "HEAD"], wt)}), log ${logs}/alerts-inbox.log`);
  } else {
    if (!apps.length) throw new Error("name the apps' folders");
    const dir = Deno.env.get("ALERTS_DIR") ?? `${home}/.cache/pronto/alerts`;
    const token = gcloudToken();
    const say = (s: string) => console.log(`${new Date().toISOString()} alerts: ${s}`);
    // Each app is read on its own: one whose file is gone or whose pulls fail says so and tries again, and the others go on.
    const pause = () => new Promise((r) => setTimeout(r, 10_000));
    await Promise.all(apps.map(async (a) => {
      for (;;) {
        try {
          const sub = read(a);
          say(`${sub.app}: reading ${subscriptionPath(sub.project, sub.subscription)}`);
          for (;;) {
            try {
              const r = await pollOnce({ api: "https://pubsub.googleapis.com", sub, token, dir, ntfyToken, say });
              if (r.pulled) say(`${sub.app}: ${r.written} written, ${r.pushed} to the phone, ${r.dropped} dropped`);
            } catch (e) {
              say(`${sub.app}: ${String(e)}`);
              await pause();
            }
          }
        } catch (e) {
          say(`${a}: ${String(e)}`);
          await pause();
        }
      }
    }));
  }
}
