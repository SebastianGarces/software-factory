# Software Factory — Architecture Overview

## How It Works

```
You provide a spec (JSON, markdown, or plain text)
                    │
                    ▼
        ┌───────────────────────┐
        │   factory-heartbeat   │  Watchdog: monitors liveness,
        │   (bash, tmux/launchd)│  restarts on stall, kills orphans
        └───────────┬───────────┘
                    │ spawns & monitors
                    ▼
        ┌───────────────────────┐
        │    factory-runner     │  Orchestrator: runs each phase as
        │    (bash)             │  a separate `claude -p` session,
        │                      │  checks gates, retries on failure
        └───────────┬───────────┘
                    │ one session per phase
                    ▼
    ┌──────────────────────────────────────────┐
    │           PIPELINE (7 phases)            │
    │                                          │
    │  ┌─────────┐    ┌──────────┐             │
    │  │ INTAKE  │───▶│ RESEARCH │──┐          │
    │  └─────────┘    └──────────┘  │          │
    │                               ▼          │
    │                 ┌──────────────────┐      │
    │                 │   ARCHITECTURE   │      │
    │                 └────────┬─────────┘      │
    │              ┌───────── GATE ─────────┐   │
    │              │ pass              fail │   │
    │              ▼                   ▼    │   │
    │        ┌──────────┐      route back   │   │
    │        │ PLANNING │      to research  │   │
    │        │          │      or architect  │   │
    │        └────┬─────┘                   │   │
    │             ▼                         │   │
    │  ┌────────────────────┐               │   │
    │  │  IMPLEMENTATION    │  TDD cycle    │   │
    │  │  (Agent Team)      │  per task     │   │
    │  └────────┬───────────┘               │   │
    │      ┌─── GATE ───┐                  │   │
    │      │pass    fail │                  │   │
    │      ▼        ▼    │                  │   │
    │  ┌──────────┐ retry│                  │   │
    │  │ VERIFY   │      │                  │   │
    │  └────┬─────┘      │                  │   │
    │  ┌─── GATE ───┐    │                  │   │
    │  │pass    fail │    │                  │   │
    │  ▼        ▼    │    │                  │   │
    │  ┌──────────┐  route back             │   │
    │  │ PR       │  to appropriate phase   │   │
    │  │ ASSEMBLY │                         │   │
    │  └──────────┘                         │   │
    │                                       │   │
    └───────────────────────────────────────┘   │
                    │                           │
                    ▼                           │
              Pull Request                      │
              (human reviews)                   │
```

## Agent Personas

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  RESEARCHER  │  │  ARCHITECT   │  │ IMPLEMENTER  │
│  (sonnet)    │  │  (opus)      │  │ (sonnet)     │
│              │  │              │  │              │
│  read-only   │  │  read-only   │  │  full tools  │
│  explores    │  │  designs     │  │  TDD cycle   │
│  codebase    │  │  solutions   │  │  worktree    │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
   research.md    architecture.md      code + tests
                     plan.md
                                    ┌──────────────┐
                                    │   REVIEWER   │
                                    │   (sonnet)   │
                                    │              │
                                    │  read + bash │
                                    │  runs tests  │
                                    │  checks QA   │
                                    └──────┬───────┘
                                           │
                                           ▼
                                       review.md
```

## Persistence & Recovery

```
┌─────────────────────────────────────────────────┐
│                    tmux / launchd                │
│  ┌─────────────────────────────────────────┐    │
│  │  factory-heartbeat (watchdog)           │    │
│  │  • checks .factory/heartbeat every 30s  │    │
│  │  • kills + restarts if stalled > 5min   │    │
│  │  • cleans up orphaned processes         │    │
│  │  • max 5 restart attempts               │    │
│  └─────────────────────┬───────────────────┘    │
│                        │                        │
│  ┌─────────────────────▼───────────────────┐    │
│  │  factory-runner (phase orchestrator)     │    │
│  │  • each phase = one `claude -p` call    │    │
│  │  • fresh context window per phase       │    │
│  │  • state checkpointed to disk           │    │
│  │  • API errors → exponential backoff     │    │
│  │  • resumable from last completed phase  │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘

On disk (.factory/):
  state.json          pipeline progress + session IDs
  spec.json           normalized feature spec
  heartbeat           touched every 10s (liveness signal)
  artifacts/          phase outputs (research.md, etc.)
  logs/               per-phase streaming logs
  done                created when factory finishes
```

## Feedback Loop

```
         ┌──────────────────────┐
         │  Agent does work     │
         └──────────┬───────────┘
                    │
                    ▼
         ┌──────────────────────┐
         │  Gate evaluates      │  checks artifact exists,
         │  output              │  has required sections,
         └──────────┬───────────┘  meets criteria
                    │
              ┌─────┴─────┐
              │           │
            pass        fail
              │           │
              ▼           ▼
           next       retry same phase
           phase      with feedback
                      (max 5 iterations)
```

## How To Run

```bash
# Interactive (inside Claude Code)
/factory spec.json
/factory "Build a user management page"

# Overnight (terminal)
factory-heartbeat spec.json .          # in tmux
factory-watch .                        # in second pane

# As macOS service
factory-install spec.json .            # survives terminal close

# Check progress anytime
factory-status .
```
