// runners: GitHub Actions runners on a cluster, an ARC runner scale set per repository (or
// organization) whose runners build through one shared BuildKit. README.md says more. From this
// repository's root:
//   deno run -A runners/runners.ts <setup> apply    the VM (a Colima setup's), the controller, BuildKit, then the scale sets
//   deno run -A runners/runners.ts <setup> status   the releases and the pods
//   deno run -A runners/runners.ts <setup> remove   the setup's scale sets gone (the VM, the controller and BuildKit kept)
// What it applies is plans[<setup>] (host.cue) of setups[<setup>] (setups.cue), never a value of its
// own; what to do, given what it finds, is plan.js's. Every kubectl and helm call names the plan's
// context, never the current one. Applying again changes only what differs.
import { secretHelp, steps } from "./plan.js";

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
const plan = JSON.parse(await must("./saytw", ["--script", "tools.nu", "cue", "export", "./runners/export", "-t", `setup=${setup}`, "-e", "plan", "--out", "json"]));
const kubectl = (...args: string[]) => ["kubectl", ["--context", plan.context, ...args]] as const;
const helm = (...args: string[]) => ["helm", ["--kube-context", plan.context, ...args]] as const;
const chart = (name: string) => `${plan.charts.repo}/${name}`;
const releases = async () => {
  const o = await run(...helm("list", "--namespace", plan.runnerNamespace, "--short"));
  return o.ok ? o.out.split("\n").filter(Boolean) : [];
};

if (verb === "apply") {
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
