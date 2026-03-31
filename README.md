# Software Factory

An autonomous software factory built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and the [Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk). Give it a feature spec, get back a deployable pull request — no human intervention until final review.

```
spec.json ──▶ Planning ──▶ Implementation ──▶ Verification ──▶ PR
                 │               │                  │
             plan.md      code + tests          review.md
                                                README.md
                                                 QA.md
```

Three specialized agents coordinate through a 3-phase pipeline with quality gates, automatic retries, and feedback loops. Each phase runs as an isolated `query()` call via the Claude Agent SDK, with its own context window and tool restrictions.

## Quick Start

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [Bun](https://bun.sh) runtime
- macOS or Linux

### 1. Write a spec

```json
{
  "name": "payment-methods",
  "description": "CRUD page for managing payment methods. Users can add credit cards and bank accounts, set a default, and delete old ones."
}
```

### 2. Run the factory

```bash
# Interactive (inside Claude Code)
/factory spec.json

# Programmatic (in tmux or background)
bun run ts/src/index.ts spec.json /path/to/project

# With watchdog (auto-restart on stalls)
bun run ts/src/heartbeat.ts spec.json /path/to/project

# As macOS background service
bun run ts/src/install.ts spec.json /path/to/project
```

### 3. Monitor progress

```bash
# Live terminal dashboard
bun run ts/src/monitor/watch.ts /path/to/project

# One-shot status check
bun run ts/src/monitor/status.ts /path/to/project

# Stream agent activity
bun run ts/src/monitor/tail.ts /path/to/project

# Web dashboard (optional)
cd frontend && npm run dev    # http://localhost:4040
```

## How It Works

```
┌───────────────────────────────────────────────────────┐
│  heartbeat.ts (watchdog)                              │
│  Monitors liveness every 30s, restarts stalled        │
│  processes (max 5 attempts), cleans up orphans         │
└───────────────────┬───────────────────────────────────┘
                    │ spawns & monitors
                    ▼
┌───────────────────────────────────────────────────────┐
│  factory.ts (orchestrator)                            │
│  Runs each phase as a separate query() call via       │
│  the Claude Agent SDK. Evaluates quality gates,       │
│  retries failed phases with feedback (max 10x),       │
│  handles reroutes (verification → implementation).    │
└───────────────────────────────────────────────────────┘
```

### Agents

| Agent | Model | Role | Tools |
|-------|-------|------|-------|
| **Planner** | Opus | Surveys codebase, designs data model + API + components + visual direction, decomposes into tasks with TDD specs | Read, Grep, Glob, Bash, Agent |
| **Implementer** | Opus | Orchestrates sub-agents in parallel (worktree isolation), executes TDD cycle per task | All tools |
| **Verifier** | Opus | Runs tests/lint/typecheck, reviews code + UI quality, browser verification, writes verdict | Read, Grep, Glob, Bash, Agent |

### Quality Gates

Every phase is evaluated by a quality gate before advancing:

- **Plan**: `plan.md` exists, contains Data Model + API/Routes + Components + Tasks + Acceptance Criteria + TDD specs, >1000 bytes
- **Implementation**: Task completion reports exist for all planned tasks
- **Verification**: `review.md` exists with PASS verdict, `README.md` and `QA.md` created in project root

Gates operate at two levels:
1. **SDK Stop hooks** — block the agent from stopping mid-session if gate criteria aren't met (the agent continues in the same context)
2. **Post-session evaluation** — after the session ends, update state and decide to retry or advance

Failed gates retry the phase with specific feedback. After 10 failures, the orchestrator force-advances and logs the decision.

### Feedback Loops

```
Agent does work ──▶ Gate evaluates ──┬── pass ──▶ next phase
                                     │
                                     └── fail ──▶ retry with feedback
                                                  (max 10 iterations)
```

When verification fails, the pipeline automatically routes back to implementation with the verifier's feedback so the implementer knows exactly what to fix.

## Spec Format

Minimal:

```json
{
  "name": "feature-name",
  "description": "What to build, in plain English."
}
```

Full spec with all options:

```json
{
  "name": "therapist-dashboard",
  "description": "Dashboard for therapists to manage client sessions and treatment notes",
  "pattern": "crud_ui",
  "entity": "Session",
  "fields": [
    { "name": "clientName", "kind": "string", "required": true },
    { "name": "date", "kind": "date", "required": true },
    { "name": "notes", "kind": "string" },
    { "name": "status", "kind": "enum", "values": ["scheduled", "completed", "cancelled"] }
  ],
  "ui": { "list": true, "detail": true, "form": true, "search": true },
  "constraints": {
    "max_iterations": 5,
    "target_branch": "main"
  }
}
```

You can also pass a markdown brief or plain text:

```bash
/factory "Add a settings page where users can update their profile, change email, and manage notification preferences"
```

## Project Structure

```
.claude/
├── agents/                        # Agent personas
│   ├── planner/AGENT.md           # Research + architecture + task planning
│   ├── implementer/AGENT.md       # TDD coder (orchestrates sub-agents)
│   └── verifier/AGENT.md          # QA + PR assembly
├── skills/                        # Slash commands
│   ├── factory/SKILL.md           # /factory — full pipeline
│   ├── factory-implement/SKILL.md # /factory-implement — implementation only
│   └── factory-verify/SKILL.md    # /factory-verify — verification only
└── settings.json                  # Claude Code settings

ts/                                # TypeScript orchestrator
├── package.json
└── src/
    ├── index.ts                   # CLI entry point
    ├── factory.ts                 # Pipeline orchestrator (query() loop)
    ├── heartbeat.ts               # Watchdog (liveness + auto-restart)
    ├── state.ts                   # State machine + initialization
    ├── agents.ts                  # Model + tool config per phase
    ├── gates.ts                   # Quality gate evaluation
    ├── hooks.ts                   # SDK hooks (Stop gate, heartbeat)
    ├── prompts.ts                 # Phase-specific prompt builders
    ├── types.ts                   # Type definitions
    ├── utils.ts                   # File I/O, logging, time
    ├── install.ts                 # macOS launchd service installer
    ├── ci-simulate.ts             # Multi-language CI checker
    └── monitor/
        ├── watch.ts               # Live terminal dashboard
        ├── status.ts              # One-shot status snapshot
        └── tail.ts                # Stream activity parser

frontend/                          # Next.js monitoring dashboard
├── package.json
├── src/
│   ├── app/                       # App Router pages + API routes
│   ├── components/                # UI components (shadcn/ui)
│   ├── lib/factory/               # Factory state readers + queries
│   └── db/                        # SQLite + Drizzle (projects, runs)
└── drizzle.config.ts

templates/
├── gate-criteria.md               # Gate evaluation standards
├── spec-schema.json               # Input spec JSON schema
└── state.json                     # Pipeline state template
```

### Runtime Directory (`.factory/`, gitignored)

Created at runtime for each factory run:

```
.factory/
├── state.json                     # Pipeline state machine
├── spec.json                      # Normalized input spec
├── heartbeat                      # Liveness signal (touched every tool use)
├── done                           # Completion marker
├── artifacts/
│   ├── plan.md                    # Planning output
│   ├── tasks/task-*-complete.md   # Per-task completion reports
│   └── review.md                  # Verification output
├── logs/
│   ├── *.stream                   # Raw NDJSON from query() (real-time)
│   ├── *.log                      # Plain text logs
│   └── heartbeat.log              # Watchdog activity
└── reroute.json                   # Architecture change request (if any)
```

## Running Individual Phases

You don't have to run the full pipeline. Two phase-specific slash commands are available:

```bash
/factory-implement              # Implementation only (needs plan.md)
/factory-verify                 # Verification only (needs implementation)
```

## Frontend Dashboard

The optional Next.js dashboard (`frontend/`) provides a web UI for managing and monitoring factory runs.

### Features

- **Project management**: Register projects, view run history, start new runs
- **Live monitoring**: Real-time phase progress, gate statuses, artifact sizes
- **Event stream**: SSE-powered live view of agent activity (tool calls, text output)
- **Artifact viewer**: Read plan.md and review.md rendered as markdown
- **Log tail**: Phase log viewer with syntax highlighting
- **Preview integration**: Live preview of the app being built

### Running the Dashboard

```bash
cd frontend
npm install
npm run db:push          # Initialize SQLite database
npm run dev              # Start on http://localhost:4040
```

### How It Connects to the Factory

The dashboard reads `.factory/state.json` and `.factory/logs/` directly from disk — the same files the CLI monitoring tools use. When you start a new run from the dashboard, it spawns `ts/src/heartbeat.ts` as a detached child process, the same entry point as running from the command line.

```
┌──────────────────────┐       ┌─────────────────────┐
│  Frontend Dashboard  │       │  CLI Monitoring      │
│  (Next.js on :4040)  │       │  (watch/status/tail) │
└──────────┬───────────┘       └──────────┬──────────┘
           │ reads                        │ reads
           ▼                              ▼
    ┌──────────────────────────────────────────┐
    │         .factory/ (on disk)              │
    │  state.json, logs/, artifacts/           │
    └──────────────────┬───────────────────────┘
                       │ written by
                       ▼
              ┌──────────────────┐
              │   factory.ts     │
              │   (orchestrator) │
              └──────────────────┘
```

## Configuration

Environment variables for the TypeScript runner:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_ITERATIONS` | `10` | Max retries per phase |
| `PHASE_TIMEOUT` | `3600` | Max seconds per phase (1 hour) |
| `FACTORY_TIMEOUT` | `14400` | Max total seconds (4 hours) |
| `API_RETRY_MAX` | `5` | API error retry attempts |
| `API_RETRY_INITIAL_WAIT` | `30` | Initial backoff wait (seconds) |
| `MAX_TURNS` | — | Optional limit on conversation turns per phase |
| `MAX_GATE_BLOCKS` | `10` | Max Stop hook blocks before allowing stop |
| `FACTORY_HOME` | auto-detected | Path to software-factory repo |

## License

MIT
