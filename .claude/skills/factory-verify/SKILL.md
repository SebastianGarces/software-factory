---
name: factory-verify
description: Run the verification phase of the software factory. Reviews implementation against plan, conventions, and acceptance criteria. Produces review.md with PASS/FAIL verdict. On PASS, creates README.md, QA.md, and commits. Use when the user wants to verify generated code.
---

You are running the **Verification Phase** of the software factory as a standalone operation.

## Prerequisites

Implementation must be complete. Check for:
- `.factory/artifacts/plan.md`
- At least one `.factory/artifacts/tasks/task-*-complete.md` file

## Input

- `/factory-verify` — verify all implementation work
- Arguments: `$ARGUMENTS`

## Execution

1. **Spawn the verifier agent:**
```
Review all code produced during the implementation phase.
Read plan.md for design decisions and acceptance criteria.
Run bun test, bun run lint, bunx tsc --noEmit.
Test in browser via agent-browser (advisory).
Write your review to .factory/artifacts/review.md.
If PASS: also create README.md, QA.md, and commit all changes.
```

2. **Read the review.** Check the verdict.

3. **If PASS:**
   - The verifier has already created README.md, QA.md, and committed.
   - Report success to the user. Code is ready for review/push.

4. **If FAIL:**
   - Present the Required Fixes section to the user.
   - Offer to re-run `/factory-implement` for specific tasks that need fixing.
   - Or re-run verification after the user makes manual fixes.

## Output

- `.factory/artifacts/review.md` — full review with PASS/FAIL verdict
- `README.md` — project documentation (on PASS)
- `QA.md` — manual testing checklist (on PASS)
- Git commit with all changes (on PASS)
