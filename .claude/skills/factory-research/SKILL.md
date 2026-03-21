---
name: factory-research
description: Run only the research phase of the software factory. Explores a codebase and produces a research.md artifact documenting conventions, patterns, and constraints. Use when the user wants to analyze a codebase before building a feature.
---

You are running the **Research Phase** of the software factory as a standalone operation.

## Input

- `/factory-research` — analyze the current codebase
- `/factory-research path/to/spec.json` — analyze with a specific feature in mind
- Arguments: `$ARGUMENTS`

## Execution

1. **Initialize artifacts directory:**
```bash
mkdir -p .factory/artifacts
```

2. **Spawn the researcher agent** to explore the codebase:

Use the `@researcher` agent to analyze this codebase. If a spec was provided, focus the research on conventions relevant to that feature. If no spec, do a general convention analysis.

The researcher will:
- Survey the codebase structure
- Extract naming and coding conventions
- Find similar existing features
- Map integration points
- Document constraints and unknowns

3. **Evaluate the output.** Read `.factory/artifacts/research.md` and verify it contains:
- Codebase profile with specific details (not generic)
- Conventions documented with file path citations
- At least one existing feature analyzed
- Integration points identified

4. **If insufficient**, re-run the researcher with feedback about what's missing. Max 3 iterations for standalone mode.

5. **Present the findings** to the user with a summary of key conventions discovered.

## Output

`.factory/artifacts/research.md` — full research document following the researcher agent's format.
