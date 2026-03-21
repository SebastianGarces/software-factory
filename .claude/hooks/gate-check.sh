#!/bin/bash
# gate-check.sh — Stop hook for factory quality gates
#
# This hook runs when a factory agent completes its work.
# It evaluates the output against gate criteria and returns
# {ok: false, reason: "..."} to force the agent to continue if the gate fails.
#
# Used as a Stop hook in .claude/settings.json

set -euo pipefail

INPUT=$(cat)

# Only activate during factory runs
if [ ! -d ".factory" ]; then
  exit 0
fi

# Read current phase from state
STATE_FILE=".factory/state.json"
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

CURRENT_PHASE=$(jq -r '.current_phase' "$STATE_FILE" 2>/dev/null || echo "unknown")

# Touch heartbeat to signal liveness
touch .factory/heartbeat 2>/dev/null || true

# Self-limiting block counter: prevent infinite stop-hook loops.
# If we've blocked the agent too many times for the same phase, let it stop.
BLOCK_COUNT_FILE=".factory/.gate-blocks-${CURRENT_PHASE}"
BLOCK_COUNT=$(cat "$BLOCK_COUNT_FILE" 2>/dev/null || echo "0")
MAX_GATE_BLOCKS="${MAX_GATE_BLOCKS:-10}"

if [ "$BLOCK_COUNT" -ge "$MAX_GATE_BLOCKS" ]; then
  echo "Gate has blocked agent $BLOCK_COUNT times for phase '$CURRENT_PHASE'. Allowing stop to prevent infinite loop." >&2
  rm -f "$BLOCK_COUNT_FILE"
  exit 0
fi

check_research_gate() {
  local artifact=".factory/artifacts/research.md"
  if [ ! -f "$artifact" ]; then
    echo "Research artifact not found. The researcher must write findings to $artifact."
    return 1
  fi

  # Check for required sections
  local missing=""
  grep -q "## Codebase Profile" "$artifact" || missing="$missing Codebase Profile,"
  grep -q "## Conventions" "$artifact" || missing="$missing Conventions,"
  grep -q "## Integration Points" "$artifact" || missing="$missing Integration Points,"

  # Check that file paths are cited (not generic)
  local path_count
  path_count=$(grep -cE '(src/|lib/|app/|pages/|components/|routes/)' "$artifact" 2>/dev/null || echo "0")
  if [ "$path_count" -lt 3 ]; then
    missing="$missing Specific file path citations (found only $path_count),"
  fi

  # If design integration is configured, Required Screens section must exist
  local has_design
  has_design=$(jq -r '.design // .stitch // empty' ".factory/spec.json" 2>/dev/null)
  if [ -n "$has_design" ]; then
    grep -q "Required Screens\|## Required Screens" "$artifact" || missing="$missing Required Screens section (needed for design integration),"
  fi

  if [ -n "$missing" ]; then
    echo "Research gate FAILED. Missing sections:${missing%. }. Review templates/gate-criteria.md for requirements."
    return 1
  fi
  return 0
}

check_design_gate() {
  if [ ! -f ".factory/artifacts/design.pen" ]; then
    echo "Pencil design file not found at .factory/artifacts/design.pen."
    return 1
  fi
  local manifest=".factory/artifacts/design-manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "Design manifest not found at $manifest."
    return 1
  fi
  if [ ! -f ".factory/artifacts/design-system.md" ]; then
    echo "Design system document not found."
    return 1
  fi
  local ds_size
  ds_size=$(wc -c < ".factory/artifacts/design-system.md" | tr -d ' ')
  if [ "$ds_size" -lt 200 ]; then
    echo "Design system too short ($ds_size bytes). Need color tokens, typography, spacing."
    return 1
  fi
  local screen_count
  screen_count=$(find .factory/artifacts/screens/ -name "screenshot.png" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$screen_count" -eq 0 ]; then
    echo "No screen screenshots found in .factory/artifacts/screens/."
    return 1
  fi
  return 0
}

check_architecture_gate() {
  local artifact=".factory/artifacts/architecture.md"
  if [ ! -f "$artifact" ]; then
    echo "Architecture artifact not found. The architect must write design to $artifact."
    return 1
  fi

  local missing=""
  grep -q "## Data Model" "$artifact" || missing="$missing Data Model,"
  grep -q "## API Contract" "$artifact" || missing="$missing API Contract,"

  if [ -n "$missing" ]; then
    echo "Architecture gate FAILED. Missing sections:${missing%. }."
    return 1
  fi
  return 0
}

check_plan_gate() {
  local artifact=".factory/artifacts/plan.md"
  if [ ! -f "$artifact" ]; then
    echo "Plan artifact not found. The architect must write the plan to $artifact."
    return 1
  fi

  local missing=""
  grep -q "## Tasks" "$artifact" || grep -q "### Task" "$artifact" || missing="$missing Task definitions,"
  grep -q "Acceptance Criteria" "$artifact" || missing="$missing Acceptance Criteria,"
  grep -q "TDD" "$artifact" || grep -q "Red" "$artifact" || missing="$missing TDD specs,"

  if [ -n "$missing" ]; then
    echo "Plan gate FAILED. Missing:${missing%. }."
    return 1
  fi
  return 0
}

check_implementation_gate() {
  local task_count
  task_count=$(ls .factory/artifacts/tasks/task-*-complete.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$task_count" -eq 0 ]; then
    echo "Implementation gate FAILED. No task completion reports found in .factory/artifacts/tasks/."
    return 1
  fi

  # Check how many tasks the plan defined vs how many are done
  local planned_tasks
  planned_tasks=$(grep -cE "^###? Task [0-9]" .factory/artifacts/plan.md 2>/dev/null || echo "0")
  if [ "$planned_tasks" -gt 0 ] && [ "$task_count" -lt "$planned_tasks" ]; then
    echo "Implementation gate FAILED. Only $task_count of $planned_tasks tasks completed. Continue implementing remaining tasks."
    return 1
  fi
  return 0
}

check_verification_gate() {
  local artifact=".factory/artifacts/review.md"
  if [ ! -f "$artifact" ]; then
    echo "Review artifact not found. The reviewer must write findings to $artifact."
    return 1
  fi

  # The reviewer's job is to write a verdict (PASS or FAIL). Once it has done that,
  # let it stop. The runner handles FAIL verdicts by rerouting back to implementation.
  # Blocking the reviewer on FAIL traps it in a loop — it's read-only and can't fix anything.
  if grep -qiE "Verdict.*PASS" "$artifact" || grep -qiE "Verdict.*FAIL" "$artifact"; then
    return 0
  fi
  echo "Verification gate: review.md exists but has no clear PASS or FAIL verdict. Write a verdict."
  return 1
}

# Run the appropriate gate check
# Stop hooks: exit 0 = allow stop, exit 2 = block (agent continues), feedback on stderr
gate_failed=false
case "$CURRENT_PHASE" in
  research)
    if ! feedback=$(check_research_gate); then gate_failed=true; fi
    ;;
  design)
    if ! feedback=$(check_design_gate); then gate_failed=true; fi
    ;;
  architecture)
    if ! feedback=$(check_architecture_gate); then gate_failed=true; fi
    ;;
  planning)
    if ! feedback=$(check_plan_gate); then gate_failed=true; fi
    ;;
  implementation)
    if ! feedback=$(check_implementation_gate); then gate_failed=true; fi
    ;;
  verification)
    if ! feedback=$(check_verification_gate); then gate_failed=true; fi
    ;;
  *)
    # Not a factory phase, allow
    ;;
esac

if [ "$gate_failed" = "true" ]; then
  # Increment block counter and block the agent
  echo $((BLOCK_COUNT + 1)) > "$BLOCK_COUNT_FILE"
  echo "$feedback" >&2
  exit 2
fi

# Gate passed — reset block counter
rm -f "$BLOCK_COUNT_FILE"
exit 0
