// heartbeat.ts — Watchdog process (replaces factory-heartbeat.sh)

import { join, dirname, resolve } from "node:path";
import { log, logOk, logWarn, logErr, readJson, fileExists, sleep, epochNow } from "./utils.js";
import { appendFile, mkdir } from "node:fs/promises";

const STALL_THRESHOLD = parseInt(process.env.STALL_THRESHOLD || "300"); // 5 minutes
const CHECK_INTERVAL = parseInt(process.env.CHECK_INTERVAL || "30"); // 30 seconds
const MAX_RESTARTS = parseInt(process.env.MAX_RESTARTS || "5");

function getHeartbeatAge(heartbeatFile: string): number {
  try {
    const stat = Bun.file(heartbeatFile);
    if (!stat.size && stat.size !== 0) return 999999;
    const lastBeat = Math.floor(stat.lastModified / 1000);
    return epochNow() - lastBeat;
  } catch {
    return 999999;
  }
}

async function cleanupOrphans(): Promise<void> {
  try {
    const result = Bun.spawnSync(["pgrep", "-f", "claude.*factory-"]);
    const pids = result.stdout.toString().trim();
    if (pids) {
      logWarn(`Cleaning up orphaned claude processes: ${pids}`);
      for (const pid of pids.split("\n")) {
        try {
          process.kill(parseInt(pid));
        } catch {}
      }
      await sleep(2000);
      // Force kill if still running
      for (const pid of pids.split("\n")) {
        try {
          process.kill(parseInt(pid), 9);
        } catch {}
      }
    }
  } catch {}
}

async function logToFile(logFile: string, msg: string): Promise<void> {
  const line = `[heartbeat ${new Date().toISOString()}] ${msg}\n`;
  console.log(msg);
  try {
    await appendFile(logFile, line);
  } catch {}
}

async function watchdog(specInput: string, projectDir: string): Promise<void> {
  const factoryDir = join(projectDir, ".factory");
  const heartbeatFile = join(factoryDir, "heartbeat");
  const doneFile = join(factoryDir, "done");
  const logFile = join(factoryDir, "logs/heartbeat.log");

  await mkdir(join(factoryDir, "logs"), { recursive: true });

  // Resolve the runner script path
  const srcDir = dirname(new URL(import.meta.url).pathname);
  const indexScript = resolve(join(srcDir, "index.ts"));

  await logToFile(logFile, `Starting factory watchdog`);
  await logToFile(logFile, `Spec: ${specInput}`);
  await logToFile(logFile, `Project: ${projectDir}`);
  await logToFile(logFile, `Stall threshold: ${STALL_THRESHOLD}s`);
  await logToFile(logFile, `Max restarts: ${MAX_RESTARTS}`);

  let restartCount = 0;

  while (!(await fileExists(doneFile)) && restartCount < MAX_RESTARTS) {
    await logToFile(logFile, `Starting factory runner (attempt ${restartCount + 1}/${MAX_RESTARTS})`);

    // Start the runner
    const proc = Bun.spawn(["bun", "run", indexScript, specInput, projectDir], {
      cwd: projectDir,
      stdout: "pipe",
      stderr: "pipe",
    });

    await logToFile(logFile, `Runner PID: ${proc.pid}`);

    // Monitor loop
    let killed = false;
    while (true) {
      await sleep(CHECK_INTERVAL * 1000);

      // Check if done
      if (await fileExists(doneFile)) {
        logOk("Factory completed! Done file found.");
        proc.kill();
        return;
      }

      // Check if process is still running
      if (proc.exitCode !== null) {
        break; // Process exited
      }

      // Check heartbeat
      const age = getHeartbeatAge(heartbeatFile);

      if (age > STALL_THRESHOLD) {
        await logToFile(
          logFile,
          `WARN: Factory stalled! No heartbeat for ${age}s (threshold: ${STALL_THRESHOLD}s)`,
        );
        await logToFile(logFile, `WARN: Killing runner PID ${proc.pid}`);

        proc.kill();
        await sleep(3000);
        try {
          proc.kill(9);
        } catch {}

        await cleanupOrphans();
        restartCount++;
        killed = true;
        break;
      }

      // Log status
      try {
        const state = await readJson<{ current_phase: string }>(join(factoryDir, "state.json"));
        await logToFile(logFile, `Heartbeat OK (age: ${age}s). Phase: ${state.current_phase}`);
      } catch {
        await logToFile(logFile, `Heartbeat OK (age: ${age}s). Phase: unknown`);
      }
    }

    // If runner exited on its own (not killed by us)
    if (!killed) {
      const exitCode = proc.exitCode ?? -1;

      if (await fileExists(doneFile)) {
        logOk("Factory completed successfully!");
        return;
      } else if (exitCode === 0) {
        await logToFile(logFile, "Runner exited cleanly but no done file. Checking state...");
        try {
          const state = await readJson<{ current_phase: string }>(join(factoryDir, "state.json"));
          if (state.current_phase === "done") {
            await Bun.write(doneFile, "");
            return;
          }
          await logToFile(logFile, `WARN: Runner exited at phase: ${state.current_phase}. Restarting...`);
        } catch {
          await logToFile(logFile, "WARN: Could not read state. Restarting...");
        }
        restartCount++;
      } else {
        await logToFile(logFile, `ERROR: Runner exited with code ${exitCode}. Restarting...`);
        restartCount++;
      }
    }

    await sleep(5000);
  }

  // Final report
  console.log("");
  console.log("================================");
  if (await fileExists(doneFile)) {
    logOk("FACTORY COMPLETE");
    try {
      const state = await readJson<Record<string, unknown>>(join(factoryDir, "state.json"));
      console.log(JSON.stringify(state, null, 2));
    } catch {}
  } else {
    logErr("FACTORY DID NOT COMPLETE");
    logErr(`Exhausted ${MAX_RESTARTS} restart attempts.`);
    try {
      const state = await readJson<{ phases: Record<string, { status: string; iterations: number }> }>(
        join(factoryDir, "state.json"),
      );
      for (const [name, info] of Object.entries(state.phases)) {
        console.log(`  ${name}: ${info.status} (iterations: ${info.iterations})`);
      }
    } catch {}
    console.log(`\nTo resume: bun run ts/src/heartbeat.ts ${specInput} ${projectDir}`);
    process.exit(1);
  }
}

// --- CLI entry ---
const args = process.argv.slice(2);
if (args.length < 1) {
  console.error("Usage: bun run ts/src/heartbeat.ts <spec-file> [project-dir]");
  process.exit(1);
}

const specInput = args[0];
const projectDir = args[1] || ".";

watchdog(specInput, projectDir).catch((err) => {
  logErr(`Watchdog crashed: ${err}`);
  process.exit(1);
});
