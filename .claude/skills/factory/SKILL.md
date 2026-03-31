---
name: factory
description: Run the full software factory pipeline. Takes a feature specification and produces a deployable PR. Use when the user says "factory", provides a feature spec, or wants to generate a complete feature autonomously.
---

You are running the **Software Factory** — an autonomous pipeline that transforms a feature specification into a complete, tested, committed web app.

**Stack:** Bun, TypeScript, Next.js App Router, SQLite/Drizzle, shadcn/ui, Tailwind, Motion, Vitest

## Input

The user will provide one of:
- A JSON spec file: `/factory path/to/spec.json`
- A markdown/text brief: `/factory path/to/brief.md`
- A natural language description: `/factory Add a todo app with drag-and-drop...`
- Arguments: `$ARGUMENTS`

## Initialization

1. **Parse the input.** If a file, read it. If inline text, treat as description.
2. **Initialize `.factory/` directory:**
```bash
mkdir -p .factory/artifacts/tasks .factory/logs
```
3. **Write `.factory/spec.json`** (normalized JSON, always has `name` and `description`).
4. **Write `.factory/state.json`** with the 3-phase state structure (planning, implementation, verification).
5. **Create feature branch:**
```bash
git checkout -b factory/$(feature-name-kebab-case)
```

## Pipeline (3 Phases)

### Phase 1: Planning
Spawn the **planner** agent:
```
Read .factory/spec.json and produce a comprehensive plan.
Write .factory/artifacts/plan.md with: data model, API routes, component tree, visual design, tasks with TDD specs.
```

**Gate check:** `plan.md` exists, >1000 bytes, has Data Model, API Routes, Component Tree, Tasks with acceptance criteria and TDD specs. If it fails, re-run planner with feedback.

### Phase 2: Implementation
Spawn the **implementer** agent:
```
Execute ALL tasks in .factory/artifacts/plan.md using TDD (Red-Green-Refactor).
Write task completion reports to .factory/artifacts/tasks/task-{id}-complete.md.
```

**Gate check:** Task completion reports count >= planned task count. If it fails, re-run implementer with feedback about missing tasks.

### Phase 3: Verification
Spawn the **verifier** agent:
```
Review all implementation. Run tests, lint, type check. Review UI quality.
Test in browser via agent-browser. Write .factory/artifacts/review.md with verdict.
If PASS: also create README.md, QA.md, and commit all changes.
```

**Gate check:** `review.md` has PASS verdict, `README.md` and `QA.md` exist.
- If FAIL: route back to Phase 2 (implementation) with the Required Fixes from review.md.

### Completion
Once verification passes:
1. Touch `.factory/done`
2. Update `state.json` with `completed_at` and `final_verdict: "pass"`

## Error Handling

- **Phase exceeds max iterations (10):** Force-advance with best output. Log warning.
- **Reroute requested:** Read `.factory/reroute.json`, route back to planning with feedback.
- **Cycle detected (same failure 3x):** Force-advance.
- **Verification FAIL:** Auto-route back to implementation with fix instructions.

## Heartbeat
Touch `.factory/heartbeat` at the start of each phase.
