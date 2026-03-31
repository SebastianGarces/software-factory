# Architectural Decisions

This document captures the key decisions behind the software factory — what we chose, what we tried, and why. It's written chronologically as the system evolved.

## 1. Build on Claude Code, not a custom harness

The first and most fundamental decision. We explicitly chose **not** to build our own LLM orchestrator.

Claude Code already handles auth, context management, tool execution, permission modes, streaming, and error recovery. Building a custom harness means maintaining API integrations, token management, tool sandboxing, retry logic — all solved problems. We'd be rebuilding infrastructure instead of building the factory.

The Claude Agent SDK's `query()` function gives us programmatic control where we need it: model selection, tool restrictions, hooks for quality gates, AbortController for timeouts. Claude Code handles everything else.

**Trade-off**: We're coupled to Claude Code's ecosystem. If Anthropic changes the SDK interface or Claude Code's runtime behavior, we adapt. But the leverage is enormous — our entire orchestration layer (`ts/src/`) is ~1000 lines of TypeScript focused purely on pipeline logic, not LLM infrastructure.

**What this means in practice**: The factory runs on a standard Claude Code subscription. No API keys to manage, no token budgets to track, no separate billing. The same subscription that powers interactive Claude Code usage powers the factory's autonomous runs.

## 2. From 7 phases to 3

V1 had 8 phases: intake, research, design, architecture, planning, implementation, verification, PR assembly.

In practice, the handoff overhead between phases outweighed the specialization benefits. Each handoff meant:
- Context loss: the next agent starts fresh, reads artifacts, rebuilds understanding
- Redundant work: the architect re-reads everything the researcher just summarized
- Artifact bloat: intermediate files (research.md, architecture.md) that exist only to pass information between phases
- More gates to fail: each phase boundary is a point where the pipeline can stall

The current 3-phase pipeline eliminates these problems:
- **Planning** consolidates research + architecture + task decomposition into one pass. The planner reads the codebase and produces `plan.md` in a single session with full context.
- **Implementation** is unchanged — it's inherently a separate phase because it modifies code.
- **Verification** consolidates review + PR assembly. The verifier evaluates code, writes the verdict, and if PASS, creates README.md, QA.md, and commits — all in one session.

**Result**: Fewer context switches, faster end-to-end, simpler state machine, fewer failure points.

## 3. From 6 agents to 3

V1 had six specialized agents: researcher, designer, architect, implementer, reviewer, orchestrator.

**Orchestrator → TypeScript code**: The orchestrator made judgment calls about retries, reroutes, and phase transitions. But these decisions are deterministic: "did the gate pass? if no, retry. if cycle detected, force-advance." This logic doesn't need an LLM — it's a state machine. Moving it to TypeScript (`factory.ts`) made it faster, cheaper, and predictable.

**Researcher + Architect → Planner**: The researcher produced `research.md` (codebase analysis), then the architect read it and produced `architecture.md` (technical design). Two context windows, two sessions, one lossy handoff. A single planner agent can survey the codebase and design the solution in the same context window, producing a better result because it has all the information at once.

**Reviewer → Verifier**: The reviewer produced `review.md`, then a separate PR assembly step created README.md, QA.md, and committed. Combining these into one agent (verifier) is natural — the agent that just reviewed the code is best positioned to write the README and commit message.

**Designer → removed** (see decision #8 below).

## 4. From bash to TypeScript

V1 used bash scripts for orchestration: `factory-runner.sh`, `factory-heartbeat.sh`, `gate-check.sh`, monitoring scripts. The rationale was zero dependencies — bash runs anywhere Claude Code runs.

As complexity grew (retry logic with exponential backoff, cycle detection, rerouting, atomic state management, structured logging), bash became a liability:
- No types: a typo in a JSON field name is a silent bug
- Brittle JSON: parsing with `jq` works until it doesn't (nested objects, special characters, null handling)
- Hard to test: no unit testing framework for bash pipeline logic
- Process management: tracking PIDs, cleanup on exit, signal handling — all manual

The Claude Agent SDK providing a TypeScript-native `query()` function was the tipping point. Instead of spawning `claude -p` as a subprocess and parsing its stream output, we call `query()` directly and iterate an AsyncGenerator. SDK hooks (Stop, PostToolUse) replace shell scripts.

**Trade-off**: Requires Bun runtime. Acceptable because the factory's target stack already uses Bun, and the TypeScript runner has a single dependency (`@anthropic-ai/claude-agent-sdk`).

## 5. Stop hooks as quality gates

The key insight: **it's cheaper to block an agent from stopping than to kill and restart a session**.

When an agent calls the Stop tool, the SDK invokes our Stop hook. If the gate check fails (e.g., `plan.md` is missing required sections), the hook returns `{ decision: "block", reason: "..." }` and the agent continues in the same session — with full context, conversation history, and understanding of what it just did.

The alternative (kill the session, start a new one with retry feedback) means the agent has to rebuild its understanding from scratch. For a planning session that's been running for 10 minutes, that's expensive.

**Self-limiting**: A block counter prevents infinite gate loops. After 10 consecutive blocks, the hook allows the stop and the factory-level gate evaluator decides whether to retry or force-advance.

## 6. Heartbeat files over process monitoring

A running process doesn't mean a working agent. It could be:
- Stuck in an infinite loop
- Waiting on a hung API call
- In a retry cycle that never succeeds
- Spinning on a tool that produces no useful output

The heartbeat file (`.factory/heartbeat`) is touched on every tool use via a PostToolUse SDK hook. Its mtime proves the agent is making forward progress — not just alive, but actively using tools and producing work.

The watchdog (`heartbeat.ts`) checks this file every 30 seconds. If the mtime is stale (>300s), it kills the runner and restarts. This is more reliable than process monitoring because it detects *functional* stalls, not just process death.

## 7. Sub-agent parallelism with worktree isolation

The implementer doesn't write code directly. It reads `plan.md`, identifies task waves (groups of independent tasks), and spawns sub-agents — one per task — using Claude Code's `Agent` tool with `isolation: "worktree"`.

Each sub-agent works in a git worktree: an isolated copy of the repository. Multiple agents can write to the same codebase simultaneously without merge conflicts because they're working on separate filesystem copies. After all tasks in a wave complete, the implementer merges worktrees back and runs tests before moving to the next wave.

This is the key scaling mechanism. A plan with 8 tasks across 3 waves might take 3x the time of the longest wave, not 8x the time of a single task. The planner explicitly groups tasks into waves based on dependency analysis to maximize parallelism.

## 8. The frontend quality problem

The factory's hardest unsolved problem: how to produce UIs that look *designed*, not generated.

### Approach 1: Google Stitch MCP

Tried integrating [Stitch](https://stitch.withgoogle.com/) for AI-powered design-to-code. The idea was to generate screen designs and convert them to React components.

**Result**: Super unreliable. Frequent failures, inconsistent output, poor integration with our pipeline's artifact flow. Dropped for now — want to revisit when it stabilizes.

### Approach 2: Pencil MCP

Added a dedicated design phase where a Designer agent generated UI mockups in [Pencil](https://pencil.li) (`.pen` files). Downstream agents queried the Pencil file for exact CSS values, colors, typography. The architecture had:
- A Research phase that identified Required Screens
- A Design phase that generated or ingested `.pen` files
- Design artifacts: `design.pen`, `design-system.md`, `design-manifest.json`, screenshots
- Read-only Pencil MCP access for the architect and implementer

This worked — the design fidelity was noticeably better when agents had concrete visual targets. But it added significant pipeline complexity: an extra phase, an extra agent, extra artifacts, an extra gate, and a dependency on the Pencil MCP server being available and reliable.

**Removed** when we simplified from 7 to 3 phases. The trade-off was: simpler/faster pipeline vs. less design fidelity.

### Approach 3: Embedded frontend skill (current)

Instead of a separate design tool, we embedded a frontend quality skill directly into the planner and implementer agent prompts. The planner produces a detailed **Visual Design Direction** section in `plan.md` with:
- Exact color values (not "pick a blue", but `hsl(222, 47%, 11%)`)
- Typography scale with specific sizes and weights
- Spacing rhythm with pixel values
- Component styling specs (cards, buttons, tables, forms, nav, empty states)
- Animations plan using Motion with specific transitions, durations, easings

The implementer follows these specs. The verifier checks adherence.

This keeps the pipeline simple (no extra phase, no external tool dependency) while still pushing for visual quality. The quality is better than raw shadcn defaults but not as good as having actual design mockups.

### Approach 4: Considering dropping shadcn/ui

All factory-built apps currently look generic because shadcn defaults dominate the visual output. The card styles, button styles, table styles — they all scream "shadcn starter template." No amount of color customization fully escapes it.

Considering removing the shadcn constraint to give agents more creative freedom with Tailwind directly. The hypothesis: without a component library defaulting everything to the same look, agents will produce more distinctive UIs guided by the plan's design direction.

**Risk**: shadcn provides accessible, well-tested component primitives (dialogs, dropdowns, tooltips). Without it, agents might produce less accessible or more buggy interactive components.

This is an active area of experimentation. The right answer likely involves better design input (when Stitch/Pencil mature) combined with fewer defaults that constrain visual output.

## 9. Frontend dashboard as a separate app

CLI monitoring tools (`watch.ts`, `status.ts`, `tail.ts`) work well for individual sessions but don't persist history or provide a visual overview across multiple projects.

The frontend dashboard (`frontend/`) is a Next.js app with:
- **SQLite + Drizzle** for project/run persistence (which projects exist, their run history, outcomes)
- **Filesystem reads** for live state (`.factory/state.json`, logs, artifacts) — same source of truth as CLI tools
- **SSE streams** for real-time updates in the browser
- **Process spawning** to start new factory runs (`heartbeat.ts` as a detached child)

The key architectural choice: the dashboard is **optional and self-contained**. The factory runner (`ts/src/`) has zero web dependencies. It writes to `.factory/` on disk and doesn't know or care whether a dashboard is watching. The dashboard is a read-only observer (plus a run trigger) layered on top.

This separation means:
- The factory runs identically from CLI, tmux, launchd, or the dashboard
- The dashboard can be down without affecting running factories
- Multiple monitoring tools (CLI + dashboard) can observe the same run simultaneously
