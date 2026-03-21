# Software Factory

This is an autonomous software factory built on Claude Code's agent infrastructure. It takes a feature specification and produces a deployable pull request without human intervention until final review.

## Project Structure

```
.claude/agents/     — Agent personas (orchestrator, researcher, designer, architect, implementer, reviewer)
.claude/skills/     — Skills (slash commands: /factory, /factory-research, etc.)
.claude/hooks/      — Quality gate hooks
scripts/            — Bash runner scripts for persistence and overnight execution
templates/          — State, spec schema, and gate criteria templates
```

## How It Works

1. User provides a feature spec (JSON or natural language)
2. `/factory` skill initializes the pipeline
3. Orchestrator coordinates: research → design → architecture → planning → implementation → verification → PR
4. Each phase runs as an isolated `claude -p` call with its own session
5. Quality gates (Stop hooks) evaluate output after each phase
6. Failed gates route back to the appropriate phase with feedback (max 5 iterations)
7. Final output: a clean PR ready for human review

## Key Conventions

- **Artifacts**: Each phase writes its output to `.factory/artifacts/`
- **State**: Pipeline state tracked in `.factory/state.json`
- **Heartbeat**: Phases touch `.factory/heartbeat` to signal liveness
- **Reroutes**: Implementation blockers write `.factory/reroute.json` to request architecture changes
- **Gate criteria**: Defined in `templates/gate-criteria.md`

## Running the Factory

### Interactive (within Claude Code)
```
/factory path/to/spec.json
```

### Overnight (unattended)
```bash
# In tmux
./scripts/factory-heartbeat.sh path/to/spec.json

# As macOS service
./scripts/factory-install.sh path/to/spec.json
```

## Pencil Design Integration

The factory integrates with Pencil (via MCP) for UI design generation:

- Add a `design` object to your spec to enable the design phase
- **Path A**: No `penFile` → factory generates designs via Pencil from research + spec
- **Path B**: With `penFile` → factory ingests existing Pencil file designs
- Design artifacts (`.pen` file, screenshots, design system, manifest) constrain the architect and implementer
- Architecture and implementation phases get read-only Pencil MCP access to query `design.pen` for precise values
- Standalone: `/factory-design` runs just the design phase

```json
{
  "name": "my-feature",
  "description": "...",
  "design": {
    "topic": "web-app",
    "styleTags": ["calm", "modern", "webapp"],
    "designBrief": "Clean SaaS dashboard like Linear"
  }
}
```

## Agent Teams

Implementation phase uses experimental Agent Teams for parallel task execution.
Requires: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
