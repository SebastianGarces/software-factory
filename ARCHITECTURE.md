# Software Factory — Architecture

## System Overview

The factory is a two-layer system: a **bash orchestration layer** manages state, retries, and process lifecycle, while an **agent layer** performs the actual work through Claude Code sessions.

```
                         ┌─────────────────────┐
                         │    User provides     │
                         │    feature spec      │
                         │  (JSON / md / text)  │
                         └──────────┬──────────┘
                                    │
              ┌─────────────────────▼─────────────────────┐
              │          factory-heartbeat.sh              │
              │  Watchdog: checks liveness every 30s,     │
              │  restarts stalled processes (max 5x),     │
              │  cleans up orphaned claude sessions        │
              └─────────────────────┬─────────────────────┘
                                    │ spawns & monitors
              ┌─────────────────────▼─────────────────────┐
              │           factory-runner.sh                │
              │  Orchestrator: normalizes input, runs      │
              │  each phase as isolated `claude -p` call,  │
              │  evaluates gates, handles retries/reroutes │
              └─────────────────────┬─────────────────────┘
                                    │ one session per phase
    ┌───────────────────────────────▼──────────────────────────────┐
    │                    PIPELINE (8 phases)                       │
    │                                                              │
    │  INTAKE ──▶ RESEARCH ──▶ DESIGN* ──▶ ARCHITECTURE           │
    │                                           │                  │
    │                                      ◀── GATE ──▶           │
    │                                     pass         fail        │
    │                                      │        retry with     │
    │                                      ▼        feedback       │
    │                                   PLANNING                   │
    │                                      │                       │
    │                                      ▼                       │
    │                               IMPLEMENTATION                 │
    │                                      │                       │
    │                        ┌──────── GATE ────────┐              │
    │                        │ pass            fail  │              │
    │                        ▼             retry or  │              │
    │                   VERIFICATION      reroute to │              │
    │                        │            architect  │              │
    │                   ┌── GATE ──┐                 │              │
    │                   │pass  fail│                 │              │
    │                   ▼      │   │                 │              │
    │              PR ASSEMBLY  └──▶ back to impl   │              │
    │                                                              │
    │                    * Design phase is optional                 │
    └──────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                              Pull Request
```

## Agent Architecture

Each phase is executed by a specialized agent persona running in its own `claude -p` session. Agents have no shared context — they communicate exclusively through artifacts on disk.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ ORCHESTRATOR │  │  RESEARCHER  │  │   DESIGNER   │
│   (opus)     │  │  (sonnet)    │  │   (opus)     │
│              │  │              │  │              │
│  all tools   │  │  read-only   │  │  Pencil MCP  │
│  intake +    │  │  explores    │  │  generates   │
│  PR assembly │  │  codebase    │  │  UI designs  │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
  branch setup       research.md      design.pen
  README.md                           design-system.md
  QA.md                               design-manifest.json
  git commits                         screenshots/

┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  ARCHITECT   │  │ IMPLEMENTER  │  │   REVIEWER   │
│   (opus)     │  │  (sonnet)    │  │   (sonnet)   │
│              │  │              │  │              │
│  read-only   │  │  full tools  │  │  read + bash │
│  designs     │  │  TDD cycle   │  │  runs tests  │
│  solutions   │  │  worktree    │  │  checks QA   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
 architecture.md     code + tests      review.md
 plan.md             task reports
```

### Tool Isolation

Agents are restricted to specific tools to enforce separation of concerns:

| Agent | Read | Edit/Write | Bash | Grep/Glob | Agent | Web | Pencil MCP |
|-------|------|------------|------|-----------|-------|-----|------------|
| Orchestrator | yes | yes | yes | yes | yes | yes | — |
| Researcher | yes | — | yes | yes | yes | yes | — |
| Designer | — | — | — | — | — | — | full |
| Architect | yes | — | yes | yes | yes | — | read-only* |
| Implementer | yes | yes | yes | yes | yes | yes | read-only* |
| Reviewer | yes | — | yes | yes | yes | — | — |

*Read-only Pencil access only when `design.pen` exists.

## Artifact Flow

Phases communicate through artifacts in `.factory/artifacts/`. Each phase reads upstream artifacts and writes exactly one primary output. No phase modifies another's artifacts.

```
                    ┌────────────────┐
                    │   spec.json    │ (normalized input)
                    └───────┬────────┘
                            │ read by all phases
                            ▼
┌───────────┐      ┌────────────────┐
│  INTAKE   │─────▶│  git branch    │
└───────────┘      └────────────────┘
                            │
                            ▼
┌───────────┐      ┌────────────────┐
│ RESEARCH  │─────▶│  research.md   │──────────────────┐
└───────────┘      └────────────────┘                  │
                            │                          │
                            ▼                          │
┌───────────┐      ┌────────────────┐                  │
│  DESIGN   │─────▶│  design.pen    │                  │
│ (optional)│      │  design-system │                  │
│           │      │  manifest.json │                  │
│           │      │  screenshots/  │                  │
└───────────┘      └───────┬────────┘                  │
                           │                           │
                           ▼                           ▼
┌───────────┐      ┌────────────────┐    reads research +
│ARCHITECTURE│────▶│architecture.md │    design artifacts
└───────────┘      └───────┬────────┘
                           │
                           ▼
┌───────────┐      ┌────────────────┐
│ PLANNING  │─────▶│   plan.md      │
└───────────┘      └────────────────┘
                           │
                           ▼
┌───────────┐      ┌────────────────┐    reads research +
│  IMPLEMENT│─────▶│  source code   │    architecture +
│           │      │  tests         │    plan + design
│           │      │  task reports  │
└───────────┘      └────────────────┘
                           │
                           ▼
┌───────────┐      ┌────────────────┐    reads all upstream
│  VERIFY   │─────▶│  review.md     │    artifacts + runs
└───────────┘      └────────────────┘    tests
                           │
                           ▼
┌───────────┐      ┌────────────────┐
│PR ASSEMBLY│─────▶│  README.md     │
│           │      │  QA.md         │
│           │      │  git commits   │
└───────────┘      └────────────────┘
```

## State Machine

All pipeline state lives in `.factory/state.json`. The runner updates it atomically (write to `.tmp`, then `mv`) so concurrent readers (dashboard, status checks) never see partial writes.

### Phase Lifecycle

```
pending ──▶ in_progress ──▶ completed
                │                ▲
                │                │ gate passes
                ▼                │
             failed ─────────────┘
               │     retry with feedback
               │     (iteration counter increments)
               │
               ▼ (after MAX_ITERATIONS)
           force-advanced to completed
           (logged to decisions.md)
```

### State Schema

```json
{
  "factory_version": "1.0.0",
  "current_phase": "implementation",
  "phases": {
    "<phase_name>": {
      "status": "pending | in_progress | completed | failed",
      "session_id": "factory-research-1710950400",
      "iterations": 2,
      "started_at": "2026-03-20T15:30:00Z",
      "completed_at": "2026-03-20T15:45:00Z"
    }
  },
  "gates": {
    "<gate_name>": {
      "passed": true,
      "feedback": "error message if failed",
      "evaluated_at": "2026-03-20T15:45:00Z"
    }
  },
  "reroutes": [],
  "cycle_detection": {},
  "max_iterations_per_phase": 5
}
```

## Quality Gates

Every phase (except intake and PR assembly) has a quality gate — a programmatic check that runs after the agent finishes. Gates are implemented in two places:

1. **Stop hook** (`gate-check.sh`): Runs inside the `claude -p` session. Returns `exit 2` to block the agent from stopping, forcing it to continue and fix its output. Has a self-limiting block counter to prevent infinite loops.

2. **Runner evaluation** (`evaluate_gate` in `factory-runner.sh`): Runs after the session ends. Updates state with pass/fail + feedback, decides whether to retry the phase or advance.

### Gate Criteria

| Gate | Checks |
|------|--------|
| **Research** | `research.md` exists, has Codebase Profile + Conventions + Integration Points sections, cites 3+ real file paths, has Required Screens section if design is configured |
| **Design** | `design.pen` + `design-manifest.json` + `design-system.md` exist, design system is >200 bytes, screen screenshots exported |
| **Architecture** | `architecture.md` exists, has Data Model + API Contract sections, >500 bytes |
| **Plan** | `plan.md` exists, has Task definitions + Acceptance Criteria + TDD Specs |
| **Implementation** | Task completion reports exist for all planned tasks |
| **Verification** | `review.md` exists with a clear PASS or FAIL verdict |

### Gate Failure Handling

```
Gate evaluates ──┬── PASS ──▶ advance to next phase
                 │
                 └── FAIL ──▶ retry same phase with feedback
                                │
                                ├── same error 3x ──▶ force-advance (cycle detection)
                                │
                                ├── iteration >= MAX ──▶ force-advance
                                │
                                └── verification fail ──▶ reroute to implementation
```

Force-advance decisions are logged to `.factory/artifacts/decisions.md` with timestamps and rationale.

## Feedback Loops

### Retry with Context

When a phase fails its gate, the runner restarts the same phase with feedback injected into the prompt:

```
"IMPORTANT: This is retry #3. Previous attempt failed with feedback:
research.md missing Required Screens section (needed for design integration).
Address this feedback specifically."
```

The agent gets a fresh context window but knows exactly what went wrong.

### Reroute Mechanism

The implementer can request architectural changes mid-execution by writing `.factory/reroute.json`:

```json
{
  "from": "implementation",
  "to": "architecture",
  "task_id": "task-3",
  "reason": "API contract doesn't account for pagination",
  "suggestion": "Add ?page=1&per_page=20 to GET /api/payment-methods"
}
```

The runner detects this file, resets the target phase to `pending`, and re-runs it with the reroute feedback. This allows the pipeline to self-correct without human intervention.

### Verification → Implementation Loop

When the reviewer issues a FAIL verdict, the runner automatically routes back to implementation (not verification) so the implementer can fix the issues. The review feedback is stored in the implementation gate's feedback field so the implementer knows exactly what to fix.

## Process Lifecycle

### Session Isolation

Each phase runs as a separate `claude -p` process with:
- Its own session name (`factory-{phase}-{timestamp}`)
- `--dangerously-skip-permissions` (unattended execution)
- `--allowedTools` restricting available tools per agent role
- `--output-format stream-json` for real-time monitoring
- Stream output redirected to `.factory/logs/{phase}.stream`

No two phases share a context window. This prevents context overflow and enforces phase boundaries.

### Staleness Detection

The runner monitors each `claude -p` process for output staleness:

```
Phase starts ──▶ monitor stream file size every 10s
                       │
                       ├── stream growing ──▶ agent is active, reset timer
                       │
                       └── stream stale ──▶ check duration
                                                │
                                                ├── < threshold ──▶ keep waiting
                                                │
                                                └── >= threshold ──▶ kill process
```

Thresholds vary by phase:
- **Default**: 180s (3 min)
- **Design**: 300s (5 min) — Pencil runs locally
- **Architecture/Planning**: 420s (7 min) — extended thinking time
- **Implementation**: 300s (5 min) — builds/installs can be slow

### API Error Recovery

Transient API errors (529 overloaded, 500, rate limits) are retried with exponential backoff:

```
Attempt 1 ──▶ fail ──▶ wait 30s ──▶ Attempt 2 ──▶ fail ──▶ wait 60s ──▶ ...
                                                                          │
                                                          (cap at 300s, max 5 attempts)
```

API errors don't count against the phase iteration limit — the agent shouldn't be penalized for infrastructure issues.

## Watchdog (factory-heartbeat.sh)

The heartbeat monitor runs as an outer wrapper for unattended/overnight execution:

```
┌─────────────────────────────────────────┐
│  factory-heartbeat.sh                   │
│                                         │
│  every 30s:                             │
│    1. check .factory/heartbeat mtime    │
│    2. if stale > 300s → kill runner     │
│    3. if done file exists → exit clean  │
│    4. if runner dead → restart          │
│       (exponential backoff, max 5x)     │
│    5. clean up orphaned claude procs    │
└─────────────────────────────────────────┘
```

The heartbeat file is touched by:
- The runner's monitoring loop (every 10s while a phase runs)
- The gate-check.sh Stop hook (on every gate evaluation)
- Agent prompts instruct agents to touch it during long operations

### Deployment Modes

| Mode | Command | Survives |
|------|---------|----------|
| Interactive | `/factory spec.json` | Terminal only |
| tmux | `./scripts/factory-heartbeat.sh spec.json` | Terminal close |
| launchd | `./scripts/factory-install.sh spec.json` | Reboot |

The launchd installer creates a `~/Library/LaunchAgents` plist with KeepAlive enabled, so the factory auto-restarts if the process crashes.

## Monitoring

### Live Dashboard (factory-watch.sh)

Terminal UI refreshing every 3s showing:
- Phase status (DONE / RUNNING / FAILED / pending)
- Heartbeat age + staleness warning
- Gate pass/fail results
- Artifact file sizes
- Current agent activity (parsed from stream)
- Log tail

### Stream Parser (factory-tail.sh)

Tails the active phase's `.stream` file and renders agent activity:
- Tool calls color-coded by type (Read=blue, Edit=yellow, Write=green, Bash=cyan)
- Thinking blocks (dim magenta)
- File paths and commands extracted from tool parameters
- Session completion with duration and cost

### Status Snapshot (factory-status.sh)

One-shot query showing all phase statuses, iteration counts, reroutes, artifact sizes, and task completion.

## Design Integration (Pencil MCP)

When the spec includes a `design` object, the pipeline adds a design phase between research and architecture.

### Data Flow

```
Research ──▶ Required Screens table
                    │
                    ▼
Design ──▶ design.pen (Pencil file, queryable via MCP)
           design-system.md (color tokens, typography, spacing)
           design-manifest.json (screen names, node IDs, descriptions)
           screenshots/*.png (visual reference)
                    │
                    ▼
Architecture ──▶ Visual Design section transcribed from design-system.md
                 Queries design.pen for precise CSS values
                    │
                    ▼
Implementation ──▶ Views screenshots for visual reference
                   Queries design.pen for exact colors, fonts, spacing
                   Uses design tokens as CSS variables
                    │
                    ▼
Verification ──▶ Checks design fidelity against screenshots
```

### Two Paths

**Path A** (generate from scratch): No `penFile` in spec. Designer uses Pencil guidelines + style guide to create all screens listed in Required Screens.

**Path B** (ingest existing): `penFile` points to an existing `.pen` file. Designer opens it, validates coverage against Required Screens, and generates any missing screens.

### Pencil Tool Access

| Phase | Access Level | Tools |
|-------|-------------|-------|
| Design | Full | batch_design, batch_get, set_variables, export_nodes, get_guidelines, get_style_guide, open_document, get_screenshot, etc. |
| Architecture | Read-only | batch_get, get_variables, search_all_unique_properties, get_screenshot, snapshot_layout |
| Implementation | Read-only | Same as architecture |

## Resumability

The factory is designed to resume from any point after a crash:

1. Runner checks `state.json` for `current_phase`
2. `next_pending_phase()` skips all `completed` phases
3. `spec.json` is preserved (not re-normalized on resume)
4. Implementation checks `.factory/artifacts/tasks/` for existing completion reports and skips finished tasks
5. Heartbeat watchdog detects the runner died and restarts it

## CI Simulation (ci-simulate.sh)

Multi-language CI checker that auto-detects the project stack:

| Language | Lint | Types | Test | Build |
|----------|------|-------|------|-------|
| Node.js | `npm run lint` | `tsc --noEmit` | `npm test` | `npm run build` |
| Python | `ruff check` | `mypy .` | `pytest` | — |
| Go | `go vet ./...` | — | `go test ./...` | `golangci-lint run` |

Returns PASS/FAIL per check, exit code 0 (all pass) or 1 (any fail).

## Key Design Decisions

**Why separate `claude -p` sessions per phase?**
Context windows are finite. A full factory run can generate hundreds of thousands of tokens across research, architecture, and implementation. Separate sessions ensure each agent gets a clean context focused on its task.

**Why bash for orchestration?**
Zero dependencies. The factory runs anywhere Claude Code runs. Bash handles file I/O, process management, and JSON manipulation (via `jq`) without requiring Node.js, Python, or any runtime.

**Why Stop hooks for gates?**
Claude Code's Stop hook mechanism lets us intercept the agent before it exits. If the output doesn't meet criteria, we block the stop and the agent continues — this is cheaper and faster than killing the process and starting a new session.

**Why atomic state writes?**
The dashboard (`factory-watch.sh`) reads `state.json` concurrently while the runner writes it. Writing to a `.tmp` file and atomically moving it prevents the dashboard from reading a half-written JSON file.

**Why heartbeat files instead of process monitoring?**
A running process doesn't mean a working agent. The agent could be stuck in an infinite loop, waiting on a hung API call, or in a retry cycle. Heartbeat file mtime proves the agent is making forward progress, not just alive.

**Why force-advance after N iterations?**
Perfection is the enemy of done. If a phase can't pass its gate after 5 attempts, the output is likely "good enough" — the downstream phases can often compensate. Forcing an advance prevents the pipeline from getting stuck indefinitely. All force decisions are logged for human review.
