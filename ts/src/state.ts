// state.ts — State machine: init, update, transitions

import { mkdir } from "node:fs/promises";
import { join, extname, basename, dirname, resolve } from "node:path";
import {
  type FactoryState,
  type FactoryConfig,
  type Phase,
  type PhaseStatus,
  type GateName,
  PHASE_ORDER,
} from "./types.js";
import {
  readJson,
  writeJsonAtomic,
  touchFile,
  fileExists,
  isoNow,
  log,
  logWarn,
  logErr,
} from "./utils.js";

const DEFAULT_STATE: FactoryState = {
  factory_version: "1.0.0",
  spec_file: "",
  project_dir: "",
  current_phase: "planning",
  phases: {
    planning: { status: "pending", session_id: "", iterations: 0, started_at: "", completed_at: "" },
    implementation: { status: "pending", session_id: "", iterations: 0, started_at: "", completed_at: "", tasks_total: 0, tasks_completed: 0 },
    verification: { status: "pending", session_id: "", iterations: 0, started_at: "", completed_at: "" },
  },
  gates: {
    plan: { passed: false, feedback: "", evaluated_at: "" },
    implementation: { passed: false, feedback: "", evaluated_at: "" },
    verification: { passed: false, feedback: "", evaluated_at: "" },
  },
  reroutes: [],
  alerts: [],
  cycle_detection: {},
  max_iterations_per_phase: 5,
  started_at: "",
  updated_at: "",
  completed_at: "",
  final_verdict: "",
};

export function buildConfig(specInput: string, projectDir: string): FactoryConfig {
  const factoryDir = join(projectDir, ".factory");
  const factoryHome = process.env.FACTORY_HOME || resolve(join(dirname(new URL(import.meta.url).pathname), "../.."));

  return {
    specInput,
    projectDir,
    factoryDir,
    factoryHome,
    maxTurns: process.env.MAX_TURNS ? parseInt(process.env.MAX_TURNS) : undefined,
    maxIterations: parseInt(process.env.MAX_ITERATIONS || "10"),
    phaseTimeout: parseInt(process.env.PHASE_TIMEOUT || "3600"),
    factoryTimeout: parseInt(process.env.FACTORY_TIMEOUT || "14400"),
    apiRetryMax: parseInt(process.env.API_RETRY_MAX || "5"),
    apiRetryInitialWait: parseInt(process.env.API_RETRY_INITIAL_WAIT || "30"),
  };
}

async function createGitBranch(factoryDir: string, projectDir: string): Promise<void> {
  const spec = await readJson<{ name?: string }>(join(factoryDir, "spec.json"));
  const branchName = `factory/${(spec.name || "feature").toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
  const result = Bun.spawnSync(["git", "checkout", "-b", branchName], { cwd: projectDir });
  if (result.exitCode === 0) log(`Created branch: ${branchName}`);
  else logWarn(`Branch creation returned ${result.exitCode} (may already exist)`);
}

export async function initFactory(config: FactoryConfig): Promise<void> {
  const { specInput, projectDir, factoryDir } = config;

  log(`Initializing factory for input: ${specInput}`);

  await mkdir(join(factoryDir, "artifacts/tasks"), { recursive: true });
  await mkdir(join(factoryDir, "logs"), { recursive: true });

  // Remove stale done file from previous runs
  const doneFile = join(factoryDir, "done");
  if (await fileExists(doneFile)) {
    const { unlink } = await import("node:fs/promises");
    await unlink(doneFile);
  }

  const stateFile = join(factoryDir, "state.json");
  const specFile = join(factoryDir, "spec.json");
  const heartbeatFile = join(factoryDir, "heartbeat");

  // Initialize state file if not exists
  if (!(await fileExists(stateFile))) {
    // Try to copy template
    const templatePath = join(config.factoryHome, "templates/state.json");
    let state: FactoryState;
    if (await fileExists(templatePath)) {
      state = await readJson<FactoryState>(templatePath);
    } else {
      state = structuredClone(DEFAULT_STATE);
    }

    const specRef = await fileExists(specInput) ? specInput : "(inline)";
    const ts = isoNow();
    state.spec_file = specRef;
    state.project_dir = projectDir;
    state.started_at = ts;
    state.updated_at = ts;

    await writeJsonAtomic(stateFile, state);
  }

  // Normalize the input into .factory/spec.json
  if (await fileExists(specFile)) {
    log("Resuming: spec.json already exists, skipping normalization");
  } else if (await fileExists(specInput)) {
    const ext = extname(specInput).toLowerCase();
    if (ext === ".json") {
      const content = await Bun.file(specInput).text();
      await Bun.write(specFile, content);
      log("Input: JSON spec");
    } else if (ext === ".md" || ext === ".txt") {
      // Save original and create wrapper spec
      const origDest = join(factoryDir, `original-brief${ext}`);
      await Bun.write(origDest, await Bun.file(specInput).text());

      const desc = await Bun.file(specInput).text();
      const name = basename(specInput, ext).replace(/-/g, " ");
      await Bun.write(specFile, JSON.stringify({ name, description: desc }, null, 2));
      log("Input: markdown/text brief -> normalized to spec.json");
    } else {
      await Bun.write(join(factoryDir, "original-input.txt"), await Bun.file(specInput).text());
      const desc = await Bun.file(specInput).text();
      await Bun.write(specFile, JSON.stringify({ name: "feature", description: desc }, null, 2));
      log("Input: text file -> normalized to spec.json");
    }
  } else {
    // Input is an inline string
    await Bun.write(specFile, JSON.stringify({ name: "feature", description: specInput }, null, 2));
    await Bun.write(join(factoryDir, "original-input.txt"), specInput);
    log("Input: inline description -> normalized to spec.json");
  }

  await touchFile(heartbeatFile);

  // Create git branch for this factory run
  await createGitBranch(factoryDir, projectDir);
}

export async function getState(factoryDir: string): Promise<FactoryState> {
  return readJson<FactoryState>(join(factoryDir, "state.json"));
}

export async function updateState(
  factoryDir: string,
  phase: Phase,
  status: PhaseStatus,
  sessionId?: string,
): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);
  const ts = isoNow();

  const phaseState = state.phases[phase];
  phaseState.status = status;
  phaseState.session_id = sessionId || phaseState.session_id;
  state.updated_at = ts;

  if (status === "in_progress") {
    state.current_phase = phase;
    phaseState.started_at = ts;
    phaseState.iterations += 1;
  } else if (status === "completed") {
    phaseState.completed_at = ts;
  }

  await writeJsonAtomic(stateFile, state);
}

export async function updateGate(
  factoryDir: string,
  gate: GateName | string,
  passed: boolean,
  feedback: string = "",
): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);
  const ts = isoNow();

  const g = state.gates[gate as GateName];
  if (g) {
    g.passed = passed;
    g.feedback = feedback;
    g.evaluated_at = ts;
  }

  await writeJsonAtomic(stateFile, state);
}

export async function nextPendingPhase(config: FactoryConfig): Promise<Phase | null> {
  const { factoryDir } = config;
  const stateFile = join(factoryDir, "state.json");

  const state = await readJson<FactoryState>(stateFile);

  for (const phase of PHASE_ORDER) {
    if (state.phases[phase].status !== "completed") {
      return phase;
    }
  }

  return null; // All phases complete
}

export async function getIterations(factoryDir: string, phase: Phase): Promise<number> {
  try {
    const state = await readJson<FactoryState>(join(factoryDir, "state.json"));
    return state.phases[phase].iterations || 0;
  } catch {
    return 0;
  }
}

export async function writeAlert(
  factoryDir: string,
  alertType: string,
  message: string,
  phase: string = "unknown",
): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);
  const ts = isoNow();

  if (!state.alerts) state.alerts = [];
  state.alerts.push({ type: alertType, message, phase, timestamp: ts });

  await writeJsonAtomic(stateFile, state);
  logErr(`ALERT [${alertType}]: ${message}`);
}

export async function checkAuthExpiry(): Promise<void> {
  const credFile = join(process.env.HOME || "~", ".claude/.credentials.json");
  if (!(await fileExists(credFile))) {
    logWarn("No credentials file found. Skipping auth check.");
    return;
  }

  try {
    const creds = await readJson<{ expiresAt?: number }>(credFile);
    const expires = creds.expiresAt || 0;
    if (expires === 0) return;

    const now = Math.floor(Date.now() / 1000);
    const remaining = Math.floor(expires / 1000) - now;

    if (remaining < 7200) {
      logErr(`Auth token expires in ${remaining}s (< 2 hours). Re-authenticate first.`);
      logErr("Run: claude auth login");
      process.exit(1);
    }

    const hours = Math.floor(remaining / 3600);
    const mins = Math.floor((remaining % 3600) / 60);
    log(`Auth token valid for ${hours}h ${mins}m`);
  } catch {
    logWarn("Could not read credentials file. Skipping auth check.");
  }
}

export async function decrementIterations(factoryDir: string, phase: Phase): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);
  state.phases[phase].iterations = Math.max(state.phases[phase].iterations - 1, 0);
  await writeJsonAtomic(stateFile, state);
}

export async function updateCycleDetection(
  factoryDir: string,
  phase: Phase,
  feedback: string,
): Promise<number> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);

  if (!state.cycle_detection) state.cycle_detection = {};

  const prev = state.cycle_detection[phase];
  let count: number;

  if (prev && prev.feedback === feedback && feedback) {
    count = prev.count + 1;
  } else {
    count = 1;
  }

  state.cycle_detection[phase] = { count, feedback };
  await writeJsonAtomic(stateFile, state);

  return count;
}

export async function setVerificationReroute(factoryDir: string, feedback: string): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);

  state.gates.implementation.feedback = feedback;
  state.gates.implementation.passed = false;

  await writeJsonAtomic(stateFile, state);
}

export async function finalizeFactory(factoryDir: string, success: boolean): Promise<void> {
  const stateFile = join(factoryDir, "state.json");
  const state = await readJson<FactoryState>(stateFile);

  if (success) {
    state.final_verdict = "pass";
    state.completed_at = isoNow();
  }

  await writeJsonAtomic(stateFile, state);
}
