---
name: factory
description: Run the full software factory pipeline. Takes a feature specification and produces a deployable PR. Use when the user says "factory", provides a feature spec, or wants to generate a complete feature autonomously.
---

You are running the **Software Factory** — an autonomous pipeline that transforms a feature specification into a complete, tested, deployable pull request.

## Input

The user will provide one of:
- A JSON spec file: `/factory path/to/spec.json`
- A markdown/text brief: `/factory path/to/brief.md`
- A natural language description: `/factory Add a payment methods management page...`
- Arguments: `$ARGUMENTS`

**All formats are valid.** The factory accepts JSON specs, markdown briefs, plain text files, or inline natural language descriptions. If the input is not structured JSON, the orchestrator converts it to a normalized spec during intake.

## Initialization

1. **Parse the input.** Determine the format:
   - If `$ARGUMENTS` is a file path and the file exists, read it
   - If the file is JSON (`.json`), use it as-is after validation
   - If the file is markdown/text (`.md`, `.txt`), or if `$ARGUMENTS` is inline text, treat it as a natural language brief
   - For natural language input: extract the feature name, description, and any structured details (entity, fields, permissions, etc.) and write a normalized `spec.json`

2. **Initialize `.factory/` directory in the current working directory:**
```bash
mkdir -p .factory/artifacts/tasks .factory/logs
```
   Create `.factory/state.json` with the default state structure (see the orchestrator agent for the schema). No need to find external templates — the state structure is defined inline in the orchestrator's AGENT.md.

3. **Write `.factory/spec.json`** with the normalized spec (always JSON, regardless of input format). Also save the original input as `.factory/original-input.*` for reference.

4. **Update `.factory/state.json`** with spec file path, project directory, and start timestamp.

5. **Create a feature branch:**
```bash
git checkout -b factory/$(echo "$FEATURE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
```

## Pipeline Execution

Execute each phase sequentially. After each phase, evaluate the gate. If the gate fails, retry the phase with feedback (max 5 iterations per phase).

### Phase 1: Research
Spawn the **researcher** agent:
```
Explore this codebase and produce research findings for the feature described in .factory/spec.json.
Write your findings to .factory/artifacts/research.md following the format in your AGENT.md instructions.
```

**Gate check:** Read `.factory/artifacts/research.md`. Verify it meets the research gate criteria from `templates/gate-criteria.md`. If the spec has a `design` config, also verify the research includes a "Required Screens" section. If it fails, re-run the researcher with specific feedback about what's missing.

### Phase 2: Design (if spec has `design` config)
Check if `.factory/spec.json` contains a `design` configuration object. If it does NOT, skip directly to Phase 3.

If `design.penFile` is present (existing .pen file):
Spawn the **designer** agent:
```
Ingest designs from the existing Pencil file.
Read .factory/spec.json and .factory/artifacts/research.md (especially the Required Screens section).
Open the .pen file, discover screens, validate coverage, fill gaps, and export.
Write design.pen, design-system.md, screenshots, and design-manifest.json to .factory/artifacts/.
```

If `design.penFile` is NOT present (generate new):
Spawn the **designer** agent:
```
Generate new designs via Pencil.
Read .factory/spec.json and .factory/artifacts/research.md (especially the Required Screens section).
Get guidelines, open new document, set variables, design screens, and export.
Write design.pen, design-system.md, screenshots, and design-manifest.json to .factory/artifacts/.
```

**Gate check:** Verify:
- `.factory/artifacts/design.pen` exists
- `.factory/artifacts/design-manifest.json` exists with screen entries
- `.factory/artifacts/design-system.md` has color tokens, typography, spacing
- Screen screenshots exist in `.factory/artifacts/screens/`
If the gate fails, re-run the designer with feedback. Max iterations from `design.maxDesignIterations` (default 3).

### Phase 3: Architecture
Spawn the **architect** agent:
```
Read .factory/artifacts/research.md and design the architecture for the feature in .factory/spec.json.
If .factory/artifacts/design-system.md exists, read it, view screenshots in .factory/artifacts/screens/, and query .factory/artifacts/design.pen via Pencil MCP for precise values.
Use the Pencil design system as your Visual Design reference — do NOT invent a new design.
Write your design to .factory/artifacts/architecture.md following the format in your AGENT.md instructions.
```

**Gate check:** Read `.factory/artifacts/architecture.md`. Verify:
- Data model aligns with conventions from research.md
- API contracts are complete
- Integration points are specified

If the gate fails, determine if the issue is:
- Research gap → re-run researcher with feedback
- Architecture gap → re-run architect with feedback

### Phase 4: Planning
Spawn the **architect** agent again:
```
Read .factory/artifacts/architecture.md and decompose it into an ordered implementation plan.
Write the plan to .factory/artifacts/plan.md following the format in your AGENT.md instructions.
```

**Gate check:** Verify plan has tasks with IDs, dependencies, acceptance criteria, and TDD specs.

### Phase 5: Implementation
For each task in the dependency order from plan.md:

**If tasks can run in parallel** (no dependencies between them), use Agent Teams:
```
Create a team of implementers. Assign each independent task to a teammate.
Each works in a worktree. Tasks: [list independent tasks]
```

**If tasks are sequential**, spawn single **implementer** agents:
```
Execute Task {id} from .factory/artifacts/plan.md.
Read research.md and architecture.md for conventions and design.
If .factory/artifacts/screens/ exists, view the corresponding screenshot as your design reference.
Query .factory/artifacts/design.pen via Pencil MCP for precise design values.
Follow TDD: write tests first, then implement, then refactor.
Write completion report to .factory/artifacts/tasks/task-{id}-complete.md
```

**Gate check after each task:** Run tests. If they fail, re-run implementer with test output.

**Gate check after all tasks:** Run full test suite + lint + type check. If anything fails, identify which task broke and re-run that implementer.

### Phase 6: Verification
Spawn the **reviewer** agent:
```
Review all code produced during implementation.
Read research.md for conventions, architecture.md for design, plan.md for acceptance criteria.
Run the full test suite, linter, and type checker.
Write your review to .factory/artifacts/review.md following the format in your AGENT.md instructions.
```

**Gate check:** If review verdict is FAIL, read the Required Fixes section and route back:
- Convention issues → re-run implementer for specific files
- Design issues → re-run architect, then implementer
- Security issues → re-run implementer with security fix instructions
- Test gaps → re-run implementer to add missing tests

### Phase 7: PR Assembly
Once verification passes:

1. **Stage and commit** all changes with clear messages following the codebase's commit convention.

2. **Create PR** with:
   - Title: descriptive summary of the feature
   - Body: what was generated, architecture decisions, test coverage summary
   - Link to `.factory/artifacts/` for full audit trail

3. **Write `.factory/done`** to signal completion to the watchdog.

4. **Update state.json** with `completed_at` and `final_verdict: "pass"`.

## Error Handling

- **Phase exceeds 5 iterations:** Force-advance with the best output so far. Log a warning in `decisions.md`.
- **Reroute requested:** Read `.factory/reroute.json`, route back to the specified phase with the feedback.
- **Auth expiry imminent:** Check `~/.claude/.credentials.json`. If token expires within 2 hours, write state and exit gracefully.
- **Unrecoverable error:** Write state, log the error, and exit. The watchdog or human can resume.

## Heartbeat

Touch `.factory/heartbeat` at the start of each phase to signal liveness:
```bash
touch .factory/heartbeat
```
