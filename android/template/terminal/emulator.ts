// integrate@android's emulator, started for one command and always ended after it (PRONTO_ANDROID_EMULATOR):
//
//   deno run -A --no-lock android/terminal/emulator.ts <system-image> -- <command...>
//
// It boots a headless emulator on the first free even console port from 5554, on an AVD of its own
// (pronto-<port>, under ANDROID_AVD_HOME, never ~/.android/avd), waits for it to finish booting (a hang
// guard of 10 minutes), runs the command with ANDROID_SERIAL=emulator-<port>, passes its exit code through,
// and ends only the emulator it started: `adb emu kill` (only on a device that answers to its AVD's name), then
// TERM to its recorded pid, then KILL after 30 s. The port is claimed with a lock directory (<avd home>/pronto-<port>.lock
// holding the pid), so two runs never take one. Needs ANDROID_HOME with the emulator and the image installed, and adb
// and avdmanager on the PATH, as under run-mise (./saytw setup@android).

const BOOT_MINUTES = 10;

/** The first even console port from 5554 that is not in use (the emulator takes a console port and the one above it for adb). */
export function emulatorPort(used: number[]): number {
  let port = 5554;
  while (used.includes(port) || used.includes(port + 1)) port += 2;
  return port;
}

/** The AVD this port's emulator runs on. */
export function avdName(port: number): string {
  return `pronto-${port}`;
}

/** The emulator's arguments: headless, nothing saved, a clean disk. */
export function emulatorArgs(avd: string, port: number, cores = 2): string[] {
  return ["-avd", avd, "-port", String(port), "-no-window", "-no-snapshot-save", "-no-audio", "-no-boot-anim", "-wipe-data", "-cores", String(cores)];
}

async function main() {
  const dash = Deno.args.indexOf("--");
  const image = Deno.args[0];
  const command = dash < 0 ? [] : Deno.args.slice(dash + 1);
  if (!image || !command.length) throw new Error("usage: emulator.ts <system-image> -- <command...>");
  const home = Deno.env.get("ANDROID_HOME");
  if (!home) throw new Error("ANDROID_HOME is not set: run ./saytw setup@android");
  const user = Deno.env.get("HOME");
  if (!user) throw new Error("HOME is not set");
  const exists = (p: string) => { try { Deno.statSync(p); return true; } catch { return false; } };
  const onPath = (name: string) => (Deno.env.get("PATH") ?? "").split(":").some((d) => d && exists(`${d}/${name}`));
  const emulator = `${home}/emulator/emulator`;
  const missing = [...(exists(emulator) ? [] : ["emulator"]), ...(exists(`${home}/${image.replaceAll(";", "/")}`) ? [] : [image]), ...["adb", "avdmanager"].filter((t) => !onPath(t))];
  if (missing.length) throw new Error(`${missing.join(", ")} not installed: run ./saytw setup@android`);

  // Always this folder, whatever the caller inherited: never ~/.android/avd.
  const avdHome = `${user}/.cache/pronto/android/avd`;
  Deno.mkdirSync(avdHome, { recursive: true });
  const env = { ...Deno.env.toObject(), ANDROID_AVD_HOME: avdHome };
  // Every call is bounded, so the boot's 10 minutes are strict.
  const out = async (cmd: string, args: string[], seconds: number, input?: string) => {
    const p = new Deno.Command(cmd, { args, env, signal: AbortSignal.timeout(seconds * 1000), stdin: input === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
    if (input !== undefined) { const w = p.stdin.getWriter(); await w.write(new TextEncoder().encode(input)); await w.close(); }
    const r = await p.output();
    return { code: r.code, text: new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr) };
  };
  const alive = (pid: number) => new Deno.Command("kill", { args: ["-0", String(pid)], stdout: "null", stderr: "null" }).outputSync().code === 0;

  const listed = await out("adb", ["devices"], 60);
  if (listed.code !== 0) throw new Error(`adb devices failed (exit ${listed.code}): ${listed.text.trim()}`);
  const used = [...listed.text.matchAll(/emulator-(\d+)/g)].map((m) => Number(m[1]));
  // The port is claimed by making its lock directory, which only one run can; a holder whose pid is gone is taken over.
  let port = 0, lock = "";
  for (;;) {
    port = emulatorPort(used);
    lock = `${avdHome}/${avdName(port)}.lock`;
    try { Deno.mkdirSync(lock); Deno.writeTextFileSync(`${lock}/pid`, String(Deno.pid)); break; } catch (e) {
      if (!(e instanceof Deno.errors.AlreadyExists)) throw e;
      const holder = (() => { try { return Number(Deno.readTextFileSync(`${lock}/pid`)); } catch { return 0; } })();
      const fresh = Date.now() - Deno.statSync(lock).mtime!.getTime() < 60_000;
      if (holder ? !alive(holder) : !fresh) { Deno.removeSync(lock, { recursive: true }); continue; }
      used.push(port);
    }
  }
  const avd = avdName(port);
  const serial = `emulator-${port}`;
  const release = () => { try { Deno.removeSync(lock, { recursive: true }); } catch { /* already gone */ } };

  let proc: Deno.ChildProcess | undefined, log: Deno.FsFile | undefined, pumps: Promise<void>[] = [], cmdProc: Deno.ChildProcess | undefined;
  let ours = false, exitedAlready = false, ending: Promise<void> | undefined;
  // Only the emulator this run started, once, whoever asks: the command's child first, `adb emu kill` only on a device
  // that answered to this AVD's name, TERM to the recorded pid and KILL after 30 s.
  const end = () => ending ??= (async () => {
    const note = (what: string, e: unknown) => console.error(`emulator: ${what}: ${(e as Error).message}`);
    if (cmdProc) { try { cmdProc.kill("SIGTERM"); } catch { /* already exited */ } }
    if (ours) await out("adb", ["-s", serial, "emu", "kill"], 15).catch((e) => note("adb emu kill", e));
    if (proc && !exitedAlready) {
      try { proc.kill("SIGTERM"); } catch (e) { note("TERM to the emulator", e); }
      const done = proc.status.then(() => true);
      if (!(await Promise.race([done, new Promise<boolean>((r) => setTimeout(() => r(false), 30_000))]))) {
        console.error(`emulator: ${serial} did not end 30 s after TERM: KILL`);
        try { proc.kill("SIGKILL"); } catch (e) { note("KILL to the emulator", e); }
        await proc.status;
      }
    }
    await Promise.all(pumps);
    log?.close();
    release();
  })();
  let code = 1;
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as Deno.Signal[]) Deno.addSignalListener(sig, async () => { await end(); Deno.exit(130); });
  try {
    const made = await out("avdmanager", ["create", "avd", "--force", "-n", avd, "-k", image, "-d", "pixel_6"], 120, "no\n");
    if (made.code !== 0) throw new Error(`avdmanager failed: ${made.text.trim()}`);

    const logPath = `${avdHome}/${avd}.log`;
    log = Deno.openSync(logPath, { write: true, create: true, truncate: true });
    proc = new Deno.Command(emulator, { args: emulatorArgs(avd, port), env, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
    proc.status.then(() => { exitedAlready = true; });
    const pump = async (from: ReadableStream<Uint8Array>) => { for await (const chunk of from) log!.writeSync(chunk); };
    pumps = [pump(proc.stdout), pump(proc.stderr)];

    const deadline = Date.now() + BOOT_MINUTES * 60_000;
    for (;;) {
      if (exitedAlready) throw new Error(`the emulator exited before it booted:\n${Deno.readTextFileSync(logPath).split("\n").slice(-20).join("\n")}`);
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`${serial} did not finish booting in ${BOOT_MINUTES} minutes`);
      const wait = Math.min(15, Math.ceil(left / 1000));
      // The device on this serial must be ours before anything is sent to it, and before it is ever killed.
      if (!ours) {
        const named = (await out("adb", ["-s", serial, "emu", "avd", "name"], wait)).text.split("\n")[0].trim();
        if (named && named !== avd && /^[\w.-]+$/.test(named)) throw new Error(`${serial} is the emulator ${named}, not ${avd}: left alone`);
        ours = named === avd;
      }
      if (ours) {
        const booted = await out("adb", ["-s", serial, "shell", "getprop", "sys.boot_completed"], wait);
        if (booted.code === 0 && booted.text.trim() === "1") break;
      }
      await new Promise((r) => setTimeout(r, 5000));
    }
    cmdProc = new Deno.Command(command[0], { args: command.slice(1), env: { ...env, ANDROID_SERIAL: serial }, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).spawn();
    code = (await cmdProc.status).code;
  } finally {
    await end();
  }
  Deno.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`emulator: ${(e as Error).message}`); Deno.exit(1); });
}
