// runners: GitHub Actions runners on a cluster, an ARC runner scale set per repository (or
// organization) whose runners build through one shared BuildKit; or, for a host setup, GitHub's
// runner on this Mac as a launchd agent. README.md says more. From this repository's root:
//   deno run -A runners/runners.ts <setup> apply    the VM (a Colima setup's), the controller, BuildKit, then the scale sets;
//                                                   a host setup's runners downloaded, registered and their agents loaded
//   deno run -A runners/runners.ts <setup> status   the releases and the pods; a host runner's agent and GitHub's view of it
//   deno run -A runners/runners.ts <setup> remove   the setup's scale sets gone (the VM, the controller and BuildKit kept);
//                                                   a host runner unregistered and its agent unloaded (its folder kept)
// What it applies is plans[<setup>] (host.cue) of setups[<setup>] (setups.cue), never a value of its
// own; what to do, given what it finds, is plan.js's. Every kubectl and helm call names the plan's
// context, never the current one. Applying again changes only what differs.
import { hostSteps, registerArgs, registerHelp, registration, secretHelp, steps } from "./plan.js";

const root = Deno.realPathSync(new URL("..", import.meta.url).pathname);
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
const [setup, verb = "status"] = Deno.args;
if (!setup) throw new Error("name the setup (setups.cue): runners.ts <setup> [apply|status|remove]");

const run = async (cmd: string, args: readonly string[], input?: string) => {
  const p = new Deno.Command(cmd, { args: [...args], cwd: root, stdin: input === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
  if (input !== undefined) {
    const w = p.stdin.getWriter();
    await w.write(new TextEncoder().encode(input));
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
const plan = JSON.parse(await must("./saytw", ["--script", "tools.nu", "cue", "export", "./runners/export", "-t", `setup=${setup}`, "-t", `home=${home}`, "-e", "plan", "--out", "json"]));
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
  service: { label: string; path: string; plist: Record<string, unknown> & { StandardOutPath: string } };
};

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
  const uid = (await must("id", ["-u"]));
  const domain = `gui/${uid}`;
  const loaded = async (label: string) => (await run("launchctl", ["print", `${domain}/${label}`])).ok;
  // The agent on disk is the plan's when plutil reads back the same keys and values.
  const sameAgent = async (svc: { path: string; plist: Record<string, unknown> }) => {
    const o = await run("plutil", ["-convert", "json", "-o", "-", svc.path]);
    if (!o.ok) return false;
    const sort = (v: unknown): unknown => v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort().map(([k, x]) => [k, sort(x)])) : v;
    return JSON.stringify(sort(JSON.parse(o.out))) === JSON.stringify(sort(svc.plist));
  };
  const token = async (api: string, kind: string) => {
    const o = await run("gh", ["api", "-X", "POST", `${api}/${kind}-token`, "--jq", ".token"]);
    return o.ok && o.out ? o.out : undefined;
  };
  const config = (r: HostRunner, args: string[]) => new Deno.Command("./config.sh", { args, cwd: r.dir, env: { PATH: r.path }, stdin: "null", stdout: "inherit", stderr: "inherit" }).output();

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
    const seen: Record<string, { installed: boolean; registration: string; agent: boolean }> = {};
    for (const [name, r] of Object.entries(runners)) {
      const file = read(`${r.dir}/.runner`);
      const found = { runner: file ? JSON.parse(file) : null, path: read(`${r.dir}/.path`), labels: file ? await labels(r, name) : null };
      seen[name] = { installed: exists(`${r.dir}/config.sh`), registration: registration(plan, name, found), agent: (await sameAgent(r.service)) && (await loaded(r.service.label)) };
    }
    for (const step of hostSteps(plan, seen)) {
      const r = runners[step.name];
      switch (step.do) {
        case "install": {
          say(`${step.name}: actions/runner into ${r.dir}`);
          Deno.mkdirSync(r.dir, { recursive: true });
          const tgz = `${r.dir}/runner.tar.gz`;
          await must("curl", ["-fsSL", "-o", tgz, r.download.url]);
          await must("shasum", ["-a", "256", "-c", "-"], `${r.download.sha256}  ${tgz}\n`);
          await must("tar", ["xzf", tgz, "-C", r.dir]);
          Deno.removeSync(tgz);
          break;
        }
        case "unregister": {
          say(`${step.name}: registered otherwise than the plan says; unregistering first`);
          if (await loaded(r.service.label)) await must("launchctl", ["bootout", `${domain}/${r.service.label}`]);
          const t = await token(r.api, "remove");
          if (!t || !(await config(r, ["remove", "--token", t])).success) throw new Error(`${step.name}: config.sh remove failed; remove it under the repository's Settings, Actions, Runners and apply again`);
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
          if (!(await config(r, [...registerArgs(plan, step.name), "--token", t!])).success) throw new Error(`${step.name}: config.sh failed`);
          break;
        }
        case "agent": {
          say(`${step.name}: launchd agent ${r.service.label}`);
          Deno.mkdirSync(r.service.plist.StandardOutPath.replace(/\/[^/]*$/, ""), { recursive: true });
          Deno.mkdirSync(r.service.path.replace(/\/[^/]*$/, ""), { recursive: true });
          await must("plutil", ["-convert", "xml1", "-o", r.service.path, "-"], JSON.stringify(r.service.plist));
          if (await loaded(r.service.label)) await must("launchctl", ["bootout", `${domain}/${r.service.label}`]);
          await must("launchctl", ["bootstrap", domain, r.service.path]);
          break;
        }
      }
    }
    const runsOn = Object.values(runners).map((r) => `[self-hosted, macOS, ${r.labels.join(", ")}]`);
    say(`applied: workflows say runs-on: ${runsOn.join(" | ")}`);
  } else if (verb === "status") {
    for (const [name, r] of Object.entries(runners)) {
      const o = await run("launchctl", ["print", `${domain}/${r.service.label}`]);
      const state = o.ok ? (o.out.match(/^\s*state = (.*)$/m)?.[1] ?? "loaded") : "not loaded";
      const gh = await run("gh", ["api", r.api, "--jq", `.runners[] | select(.name == "${name}") | "\\(.status)\\(if .busy then ", busy" else "" end)"`]);
      say(`${name}: agent ${state}; GitHub: ${gh.ok && gh.out ? gh.out : "not registered"}`);
    }
  } else if (verb === "remove") {
    for (const [name, r] of Object.entries(runners)) {
      if (await loaded(r.service.label)) await must("launchctl", ["bootout", `${domain}/${r.service.label}`]);
      if (exists(r.service.path)) Deno.removeSync(r.service.path);
      if (exists(`${r.dir}/.runner`)) {
        const t = await token(r.api, "remove");
        if (!t || !(await config(r, ["remove", "--token", t])).success) say(`${name}: unregister it under the repository's Settings, Actions, Runners`);
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
