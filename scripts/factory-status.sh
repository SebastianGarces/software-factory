#!/bin/bash
# factory-status.sh — Display factory pipeline status
#
# Reads .factory/state.json and prints a human-readable progress report.
#
# Usage: ./scripts/factory-status.sh [project-dir]

set -euo pipefail

PROJECT_DIR="${1:-.}"
STATE_FILE="$PROJECT_DIR/.factory/state.json"
HEARTBEAT_FILE="$PROJECT_DIR/.factory/heartbeat"

if [ ! -f "$STATE_FILE" ]; then
  echo "No factory state found at $STATE_FILE"
  echo "Run /factory or ./scripts/factory-runner.sh to start."
  exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

status_icon() {
  case "$1" in
    completed) echo -e "${GREEN}done${NC}" ;;
    in_progress) echo -e "${YELLOW}running${NC}" ;;
    failed) echo -e "${RED}failed${NC}" ;;
    pending) echo -e "${DIM}pending${NC}" ;;
    *) echo -e "${DIM}$1${NC}" ;;
  esac
}

gate_icon() {
  if [ "$1" = "true" ]; then
    echo -e "${GREEN}PASS${NC}"
  else
    echo -e "${DIM}---${NC}"
  fi
}

echo ""
echo "=== Software Factory Status ==="
echo ""

# Spec info — show the name from spec.json, not the raw spec_file field
if [ -f "$PROJECT_DIR/.factory/spec.json" ]; then
  spec=$(jq -r '.name // (.description | .[0:80]) // "unknown"' "$PROJECT_DIR/.factory/spec.json" 2>/dev/null | head -1)
else
  spec=$(jq -r '.spec_file // "unknown"' "$STATE_FILE" | head -c 80)
fi
started=$(jq -r '.started_at // "not started"' "$STATE_FILE")
echo "Spec:    $spec"
echo "Started: $started"

# Heartbeat
if [ -f "$HEARTBEAT_FILE" ]; then
  if stat -f %m "$HEARTBEAT_FILE" &>/dev/null; then
    last_beat=$(stat -f %m "$HEARTBEAT_FILE")
  else
    last_beat=$(stat -c %Y "$HEARTBEAT_FILE")
  fi
  now=$(date +%s)
  age=$((now - last_beat))
  if [ "$age" -lt 60 ]; then
    echo -e "Heartbeat: ${GREEN}${age}s ago${NC}"
  elif [ "$age" -lt 300 ]; then
    echo -e "Heartbeat: ${YELLOW}${age}s ago${NC}"
  else
    echo -e "Heartbeat: ${RED}${age}s ago (STALE)${NC}"
  fi
else
  echo -e "Heartbeat: ${DIM}no heartbeat file${NC}"
fi

echo ""
echo "--- Pipeline Progress ---"
echo ""

phases=("intake" "research" "architecture" "planning" "implementation" "verification" "pr_assembly")
gates=("intake" "research" "architecture" "plan" "implementation" "verification")

printf "%-16s %-12s %-6s %-6s\n" "PHASE" "STATUS" "ITER" "GATE"
printf "%-16s %-12s %-6s %-6s\n" "-----" "------" "----" "----"

for i in "${!phases[@]}"; do
  phase="${phases[$i]}"
  status=$(jq -r ".phases.\"$phase\".status // \"pending\"" "$STATE_FILE")
  iterations=$(jq -r ".phases.\"$phase\".iterations // 0" "$STATE_FILE")

  gate_name="${gates[$i]:-}"
  gate_passed="false"
  if [ -n "$gate_name" ]; then
    gate_passed=$(jq -r ".gates.\"$gate_name\".passed // false" "$STATE_FILE")
  fi

  printf "%-16s " "$phase"
  printf "%-20s " "$(status_icon "$status")"
  printf "%-6s " "$iterations"
  printf "%-12s\n" "$(gate_icon "$gate_passed")"
done

echo ""

# Reroutes
reroute_count=$(jq '.reroutes | length' "$STATE_FILE" 2>/dev/null || echo "0")
if [ "$reroute_count" -gt 0 ]; then
  echo -e "${YELLOW}Reroutes: $reroute_count${NC}"
  jq -r '.reroutes[] | "  \(.from) -> \(.to): \(.reason)"' "$STATE_FILE" 2>/dev/null || true
  echo ""
fi

# Artifacts
echo "--- Artifacts ---"
echo ""
for artifact in research.md architecture.md plan.md review.md; do
  path="$PROJECT_DIR/.factory/artifacts/$artifact"
  if [ -f "$path" ]; then
    size=$(wc -c < "$path" | tr -d ' ')
    echo -e "  ${GREEN}$artifact${NC} (${size} bytes)"
  else
    echo -e "  ${DIM}$artifact (not yet created)${NC}"
  fi
done

# Task reports
task_count=$(find "$PROJECT_DIR/.factory/artifacts/tasks/" -name "task-*-complete.md" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  Tasks completed: $task_count"

echo ""

# Final verdict
verdict=$(jq -r '.final_verdict // ""' "$STATE_FILE")
if [ -n "$verdict" ] && [ "$verdict" != "null" ]; then
  echo -e "Final Verdict: ${GREEN}${verdict}${NC}"
  completed=$(jq -r '.completed_at // ""' "$STATE_FILE")
  echo "Completed: $completed"
fi

# Done file
if [ -f "$PROJECT_DIR/.factory/done" ]; then
  echo -e "\n${GREEN}FACTORY COMPLETE${NC}"
fi
