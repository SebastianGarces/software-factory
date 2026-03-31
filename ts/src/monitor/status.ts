// monitor/status.ts — One-shot status query (replaces factory-status.sh)

import { join } from "node:path";
import { readJson, fileExists, fileSize, epochNow } from "../utils.js";
import type { FactoryState } from "../types.js";

const RED = "\x1b[0;31m";
const GREEN = "\x1b[0;32m";
const YELLOW = "\x1b[1;33m";
const DIM = "\x1b[2m";
const NC = "\x1b[0m";

function statusIcon(status: string): string {
  switch (status) {
    case "completed": return `${GREEN}done${NC}`;
    case "in_progress": return `${YELLOW}running${NC}`;
    case "failed": return `${RED}failed${NC}`;
    case "pending": return `${DIM}pending${NC}`;
    default: return `${DIM}${status}${NC}`;
  }
}

function gateIcon(passed: boolean): string {
  return passed ? `${GREEN}PASS${NC}` : `${DIM}---${NC}`;
}

async function showStatus(projectDir: string): Promise<void> {
  const factoryDir = join(projectDir, ".factory");
  const stateFile = join(factoryDir, "state.json");
  const heartbeatFile = join(factoryDir, "heartbeat");

  if (!(await fileExists(stateFile))) {
    console.log(`No factory state found at ${stateFile}`);
    console.log("Run /factory or bun run ts/src/index.ts to start.");
    process.exit(1);
  }

  const state = await readJson<FactoryState>(stateFile);

  // Spec info
  let specDisplay = "unknown";
  const specFile = join(factoryDir, "spec.json");
  if (await fileExists(specFile)) {
    try {
      const spec = await readJson<{ name?: string; description?: string }>(specFile);
      specDisplay = (spec.name || spec.description?.slice(0, 80) || "unknown").slice(0, 80);
    } catch {}
  }

  console.log("");
  console.log("=== Software Factory Status ===");
  console.log("");
  console.log(`Spec:    ${specDisplay}`);
  console.log(`Started: ${state.started_at || "not started"}`);

  // Heartbeat
  try {
    const f = Bun.file(heartbeatFile);
    const lastBeat = Math.floor(f.lastModified / 1000);
    const age = epochNow() - lastBeat;
    if (age < 60) console.log(`Heartbeat: ${GREEN}${age}s ago${NC}`);
    else if (age < 300) console.log(`Heartbeat: ${YELLOW}${age}s ago${NC}`);
    else console.log(`Heartbeat: ${RED}${age}s ago (STALE)${NC}`);
  } catch {
    console.log(`Heartbeat: ${DIM}no heartbeat file${NC}`);
  }

  console.log("");
  console.log("--- Pipeline Progress ---");
  console.log("");

  const phases = ["planning", "implementation", "verification"];
  const gates = ["plan", "implementation", "verification"];

  console.log(
    `${"PHASE".padEnd(16)} ${"STATUS".padEnd(12)} ${"ITER".padEnd(6)} GATE`,
  );
  console.log(
    `${"-----".padEnd(16)} ${"------".padEnd(12)} ${"----".padEnd(6)} ----`,
  );

  for (let i = 0; i < phases.length; i++) {
    const phase = phases[i];
    const phaseState = state.phases[phase as keyof typeof state.phases];
    const gateName = gates[i] || "";
    const gatePassed = gateName
      ? state.gates[gateName as keyof typeof state.gates]?.passed || false
      : false;

    // Use raw ANSI since padding with colors is tricky
    process.stdout.write(`${phase.padEnd(16)} `);
    process.stdout.write(`${statusIcon(phaseState.status)}`.padEnd(20) + " ");
    process.stdout.write(`${String(phaseState.iterations).padEnd(6)} `);
    process.stdout.write(gateIcon(gatePassed));
    console.log("");
  }

  console.log("");

  // Reroutes
  if (state.reroutes && state.reroutes.length > 0) {
    console.log(`${YELLOW}Reroutes: ${state.reroutes.length}${NC}`);
    for (const r of state.reroutes) {
      console.log(`  ${r.from} -> ${r.to}: ${r.reason}`);
    }
    console.log("");
  }

  // Artifacts
  console.log("--- Artifacts ---");
  console.log("");
  for (const artifact of ["plan.md", "review.md"]) {
    const path = join(factoryDir, "artifacts", artifact);
    if (await fileExists(path)) {
      const size = await fileSize(path);
      console.log(`  ${GREEN}${artifact}${NC} (${size} bytes)`);
    } else {
      console.log(`  ${DIM}${artifact} (not yet created)${NC}`);
    }
  }

  // Task count
  let taskCount = 0;
  try {
    const glob = new Bun.Glob("task-*-complete.md");
    for await (const _ of glob.scan({ cwd: join(factoryDir, "artifacts/tasks") })) taskCount++;
  } catch {}
  console.log(`  Tasks completed: ${taskCount}`);
  console.log("");

  // Final verdict
  if (state.final_verdict) {
    console.log(`Final Verdict: ${GREEN}${state.final_verdict}${NC}`);
    console.log(`Completed: ${state.completed_at}`);
  }

  // Done file
  if (await fileExists(join(factoryDir, "done"))) {
    console.log(`\n${GREEN}FACTORY COMPLETE${NC}`);
  }
}

const projectDir = process.argv[2] || ".";
showStatus(projectDir).catch((err) => {
  console.error(`Error: ${err}`);
  process.exit(1);
});
