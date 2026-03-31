# Software Factory — Architecture

## System Overview

The factory is a three-layer system:

1. **TypeScript orchestration layer** (`ts/src/`) manages state, retries, process lifecycle, and phase sequencing
2. **Agent layer** performs the actual work through Claude Code sessions invoked via the Agent SDK's `query()` function
3. **Monitoring layer** provides CLI tools and an optional Next.js web dashboard for observability

```
                         ┌─────────────────────┐
                         │    User provides     │
                         │    feature spec      │
                         │  (JSON / md / text)  │
                         └──────────┬──────────┘
                                    │
              ┌─────────────────────▼─────────────────────┐
              │            heartbeat.ts                    │
              │  Watchdog: checks liveness every 30s,     │
              │  restarts stalled processes (max 5x),     │
              │  cleans up orphaned claude sessions        │
              └─────────────────────┬─────────────────────┘
                                    │ spawns & monitors
              ┌─────────────────────▼─────────────────────┐
              │              factory.ts                    │
              │  Orchestrator: normalizes input, runs      │
              │  each phase as isolated query() call,      │
              │  evaluates gates, handles retries/reroutes │
              └─────────────────────┬─────────────────────┘
                                    │ one query() per phase
    ┌───────────────────────────────▼──────────────────────────────┐
    │                    PIPELINE (3 phases)                       │
    │                                                              │
    │  PLANNING ──▶ IMPLEMENTATION ──▶ VERIFICATION               │
    │      │              │                  │                     │
    │   plan.md    code + tests         review.md                 │
    │                                   README.md                 │
    │              ┌──── GATE ────┐      QA.md                    │
    │              │pass      fail│     commit                    │
    │              ▼         ▼    │                                │
    │          VERIFY    reroute  │                                │
    │              │     to impl  │                                │
    │         ┌── GATE ──┐       │                                │
    │         │pass  fail│       │                                │
    │         ▼      └───▶ back  │                                │
    │        DONE    to impl     │                                │
    └──────────────────────────────────────────────────────────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  .factory/ on disk   │◀── read by monitoring
                         └─────────────────────┘
```

## Agent Architecture

Each phase is executed by a specialized agent persona running in its own `query()` session. Agents have no shared context — they communicate exclusively through artifacts on disk.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   PLANNER    │  │ IMPLEMENTER  │  │   VERIFIER   │
│   (opus)     │  │   (opus)     │  │   (opus)     │
│              │  │              │  │              │
│  read-only   │  │  full tools  │  │  read-only   │
│  researches  │  │  sub-agents  │  │  runs tests  │
│  + plans     │  │  + worktrees │  │  + reviews   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
   plan.md          code + tests      review.md
                    task reports       README.md
                                      QA.md
                                      git commit
```

### Tool Isolation

Agents are restricted to specific tools to enforce separation of concerns:

| Agent | Read | Edit/Write | Bash | Grep/Glob | Agent | Web |
|-------|------|------------|------|-----------|-------|-----|
| Planner | yes | — | yes | yes | yes | yes |
| Implementer | yes | yes | yes | yes | yes | yes |
| Verifier | yes | — | yes | yes | yes | yes |

The planner and verifier are read-only for source code — they plan and evaluate but never modify. The implementer has full tool access and spawns sub-agents with `isolation: "worktree"` for parallel task execution.

### Agent Consolidation

The current 3-agent system is a consolidation of an earlier 6-agent design:

- **Planner** = researcher + architect + planner. One agent can survey the codebase and produce a complete plan in a single context window, avoiding lossy artifact handoffs.
- **Verifier** = reviewer + PR assembler. Review and commit are naturally sequential in the same session.
- **Orchestrator** was replaced by TypeScript code (`factory.ts`) — deterministic logic doesn't need an LLM.

## Artifact Flow

Phases communicate through artifacts in `.factory/artifacts/`. Each phase reads upstream artifacts and writes exactly one primary output.

```
                    ┌────────────────┐
                    │   spec.json    │ (normalized input)
                    └───────┬────────┘
                            │ read by all phases
                            ▼
┌───────────┐      ┌────────────────┐
│ PLANNING  │─────▶│   plan.md      │
└───────────┘      └───────┬────────┘
                           │
                           ▼
┌───────────┐      ┌────────────────┐
│  IMPLEMENT│─────▶│  source code   │    reads plan.md
│           │      │  tests         │
│           │      │  task reports  │
└───────────┘      └───────┬────────┘
                           │
                           ▼
┌───────────┐      ┌────────────────┐    reads all upstream
│  VERIFY   │─────▶│  review.md     │    artifacts + runs
│           │      │  README.md     │    tests
│           │      │  QA.md         │
│           │      │  git commit    │
└───────────┘      └────────────────┘
```

## The `query()` Interface

Each phase runs as a separate `query()` call via the Claude Agent SDK. This replaced the earlier approach of spawning `claude -p` CLI processes.

```typescript
import { query } from "@anthropic-ai/claude-agent-sdk";

const queryResult = query({ prompt, options });

// query() returns an AsyncGenerator that yields messages
for await (const message of queryResult) {
  // Each message: { type, message, session_id, ... }
  // Types: "assistant" | "result" | "user" | "tool_result"
  await appendFile(streamFile, JSON.stringify(message) + "\n");
}
```

### Options

```typescript
const options: Options = {
  abortController,                     // Timeout and staleness abort
  allowedTools,                        // Phase-specific tool whitelist
  permissionMode: "bypassPermissions", // Unattended execution
  model,                               // "opus" or "sonnet"
  cwd: projectDir,                     // Working directory
  hooks: {
    Stop: [{ hooks: [stopHook] }],          // Gate check on Stop tool
    PostToolUse: [{ hooks: [heartbeatHook] }], // Heartbeat update
  },
  maxTurns,                            // Optional turn limit
};
```

No two phases share a context window. This prevents context overflow and enforces phase boundaries.

## State Machine

All pipeline state lives in `.factory/state.json`. The orchestrator updates it atomically (write to `.tmp`, then rename) so concurrent readers never see partial writes.

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
           (logged as alert in state.json)
```

### State Schema (v2.0.0)

```json
{
  "factory_version": "1.0.0",
  "current_phase": "implementation",
  "phases": {
    "planning":       { "status": "completed", "iterations": 1, ... },
    "implementation": { "status": "in_progress", "iterations": 2, ... },
    "verification":   { "status": "pending", "iterations": 0, ... }
  },
  "gates": {
    "plan":           { "passed": true, "feedback": "", ... },
    "implementation": { "passed": false, "feedback": "...", ... },
    "verification":   { "passed": false, "feedback": "", ... }
  },
  "reroutes": [],
  "alerts": [],
  "cycle_detection": {},
  "max_iterations_per_phase": 10
}
```

## Quality Gates

Every phase has a quality gate — a programmatic check that runs after the agent finishes. Gates operate at two levels:

### 1. SDK Stop Hooks (in-process)

Implemented in `ts/src/hooks.ts`. When the agent calls the Stop tool, the hook intercepts and checks gate criteria via `checkGateForStopHook()`. If the gate fails, the hook returns `{ decision: "block", reason: "..." }` — the agent continues in the same session with full context.

A self-limiting block counter (`.gate-blocks-{phase}`) prevents infinite loops. After `MAX_GATE_BLOCKS` (default 10) consecutive blocks, the hook allows the stop.

### 2. Post-Session Evaluation

Implemented in `ts/src/gates.ts`. After the `query()` session ends, `evaluateGate()` runs the same checks and updates `state.json` with pass/fail + feedback. This determines whether to advance to the next phase or retry.

### Gate Criteria

| Gate | Checks |
|------|--------|
| **Plan** | `plan.md` exists, >1000 bytes, contains Data Model + API/Routes + Components + Tasks + Acceptance Criteria + TDD specs |
| **Implementation** | Task completion reports (`task-*-complete.md`) exist for all planned tasks |
| **Verification** | `review.md` exists with "Verdict: PASS", `README.md` and `QA.md` exist in project root |

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

## Feedback Loops

### Retry with Context

When a phase fails its gate, the orchestrator restarts the same phase with feedback injected into the prompt:

```
"IMPORTANT: This is retry #3. Previous attempt failed with feedback:
plan.md missing TDD specs section.
Address this feedback specifically."
```

The agent gets a fresh context window but knows exactly what went wrong.

### Verification → Implementation Loop

When the verifier issues a FAIL verdict, the orchestrator automatically routes back to implementation (not planning) so the implementer can fix the issues. The review feedback is stored in the implementation gate's feedback field.

### Cycle Detection

If the same phase fails with the same error 3 consecutive times, the orchestrator force-advances to prevent infinite loops. This is tracked in `state.json` under `cycle_detection`.

## Process Lifecycle

### Staleness Detection

The heartbeat file (`.factory/heartbeat`) is touched on every tool use via a PostToolUse SDK hook. The orchestrator tracks `lastActivityTime` in-process:

```
Phase running ──▶ check lastActivityTime every 10s
                       │
                       ├── recent activity ──▶ continue
                       │
                       └── stale >= 300s ──▶ abort (AbortController)
```

### API Error Recovery

Transient API errors (529 overloaded, 500, rate limits) are retried with exponential backoff:

```
Attempt 1 ──▶ fail ──▶ wait 30s ──▶ Attempt 2 ──▶ fail ──▶ wait 60s ──▶ ...
                                                                          │
                                                          (cap at 300s, max 5 attempts)
```

API errors don't count against the phase iteration limit.

### Wall-Clock Timeouts

- **Per-phase**: 3600s (1 hour) — enforced via `setTimeout` + `AbortController`
- **Factory-wide**: 14400s (4 hours) — checked at the start of each phase loop

## Watchdog (`heartbeat.ts`)

The heartbeat monitor runs as an outer wrapper for unattended/overnight execution:

```
┌─────────────────────────────────────────┐
│  heartbeat.ts                           │
│                                         │
│  every 30s:                             │
│    1. check .factory/heartbeat mtime    │
│    2. if stale > 300s → kill runner     │
│    3. if done file exists → exit clean  │
│    4. if runner dead → restart          │
│       (max 5 restarts)                  │
│    5. clean up orphaned claude procs    │
└─────────────────────────────────────────┘
```

Uses `Bun.spawn()` with `detached: true`. Sends SIGTERM first, waits 3s, then SIGKILL if needed.

### Deployment Modes

| Mode | Command | Survives |
|------|---------|----------|
| Interactive | `/factory spec.json` | Terminal only |
| tmux | `bun run ts/src/heartbeat.ts spec.json ./project` | Terminal close |
| launchd | `bun run ts/src/install.ts spec.json ./project` | Reboot |

The launchd installer creates a `~/Library/LaunchAgents` plist with KeepAlive enabled.

## Monitoring

### CLI Tools

| Tool | Command | Description |
|------|---------|-------------|
| **Live Dashboard** | `bun run ts/src/monitor/watch.ts` | Terminal UI refreshing every 3s: phase status, heartbeat, gates, artifacts, current activity, log tail |
| **Stream Parser** | `bun run ts/src/monitor/tail.ts` | Tails `.stream` NDJSON, color-codes tool calls (Read=blue, Edit=yellow, Bash=magenta, Agent=red) |
| **Status Snapshot** | `bun run ts/src/monitor/status.ts` | One-shot: phases, iterations, reroutes, artifacts, task count, verdict |

### Frontend Dashboard

The Next.js app (`frontend/`) provides a web-based monitoring interface:

**Stack**: Next.js 16 (App Router), SQLite + Drizzle ORM, shadcn/ui, Tailwind CSS

**Database Schema**:
- `projects` — registered project directories with factory home paths
- `runs` — run history per project (spec, PID, timestamps, verdict)

**How it reads factory state**: The dashboard reads `.factory/state.json`, `.factory/heartbeat`, and `.factory/logs/` directly from disk — the same files the CLI tools consume. No separate data pipeline.

**How it starts runs**: The `POST /api/projects/[id]/runs` endpoint spawns `ts/src/heartbeat.ts` as a detached child process with `child_process.spawn()`. Same entry point as running from CLI.

**Real-time updates**: The `POST /api/projects/[id]/events` endpoint provides Server-Sent Events (SSE). The dashboard polls state.json and streams phase transitions, gate results, and log updates to connected clients.

**Key API routes**:

| Route | Method | Description |
|-------|--------|-------------|
| `/api/projects` | GET/POST | List all projects / create new |
| `/api/projects/[id]` | GET/DELETE | Project details / remove |
| `/api/projects/[id]/runs` | POST | Start new factory run |
| `/api/projects/[id]/events` | POST | SSE event stream |
| `/api/projects/[id]/logs/[phase]` | GET | Phase log tail |
| `/api/projects/[id]/artifacts/[name]` | GET | Download artifact |
| `/api/projects/[id]/preview` | GET | Preview server status |
| `/api/projects/[id]/stop` | POST | Stop active run |

## Resumability

The factory resumes from any point after a crash:

1. Orchestrator checks `state.json` for `current_phase`
2. `nextPendingPhase()` skips all `completed` phases
3. `spec.json` is preserved (not re-normalized on resume)
4. Implementation checks `.factory/artifacts/tasks/` for existing completion reports and skips finished tasks
5. Heartbeat watchdog detects the runner died and restarts it

## Sub-Agent Parallelism

The implementer doesn't write code directly. It spawns sub-agents using Claude Code's `Agent` tool with `isolation: "worktree"`:

```
Implementer reads plan.md
    │
    ├── Wave 1 (parallel):
    │   ├── Agent (worktree) → Task 1
    │   └── Agent (worktree) → Task 2
    │   merge worktrees, run tests
    │
    ├── Wave 2 (parallel):
    │   ├── Agent (worktree) → Task 3
    │   ├── Agent (worktree) → Task 4
    │   └── Agent (worktree) → Task 5
    │   merge worktrees, run tests
    │
    └── Wave 3:
        └── Agent (worktree) → Task 6 (integration)
        merge, run tests
```

Each sub-agent works in a git worktree — an isolated copy of the repo. No merge conflicts during parallel execution. After each wave, the implementer merges back and verifies tests pass before moving to the next wave.

## Key Design Decisions

See [DECISIONS.md](DECISIONS.md) for the full architectural decision log.

**Why `query()` instead of `claude -p`?**
The Agent SDK's `query()` function gives us typed, in-process control: AbortController for timeouts, SDK hooks for gate checks and heartbeat, AsyncGenerator for streaming. The old `claude -p` approach required shell-level process management, stream file parsing, and external gate scripts.

**Why Stop hooks for gates?**
It's cheaper to block an agent from stopping than to kill and restart a session. The agent continues in the same context window with full history, addressing the gate feedback immediately.

**Why heartbeat files instead of process monitoring?**
A running process doesn't mean a working agent. The heartbeat file mtime proves the agent is making forward progress, not just alive.

**Why atomic state writes?**
The dashboard and CLI tools read `state.json` concurrently while the orchestrator writes it. Writing to a `.tmp` file and atomically renaming prevents readers from seeing partial JSON.

**Why force-advance after N iterations?**
Perfection is the enemy of done. If a phase can't pass its gate after 10 attempts, the output is likely good enough — downstream phases can often compensate. All force decisions are logged as alerts.
