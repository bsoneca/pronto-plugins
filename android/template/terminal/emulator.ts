// integrate@android's emulator, started for one command and always ended after it (PRONTO_ANDROID_EMULATOR):
//
//   deno run -A --no-lock android/terminal/emulator.ts <system-image> -- <command...>
//
// It boots a headless emulator on the first free even console port from 5554, on an AVD of its own
// (pronto-<port>, under ANDROID_AVD_HOME, never ~/.android/avd), waits for it to finish booting (a hang
// guard of 10 minutes), runs the command with ANDROID_SERIAL=emulator-<port>, passes its exit code through,
// and ends only the emulator it started: `adb emu kill`, then TERM to its recorded pid. Needs ANDROID_HOME
// with the emulator and the image installed (./saytw setup@android).

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
  const exists = (p: string) => { try { Deno.statSync(p); return true; } catch { return false; } };
  const adb = `${home}/platform-tools/adb`, emulator = `${home}/emulator/emulator`;
  const avdManager = `${home}/cmdline-tools/latest/bin/avdmanager`;
  if (!exists(emulator) || !exists(`${home}/${image.replaceAll(";", "/")}`)) throw new Error(`the emulator or ${image} is not installed: run ./saytw setup@android`);

  const avdHome = Deno.env.get("ANDROID_AVD_HOME") ?? `${Deno.env.get("HOME")}/.cache/pronto/android/avd`;
  Deno.mkdirSync(avdHome, { recursive: true });
  const env = { ...Deno.env.toObject(), ANDROID_AVD_HOME: avdHome };
  const out = async (cmd: string, args: string[], input?: string) => {
    const p = new Deno.Command(cmd, { args, env, stdin: input === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
    if (input !== undefined) { const w = p.stdin.getWriter(); await w.write(new TextEncoder().encode(input)); await w.close(); }
    const r = await p.output();
    return { code: r.code, text: new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr) };
  };

  const listed = await out(adb, ["devices"]);
  const used = [...listed.text.matchAll(/emulator-(\d+)/g)].map((m) => Number(m[1]));
  const port = emulatorPort(used);
  const avd = avdName(port);
  const made = await out(avdManager, ["create", "avd", "--force", "-n", avd, "-k", image, "-d", "pixel_6"], "no\n");
  if (made.code !== 0) throw new Error(`avdmanager failed: ${made.text.trim()}`);

  const logPath = `${avdHome}/${avd}.log`;
  const log = Deno.openSync(logPath, { write: true, create: true, truncate: true });
  const proc = new Deno.Command(emulator, { args: emulatorArgs(avd, port), env, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  proc.stdout.pipeTo(log.writable, { preventClose: true }).catch(() => {});
  proc.stderr.pipeTo(log.writable, { preventClose: true }).catch(() => {});
  const serial = `emulator-${port}`;
  let ended = false;
  const exited = proc.status.then((s) => { ended = true; return s; });

  // Only the emulator this run started: its console's `adb emu kill`, then TERM to its pid.
  const end = async () => {
    await out(adb, ["-s", serial, "emu", "kill"]).catch(() => {});
    if (!ended) { try { proc.kill("SIGTERM"); } catch { /* gone */ } }
    await Promise.race([exited, new Promise((r) => setTimeout(r, 30_000))]);
    log.close();
  };
  let code = 1;
  const signals: Deno.Signal[] = ["SIGINT", "SIGTERM", "SIGHUP"];
  for (const s of signals) Deno.addSignalListener(s, async () => { await end(); Deno.exit(130); });
  try {
    const deadline = Date.now() + BOOT_MINUTES * 60_000;
    for (;;) {
      if (ended) throw new Error(`the emulator exited before it booted:\n${Deno.readTextFileSync(logPath).split("\n").slice(-20).join("\n")}`);
      if (Date.now() > deadline) throw new Error(`${serial} did not finish booting in ${BOOT_MINUTES} minutes`);
      const booted = await out(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"]);
      if (booted.code === 0 && booted.text.trim() === "1") break;
      await new Promise((r) => setTimeout(r, 5000));
    }
    const ran = await new Deno.Command(command[0], { args: command.slice(1), env: { ...env, ANDROID_SERIAL: serial }, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).spawn().status;
    code = ran.code;
  } finally {
    await end();
  }
  Deno.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`emulator: ${(e as Error).message}`); Deno.exit(1); });
}
