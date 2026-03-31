# Definition of Done — Gate Criteria

This document defines what each quality gate checks before allowing the pipeline to proceed.

## Plan Gate

The planning phase is complete when `plan.md` contains:

- [ ] Project overview with clear feature description
- [ ] Data model (Drizzle schema with SQLite types, relationships, indexes)
- [ ] API routes (Next.js App Router route handlers with request/response types)
- [ ] Component tree (React components with props, page layouts)
- [ ] Visual design direction (specific colors, typography, spacing, animation plan)
- [ ] All tasks listed with unique IDs
- [ ] Dependency graph (which tasks depend on which)
- [ ] Each task has acceptance criteria (specific, testable)
- [ ] Each task has TDD spec (Red/Green/Refactor)
- [ ] Gap analysis pass confirms every spec requirement maps to a task

**Auto-fail if:**
- No data model section
- No API routes section
- No task definitions
- Tasks without acceptance criteria
- Tasks without TDD specs

## Implementation Gate

The implementation phase is complete when:

- [ ] All tests pass (`bun test` exits 0)
- [ ] No lint errors (`bun run lint` exits 0)
- [ ] No type errors (`bunx tsc --noEmit` exits 0)
- [ ] Every task has a completion report in `.factory/artifacts/tasks/`
- [ ] Every acceptance criterion is marked complete with evidence
- [ ] No `reroute.json` files pending

**Auto-fail if:**
- Any test fails
- Any type error exists
- An acceptance criterion is unmet
- Task completion count < planned task count

## Verification Gate (Final)

The verification phase is complete when:

- [ ] `review.md` has verdict PASS
- [ ] All tests passing
- [ ] No lint/type errors
- [ ] Functional correctness verified against plan.md
- [ ] Convention compliance: no blocking deviations
- [ ] Test coverage: all endpoints/components have tests
- [ ] Security: no HIGH/CRITICAL findings
- [ ] UI quality: custom colors, typography hierarchy, animations present
- [ ] `README.md` exists at project root
- [ ] `QA.md` exists at project root
- [ ] Changes committed to git

**Auto-fail if:**
- Review verdict is FAIL
- Any security finding is severity HIGH or CRITICAL
- Any test is failing
- README.md or QA.md missing (verifier creates these on PASS)
