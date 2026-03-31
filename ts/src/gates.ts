// gates.ts — Gate evaluation (replaces evaluate_gate + gate-check.sh)

import { join } from "node:path";
import type { Phase, GateResult } from "./types.js";
import { fileExists, fileSize, readTextFile, countFiles } from "./utils.js";

export async function evaluateGate(
  phase: Phase,
  factoryDir: string,
  projectDir: string,
): Promise<GateResult> {
  switch (phase) {
    case "planning":
      return evaluatePlanningGate(factoryDir);
    case "implementation":
      return evaluateImplementationGate(factoryDir);
    case "verification":
      return evaluateVerificationGate(factoryDir, projectDir);
    default:
      return { passed: true, feedback: "" };
  }
}

async function evaluatePlanningGate(factoryDir: string): Promise<GateResult> {
  const artifactPath = join(factoryDir, "artifacts/plan.md");
  if (!(await fileExists(artifactPath))) {
    return { passed: false, feedback: "plan.md artifact not found" };
  }

  const size = await fileSize(artifactPath);
  if (size <= 1000) {
    return {
      passed: false,
      feedback: `plan.md is too short (${size} bytes). Need comprehensive plan with data model, routes, components, and tasks.`,
    };
  }

  return { passed: true, feedback: "" };
}

async function evaluateImplementationGate(factoryDir: string): Promise<GateResult> {
  const tasksDir = join(factoryDir, "artifacts/tasks");
  const taskCount = await countFiles(tasksDir, /^task-.*-complete\.md$/);

  if (taskCount === 0) {
    return {
      passed: false,
      feedback:
        "No task completion reports found in .factory/artifacts/tasks/. Ensure each completed task writes task-{id}-complete.md.",
    };
  }

  // Check how many tasks the plan defined vs how many are done
  const planPath = join(factoryDir, "artifacts/plan.md");
  if (await fileExists(planPath)) {
    const planContent = await readTextFile(planPath);
    const plannedTasks = (planContent.match(/^###? Task [0-9]/gm) || []).length;
    if (plannedTasks > 0 && taskCount < plannedTasks) {
      return {
        passed: false,
        feedback: `Only ${taskCount} of ${plannedTasks} tasks completed. Missing tasks need implementation.`,
      };
    }
  }

  return { passed: true, feedback: "" };
}

async function evaluateVerificationGate(factoryDir: string, projectDir: string): Promise<GateResult> {
  const artifactPath = join(factoryDir, "artifacts/review.md");
  if (!(await fileExists(artifactPath))) {
    return { passed: false, feedback: "review.md artifact not found" };
  }

  const content = await readTextFile(artifactPath);
  const hasPass = /Verdict.*PASS/i.test(content);
  const hasFail = /Verdict.*FAIL/i.test(content);

  if (!hasPass || hasFail) {
    // Extract fix details
    const lines = content.split("\n");
    let fixes = "";
    for (let i = 0; i < lines.length; i++) {
      if (/Required Fixes|Required for PASS|Summary/i.test(lines[i])) {
        fixes = lines.slice(i, i + 10).join("\n");
        break;
      }
    }

    return {
      passed: false,
      feedback: `Review verdict: FAIL. ${fixes || "See review.md"}`,
    };
  }

  // Verdict is PASS — also check that README.md and QA.md exist in projectDir
  const readmePath = join(projectDir, "README.md");
  const qaPath = join(projectDir, "QA.md");

  const hasReadme = await fileExists(readmePath);
  const hasQa = await fileExists(qaPath);

  if (!hasReadme || !hasQa) {
    const missing: string[] = [];
    if (!hasReadme) missing.push("README.md");
    if (!hasQa) missing.push("QA.md");

    return {
      passed: false,
      feedback: `Review passed but missing deliverables: ${missing.join(", ")}. Verifier must create these on PASS.`,
    };
  }

  return { passed: true, feedback: "" };
}

// --- Stop hook gate checks (used by hooks.ts) ---
// These are the in-process equivalents of gate-check.sh

export async function checkGateForStopHook(
  phase: Phase,
  factoryDir: string,
): Promise<{ shouldBlock: boolean; feedback: string }> {
  switch (phase) {
    case "planning":
      return checkPlanStopGate(factoryDir);
    case "implementation":
      return checkImplementationStopGate(factoryDir);
    case "verification":
      return checkVerificationStopGate(factoryDir);
    default:
      return { shouldBlock: false, feedback: "" };
  }
}

async function checkPlanStopGate(
  factoryDir: string,
): Promise<{ shouldBlock: boolean; feedback: string }> {
  const artifact = join(factoryDir, "artifacts/plan.md");
  if (!(await fileExists(artifact))) {
    return {
      shouldBlock: true,
      feedback: `Plan artifact not found. The planner must write the plan to ${artifact}.`,
    };
  }

  const content = await readTextFile(artifact);
  const missing: string[] = [];

  if (!content.includes("## Data Model")) missing.push("Data Model");
  if (!content.includes("## API") && !content.includes("## Routes")) missing.push("API/Routes");
  if (!content.includes("## Component") && !content.includes("## Frontend")) missing.push("Component/Frontend");
  if (!content.match(/[Tt]ask/)) missing.push("Task definitions");
  if (!content.includes("Acceptance Criteria")) missing.push("Acceptance Criteria");
  if (!content.includes("TDD") && !content.includes("Red")) missing.push("TDD specs");

  if (missing.length > 0) {
    return {
      shouldBlock: true,
      feedback: `Plan gate FAILED. Missing: ${missing.join(", ")}.`,
    };
  }

  return { shouldBlock: false, feedback: "" };
}

async function checkImplementationStopGate(
  factoryDir: string,
): Promise<{ shouldBlock: boolean; feedback: string }> {
  const tasksDir = join(factoryDir, "artifacts/tasks");
  const taskCount = await countFiles(tasksDir, /^task-.*-complete\.md$/);

  if (taskCount === 0) {
    return {
      shouldBlock: true,
      feedback:
        "Implementation gate FAILED. No task completion reports found in .factory/artifacts/tasks/.",
    };
  }

  const planPath = join(factoryDir, "artifacts/plan.md");
  if (await fileExists(planPath)) {
    const planContent = await readTextFile(planPath);
    const plannedTasks = (planContent.match(/^###? Task [0-9]/gm) || []).length;
    if (plannedTasks > 0 && taskCount < plannedTasks) {
      return {
        shouldBlock: true,
        feedback: `Implementation gate FAILED. Only ${taskCount} of ${plannedTasks} tasks completed. Continue implementing remaining tasks.`,
      };
    }
  }

  return { shouldBlock: false, feedback: "" };
}

async function checkVerificationStopGate(
  factoryDir: string,
): Promise<{ shouldBlock: boolean; feedback: string }> {
  const artifact = join(factoryDir, "artifacts/review.md");
  if (!(await fileExists(artifact))) {
    return {
      shouldBlock: true,
      feedback: `Review artifact not found. The reviewer must write findings to ${artifact}.`,
    };
  }

  const content = await readTextFile(artifact);
  // Let the reviewer stop once it has written a verdict (PASS or FAIL)
  if (/Verdict.*PASS/i.test(content) || /Verdict.*FAIL/i.test(content)) {
    return { shouldBlock: false, feedback: "" };
  }

  return {
    shouldBlock: true,
    feedback: "Verification gate: review.md exists but has no clear PASS or FAIL verdict. Write a verdict.",
  };
}
