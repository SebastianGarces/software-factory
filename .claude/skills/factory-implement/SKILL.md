---
name: factory-implement
description: Run the implementation phase of the software factory. Takes plan.md and executes tasks using TDD. Use when the user has an approved plan and wants to generate code.
---

You are running the **Implementation Phase** of the software factory as a standalone operation.

## Prerequisites

This file must exist:
- `.factory/artifacts/plan.md`

If missing, tell the user to run `/factory` or the planning phase first.

## Input

- `/factory-implement` — implement all tasks from plan.md
- `/factory-implement task-3` — implement a specific task
- Arguments: `$ARGUMENTS`

## Execution

1. **Read the plan.** Parse `.factory/artifacts/plan.md` to extract the task DAG.

2. **Determine execution order.** Topologically sort tasks by dependencies.

3. **For each task (or the specified task):**

   a. Check if the task's dependencies are completed (look for `.factory/artifacts/tasks/task-{dep-id}-complete.md`)

   b. Spawn the `@implementer` agent:
   ```
   Execute Task {id}: {name} from .factory/artifacts/plan.md.
   Follow TDD: write failing tests first, implement to pass, then refactor.
   Write completion report to .factory/artifacts/tasks/task-{id}-complete.md
   ```

   c. After the implementer finishes, run tests:
   ```bash
   bun test
   ```

   d. If tests fail, re-run the implementer with the test output as feedback. Max 3 retries per task.

   e. If a `reroute.json` is written, stop and inform the user that the plan needs changes.

4. **After all tasks complete**, run the full suite:
```bash
bun test && bun run lint && bunx tsc --noEmit
```

5. **Report results** to the user.

## Output

- Code and test files (in the working tree)
- `.factory/artifacts/tasks/task-{id}-complete.md` for each task
