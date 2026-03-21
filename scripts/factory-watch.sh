#!/bin/bash
# factory-watch.sh — Live terminal dashboard for the software factory
#
# Shows real-time phase progress, heartbeat status, artifact sizes,
# gate results, and tails the current agent's streaming output.
#
# Usage:
#   ./scripts/factory-watch.sh [project-dir]
#
# Best used in a second tmux pane:
#   tmux split-window -h './scripts/factory-watch.sh'
#
# Or in a separate terminal tab while factory-runner runs in another.

set -euo pipefail

PROJECT_DIR="${1:-.}"
FACTORY_DIR="$PROJECT_DIR/.factory"
STATE_FILE="$FACTORY_DIR/state.json"
HEARTBEAT_FILE="$FACTORY_DIR/heartbeat"
LOG_DIR="$FACTORY_DIR/logs"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Get terminal dimensions
COLS=$(tput cols 2>/dev/null || echo 80)
ROWS=$(tput lines 2>/dev/null || echo 24)

# How many lines to reserve for the log tail
LOG_LINES=$(( ROWS - 20 ))
if [ "$LOG_LINES" -lt 5 ]; then
  LOG_LINES=5
fi

status_icon() {
  case "$1" in
    completed)   printf "${GREEN}%-11s${NC}" "DONE" ;;
    in_progress) printf "${YELLOW}%-11s${NC}" "RUNNING" ;;
    failed)      printf "${RED}%-11s${NC}" "FAILED" ;;
    pending)     printf "${DIM}%-11s${NC}" "pending" ;;
    *)           printf "${DIM}%-11s${NC}" "$1" ;;
  esac
}

gate_icon() {
  if [ "$1" = "true" ]; then
    printf "${GREEN}PASS${NC}"
  else
    printf "${DIM}---${NC} "
  fi
}

heartbeat_display() {
  if [ ! -f "$HEARTBEAT_FILE" ]; then
    printf "${DIM}no heartbeat${NC}"
    return
  fi

  local last_beat now age
  if stat -f %m "$HEARTBEAT_FILE" &>/dev/null; then
    last_beat=$(stat -f %m "$HEARTBEAT_FILE")
  else
    last_beat=$(stat -c %Y "$HEARTBEAT_FILE")
  fi
  now=$(date +%s)
  age=$((now - last_beat))

  if [ "$age" -lt 30 ]; then
    printf "${GREEN}%ds ago${NC}" "$age"
  elif [ "$age" -lt 120 ]; then
    printf "${YELLOW}%ds ago${NC}" "$age"
  elif [ "$age" -lt 300 ]; then
    printf "${YELLOW}%dm%ds ago${NC}" $((age/60)) $((age%60))
  else
    printf "${RED}%dm%ds ago (STALE)${NC}" $((age/60)) $((age%60))
  fi
}

extract_current_activity() {
  local phase="$1"
  local stream_file="$LOG_DIR/${phase}.stream"

  if [ ! -f "$stream_file" ]; then
    echo ""
    return
  fi

  # Get the last tool use or text from the stream
  # Look for the most recent assistant text or tool call
  local last_tool last_text

  last_tool=$(tail -20 "$stream_file" 2>/dev/null \
    | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name // empty' 2>/dev/null \
    | tail -1)

  last_text=$(tail -5 "$stream_file" 2>/dev/null \
    | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null \
    | tail -1 \
    | head -c 120)

  if [ -n "$last_tool" ]; then
    echo "Tool: $last_tool"
  elif [ -n "$last_text" ]; then
    echo "$last_text"
  fi
}

render_dashboard() {
  # Clear screen
  tput clear 2>/dev/null || printf '\033[2J\033[H'

  if [ ! -f "$STATE_FILE" ]; then
    echo -e "${DIM}Waiting for factory to start... (looking for $STATE_FILE)${NC}"
    return
  fi

  local current_phase spec_file started_at

  current_phase=$(jq -r '.current_phase // "unknown"' "$STATE_FILE" 2>/dev/null)
  started_at=$(jq -r '.started_at // ""' "$STATE_FILE" 2>/dev/null)

  # Get spec name — show from spec.json "name" field, fall back to truncated spec_file
  local spec_display
  if [ -f "$FACTORY_DIR/spec.json" ]; then
    spec_display=$(jq -r '.name // .description[:80] // "unknown"' "$FACTORY_DIR/spec.json" 2>/dev/null || echo "unknown")
    # Truncate if it's still too long (e.g. full description was used as name)
    spec_display=$(echo "$spec_display" | head -1 | head -c 80)
  else
    spec_display=$(jq -r '.spec_file // "unknown"' "$STATE_FILE" 2>/dev/null | head -c 80)
  fi

  # Calculate elapsed time using UTC to match state.json timestamps
  local elapsed_display=""
  if [ -n "$started_at" ] && [ "$started_at" != "null" ]; then
    local start_epoch now_epoch elapsed_secs
    # Parse ISO 8601 UTC timestamp — use TZ=UTC so the Z suffix is handled correctly
    start_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -u -d "$started_at" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [ "$start_epoch" -gt 0 ]; then
      elapsed_secs=$((now_epoch - start_epoch))
      local hours=$((elapsed_secs / 3600))
      local mins=$(( (elapsed_secs % 3600) / 60 ))
      local secs=$((elapsed_secs % 60))
      if [ "$hours" -gt 0 ]; then
        elapsed_display="${hours}h ${mins}m ${secs}s"
      elif [ "$mins" -gt 0 ]; then
        elapsed_display="${mins}m ${secs}s"
      else
        elapsed_display="${secs}s"
      fi
    fi
  fi

  # Find active claude agent processes
  local agent_pids agent_count
  agent_pids=$(pgrep -f "claude.*factory-" 2>/dev/null || true)
  if [ -n "$agent_pids" ]; then
    agent_count=$(echo "$agent_pids" | wc -l | tr -d ' ')
  else
    agent_count=0
  fi

  # Header
  echo -e "${BOLD}SOFTWARE FACTORY${NC}  $(date +%H:%M:%S)"
  printf '%.0s─' $(seq 1 "$COLS"); echo ""

  # Status row
  printf "  Spec: ${CYAN}%s${NC}\n" "$spec_display"
  printf "  Started: %s" "$started_at"
  if [ -n "$elapsed_display" ]; then
    printf "   Elapsed: ${CYAN}${BOLD}%s${NC}" "$elapsed_display"
  fi
  echo ""
  printf "  Heartbeat: "
  heartbeat_display
  echo ""

  # Agent list
  if [ "$agent_count" -gt 0 ]; then
    printf "  Agents: ${GREEN}%s active${NC}\n" "$agent_count"
    echo "$agent_pids" | while read -r pid; do
      local cmd phase_name
      cmd=$(ps -o args= -p "$pid" 2>/dev/null || echo "")
      phase_name=$(echo "$cmd" | grep -oE "factory-[a-z_]+" | head -1 | sed 's/factory-//' || echo "unknown")
      printf "    ${GREEN}PID %s${NC}  %s\n" "$pid" "$phase_name"
    done
  else
    printf "  Agents: ${DIM}none running${NC}\n"
  fi

  # Preview status
  if [ -f "$FACTORY_DIR/preview.json" ]; then
    preview_status=$(jq -r '.status' "$FACTORY_DIR/preview.json")
    preview_ports=$(jq -r '.ports | to_entries | map("\(.key):\(.value)") | join(" ")' "$FACTORY_DIR/preview.json")
    printf "  Preview: %s  %s\n" "$preview_status" "$preview_ports"
  fi

  # Phase table
  echo ""
  printf "  ${BOLD}%-16s %-13s %-6s %-6s %s${NC}\n" "PHASE" "STATUS" "ITER" "GATE" ""
  printf "  %-16s %-13s %-6s %-6s %s\n" "─────" "──────" "────" "────" ""

  local phases=("intake" "research" "architecture" "planning" "implementation" "verification" "pr_assembly")
  local gate_names=("intake" "research" "architecture" "plan" "implementation" "verification" "")

  for i in "${!phases[@]}"; do
    local phase="${phases[$i]}"
    local status iterations gate_passed indicator

    status=$(jq -r ".phases.\"$phase\".status // \"pending\"" "$STATE_FILE" 2>/dev/null)
    iterations=$(jq -r ".phases.\"$phase\".iterations // 0" "$STATE_FILE" 2>/dev/null)

    local gate_name="${gate_names[$i]:-}"
    gate_passed="false"
    if [ -n "$gate_name" ]; then
      gate_passed=$(jq -r ".gates.\"$gate_name\".passed // false" "$STATE_FILE" 2>/dev/null)
    fi

    # Current phase indicator
    indicator="  "
    if [ "$phase" = "$current_phase" ] && [ "$status" = "in_progress" ]; then
      indicator="${YELLOW}> ${NC}"
    fi

    printf "  %b%-14s " "$indicator" "$phase"
    status_icon "$status"
    printf " %-6s " "$iterations"
    gate_icon "$gate_passed"
    echo ""
  done

  # Artifacts
  echo ""
  printf "  ${BOLD}ARTIFACTS${NC}\n"
  for artifact in research.md architecture.md plan.md review.md; do
    local path="$FACTORY_DIR/artifacts/$artifact"
    if [ -f "$path" ]; then
      local size
      size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
      printf "    ${GREEN}%-20s${NC} %s bytes\n" "$artifact" "$size"
    else
      printf "    ${DIM}%-20s${NC} ${DIM}not created${NC}\n" "$artifact"
    fi
  done

  local task_count
  task_count=$(find "$FACTORY_DIR/artifacts/tasks/" -name "task-*-complete.md" 2>/dev/null | wc -l | tr -d ' ')
  printf "    %-20s %s\n" "tasks completed:" "$task_count"

  # Current activity
  echo ""
  printf '%.0s─' $(seq 1 "$COLS"); echo ""

  if [ "$current_phase" != "unknown" ] && [ "$current_phase" != "done" ]; then
    local activity
    activity=$(extract_current_activity "$current_phase")
    if [ -n "$activity" ]; then
      printf "  ${BOLD}Current:${NC} %s\n" "$activity"
    fi

    # Tail the live log
    local log_file="$LOG_DIR/${current_phase}.log"
    if [ -f "$log_file" ]; then
      printf "  ${BOLD}Agent output:${NC} (${current_phase})\n"
      echo -e "${DIM}"
      tail -"$LOG_LINES" "$log_file" 2>/dev/null | head -"$LOG_LINES" | sed 's/^/  /'
      echo -e "${NC}"
    else
      printf "  ${DIM}Waiting for agent output...${NC}\n"
    fi
  fi

  # Done check
  if [ -f "$FACTORY_DIR/done" ]; then
    echo ""
    echo -e "  ${GREEN}${BOLD}FACTORY COMPLETE${NC}"
    local verdict
    verdict=$(jq -r '.final_verdict // ""' "$STATE_FILE" 2>/dev/null)
    if [ -n "$verdict" ] && [ "$verdict" != "null" ]; then
      echo -e "  Verdict: ${GREEN}$verdict${NC}"
    fi
  fi

  # Gate failures
  local failed_gates
  failed_gates=$(jq -r '.gates | to_entries[] | select(.value.passed == false and .value.feedback != "") | "\(.key): \(.value.feedback)"' "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$failed_gates" ]; then
    echo ""
    printf "  ${RED}${BOLD}Gate Failures:${NC}\n"
    echo "$failed_gates" | while read -r line; do
      printf "    ${RED}%s${NC}\n" "$line"
    done
  fi
}

# Main loop
trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
tput civis 2>/dev/null  # Hide cursor

while true; do
  render_dashboard
  sleep "$REFRESH_INTERVAL"
done
