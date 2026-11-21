// runners: GitHub Actions runners on a cluster, an ARC runner scale set per repository (or
// organization) whose runners build through one shared BuildKit; or, for a host setup, GitHub's
// runner on this machine as a launchd agent (macOS) or a systemd unit (Linux, installed with sudo). README.md says more. From this repository's root:
//   deno run -A runners/runners.ts <setup> apply    the VM (a Colima setup's), the controller, BuildKit, then the scale sets;
//                                                   a host setup's runners downloaded, registered and their services started
//   deno run -A runners/runners.ts <setup> status   the releases and the pods; a host runner's agent and GitHub's view of it
//   deno run -A runners/runners.ts <setup> remove   the setup's scale sets gone (the VM, the controller and BuildKit kept);
//                                                   a host runner unregistered and its service stopped (its folder kept)
// What it applies is plans[<setup>] (host.cue) of setups[<setup>] (setups.cue), never a value of its
// own; what to do, given what it finds, is plan.js's. Every kubectl and helm call names the plan's
// context, never the current one. Applying again changes only what differs.
import { allocateUids, configCommand, gatedByBusy, hostSteps, inspectAccount, needsSudo, registerArgs, registerHelp, registration, secretHelp, shell, stepCommands, steps, tokenHelp } from "./plan.js";

const root = Deno.realPathSync(new URL("..", import.meta.url).pathname);
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
const [setup, verb = "status"] = Deno.args;
if (!setup) throw new Error("name the setup (setups.cue): runners.ts <setup> [apply|status|remove]");

const run = async (cmd: string, args: readonly string[], input?: string | Uint8Array) => {
  const p = new Deno.Command(cmd, { args: [...args], cwd: root, stdin: input === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
  if (input !== undefined) {
    const w = p.stdin.getWriter();
    await w.write(typeof input === "string" ? new TextEncoder().encode(input) : input);
    await w.close();
  }
  const o = await p.output();
  return { ok: o.success, out: decode(o.stdout).trim(), err: decode(o.stderr).trim() };
};
const must = async (cmd: string, args: readonly string[], input?: string) => {
  const o = await run(cmd, args, input);
  if (!o.ok) throw new Error(`${cmd} ${args.join(" ")}: ${o.err || o.out}`);
  return o.out;
};
const say = (s: string) => console.log(`runners: ${s}`);

// The repository's own cue, through its saytw.
const home = Deno.env.get("HOME") ?? "";
const user = Deno.env.get("USER") ?? (await run("id", ["-un"])).out;
const plan = JSON.parse(await must("./saytw", ["--script", "tools.nu", "cue", "export", "./runners/export", "-t", `setup=${setup}`, "-t", `home=${home}`, "-t", `user=${user}`, "-e", "plan", "--out", "json"]));
const kubectl = (...args: string[]) => ["kubectl", ["--context", plan.context, ...args]] as const;
const helm = (...args: string[]) => ["helm", ["--kube-context", plan.context, ...args]] as const;
const chart = (name: string) => `${plan.charts.repo}/${name}`;
const releases = async () => {
  const o = await run(...helm("list", "--namespace", plan.runnerNamespace, "--short"));
  return o.ok ? o.out.split("\n").filter(Boolean) : [];
};

type HostRunner = {
  url: string;
  api: string;
  dir: string;
  labels: string[];
  path: string;
  work: string;
  download: { url: string; sha256: string };
  service: { label: string; path: string; plist?: Record<string, unknown> & { StandardOutPath: string }; unit?: string; xml?: string; sha256?: string };
  // A runner with an account (a LaunchDaemon run as it): the account's login, the applier's own
  // folder and agent it moves from, and its job-started hook.
  user?: string;
  tools?: { dir: string; gh: { url: string; sha256: string; member: string; binary: string } };
  previous?: { dir: string; service: HostRunner["service"] };
  hook?: { path: string; text: string; owner: string; mode: string; sha256: string };
};

// A host runner's service: a launchd agent in the person's session, or a systemd unit of the
// system's, written and started with `sudo -n` (a sudo that asks for a password stops the apply
// with the commands to run).
type Service = { loaded(label: string): Promise<boolean>; same(svc: HostRunner["service"]): Promise<boolean>; install(svc: HostRunner["service"]): Promise<void>; stop(svc: HostRunner["service"]): Promise<void>; remove(svc: HostRunner["service"]): Promise<void>; state(label: string): Promise<string> };

const launchd = async (): Promise<Service> => {
  const domain = `gui/${await must("id", ["-u"])}`;
  const loaded = async (label: string) => (await run("launchctl", ["print", `${domain}/${label}`])).ok;
  const sort = (v: unknown): unknown => v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort().map(([k, x]) => [k, sort(x)])) : v;
  return {
    loaded,
    // The agent on disk is the plan's when plutil reads back the same keys and values.
    same: async (svc) => {
      const o = await run("plutil", ["-convert", "json", "-o", "-", svc.path]);
      return o.ok && JSON.stringify(sort(JSON.parse(o.out))) === JSON.stringify(sort(svc.plist));
    },
    install: async (svc) => {
      Deno.mkdirSync(svc.plist!.StandardOutPath.replace(/\/[^/]*$/, ""), { recursive: true });
      Deno.mkdirSync(svc.path.replace(/\/[^/]*$/, ""), { recursive: true });
      await must("plutil", ["-convert", "xml1", "-o", svc.path, "-"], JSON.stringify(svc.plist));
      if (await loaded(svc.label)) await must("launchctl", ["bootout", `${domain}/${svc.label}`]);
      // Right after a bootout launchd may refuse the bootstrap (error 5, Input/output error) while the
      // old job tears down; an agent left unloaded takes no jobs, so it is retried, not given up on.
      for (let i = 1; ; i++) {
        const o = await run("launchctl", ["bootstrap", domain, svc.path]);
        if (o.ok) break;
        if (i === 12) throw new Error(`launchctl bootstrap ${domain} ${svc.path}: ${o.err || o.out}`);
        await new Promise((ok) => setTimeout(ok, 5_000));
      }
    },
    stop: async (svc) => {
      if (await loaded(svc.label)) await must("launchctl", ["bootout", `${domain}/${svc.label}`]);
    },
    remove: async (svc) => {
      if (await loaded(svc.label)) await must("launchctl", ["bootout", `${domain}/${svc.label}`]);
      try { Deno.removeSync(svc.path); } catch { /* gone already */ }
    },
    state: async (label) => {
      const o = await run("launchctl", ["print", `${domain}/${label}`]);
      return o.ok ? (o.out.match(/^\s*state = (.*)$/m)?.[1] ?? "loaded") : "not loaded";
    },
  };
};

const systemd = (): Service => {
  const sudo = async (args: string[], input?: string) => {
    const o = await run("sudo", ["-n", ...args], input);
    if (!o.ok) {
      say(`sudo -n ${args.join(" ")} failed: ${o.err || o.out}`);
      say("a systemd unit is the system's: run apply where sudo needs no password, or run that as root and apply again");
      Deno.exit(3);
    }
  };
  const loaded = async (label: string) => (await run("systemctl", ["is-active", "--quiet", label])).ok;
  return {
    loaded,
    same: async (svc) => {
      try { return (await Deno.readTextFile(svc.path)) === svc.unit; } catch { return false; }
    },
    install: async (svc) => {
      await sudo(["tee", svc.path], svc.unit);
      await sudo(["systemctl", "daemon-reload"]);
      await sudo(["systemctl", "enable", svc.label]);
      await sudo(["systemctl", "restart", svc.label]);
    },
    stop: async (svc) => {
      if (await loaded(svc.label)) await sudo(["systemctl", "stop", svc.label]);
    },
    remove: async (svc) => {
      try { Deno.statSync(svc.path); } catch { return; }
      await sudo(["systemctl", "disable", "--now", svc.label]);
      await sudo(["rm", svc.path]);
      await sudo(["systemctl", "daemon-reload"]);
    },
    state: async (label) => (await run("systemctl", ["is-active", label])).out || "unknown",
  };
};

// A runner with an account is a LaunchDaemon of the system's: its plist, hook and account are root's,
// written with `sudo -n`. A sudo that asks for a password stops the apply before any of them, with the
// commands to run (below); its steps' commands are plan.js's, run here or printed there.
const daemon = (): Service => {
  const sudo = async (args: string[]) => {
    const o = await run("sudo", ["-n", ...args]);
    if (!o.ok) throw new Error(`sudo ${args.join(" ")}: ${o.err || o.out}`);
  };
  const loaded = async (label: string) => (await run("launchctl", ["print", `system/${label}`])).ok;
  const sort = (v: unknown): unknown => v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort().map(([k, x]) => [k, sort(x)])) : v;
  return {
    loaded,
    // The plist is world-readable: read it back as the agent's is.
    same: async (svc) => {
      const o = await run("plutil", ["-convert", "json", "-o", "-", svc.path]);
      return o.ok && JSON.stringify(sort(JSON.parse(o.out))) === JSON.stringify(sort(svc.plist));
    },
    install: () => Promise.reject(new Error("a daemon is installed by its hook and daemon steps")),
    stop: async (svc) => {
      if (await loaded(svc.label)) await sudo(["launchctl", "bootout", `system/${svc.label}`]);
    },
    remove: async (svc) => {
      if (await loaded(svc.label)) await sudo(["launchctl", "bootout", `system/${svc.label}`]);
      try { Deno.statSync(svc.path); } catch { return; }
      await sudo(["rm", svc.path]);
    },
    state: async (label) => {
      const o = await run("launchctl", ["print", `system/${label}`]);
      return o.ok ? (o.out.match(/^\s*state = (.*)$/m)?.[1] ?? "loaded") : "not loaded";
    },
  };
};

// A file's sha256, in Deno: shasum is macOS's, sha256sum Linux's.
const sha256 = async (path: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", Deno.readFileSync(path)))].map((b) => b.toString(16).padStart(2, "0")).join("");

if (plan.host) {
  const runners: Record<string, HostRunner> = plan.host;
  const exists = (p: string) => {
    try {
      Deno.statSync(p);
      return true;
    } catch {
      return false;
    }
  };
  const agents = plan.service === "systemd" ? systemd() : await launchd();
  const daemons = daemon();
  // A runner's service: the system's daemon when it has an account, else the applier's agent (or unit).
  const svcOf = (r: HostRunner) => r.user ? daemons : agents;
  const sudoOk = async () => (await run("sudo", ["-n", "true"])).ok;
  // As an account, with sudo -n: its folder is closed to the applier.
  const asUserRead = async (r: HostRunner, p: string) => {
    const o = await run("sudo", ["-n", "-u", r.user!, "-H", "cat", p]);
    return o.ok ? o.out.replace(/^\uFEFF/, "") : null;
  };
  const token = async (api: string, kind: string) => {
    const o = await run("gh", ["api", "-X", "POST", `${api}/${kind}-token`, "--jq", ".token"]);
    return o.ok && o.out ? o.out : undefined;
  };
  // config.sh takes its registration or removal token on stdin (plan.js's configCommand), never as an argument: another
  // account could read one with ps and register a runner of the same label.
  const config = async (r: HostRunner, args: string[], token: string, dir = r.dir) => {
    const [cmd, ...rest] = configCommand(args) as string[];
    const p = new Deno.Command(cmd, { args: rest, cwd: dir, env: { PATH: r.path }, stdin: "piped", stdout: "inherit", stderr: "inherit" }).spawn();
    const w = p.stdin.getWriter();
    await w.write(new TextEncoder().encode(`${token}\n`));
    await w.close();
    return await p.status;
  };
  // plan.js's commands, run with sudo -n; a command's token (never an argument) or file goes in on its stdin.
  const exec = async (cmds: { argv: string[]; tolerate?: boolean; stdin?: string; token?: boolean }[], token?: string) => {
    for (const c of cmds) {
      const o = await run(c.argv[0], c.argv.slice(1), c.token ? `${token}\n` : c.stdin ? Deno.readFileSync(c.stdin) : undefined);
      if (!o.ok && !c.tolerate) throw new Error(`${shell(c)}: ${o.err || o.out}`);
    }
  };
  // GitHub's view of a runner, by name: its status and labels.
  const ghRunner = async (r: HostRunner, name: string) => {
    const o = await run("gh", ["api", r.api, "--jq", `.runners[] | select(.name == "${name}") | {status, labels: [.labels[].name]}`]);
    try { return o.ok && o.out ? JSON.parse(o.out) as { status: string; labels: string[] } : null; } catch { return null; }
  };

  if (verb === "apply") {
    // What config.sh wrote (.runner, with a BOM, and .path), and the labels GitHub holds.
    const read = (p: string) => {
      try {
        return Deno.readTextFileSync(p).replace(/^\uFEFF/, "");
      } catch {
        return null;
      }
    };
    const labels = async (r: HostRunner, name: string) => {
      const o = await run("gh", ["api", r.api, "--jq", `[.runners[] | select(.name == "${name}") | .labels[].name]`]);
      return o.ok ? JSON.parse(o.out) as string[] : null;
    };
    const seen: Record<string, Record<string, unknown>> = {};
    // A runner with an account: its folder is the account's, closed to us, so what is in it is read with
    // sudo -n -u. Where sudo asks for a password nothing there is read, and a runner that already has its
    // root-owned files is judged by those and by GitHub's list: current, or left alone as unknown.
    const sudoed = Object.values(runners).some((r) => r.user) && await sudoOk();
    for (const [name, r] of Object.entries(runners)) {
      if (r.user) {
        const file = sudoed ? await asUserRead(r, `${r.dir}/.runner`) : null;
        const gh = await ghRunner(r, name);
        const as = (cmd: string[]) => run("sudo", ["-n", "-u", r.user!, "-H", ...cmd]);
        seen[name] = inspectAccount(plan, name, {
          sudo: sudoed,
          account: (await run("dscl", [".", "-read", `/Users/${r.user}`, "UniqueID"])).ok,
          oldRegistered: exists(`${r.previous!.dir}/.runner`),
          hookSame: read(r.hook!.path) === r.hook!.text,
          daemonSame: await daemons.same(r.service),
          loaded: sudoed && await daemons.loaded(r.service.label),
          gh,
          found: { runner: file ? JSON.parse(file) : null, path: sudoed ? await asUserRead(r, `${r.dir}/.path`) : null, labels: file ? gh?.labels ?? null : null },
          installed: sudoed && (await as(["test", "-e", `${r.dir}/config.sh`])).ok,
          // Locked when the folder, bin, .env and .path are all root's: the folder alone says too little.
          locked: sudoed && await (async () => {
            const o = await as(["ls", "-ldn", r.dir, `${r.dir}/bin`, `${r.dir}/.env`, `${r.dir}/.path`]);
            const lines = o.out.split("\n").filter(Boolean);
            return o.ok && lines.length === 4 && lines.every((l) => l.split(/\s+/)[2] === "0");
          })(),
          // The installed gh is the pinned one, not merely there.
          tools: !r.tools || await sha256(`${r.tools.dir}/gh`).then((h) => h === r.tools!.gh.binary, () => false),
        });
        continue;
      }
      const file = read(`${r.dir}/.runner`);
      const found = { runner: file ? JSON.parse(file) : null, path: read(`${r.dir}/.path`), labels: file ? await labels(r, name) : null };
      seen[name] = {
        installed: exists(`${r.dir}/config.sh`),
        registration: registration(plan, name, found),
        agent: (await agents.same(r.service)) && (await agents.loaded(r.service.label)),
        // A hook the applier's own runner admits behind, and a daemon it was before it went back to the applier's.
        hook: r.hook ? read(r.hook.path) === r.hook.text : undefined,
        legacyDaemon: exists(`/Library/LaunchDaemons/${r.service.label}.plist`),
      };
    }
    // A runner in the middle of a job is left alone: unregistering it or restarting its service would
    // cut the job. Its steps wait for the next apply, which says so.
    const busy = async (r: HostRunner, name: string) => (await run("gh", ["api", r.api, "--jq", `.runners[] | select(.name == "${name}") | .busy`])).out === "true";
    const held = new Set<string>();
    const todo = hostSteps(plan, seen);

    // What a step of a runner with an account does as root or as its account: the commands are plan.js's,
    // their files staged here (the plist and hook as the plan renders them, the runner's tarball once,
    // checked against its sha256), so what a person is told to run is what apply would have run.
    const stageRoot = Deno.makeTempDirSync({ prefix: "pronto-runners-" });
    const tarballs: Record<string, string> = {};
    const ghs: Record<string, string> = {};
    const stage = async (name: string) => {
      const r = runners[name];
      const dir = `${stageRoot}/${name}`;
      Deno.mkdirSync(dir, { recursive: true });
      // The plan's own text: what root installs is checked against the sha256 the plan renders for it.
      if (r.service.xml) Deno.writeTextFileSync(`${dir}/plist`, r.service.xml);
      if (r.hook) Deno.writeTextFileSync(`${dir}/job-started.sh`, r.hook.text);
      // Bytes, never a link: what root checks and extracts is a copy that is the stage's own.
      if (todo.some((s) => s.name === name && s.do === "install-as")) {
        if (!tarballs[r.download.url]) {
          const tgz = `${stageRoot}/runner-${Object.keys(tarballs).length}.tar.gz`;
          await must("curl", ["-fsSL", "-o", tgz, r.download.url]);
          if ((await sha256(tgz)) !== r.download.sha256) throw new Error(`${name}: ${r.download.url} is not the sha256 the setup pins`);
          tarballs[r.download.url] = tgz;
        }
        Deno.copyFileSync(tarballs[r.download.url], `${dir}/runner.tar.gz`);
      }
      // The pinned gh of a trusted account's PATH: the release asset is checked against its pin, the binary taken out of it
      // against the binary's own.
      if (r.tools && todo.some((s) => s.name === name && s.do === "tools")) {
        const gh = r.tools.gh;
        if (!ghs[gh.url]) {
          const asset = `${stageRoot}/gh-${Object.keys(ghs).length}.asset`;
          await must("curl", ["-fsSL", "-o", asset, gh.url]);
          if ((await sha256(asset)) !== gh.sha256) throw new Error(`${name}: ${gh.url} is not the sha256 the setup pins`);
          const out = `${asset}.bin`;
          await must("sh", ["-c", gh.url.endsWith(".zip") ? 'unzip -p "$0" "$1" > "$2"' : 'tar xzOf "$0" "$1" > "$2"', asset, gh.member, out]);
          if ((await sha256(out)) !== gh.binary) throw new Error(`${name}: ${gh.member} of ${gh.url} is not the binary sha256 the setup pins`);
          ghs[gh.url] = out;
        }
        Deno.copyFileSync(ghs[gh.url], `${dir}/gh`);
      }
      return dir;
    };
    // A free uid for each account to create, chosen once, here: what is printed and what is run agree.
    const numbers = async (kind: string, key: string) => (await must("dscl", [".", "-list", kind, key])).split("\n").map((l: string) => Number(l.trim().split(/\s+/).pop()));
    const uids = plan.accounts ? allocateUids(plan.accounts, await numbers("/Users", "UniqueID"), await numbers("/Groups", "PrimaryGroupID")) : {};
    const commands = async (name: string, step: string) => stepCommands(plan, name, step, { uids, stage: await stage(name) });
    // Where sudo needs a password the apply stops before anything runs, with the whole sequence, in order.
    const asRoot = todo.filter(needsSudo);
    if (asRoot.length && !(await sudoOk())) {
      say(`${asRoot.map((s) => s.name).filter((n, i, a) => a.indexOf(n) === i).join(", ")}: an account's runner is the system's: sudo asks for a password here.`);
      const made = new Set<string>();
      console.log("  Run these as an administrator, in this order (apply drains and unregisters the old runner itself, once it can run sudo -n):");
      for (const step of todo) {
        const r = runners[step.name];
        if (step.do === "drain") console.log(`  # wait until ${step.name} is idle: gh api ${r.api} --jq '.runners[] | select(.name == "${step.name}") | .busy'`);
        else if (step.do === "unregister-old") {
          console.log(`  # then take it off ${r.previous!.dir}: launchctl bootout gui/$(id -u)/${r.previous!.service.label} && rm ${r.previous!.service.path.replace(/ /g, "\\ ")}`);
          console.log(`  ${tokenHelp(plan, step.name, "remove")}`);
          console.log(`  printf '%s\\n' "$t" | ( cd ${r.previous!.dir} && IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN && ./config.sh remove )`);
        } else if (needsSudo(step) && !(step.do === "account" && made.has(r.user!))) {
          if (step.do === "account") made.add(r.user!);
          const cmds = await commands(step.name, step.do);
          if (step.do === "register-as" || step.do === "unregister-as") console.log(`  ${tokenHelp(plan, step.name, step.do === "register-as" ? "registration" : "remove")}`);
          for (const c of cmds) console.log(`  ${shell(c)}`);
        }
      }
      console.log(`  Then apply again.`);
      Deno.exit(3);
    }

    for (const step of todo) {
      const r = runners[step.name];
      if (held.has(step.name)) continue;
      if (gatedByBusy(step) && await busy(r, step.name)) {
        say(`${step.name}: running a job; left as it is (apply again once it is idle)`);
        held.add(step.name);
        continue;
      }
      switch (step.do) {
        case "install": {
          say(`${step.name}: actions/runner into ${r.dir}`);
          Deno.mkdirSync(r.dir, { recursive: true });
          const tgz = `${r.dir}/runner.tar.gz`;
          await must("curl", ["-fsSL", "-o", tgz, r.download.url]);
          if ((await sha256(tgz)) !== r.download.sha256) throw new Error(`${step.name}: ${r.download.url} is not the sha256 the setup pins`);
          await must("tar", ["xzf", tgz, "-C", r.dir]);
          Deno.removeSync(tgz);
          break;
        }
        case "unregister": {
          say(`${step.name}: registered otherwise than the plan says; unregistering first`);
          await agents.stop(r.service);
          const t = await token(r.api, "remove");
          if (!t || !(await config(r, ["remove"], t)).success) throw new Error(`${step.name}: config.sh remove failed; remove it under the repository's Settings, Actions, Runners and apply again`);
          break;
        }
        case "register": {
          const t = await token(r.api, "registration");
          if (!t) {
            say(`${step.name}: gh could not fetch a registration token.`);
            for (const l of registerHelp(plan, step.name)) console.log(`  ${l}`);
            console.log(`  Then apply again.`);
            Deno.exit(3);
          }
          say(`${step.name}: registering with ${r.url} as ${r.labels.join(", ")}`);
          // config.sh records the plan's PATH in .path, the one the agent's jobs run with.
          if (!(await config(r, registerArgs(plan, step.name), t!)).success) throw new Error(`${step.name}: config.sh failed`);
          break;
        }
        case "agent": {
          say(`${step.name}: ${plan.service} ${r.service.label}`);
          await agents.install(r.service);
          break;
        }
        // A runner with an account.
        case "account":
          if ((await run("dscl", [".", "-read", `/Users/${r.user}`, "UniqueID"])).ok) break;
          say(`${step.name}: account ${r.user} (hidden, no password)`);
          await exec(await commands(step.name, "account"));
          break;
        case "drain": {
          say(`${step.name}: waiting for its job to finish before it moves to ${r.user}`);
          for (let i = 0; await busy(r, step.name); i++) {
            if (i === 240) {
              say(`${step.name}: still running a job after an hour; apply again once it is idle`);
              Deno.exit(3);
            }
            await new Promise((ok) => setTimeout(ok, 15_000));
          }
          break;
        }
        case "unregister-old": {
          const old = r.previous!;
          say(`${step.name}: unregistering from ${old.dir} (kept), the agent unloaded`);
          await agents.remove(old.service);
          const t = await token(r.api, "remove");
          if (!t || !(await config(r, ["remove"], t, old.dir)).success) throw new Error(`${step.name}: config.sh remove failed in ${old.dir}; remove it under the repository's Settings, Actions, Runners and apply again`);
          break;
        }
        case "install-as":
          say(`${step.name}: actions/runner into ${r.dir}, as ${r.user}`);
          await exec(await commands(step.name, "install-as"));
          break;
        case "unregister-as":
        case "register-as": {
          const kind = step.do === "register-as" ? "registration" : "remove";
          const t = await token(r.api, kind);
          if (!t) {
            say(`${step.name}: gh could not fetch a ${kind} token.`);
            for (const l of registerHelp(plan, step.name)) console.log(`  ${l}`);
            console.log(`  Then apply again.`);
            Deno.exit(3);
          }
          say(step.do === "register-as" ? `${step.name}: registering with ${r.url} as ${r.labels.join(", ")}, as ${r.user}` : `${step.name}: registered otherwise than the plan says; unregistering first`);
          await exec(await commands(step.name, step.do), t);
          break;
        }
        case "unlock":
        case "lock":
        case "tools":
          say(`${step.name}: ${step.do === "lock" ? `its folder ${r.dir} root's but ${r.work} and _diag` : step.do === "unlock" ? `its folder ${r.dir} the account's again, to register it` : "root's copies of the trusted tools"}`);
          await exec(await commands(step.name, step.do));
          break;
        case "remove-daemon":
          say(`${step.name}: its daemon ${r.service.label} unloaded and removed: it is the applier's own again`);
          await exec(await commands(step.name, "remove-daemon"));
          break;
        case "unknown":
          say(`${step.name}: its account's folder can't be read without sudo -n, and GitHub does not show it online with its labels: left as it is`);
          break;
        case "hook":
          say(`${step.name}: job-started hook ${r.hook!.path}`);
          await exec(await commands(step.name, "hook"));
          break;
        case "daemon":
          say(`${step.name}: launchd daemon ${r.service.label} as ${r.user}`);
          await exec(await commands(step.name, "daemon"));
          break;
      }
    }
    Deno.removeSync(stageRoot, { recursive: true });
    const runsOn = Object.values(runners).map((r) => `[${[...plan.runsOn, ...r.labels].join(", ")}]`);
    say(`applied: workflows say runs-on: ${runsOn.join(" | ")}`);
  } else if (verb === "status") {
    for (const [name, r] of Object.entries(runners)) {
      const state = await svcOf(r).state(r.service.label);
      const gh = await run("gh", ["api", r.api, "--jq", `.runners[] | select(.name == "${name}") | "\\(.status)\\(if .busy then ", busy" else "" end)"`]);
      say(`${name}: ${r.user ? `daemon as ${r.user}` : plan.service} ${state}; GitHub: ${gh.ok && gh.out ? gh.out : "not registered"}`);
    }
  } else if (verb === "remove") {
    for (const [name, r] of Object.entries(runners)) {
      await svcOf(r).remove(r.service);
      if (r.user) {
        // Its folder is the account's: unregistered as the account, with sudo -n. Its hook stays, root's.
        if (await sudoOk() && await asUserRead(r, `${r.dir}/.runner`)) {
          const t = await token(r.api, "remove");
          if (!t) say(`${name}: unregister it under the repository's Settings, Actions, Runners`);
          else await exec(stepCommands(plan, name, "unregister-as", {}), t);
        }
      } else if (exists(`${r.dir}/.runner`)) {
        const t = await token(r.api, "remove");
        if (!t || !(await config(r, ["remove"], t)).success) say(`${name}: unregister it under the repository's Settings, Actions, Runners`);
      }
      say(`${name} removed (its folder ${r.dir} kept)`);
    }
  } else {
    throw new Error(`unknown verb ${verb}: apply|status|remove`);
  }
} else if (verb === "apply") {
  const vm = plan.colima ? (await run("colima", ["status", "-p", plan.colima.profile])).ok : false;
  const secret = vm || !plan.colima ? (await run(...kubectl("-n", plan.runnerNamespace, "get", "secret", plan.secret.name))).ok : false;
  for (const step of steps(plan, { vm, releases: vm || !plan.colima ? await releases() : [], secret })) {
    switch (step.do) {
      case "start-vm": {
        const c = plan.colima;
        say(`starting VM ${c.profile} (k3s, ${c.cpus} CPUs, ${c.memory} GiB, ${c.disk} GiB disk)`);
        // colima start makes its VM kubectl's and docker's current context: the operator's are put back.
        const kube = (await run("kubectl", ["config", "current-context"])).out;
        const docker = (await run("docker", ["context", "show"])).out;
        await must("colima", ["start", "-p", c.profile, "--kubernetes", "--cpu", `${c.cpus}`, "--memory", `${c.memory}`, "--disk", `${c.disk}`]);
        if (kube) await must("kubectl", ["config", "use-context", kube]);
        if (docker) await must("docker", ["context", "use", docker]);
        break;
      }
      case "controller":
        say(`controller ${plan.charts.version}`);
        await must(...helm("upgrade", "--install", plan.controller.release, chart("gha-runner-scale-set-controller"), "--version", plan.charts.version, "--namespace", plan.controller.namespace, "--create-namespace", "--wait"));
        break;
      case "buildkit":
        say(`BuildKit at ${plan.endpoint}`);
        await must(...kubectl("apply", "-f", "-"), JSON.stringify({ apiVersion: "v1", kind: "List", items: plan.buildkit }));
        await must(...kubectl("-n", "buildkit", "rollout", "status", "deployment/buildkitd", "--timeout=300s"));
        break;
      case "namespace":
        await must(...kubectl("apply", "-f", "-"), JSON.stringify({ apiVersion: "v1", kind: "Namespace", metadata: { name: plan.runnerNamespace } }));
        break;
      case "need-secret":
        say(`no secret ${plan.secret.name} in ${plan.runnerNamespace}: the scale sets register with it, and only a person creates it.`);
        for (const l of secretHelp(plan)) console.log(`  ${l}`);
        console.log(`  Then apply again.`);
        Deno.exit(3);
        break;
      case "scale-set": {
        const values = Deno.makeTempFileSync({ suffix: ".json" });
        try {
          Deno.writeTextFileSync(values, JSON.stringify(plan.scaleSets[step.name]));
          say(`scale set ${step.name} for ${plan.scaleSets[step.name].githubConfigUrl}`);
          await must(...helm("upgrade", "--install", step.name, chart("gha-runner-scale-set"), "--version", plan.charts.version, "--namespace", plan.runnerNamespace, "--values", values, "--wait"));
        } finally {
          Deno.removeSync(values);
        }
        break;
      }
      case "remove":
        say(`scale set ${step.name} removed: the setup no longer names it`);
        await must(...helm("uninstall", step.name, "--namespace", plan.runnerNamespace, "--wait"));
        break;
    }
  }
  say(`applied: workflows say runs-on: ${Object.keys(plan.scaleSets).join(" | ")}`);
} else if (verb === "status") {
  if (plan.colima && !(await run("colima", ["status", "-p", plan.colima.profile])).ok) {
    say(`VM ${plan.colima.profile} not running: apply starts it`);
    Deno.exit(1);
  }
  console.log(await must(...helm("list", "-A")));
  console.log(await must(...kubectl("get", "pods", "-n", plan.controller.namespace)));
  console.log(await must(...kubectl("-n", "buildkit", "get", "pods,pvc")));
  console.log(await must(...kubectl("-n", plan.runnerNamespace, "get", "autoscalingrunnersets,ephemeralrunners,pods")));
} else if (verb === "remove") {
  for (const name of Object.keys(plan.scaleSets)) {
    if ((await releases()).includes(name)) await must(...helm("uninstall", name, "--namespace", plan.runnerNamespace, "--wait"));
    say(`scale set ${name} removed`);
  }
  if (plan.colima) say(`colima delete -p ${plan.colima.profile} removes the VM, the controller and BuildKit`);
} else {
  throw new Error(`unknown verb ${verb}: apply|status|remove`);
}
