// prompts.ts — Phase prompt builder (replaces prompt_for_phase)

import { join } from "node:path";
import type { Phase, FactoryConfig } from "./types.js";
import { readTextFile, findFiles } from "./utils.js";
import { getIterations, getState } from "./state.js";

export async function promptForPhase(phase: Phase, config: FactoryConfig): Promise<string> {
  const { factoryDir } = config;

  const iterations = await getIterations(factoryDir, phase);
  const state = await getState(factoryDir);

  // Get gate feedback for this phase
  let feedback = "";
  try {
    const gateName = phase === "planning" ? "plan" : phase;
    const gate = state.gates[gateName as keyof typeof state.gates];
    if (gate) feedback = gate.feedback || "";
  } catch {}

  let retryContext = "";
  if (iterations > 0 && feedback) {
    retryContext = `IMPORTANT: This is retry #${iterations}. Previous attempt failed with feedback: ${feedback}. Address this feedback specifically.`;
  }

  switch (phase) {
    case "planning":
      return buildPlanningPrompt(retryContext);
    case "implementation":
      return await buildImplementationPrompt(factoryDir, retryContext);
    case "verification":
      return buildVerificationPrompt(retryContext);
    default:
      throw new Error(`Unknown phase: ${phase}`);
  }
}

const STACK_REFERENCE = `THE STACK IS PREDETERMINED:
- Runtime: Bun
- Language: TypeScript (full stack)
- Framework: Next.js (App Router) — ALWAYS install latest via next@latest (currently 16.x)
- Database: SQLite via Drizzle ORM + better-sqlite3
- UI: shadcn/ui
- Styling: Tailwind CSS v4
- Animations: Motion (motion/react)
- Fonts: Inter + JetBrains Mono (@fontsource-variable)
- Icons: lucide-react
- Testing: Vitest + Playwright
- Package manager: bun

CRITICAL NEXT.JS WARNING: Your training data is likely stale. After installing Next.js, read
node_modules/next/dist/docs/ for the actual current API. Key change: middleware.ts is DEPRECATED
and replaced by proxy.ts. Always check file conventions at
node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/ before writing any Next.js code.`;

function buildPlanningPrompt(retryContext: string): string {
  return `You are the planner agent. Produce a comprehensive plan for this feature.
Read .factory/spec.json to understand what we're building.

${STACK_REFERENCE}

If this is an existing codebase: Do a quick scan of conventions (file naming, imports, existing components) — 5 minutes max. The stack is fixed; you're only looking for project-specific patterns.
If this is greenfield: Skip research entirely. The stack is known.

Write .factory/artifacts/plan.md with these sections:
1. ## Project Overview — what we're building, from the spec
2. ## Codebase Context — (only if existing project) key conventions found
3. ## Data Model — Drizzle schema definitions (SQLite types, relationships, indexes)
4. ## API Routes — Next.js App Router route handlers (method, path, request/response TypeScript types, error cases)
5. ## Component Tree — React components with props interfaces, page layouts, route structure
6. ## Visual Design Direction — color palette, typography hierarchy (font sizes, weights), spacing rhythm, component styling, dark mode approach, animation plan (what gets Motion animations: page transitions, list stagger, card entrance, etc.). Be SPECIFIC — actual hex colors, actual px/rem values, actual font names.
7. ## Tasks — ordered list with:
   - Task ID (task-1, task-2, etc.)
   - Dependencies (which tasks must complete first)
   - Acceptance criteria (specific, testable)
   - TDD spec: Red (what failing test to write), Green (what to implement), Refactor (what to clean up)

FINAL CHECK: Re-read the spec line by line. Verify every requirement maps to at least one task. Flag any gaps.

STOP CONDITION: Once you have written .factory/artifacts/plan.md, you are DONE.
Do NOT write code. Do NOT proceed to implementation.
${retryContext}`;
}

async function buildImplementationPrompt(factoryDir: string, retryContext: string): Promise<string> {
  // Check which tasks are already done
  let resumeContext = "";
  const tasksDir = join(factoryDir, "artifacts/tasks");
  const doneFiles = await findFiles(tasksDir, /^task-.*-complete\.md$/);
  if (doneFiles.length > 0) {
    const doneIds = doneFiles.map((f) => {
      const m = f.match(/task-(.*)-complete\.md$/);
      return m ? m[1] : "";
    }).filter(Boolean);
    if (doneIds.length > 0) {
      resumeContext = `IMPORTANT: Tasks [${doneIds.join(", ")}] are already completed. Check .factory/artifacts/tasks/ for their completion reports. Skip these and continue with the NEXT uncompleted task. Do NOT redo work that is already done.`;
    }
  }

  return `You are the implementation orchestrator. You coordinate sub-agents to execute all tasks from plan.md.
You do NOT write code yourself — you dispatch tasks to sub-agents, merge their work, and ensure quality.

Read .factory/artifacts/plan.md — this is your sole source of truth.

${STACK_REFERENCE}

## Execution Protocol

1. Parse plan.md and find the "Execution Waves" section. This defines which tasks run in parallel.
2. For each wave (in order):
   a. Spawn a sub-agent for EACH task in the wave using the Agent tool with isolation: "worktree"
   b. Spawn ALL tasks in the same wave simultaneously (parallel Agent calls in one message)
   c. Give each sub-agent: the task details, TDD spec, visual design direction, and stack reference from plan.md
   d. Wait for all sub-agents in the wave to complete
   e. Merge each worktree branch back: git merge <branch> --no-edit
   f. If merge conflicts occur, resolve them (this is the ONLY case where you write code)
   g. Run: bun test && bunx tsc --noEmit
   h. If tests fail after merge, fix the integration issue
   i. Touch .factory/heartbeat
3. After all waves complete, run final check: bun test && bun run lint && bunx tsc --noEmit

Each sub-agent prompt must include:
- The full task section from plan.md (acceptance criteria, TDD spec, files list)
- The Visual Design Direction section from plan.md
- The stack reference and Next.js version warnings
- Instructions to write a completion report to .factory/artifacts/tasks/task-{id}-complete.md
- Instructions to follow TDD (Red-Green-Refactor) using bun test and Vitest

STOP CONDITION: Once every task has a completion report in .factory/artifacts/tasks/ and all tests pass, you are DONE.
Do NOT proceed to verification. Do NOT write review.md.
${resumeContext}
${retryContext}`;
}

function buildVerificationPrompt(retryContext: string): string {
  return `You are the verifier agent. Review all implementation work and produce a verdict.
Read .factory/artifacts/plan.md for requirements and acceptance criteria.

Step 1: Run automated checks
- bun test (all tests must pass)
- bun run lint (no lint errors)
- bunx tsc --noEmit (no type errors)

Step 2: Review code quality
- Functional correctness: does the code match plan.md's design?
- Convention compliance: consistent naming, file organization, import patterns
- Test coverage: every endpoint, component, and function has tests
- Security: check for OWASP top 10 (injection, XSS, auth bypass, data exposure)

Step 3: Review UI quality
- Custom colors applied (not default gray/white)?
- Typography hierarchy (distinct sizes + weights for title/subtitle/body/caption)?
- Proper padding, borders, shadows for depth?
- Hover/active states with transitions on interactive elements?
- Empty states (icon + message + CTA)?
- Visual hierarchy (important items stand out)?
- Motion library (motion/react) present and used for page transitions, list entrances, card animations?
FAIL if: >3 components with default uncustomized styles, no color palette, no animations

Step 4: Browser verification (advisory)
Try to verify the app works in a real browser:
- Install agent-browser if not available: npm i -g agent-browser
- Start dev server: bun run dev & (wait for ready)
- agent-browser open http://localhost:3000
- For each route in plan.md, navigate and verify it renders (agent-browser snapshot -i)
- Test key interactions (buttons, forms, navigation)
- Kill dev server when done
Include browser results in review.md. This is advisory — don't auto-fail on browser issues.

Step 5: Write verdict to .factory/artifacts/review.md
Include: test results, code review, UI quality, browser verification, PASS or FAIL verdict.
If FAIL: include "## Required Fixes" with specific file paths and what to change.

Step 6: If verdict is PASS, also:
1. Create README.md at project root (project name, description, prerequisites, setup with bun, how to run, how to test, API docs, architecture overview)
2. Create QA.md at project root (manual testing checklist, known limitations)
3. Stage all changes: git add (exclude .factory/ directory)
4. Create commit with descriptive message
5. Do NOT push or create PR

STOP CONDITION: Once review.md is written (and README.md + QA.md + commit if PASS), you are DONE.
Do NOT fix code. Do NOT modify source files. Just review, verdict, and deliverables.
${retryContext}`;
}
