// monitor/watch.ts — Live terminal dashboard (replaces factory-watch.sh)

import { join } from "node:path";
import { readJson, fileExists, fileSize, readTextFile, sleep, epochNow } from "../utils.js";
import type { FactoryState, Phase } from "../types.js";

const RED = "\x1b[0;31m";
const GREEN = "\x1b[0;32m";
const YELLOW = "\x1b[1;33m";
const BLUE = "\x1b[0;34m";
const CYAN = "\x1b[0;36m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const NC = "\x1b[0m";

const REFRESH_INTERVAL = parseInt(process.env.REFRESH_INTERVAL || "3");

function statusIcon(status: string): string {
  switch (status) {
    case "completed":
      return `${GREEN}DONE       ${NC}`;
    case "in_progress":
      return `${YELLOW}RUNNING    ${NC}`;
    case "failed":
      return `${RED}FAILED     ${NC}`;
    case "pending":
      return `${DIM}pending    ${NC}`;
    default:
      return `${DIM}${status.padEnd(11)}${NC}`;
  }
}

function gateIcon(passed: boolean): string {
  return passed ? `${GREEN}PASS${NC}` : `${DIM}--- ${NC}`;
}

function heartbeatDisplay(heartbeatFile: string): string {
  try {
    const f = Bun.file(heartbeatFile);
    if (!f.size && f.size !== 0) return `${DIM}no heartbeat${NC}`;
    const age = epochNow() - Math.floor(f.lastModified / 1000);
    if (age < 30) return `${GREEN}${age}s ago${NC}`;
    if (age < 120) return `${YELLOW}${age}s ago${NC}`;
    if (age < 300) return `${YELLOW}${Math.floor(age / 60)}m${age % 60}s ago${NC}`;
    return `${RED}${Math.floor(age / 60)}m${age % 60}s ago (STALE)${NC}`;
  } catch {
    return `${DIM}no heartbeat${NC}`;
  }
}

function elapsedDisplay(startedAt: string): string {
  if (!startedAt) return "";
  try {
    const startEpoch = Math.floor(new Date(startedAt).getTime() / 1000);
    const elapsed = epochNow() - startEpoch;
    if (elapsed <= 0) return "";

    const hours = Math.floor(elapsed / 3600);
    const mins = Math.floor((elapsed % 3600) / 60);
    const secs = elapsed % 60;

    if (hours > 0) return `${hours}h ${mins}m ${secs}s`;
    if (mins > 0) return `${mins}m ${secs}s`;
    return `${secs}s`;
  } catch {
    return "";
  }
}

async function getAgentInfo(): Promise<{ count: number; pids: string[] }> {
  try {
    const result = Bun.spawnSync(["pgrep", "-f", "claude.*factory-"]);
    const output = result.stdout.toString().trim();
    if (!output) return { count: 0, pids: [] };
    const pids = output.split("\n").filter(Boolean);
    return { count: pids.length, pids };
  } catch {
    return { count: 0, pids: [] };
  }
}

async function extractCurrentActivity(logDir: string, phase: string): Promise<string> {
  const streamFile = join(logDir, `${phase}.stream`);
  try {
    const content = await readTextFile(streamFile);
    const lines = content.trim().split("\n").filter(Boolean);
    const last20 = lines.slice(-20);

    let lastTool = "";
    let lastText = "";

    for (const line of last20) {
      try {
        const parsed = JSON.parse(line);
        if (parsed.type === "assistant" && parsed.message?.content) {
          for (const block of parsed.message.content) {
            if (block.type === "tool_use" && block.name) lastTool = block.name;
            if (block.type === "text" && block.text) lastText = block.text.slice(0, 120);
          }
        }
      } catch {}
    }

    if (lastTool) return `Tool: ${lastTool}`;
    if (lastText) return lastText;
    return "";
  } catch {
    return "";
  }
}

async function renderDashboard(projectDir: string): Promise<void> {
  const factoryDir = join(projectDir, ".factory");
  const stateFile = join(factoryDir, "state.json");
  const heartbeatFile = join(factoryDir, "heartbeat");
  const logDir = join(factoryDir, "logs");

  // Clear screen
  process.stdout.write("\x1b[2J\x1b[H");

  if (!(await fileExists(stateFile))) {
    console.log(`${DIM}Waiting for factory to start... (looking for ${stateFile})${NC}`);
    return;
  }

  let state: FactoryState;
  try {
    state = await readJson<FactoryState>(stateFile);
  } catch {
    console.log(`${DIM}Error reading state file${NC}`);
    return;
  }

  // Get spec name
  let specDisplay = "unknown";
  const specFile = join(factoryDir, "spec.json");
  if (await fileExists(specFile)) {
    try {
      const spec = await readJson<{ name?: string; description?: string }>(specFile);
      specDisplay = (spec.name || spec.description?.slice(0, 80) || "unknown").slice(0, 80);
    } catch {}
  }

  const cols = process.stdout.columns || 80;
  const rows = process.stdout.rows || 24;
  const logLines = Math.max(rows - 20, 5);

  const agents = await getAgentInfo();
  const elapsed = elapsedDisplay(state.started_at);

  // Header
  console.log(`${BOLD}SOFTWARE FACTORY${NC}  ${new Date().toTimeString().slice(0, 8)}`);
  console.log("─".repeat(cols));

  // Status
  console.log(`  Spec: ${CYAN}${specDisplay}${NC}`);
  let startedLine = `  Started: ${state.started_at}`;
  if (elapsed) startedLine += `   Elapsed: ${CYAN}${BOLD}${elapsed}${NC}`;
  console.log(startedLine);
  console.log(`  Heartbeat: ${heartbeatDisplay(heartbeatFile)}`);

  // Agents
  if (agents.count > 0) {
    console.log(`  Agents: ${GREEN}${agents.count} active${NC}`);
  } else {
    console.log(`  Agents: ${DIM}none running${NC}`);
  }

  // Preview
  const previewFile = join(factoryDir, "preview.json");
  if (await fileExists(previewFile)) {
    try {
      const preview = await readJson<{ status: string; ports?: Record<string, number> }>(previewFile);
      const ports = preview.ports
        ? Object.entries(preview.ports).map(([k, v]) => `${k}:${v}`).join(" ")
        : "";
      console.log(`  Preview: ${preview.status}  ${ports}`);
    } catch {}
  }

  // Phase table
  console.log("");
  console.log(`  ${BOLD}${"PHASE".padEnd(16)} ${"STATUS".padEnd(13)} ${"ITER".padEnd(6)} GATE${NC}`);
  console.log(`  ${"─────".padEnd(16)} ${"──────".padEnd(13)} ${"────".padEnd(6)} ────`);

  const phases: Phase[] = ["planning", "implementation", "verification"];
  const gateNames = ["plan", "implementation", "verification"];

  for (let i = 0; i < phases.length; i++) {
    const phase = phases[i];
    const phaseState = state.phases[phase];
    const gateName = gateNames[i];
    const gatePassed = gateName && state.gates[gateName as keyof typeof state.gates]?.passed || false;

    const indicator =
      phase === state.current_phase && phaseState.status === "in_progress"
        ? `${YELLOW}> ${NC}`
        : "  ";

    process.stdout.write(`  ${indicator}${phase.padEnd(14)} `);
    process.stdout.write(`${statusIcon(phaseState.status)} `);
    process.stdout.write(`${String(phaseState.iterations).padEnd(6)} `);
    process.stdout.write(gateIcon(gatePassed));
    console.log("");
  }

  // Artifacts
  console.log("");
  console.log(`  ${BOLD}ARTIFACTS${NC}`);
  for (const artifact of ["plan.md", "review.md"]) {
    const path = join(factoryDir, "artifacts", artifact);
    if (await fileExists(path)) {
      const size = await fileSize(path);
      console.log(`    ${GREEN}${artifact.padEnd(20)}${NC} ${size} bytes`);
    } else {
      console.log(`    ${DIM}${artifact.padEnd(20)}${NC} ${DIM}not created${NC}`);
    }
  }

  // Task count
  try {
    const glob = new Bun.Glob("task-*-complete.md");
    let count = 0;
    for await (const _ of glob.scan({ cwd: join(factoryDir, "artifacts/tasks") })) count++;
    console.log(`    ${"tasks completed:".padEnd(20)} ${count}`);
  } catch {
    console.log(`    ${"tasks completed:".padEnd(20)} 0`);
  }

  // Current activity
  console.log("");
  console.log("─".repeat(cols));

  const currentPhase = state.current_phase;
  if (currentPhase !== "done" && currentPhase !== "unknown") {
    const activity = await extractCurrentActivity(logDir, currentPhase);
    if (activity) {
      console.log(`  ${BOLD}Current:${NC} ${activity}`);
    }

    const logFile = join(logDir, `${currentPhase}.log`);
    if (await fileExists(logFile)) {
      console.log(`  ${BOLD}Agent output:${NC} (${currentPhase})`);
      const content = await readTextFile(logFile);
      const lines = content.split("\n");
      const tail = lines.slice(-logLines, lines.length);
      console.log(DIM);
      for (const line of tail) {
        console.log(`  ${line}`);
      }
      console.log(NC);
    } else {
      console.log(`  ${DIM}Waiting for agent output...${NC}`);
    }
  }

  // Done check
  if (await fileExists(join(factoryDir, "done"))) {
    console.log("");
    console.log(`  ${GREEN}${BOLD}FACTORY COMPLETE${NC}`);
    if (state.final_verdict) {
      console.log(`  Verdict: ${GREEN}${state.final_verdict}${NC}`);
    }
  }

  // Gate failures
  const failedGates: string[] = [];
  for (const [name, gate] of Object.entries(state.gates)) {
    if (!gate.passed && gate.feedback) {
      failedGates.push(`${name}: ${gate.feedback}`);
    }
  }
  if (failedGates.length > 0) {
    console.log("");
    console.log(`  ${RED}${BOLD}Gate Failures:${NC}`);
    for (const line of failedGates) {
      console.log(`    ${RED}${line}${NC}`);
    }
  }
}

// --- Main loop ---
const projectDir = process.argv[2] || ".";

// Hide cursor
process.stdout.write("\x1b[?25l");
process.on("SIGINT", () => {
  process.stdout.write("\x1b[?25h"); // Show cursor
  process.exit(0);
});
process.on("SIGTERM", () => {
  process.stdout.write("\x1b[?25h");
  process.exit(0);
});

while (true) {
  await renderDashboard(projectDir);
  await sleep(REFRESH_INTERVAL * 1000);
}
