---
name: factory-verify
description: Run the verification phase of the software factory. Reviews implementation against architecture, conventions, and acceptance criteria. Produces review.md with PASS/FAIL verdict. Use when the user wants to verify generated code.
---

You are running the **Verification Phase** of the software factory as a standalone operation.

## Prerequisites

Implementation must be complete. Check for:
- `.factory/artifacts/research.md`
- `.factory/artifacts/architecture.md`
- `.factory/artifacts/plan.md`
- At least one `.factory/artifacts/tasks/task-*-complete.md` file

## Input

- `/factory-verify` — verify all implementation work
- Arguments: `$ARGUMENTS`

## Execution

1. **Spawn the reviewer agent:**
```
Review all code produced during the implementation phase.
Read research.md for conventions, architecture.md for design, plan.md for acceptance criteria.
Run the full test suite, linter, and type checker.
Write your review to .factory/artifacts/review.md
```

2. **Read the review.** Check the verdict.

3. **If PASS:**
   - Congratulate. The code is ready for PR assembly.
   - Suggest running `/factory` to create the PR, or the user can review manually.

4. **If FAIL:**
   - Present the Required Fixes section to the user.
   - Offer to re-run `/factory-implement` for specific tasks that need fixing.
   - Or re-run the full verification after the user makes manual fixes.

## Output

`.factory/artifacts/review.md` — full review with PASS/FAIL verdict and detailed findings.
