// hooks.ts — SDK hook callbacks (Stop gate, heartbeat)

import { join } from "node:path";
import type { Phase } from "./types.js";
import { readJson, touchFile, fileExists } from "./utils.js";
import { checkGateForStopHook } from "./gates.js";
import type { HookInput, HookJSONOutput } from "@anthropic-ai/claude-agent-sdk";

const MAX_GATE_BLOCKS = parseInt(process.env.MAX_GATE_BLOCKS || "10");

type HookCallback = (
  input: HookInput,
  toolUseID: string | undefined,
  options: { signal: AbortSignal },
) => Promise<HookJSONOutput>;

/**
 * Creates a Stop hook callback that checks gate criteria before allowing the agent to stop.
 *
 * SDK Stop hook contract:
 * - Return {} to allow stop
 * - Return { decision: "block", reason: "..." } to block and force the agent to continue
 */
export function createGateStopHook(factoryDir: string): HookCallback {
  return async (
    input: HookInput,
    _toolUseID: string | undefined,
    _options: { signal: AbortSignal },
  ): Promise<HookJSONOutput> => {
    // Only activate during factory runs
    if (!(await fileExists(join(factoryDir, "state.json")))) {
      return {};
    }

    // Touch heartbeat
    await touchFile(join(factoryDir, "heartbeat")).catch(() => {});

    // Read current phase
    let currentPhase: Phase;
    try {
      const state = await readJson<{ current_phase: string }>(
        join(factoryDir, "state.json"),
      );
      currentPhase = state.current_phase as Phase;
    } catch {
      return {};
    }

    // Self-limiting block counter
    const blockCountFile = join(factoryDir, `.gate-blocks-${currentPhase}`);
    let blockCount = 0;
    try {
      const content = await Bun.file(blockCountFile).text();
      blockCount = parseInt(content.trim()) || 0;
    } catch {}

    if (blockCount >= MAX_GATE_BLOCKS) {
      console.error(
        `Gate has blocked agent ${blockCount} times for phase '${currentPhase}'. Allowing stop to prevent infinite loop.`,
      );
      // Reset counter
      try {
        const { unlink } = await import("node:fs/promises");
        await unlink(blockCountFile);
      } catch {}
      return {};
    }

    // Run gate check
    const result = await checkGateForStopHook(currentPhase, factoryDir);

    if (result.shouldBlock) {
      // Increment block counter
      await Bun.write(blockCountFile, String(blockCount + 1));
      console.error(result.feedback);
      return { decision: "block", reason: result.feedback };
    }

    // Gate passed — reset block counter
    try {
      const { unlink } = await import("node:fs/promises");
      await unlink(blockCountFile);
    } catch {}

    return {};
  };
}

/**
 * Creates a PostToolUse hook that touches the heartbeat file on every tool use.
 */
export function createHeartbeatHook(heartbeatFile: string): HookCallback {
  return async (
    _input: HookInput,
    _toolUseID: string | undefined,
    _options: { signal: AbortSignal },
  ): Promise<HookJSONOutput> => {
    await touchFile(heartbeatFile).catch(() => {});
    return {};
  };
}
