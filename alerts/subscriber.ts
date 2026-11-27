// pronto-alerts' driver (README.md): reads each app's Pub/Sub subscription of Cloud Monitoring incidents
// (observability/alerts.subscriber.json) and keeps them in a local inbox the lead tails. Its rules are
// inbox.js's, pure; this file is the network and the disk.
//   deno run -A alerts/subscriber.ts [run] <app-dir>...     read the subscriptions until stopped
//   deno run -A alerts/subscriber.ts install <app-dir>...   the launchd job that runs the above
//   deno run -A alerts/subscriber.ts uninstall
// The access token is the `pronto` gcloud configuration's, fetched when needed, fetched again when
// Pub/Sub answers 401, and held in memory only.
import { ackRequest, entryOf, expired, isDuplicate, lineOf, ntfyRequest, parseInbox, plist, pullRequest, pushes, rotatedName, subscriptionPath } from "./inbox.js";

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
  // The inbox folder: <app>.jsonl, rotated <app>.<day>.jsonl, and the heartbeat file.
  dir: string;
  // The phone's bearer token, when the ntfy topic wants one.
  ntfyToken?: () => Promise<string | undefined>;
  fetch?: typeof fetch;
  say?: (s: string) => void;
  now?: () => Date;
  timeoutMs?: number;
};

const day = (d: Date) => d.toISOString().slice(0, 10);

// The previous day's inbox is renamed for its day, and rotated files past seven days are removed.
function rotate(dir: string, app: string, today: string) {
  const path = `${dir}/${app}.jsonl`;
  try {
    const was = day(Deno.statSync(path).mtime ?? new Date());
    if (was !== today) Deno.renameSync(path, `${dir}/${rotatedName(app, was)}`);
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
  // The heartbeat says the subscriber is reading: the lead trusts the inbox while it is fresh.
  Deno.writeTextFileSync(`${o.dir}/heartbeat`, now.toISOString() + "\n");
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
  const messages: Message[] = got.receivedMessages ?? [];
  if (!messages.length) return { pulled: 0, written: 0, acked: 0, pushed: 0, dropped: 0 };

  const path = `${o.dir}/${o.sub.app}.jsonl`;
  const before = (() => { try { return parseInbox(Deno.readTextFileSync(path)); } catch { return []; } })();
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
      const r = await new Deno.Command("gcloud", { args: ["auth", "print-access-token"], env: { CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto" }, stdout: "piped", stderr: "null" }).output();
      if (!r.success) throw new Error("gcloud printed no access token for the pronto configuration");
      held = new TextDecoder().decode(r.stdout).trim();
    }
    return held;
  };
}

// The phone's token: ALERTS_NTFY_TOKEN, else the login Keychain's `pronto-ntfy-token`, else none (an open topic).
const ntfyToken = (): Promise<string | undefined> => {
  const env = Deno.env.get("ALERTS_NTFY_TOKEN");
  if (env) return Promise.resolve(env);
  if (Deno.build.os !== "darwin") return Promise.resolve(undefined);
  const r = out("security", ["find-generic-password", "-s", "pronto-ntfy-token", "-w"]);
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
  const uid = Deno.uid();
  if (verb === "uninstall") {
    out("launchctl", ["bootout", `gui/${uid}/${label}`]);
    try { Deno.removeSync(agent); } catch { /* not installed */ }
    console.log(`${label}: removed`);
  } else if (verb === "install") {
    if (!apps.length) throw new Error("name the apps' folders");
    for (const a of apps) read(a);
    const logs = `${home}/Library/Logs/pronto`;
    Deno.mkdirSync(logs, { recursive: true });
    Deno.mkdirSync(`${home}/Library/LaunchAgents`, { recursive: true });
    const path = [...new Set([...(Deno.env.get("PATH") ?? "").split(":"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])].filter(Boolean).join(":");
    const script = new URL(import.meta.url).pathname;
    Deno.writeTextFileSync(agent, plist({ label, program: Deno.execPath(), args: ["run", "-A", script, "run", ...apps], log: `${logs}/alerts-inbox.log`, env: { PATH: path, HOME: home, CLOUDSDK_ACTIVE_CONFIG_NAME: "pronto" } }));
    out("launchctl", ["bootout", `gui/${uid}/${label}`]);
    // bootout returns before the job is gone: bootstrap again until it takes.
    let ok = false;
    for (let i = 0; i < 5 && !ok; i++) {
      ok = out("launchctl", ["bootstrap", `gui/${uid}`, agent]).ok;
      if (!ok) await new Promise((r) => setTimeout(r, 1000));
    }
    if (!out("launchctl", ["print", `gui/${uid}/${label}`]).ok) throw new Error(`${label} is not loaded`);
    console.log(`${label}: reading ${apps.length} subscription(s), log ${logs}/alerts-inbox.log`);
  } else {
    if (!apps.length) throw new Error("name the apps' folders");
    const dir = Deno.env.get("ALERTS_DIR") ?? `${home}/.cache/pronto/alerts`;
    const token = gcloudToken();
    const say = (s: string) => console.log(`${new Date().toISOString()} alerts: ${s}`);
    await Promise.all(apps.map(async (a) => {
      const sub = read(a);
      say(`${sub.app}: reading ${subscriptionPath(sub.project, sub.subscription)}`);
      for (;;) {
        try {
          const r = await pollOnce({ api: "https://pubsub.googleapis.com", sub, token, dir, ntfyToken, say });
          if (r.pulled) say(`${sub.app}: ${r.written} written, ${r.pushed} to the phone, ${r.dropped} dropped`);
        } catch (e) {
          say(`${sub.app}: ${(e as Error).message}`);
          await new Promise((r) => setTimeout(r, 10_000));
        }
      }
    }));
  }
}
