# Software Factory

An autonomous web app factory built on Claude Code's agent infrastructure. Takes a feature spec, produces a complete, tested, committed TypeScript web app.

**Stack:** Bun, TypeScript, Next.js App Router, SQLite/Drizzle, shadcn/ui, Tailwind, Motion, Vitest

## Project Structure

```
.claude/agents/     — 3 agent personas (planner, implementer, verifier)
.claude/skills/     — Skills (slash commands: /factory, /factory-implement, /factory-verify)
ts/                 — TypeScript runner (Bun + Claude Agent SDK)
frontend/           — Next.js monitoring dashboard (optional)
templates/          — State schema and gate criteria
```

## How It Works

1. User provides a feature spec (JSON, markdown, or natural language)
2. `/factory` skill initializes the pipeline
3. **3-phase pipeline:** planning → implementation → verification
4. Each phase runs as a `query()` call via the Claude Agent SDK
5. Quality gates (Stop hooks) evaluate output after each phase
6. Failed gates retry with feedback (max 10 iterations)
7. Verification FAIL auto-reroutes to implementation with fix instructions
8. On PASS: verifier creates README.md, QA.md, and commits

## The 3 Agents

- **Planner** — Produces `plan.md` with data model, API routes, component tree, visual design, and TDD task list. Stack is hardcoded so planning is fast.
- **Implementer** — Executes tasks from plan.md via Red-Green-Refactor TDD. Has embedded frontend skill for visual quality. Stack-specialized (knows shadcn, Drizzle, Motion, etc.)
- **Verifier** — Runs tests/lint/typecheck, reviews code quality and UI, tests in browser via agent-browser. On PASS creates README.md, QA.md, commits. On FAIL routes back to implementer.

## Key Conventions

- **Artifacts**: Each phase writes to `.factory/artifacts/` (plan.md, task reports, review.md)
- **State**: Pipeline state tracked in `.factory/state.json`
- **Heartbeat**: Phases touch `.factory/heartbeat` to signal liveness
- **Reroutes**: Implementation blockers write `.factory/reroute.json`
- **Gate criteria**: Defined in `templates/gate-criteria.md`

## Running the Factory

### Interactive (within Claude Code)
```
/factory path/to/spec.json
/factory "Build a todo app with drag-and-drop"
```

### Programmatic (via TS runner)
```bash
bun run ts/src/index.ts spec.json /path/to/project

# With watchdog
bun run ts/src/heartbeat.ts spec.json /path/to/project

# Monitoring
bun run ts/src/monitor/watch.ts /path/to/project
bun run ts/src/monitor/status.ts /path/to/project
bun run ts/src/monitor/tail.ts /path/to/project

# As macOS service
bun run ts/src/install.ts spec.json /path/to/project
```
