---
name: factory-design
description: Run the design phase of the software factory. Generates or ingests Pencil designs for the feature. Requires research.md to exist first. Use when the user wants to produce design artifacts before architecture.
---

You are running the **Design Phase** of the software factory as a standalone operation.

## Input

- `/factory-design` — generate designs using Pencil (spec must have `design` config)
- `/factory-design path/to/spec.json` — use a specific spec file
- Arguments: `$ARGUMENTS`

## Prerequisites

Before running, verify:
1. `.factory/spec.json` exists and contains a `design` configuration object
2. `.factory/artifacts/research.md` exists with a "Required Screens" section

If prerequisites are missing, inform the user:
- No spec? → "Run `/factory` first to initialize, or create `.factory/spec.json`"
- No research? → "Run `/factory-research` first to analyze the codebase"
- No design config? → "Add a `design` object to your spec (see `templates/spec-schema.json`)"

## Execution

1. **Initialize artifacts directory:**
```bash
mkdir -p .factory/artifacts/screens
```

2. **Determine the path:**
   - If `spec.design.penFile` exists → Path B (ingest existing .pen file)
   - If no `penFile` → Path A (generate new designs)

3. **Spawn the designer agent** (`@designer`):

For Path A (generate):
```
Generate new designs via Pencil.
Read .factory/spec.json and .factory/artifacts/research.md (especially Required Screens section).
Follow the Path A protocol: get guidelines, get style guide, open new document, set variables, design screens, export screenshots.
Write design.pen, design-system.md, screenshot files, and design-manifest.json to .factory/artifacts/.
```

For Path B (ingest):
```
Ingest designs from the existing Pencil file.
Read .factory/spec.json and .factory/artifacts/research.md (especially Required Screens section).
Follow the Path B protocol: open document, discover screens, validate coverage, fill gaps, export.
Write design.pen, design-system.md, screenshot files, and design-manifest.json to .factory/artifacts/.
```

4. **Evaluate the output.** Verify:
   - `.factory/artifacts/design.pen` exists
   - `.factory/artifacts/design-manifest.json` exists with screen entries
   - `.factory/artifacts/design-system.md` has color tokens, typography, spacing (> 200 bytes)
   - Screen screenshots exist in `.factory/artifacts/screens/`
   - Every Required Screen from research.md has a corresponding screen

5. **If insufficient**, re-run the designer with feedback about what's missing. Max iterations from `design.maxDesignIterations` (default 3).

6. **Present the results** to the user with:
   - Number of screens generated/ingested
   - Design system summary (primary color, font, key tokens)
   - Any coverage gaps or warnings

## Output

- `.factory/artifacts/design.pen` — Pencil design file (queryable by downstream phases)
- `.factory/artifacts/design-system.md` — Full design system document
- `.factory/artifacts/design-manifest.json` — Screen inventory and mapping
- `.factory/artifacts/screens/{name}/screenshot.png` — Screenshot for each screen
