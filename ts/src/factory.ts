// factory.ts — Main orchestrator (replaces factory-runner.sh)

import type { Options, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { getModelForPhase, getStalenessThreshold, getToolsForPhase } from "./agents.js";
import { evaluateGate } from "./gates.js";
import { createGateStopHook, createHeartbeatHook } from "./hooks.js";
import { promptForPhase } from "./prompts.js";
import {
  buildConfig,
  checkAuthExpiry,
  decrementIterations,
  finalizeFactory,
  getIterations,
  initFactory,
  nextPendingPhase,
  setVerificationReroute,
  updateCycleDetection,
  updateGate,
  updateState,
  writeAlert,
} from "./state.js";
import type { FactoryConfig, Phase, RerouteEntry } from "./types.js";
import { PHASE_TO_GATE } from "./types.js";
import {
  epochNow,
  fileExists,
  log,
  logErr,
  logOk,
  logWarn,
  readJson,
  sleep,
  touchFile,
} from "./utils.js";

const TRANSIENT_ERROR_PATTERNS = [
  "overloaded_error",
  '"529"',
  '"500"',
  "rate_limit",
  "capacity",
  "too_many_requests",
  "server_error",
];

function isTransientApiError(output: string): boolean {
  return TRANSIENT_ERROR_PATTERNS.some((p) => output.includes(p));
}

interface PhaseRunResult {
  sessionId: string;
  isApiError: boolean;
}

async function runPhase(
  phase: Phase,
  prompt: string,
  config: FactoryConfig,
): Promise<PhaseRunResult> {
  const { factoryDir, projectDir, apiRetryMax, apiRetryInitialWait, phaseTimeout, maxTurns } = config;
  const logFile = join(factoryDir, "logs", `${phase}.log`);
  const streamFile = join(factoryDir, "logs", `${phase}.stream`);
  const heartbeatFile = join(factoryDir, "heartbeat");

  await updateState(factoryDir, phase, "in_progress");

  let waitTime = apiRetryInitialWait;

  for (let apiAttempt = 1; apiAttempt <= apiRetryMax; apiAttempt++) {
    const sessionName = `factory-${phase}-${Math.floor(Date.now() / 1000)}`;

    if (apiAttempt > 1) {
      logWarn(`API retry ${apiAttempt}/${apiRetryMax} for phase: ${phase} (waiting ${waitTime}s)`);
      await sleep(waitTime * 1000);
      waitTime = Math.min(waitTime * 2, 300); // exponential backoff, cap at 5 min
    }

    log(`Starting phase: ${phase} (session: ${sessionName}, attempt: ${apiAttempt})`);
    await touchFile(heartbeatFile);

    // Clear previous attempt's files
    await Bun.write(streamFile, "");
    await Bun.write(logFile, "");

    const allowedTools = getToolsForPhase(phase);
    const model = getModelForPhase(phase);

    // Set up abort controller for timeout/staleness
    const abortController = new AbortController();

    // Phase wall-clock timeout
    const phaseTimer = setTimeout(() => {
      logWarn(`Phase '${phase}' exceeded wall-clock timeout (${phaseTimeout}s). Aborting.`);
      abortController.abort();
    }, phaseTimeout * 1000);

    // Staleness detection
    const stalenessThreshold = getStalenessThreshold(phase);
    let lastActivityTime = epochNow();

    const stalenessInterval = setInterval(() => {
      touchFile(heartbeatFile).catch(() => {});

      const now = epochNow();
      const staleDuration = now - lastActivityTime;
      if (staleDuration >= stalenessThreshold) {
        logWarn(
          `Agent output stale for ${staleDuration}s (threshold: ${stalenessThreshold}s). Aborting.`,
        );
        abortController.abort();
      }
    }, 10_000); // check every 10s

    let sessionId = "unknown";
    let streamContent = "";

    try {
      // Build SDK hooks
      const stopHook = createGateStopHook(factoryDir);
      const heartbeatHook = createHeartbeatHook(heartbeatFile);

      // Build query options
      const options: Options = {
        abortController,
        allowedTools,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        model,
        cwd: projectDir,
        hooks: {
          Stop: [{ hooks: [stopHook] }],
          PostToolUse: [{ hooks: [heartbeatHook] }],
        },
      };

      if (maxTurns) {
        options.maxTurns = maxTurns;
      }

      // Run the agent via SDK — query returns an AsyncGenerator
      const queryResult = query({ prompt, options });

      // Iterate the async generator, writing each message to the stream file
      for await (const message of queryResult) {
        lastActivityTime = epochNow();

        // Write each message as NDJSON line to stream file
        const line = JSON.stringify(message) + "\n";
        await appendFile(streamFile, line);

        // Try to extract session_id from messages
        const msg = message as SDKMessage & { session_id?: string };
        if (msg.session_id && sessionId === "unknown") {
          sessionId = msg.session_id;
        }
      }

      streamContent = await Bun.file(streamFile).text();
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      streamContent = await Bun.file(streamFile).text().catch(() => "");

      if (abortController.signal.aborted) {
        logWarn(`Phase '${phase}' was aborted (timeout or staleness).`);
        await writeAlert(
          factoryDir,
          "phase_abort",
          `Phase '${phase}' aborted after timeout/staleness`,
          phase,
        );
      } else {
        logErr(`Phase '${phase}' error: ${errMsg}`);
      }
    } finally {
      clearTimeout(phaseTimer);
      clearInterval(stalenessInterval);
      await touchFile(heartbeatFile);
    }

    // Extract plain text log from stream
    try {
      const lines = streamContent.split("\n").filter(Boolean);
      const textLines: string[] = [];
      for (const line of lines) {
        try {
          const parsed = JSON.parse(line);
          if (parsed.type === "assistant" && parsed.message?.content) {
            for (const block of parsed.message.content) {
              if (block.type === "text" && block.text) {
                textLines.push(block.text);
              }
            }
          }
        } catch {}
      }
      await Bun.write(logFile, textLines.join("\n"));
    } catch {}

    // Check for transient API error
    if (isTransientApiError(streamContent)) {
      logWarn(`Transient API error on attempt ${apiAttempt}/${apiRetryMax}`);
      if (apiAttempt >= apiRetryMax) {
        logErr(`Exhausted ${apiRetryMax} API retries for phase: ${phase}`);
        return { sessionId: "api_error", isApiError: true };
      }
      continue;
    }

    // Not transient — we got a real response
    // Try to extract session_id from stream if not found during iteration
    if (sessionId === "unknown") {
      try {
        const lines = streamContent.split("\n").filter(Boolean);
        for (const line of lines) {
          try {
            const parsed = JSON.parse(line);
            if (parsed.session_id) {
              sessionId = parsed.session_id;
              break;
            }
          } catch {}
        }
      } catch {}
    }

    return { sessionId, isApiError: false };
  }

  // Should not reach here, but just in case
  return { sessionId: "unknown", isApiError: false };
}

export async function main(specInput: string, projectDir: string): Promise<void> {
  // Check claude CLI is available
  const which = Bun.spawnSync(["which", "claude"]);
  if (which.exitCode !== 0) {
    logErr("claude CLI not found. Install Claude Code first.");
    process.exit(1);
  }

  await checkAuthExpiry();

  const config = buildConfig(specInput, projectDir);
  await initFactory(config);

  log(`Factory started. Input: ${specInput}`);

  const factoryStartTs = epochNow();
  const { factoryDir } = config;

  while (true) {
    // Factory-level wall-clock timeout
    const factoryElapsed = epochNow() - factoryStartTs;
    if (factoryElapsed >= config.factoryTimeout) {
      logErr(
        `Factory exceeded wall-clock timeout (${config.factoryTimeout}s / ${Math.floor(config.factoryTimeout / 3600)}h). Halting.`,
      );
      await writeAlert(
        factoryDir,
        "timeout",
        `Factory exceeded ${Math.floor(config.factoryTimeout / 3600)}h wall-clock limit after ${factoryElapsed}s`,
        "factory",
      );
      break;
    }

    // Get next pending phase
    const phase = await nextPendingPhase(config);
    if (phase === null) {
      logOk("All phases complete!");

      // Stop preview process if running
      const previewFile = join(factoryDir, "preview.json");
      if (await fileExists(previewFile)) {
        try {
          const preview = await readJson<{ pid?: number }>(previewFile);
          if (preview.pid) {
            log(`Stopping preview (PID ${preview.pid})`);
            try {
              process.kill(preview.pid);
            } catch {}
          }
        } catch {}
      }

      await touchFile(join(factoryDir, "done"));
      break;
    }

    const iterations = await getIterations(factoryDir, phase);
    if (iterations >= config.maxIterations) {
      logErr(`Phase '${phase}' exceeded max iterations (${config.maxIterations}). Skipping.`);
      await writeAlert(
        factoryDir,
        "max_iterations",
        `Phase '${phase}' exceeded ${config.maxIterations} iterations — force-advancing`,
        phase,
      );
      await updateState(factoryDir, phase, "completed");
      continue;
    }

    log(`Phase: ${phase} (iteration ${iterations + 1}/${config.maxIterations})`);

    // Get prompt and run phase
    const prompt = await promptForPhase(phase, config);
    const { sessionId, isApiError } = await runPhase(phase, prompt, config);

    // Handle API-level failure
    if (isApiError) {
      logErr(`Phase '${phase}' failed due to API errors (all retries exhausted). Will retry on next loop.`);
      await updateState(factoryDir, phase, "failed");
      await decrementIterations(factoryDir, phase);
      log(`Waiting 60s before retrying phase '${phase}'...`);
      await sleep(60_000);
      continue;
    }

    // Evaluate the gate
    const gateName = PHASE_TO_GATE[phase];
    const gateResult = await evaluateGate(phase, factoryDir, config.projectDir);

    if (gateName) {
      await updateGate(factoryDir, gateName, gateResult.passed, gateResult.feedback);
    }

    if (gateResult.passed) {
      logOk(`Phase '${phase}' PASSED gate check`);
      await updateState(factoryDir, phase, "completed", sessionId);
    } else {
      logWarn(`Phase '${phase}' FAILED gate check: ${gateResult.feedback}`);
      await updateState(factoryDir, phase, "failed", sessionId);

      // Check for reroute file
      const rerouteFile = join(factoryDir, "reroute.json");
      if (await fileExists(rerouteFile)) {
        try {
          const reroute = await readJson<RerouteEntry>(rerouteFile);
          logWarn(`Reroute requested: back to '${reroute.to}' — ${reroute.reason}`);
          await updateState(factoryDir, reroute.to as Phase, "pending");
          const { unlink } = await import("node:fs/promises");
          await unlink(rerouteFile);
        } catch (err) {
          logErr(`Failed to process reroute: ${err}`);
        }
      }

      // Cycle detection
      const cycleCount = await updateCycleDetection(
        factoryDir,
        phase,
        gateResult.feedback,
      );

      if (cycleCount >= 3) {
        logErr(
          `Phase '${phase}' stuck in cycle: same failure ${cycleCount} consecutive times. Force-advancing.`,
        );
        await writeAlert(
          factoryDir,
          "cycle",
          `Phase '${phase}' failing with same error ${cycleCount} times — force-advancing`,
          phase,
        );
        await updateState(factoryDir, phase, "completed");
        continue;
      }

      // Auto-reroute: verification fail -> implementation
      if (phase === "verification") {
        logWarn("Verification failed — routing back to implementation to fix issues");
        await updateState(factoryDir, "implementation", "pending");
        await setVerificationReroute(factoryDir, gateResult.feedback);
      }
    }
  }

  // Final status
  const doneFile = join(factoryDir, "done");
  if (await fileExists(doneFile)) {
    await finalizeFactory(factoryDir, true);
    logOk("Factory completed successfully!");
  } else {
    logErr("Factory did not complete. Check .factory/state.json for status.");
    process.exit(1);
  }
}
