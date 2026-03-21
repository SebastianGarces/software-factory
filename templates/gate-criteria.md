# Definition of Done — Gate Criteria

This document defines what each quality gate checks before allowing the pipeline to proceed.

## Research Gate

The research phase is complete when `research.md` contains:

- [ ] Codebase profile (language, framework, DB, test framework)
- [ ] Directory structure mapping
- [ ] Naming conventions documented with examples
- [ ] File organization patterns documented
- [ ] At least 1 similar existing feature analyzed with file paths
- [ ] All integration points identified
- [ ] Constraints listed with rationale
- [ ] Unknowns explicitly documented

**Auto-fail if:**
- No existing file paths cited (research wasn't thorough)
- Conventions section is generic (not specific to THIS codebase)
- Design integration is configured but no Required Screens section in research.md

## Design Gate

The design phase is complete when:

- [ ] `.factory/artifacts/design.pen` exists (Pencil design file)
- [ ] `.factory/artifacts/design-manifest.json` exists with screen entries
- [ ] `.factory/artifacts/design-system.md` exists with color palette, typography, spacing
- [ ] Every required screen from research.md has a corresponding design screen
- [ ] Every screen has a screenshot at `.factory/artifacts/screens/{name}/screenshot.png`
- [ ] Design system includes primary, background, surface colors at minimum

**Auto-fail if:**
- A required screen has no corresponding design screen
- Design system document is missing or has no color tokens
- No screen screenshots were exported
- `design.pen` file does not exist

## Architecture Gate

The architecture phase is complete when `architecture.md` contains:

- [ ] Data model with all fields, types, and constraints
- [ ] Relationships defined (foreign keys, references)
- [ ] API contracts for all endpoints (method, path, request/response schemas)
- [ ] Error response format specified
- [ ] Auth/permission requirements per endpoint
- [ ] Frontend component hierarchy (if applicable)
- [ ] Visual design direction (if frontend): color palette, typography, spacing, component styling
- [ ] Integration point changes specified
- [ ] Security considerations documented
- [ ] Makefile designed with standard targets (setup, dev, build, test, lint, clean)
- [ ] Infrastructure services specified if DB/cache/queue needed
- [ ] docker-compose.dev.yml design includes health checks (if infrastructure services present)

**Auto-fail if:**
- Data model uses conventions that contradict research.md findings
- API contracts don't specify error cases
- No security section
- Frontend exists but no Visual Design section with concrete color/typography/spacing specs

## Plan Gate

The plan phase is complete when `plan.md` contains:

- [ ] All tasks listed with unique IDs
- [ ] Dependency graph (which tasks depend on which)
- [ ] Each task has acceptance criteria (specific, testable)
- [ ] Each task has TDD spec (Red/Green/Refactor)
- [ ] Tasks cover all architecture components (DB, API, frontend, tests, config)
- [ ] No circular dependencies in the task graph

**Auto-fail if:**
- A task has no acceptance criteria
- A task has no TDD spec
- Dependencies would create a deadlock

## Implementation Gate

The implementation phase is complete when:

- [ ] All tests pass (`npm test` or equivalent exits 0)
- [ ] No lint errors (`npm run lint` exits 0)
- [ ] No type errors (type checker exits 0)
- [ ] Every task has a completion report in `.factory/artifacts/tasks/`
- [ ] Every acceptance criterion is marked complete with evidence
- [ ] No `reroute.json` files pending
- [ ] Makefile exists with working `make dev` and `make test`
- [ ] docker-compose.dev.yml validates (if infrastructure needed)
- [ ] .env.example exists with all required variables (if infrastructure needed)

**Auto-fail if:**
- Any test fails
- Any type error exists
- An acceptance criterion is unmet

## Verification Gate (Final)

The verification phase is complete when `review.md` has verdict PASS:

- [ ] Test results: all passing, no failures
- [ ] Lint results: no errors
- [ ] Type check: no errors
- [ ] Functional correctness: no issues
- [ ] Convention compliance: no blocking deviations
- [ ] Test coverage: all endpoints/components have tests
- [ ] Security: no high/critical findings
- [ ] Definition of Done: all criteria PASS

**Auto-fail if:**
- Review verdict is FAIL
- Any security finding is severity HIGH or CRITICAL
- Any test is failing
