# Software Factory

An autonomous software factory built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Give it a feature spec, get back a deployable pull request — no human intervention until final review.

```
spec.json ──▶ Research ──▶ Design ──▶ Architecture ──▶ Planning ──▶ Implementation ──▶ Verification ──▶ PR
                 │            │            │               │              │                  │
              research.md  design.pen  architecture.md  plan.md     code + tests        review.md
```

Six specialized agents coordinate through a 7-phase pipeline with quality gates, automatic retries, and feedback loops. Each phase runs as an isolated `claude -p` session with its own context window.

## Quick Start

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- macOS or Linux

### 1. Clone into your project

```bash
# Clone the factory into your existing project
git clone https://github.com/SebastianGarces/software-factory.git .factory-setup
cp -r .factory-setup/.claude .factory-setup/scripts .factory-setup/templates .
rm -rf .factory-setup
```

### 2. Write a spec

```json
{
  "name": "payment-methods",
  "description": "CRUD page for managing payment methods. Users can add credit cards and bank accounts, set a default, and delete old ones."
}
```

### 3. Run the factory

```bash
# Interactive (inside Claude Code)
/factory spec.json

# Overnight (in tmux)
./scripts/factory-heartbeat.sh spec.json

# As macOS background service
./scripts/factory-install.sh spec.json
```

### 4. Monitor progress

```bash
# Live dashboard (in a second tmux pane)
./scripts/factory-watch.sh

# One-shot status check
./scripts/factory-status.sh

# Stream agent activity
./scripts/factory-tail.sh
```

## How It Works

```
┌───────────────────────────────────────────────────────┐
│  factory-heartbeat (watchdog)                         │
│  • monitors liveness every 30s                        │
│  • restarts stalled processes (max 5 attempts)        │
│  • cleans up orphaned claude sessions                 │
└───────────────────┬───────────────────────────────────┘
                    │ spawns & monitors
                    ▼
┌───────────────────────────────────────────────────────┐
│  factory-runner (orchestrator)                        │
│  • runs each phase as a separate `claude -p` call     │
│  • evaluates quality gates after each phase           │
│  • retries failed phases with feedback (max 5x)       │
│  • handles reroutes (impl → architecture)             │
│  • assembles final PR                                 │
└───────────────────────────────────────────────────────┘
```

### Agents

| Agent | Model | Role | Tools |
|-------|-------|------|-------|
| **Researcher** | Sonnet | Explores codebase, extracts conventions, maps integration points | Read-only |
| **Designer** | Opus | Generates UI designs via Pencil MCP | Pencil MCP |
| **Architect** | Opus | Designs data models, API contracts, component trees | Read-only |
| **Implementer** | Sonnet | TDD cycle: red → green → refactor | Full tools, worktree isolation |
| **Reviewer** | Sonnet | Runs tests, checks conventions, security review | Read + Bash |
| **Orchestrator** | Opus | Coordinates pipeline, evaluates gates, makes judgment calls | All tools |

### Quality Gates

Every phase is evaluated by a quality gate before advancing. Gates check:

- **Research**: File paths cited (not generic), required sections present
- **Design**: All screens generated, design system extracted, screenshots exported
- **Architecture**: Data model + API contract present, security section included
- **Planning**: Tasks have acceptance criteria + TDD specs, no circular dependencies
- **Implementation**: All tests pass, no lint errors, task reports complete
- **Verification**: PASS verdict, no critical security findings

Failed gates retry the phase with specific feedback. After 5 failures, the orchestrator force-advances with the best output and logs the decision.

### Feedback Loops

```
Agent does work ──▶ Gate evaluates ──┬── pass ──▶ next phase
                                     │
                                     └── fail ──▶ retry with feedback
                                                  (max 5 iterations)
```

Implementation can also request **reroutes** — if a task discovers an architecture gap, it writes a `reroute.json` that sends the pipeline back to the architect with specific feedback.

## Spec Format

Minimal spec:

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
  "design": {
    "topic": "web-app",
    "styleTags": ["professional", "calm", "healthcare"],
    "designBrief": "Clean, accessible design. Calming blue palette."
  },
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
│   ├── orchestrator/AGENT.md      # Pipeline coordinator
│   ├── researcher/AGENT.md        # Codebase explorer
│   ├── designer/AGENT.md          # UI design via Pencil
│   ├── architect/AGENT.md         # Solution designer
│   ├── implementer/AGENT.md       # TDD coder
│   └── reviewer/AGENT.md         # QA specialist
├── skills/                        # Slash commands
│   ├── factory/SKILL.md           # /factory — full pipeline
│   ├── factory-research/SKILL.md  # /factory-research — research only
│   ├── factory-design/SKILL.md    # /factory-design — design only
│   ├── factory-plan/SKILL.md      # /factory-plan — architecture + planning
│   ├── factory-implement/SKILL.md # /factory-implement — implementation
│   └── factory-verify/SKILL.md    # /factory-verify — verification
├── hooks/
│   └── gate-check.sh             # Quality gate evaluator (Stop hook)
└── settings.json                  # Claude Code settings

scripts/
├── factory-runner.sh              # Main orchestrator (phase execution)
├── factory-heartbeat.sh           # Watchdog (liveness + auto-restart)
├── factory-watch.sh               # Live terminal dashboard
├── factory-status.sh              # Status snapshot
├── factory-tail.sh                # Stream activity parser
├── factory-install.sh             # macOS launchd service installer
└── ci-simulate.sh                 # Multi-language CI checker

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
├── heartbeat                      # Liveness signal (touched every ~10s)
├── done                           # Completion marker
├── artifacts/
│   ├── research.md                # Codebase analysis
│   ├── design.pen                 # Pencil design file
│   ├── design-system.md           # Design tokens
│   ├── design-manifest.json       # Screen inventory
│   ├── screens/*/screenshot.png   # Exported design screenshots
│   ├── architecture.md            # Technical design
│   ├── plan.md                    # Task breakdown with TDD specs
│   ├── tasks/task-*-complete.md   # Per-task completion reports
│   ├── review.md                  # QA review
│   └── decisions.md               # Forced orchestrator decisions
├── logs/
│   ├── *.stream                   # Raw stream JSON (real-time)
│   ├── *.log                      # Plain text logs
│   └── heartbeat.log              # Watchdog activity
└── reroute.json                   # Architecture change request
```

## Running Individual Phases

You don't have to run the full pipeline. Each phase has its own slash command:

```bash
/factory-research spec.json     # Just explore the codebase
/factory-design spec.json       # Just generate designs (needs research.md)
/factory-plan spec.json         # Just architect + plan (needs research.md)
/factory-implement              # Just implement tasks (needs plan.md)
/factory-verify                 # Just run verification (needs implementation)
```

## Design Integration

The factory optionally integrates with [Pencil](https://pencil.li) (via MCP) for UI design generation. Add a `design` object to your spec:

```json
{
  "design": {
    "topic": "web-app",
    "styleTags": ["calm", "modern", "minimal"],
    "designBrief": "Clean SaaS dashboard like Linear"
  }
}
```

**Path A** (no existing designs): Factory generates designs from scratch using Pencil, guided by the style tags and brief.

**Path B** (existing `.pen` file): Factory ingests your Pencil file, validates coverage against required screens, and fills gaps.

Design artifacts flow downstream — the architect extracts exact colors, fonts, and spacing from the design system, and the implementer queries the Pencil file for precise CSS values.

## Configuration

Environment variables for `factory-runner.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PHASE_TIMEOUT` | `3600` | Max seconds per phase |
| `FACTORY_TIMEOUT` | `14400` | Max total seconds (4 hours) |
| `MAX_ITERATIONS` | `5` | Max retries per phase |
| `API_RETRY_MAX` | `5` | API error retry attempts |
| `STALL_THRESHOLD` | `300` | Heartbeat stale threshold (seconds) |
| `CHECK_INTERVAL` | `30` | Watchdog check frequency (seconds) |
| `MAX_RESTARTS` | `5` | Max watchdog restart attempts |

## License

MIT
