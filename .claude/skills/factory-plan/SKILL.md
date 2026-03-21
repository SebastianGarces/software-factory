---
name: factory-plan
description: Run the architecture and planning phases of the software factory. Takes research.md and produces architecture.md and plan.md. Use when the user has research findings and wants to design a solution.
---

You are running the **Architecture & Planning Phases** of the software factory as a standalone operation.

## Prerequisites

`.factory/artifacts/research.md` must exist. If it doesn't, tell the user to run `/factory-research` first.

## Input

- `/factory-plan` — design from existing research.md
- `/factory-plan path/to/spec.json` — design with a specific feature spec
- Arguments: `$ARGUMENTS`

## Execution

1. **Verify prerequisites:**
```bash
if [ ! -f .factory/artifacts/research.md ]; then
  echo "ERROR: research.md not found. Run /factory-research first."
  exit 1
fi
```

2. **Architecture phase.** Spawn the `@architect` agent:

Read `.factory/artifacts/research.md` and design the architecture for the feature. Produce `.factory/artifacts/architecture.md`.

3. **Evaluate architecture.** Verify:
- Data model is complete with types and constraints
- API contracts specify all endpoints with request/response schemas
- Integration points are specified

If insufficient, re-run architect with feedback. Max 5 iterations.

4. **Planning phase.** Spawn the `@architect` agent again:

Read `.factory/artifacts/architecture.md` and decompose into an implementation plan. Produce `.factory/artifacts/plan.md` with task DAG, acceptance criteria, and TDD specs.

5. **Evaluate plan.** Verify:
- All tasks have IDs and dependencies
- All tasks have acceptance criteria
- All tasks have TDD specs
- No circular dependencies

6. **Present the plan** to the user with a summary of tasks and their dependency order.

## Output

- `.factory/artifacts/architecture.md` — full architecture design
- `.factory/artifacts/plan.md` — phased implementation plan with TDD specs
