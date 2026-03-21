#!/bin/bash
# factory-tail.sh — Live agent activity viewer
#
# Parses the stream-json output from the current phase and renders
# a human-readable activity log showing tool calls, results, and text.
#
# Usage:
#   ./scripts/factory-tail.sh [project-dir]
#
# Run in a third tmux pane alongside factory-heartbeat and factory-watch.

set -euo pipefail

PROJECT_DIR="${1:-.}"
FACTORY_DIR="$PROJECT_DIR/.factory"
STATE_FILE="$FACTORY_DIR/state.json"
LOG_DIR="$FACTORY_DIR/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

get_current_phase() {
  jq -r '.current_phase // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown"
}

get_stream_file() {
  local phase="$1"
  echo "$LOG_DIR/${phase}.stream"
}

render_event() {
  local line="$1"

  local type subtype
  type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || return
  subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true

  case "$type" in
    assistant)
      # Extract content blocks
      echo "$line" | jq -r '
        .message.content[]? |
        if .type == "tool_use" then
          "TOOL: \(.name)"
        elif .type == "thinking" then
          "THINKING: \(.thinking // "" | split("\n")[0] | .[0:200])"
        elif .type == "text" then
          .text // empty
        else
          empty
        end
      ' 2>/dev/null | while IFS= read -r content; do
        if [[ "$content" == THINKING:* ]]; then
          local thought="${content#THINKING: }"
          if [ -n "$thought" ]; then
            printf "  ${DIM}%s${NC}  ${MAGENTA}think${NC}  ${DIM}%s${NC}\n" "$(date +%H:%M:%S)" "$thought"
          fi
        elif [[ "$content" == TOOL:* ]]; then
          local tool_name="${content#TOOL: }"
          local tool_input
          tool_input=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"$tool_name\") | .input | to_entries | map(\"\(.key)=\(.value | tostring | .[0:100])\") | join(\", \")" 2>/dev/null || echo "")

          case "$tool_name" in
            Read)
              local fpath
              fpath=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Read\") | .input.file_path // empty" 2>/dev/null)
              printf "  ${BLUE}%s${NC}  ${BOLD}Read${NC} %s\n" "$(date +%H:%M:%S)" "$fpath"
              ;;
            Edit)
              local fpath
              fpath=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Edit\") | .input.file_path // empty" 2>/dev/null)
              printf "  ${YELLOW}%s${NC}  ${BOLD}Edit${NC} %s\n" "$(date +%H:%M:%S)" "$fpath"
              ;;
            Write)
              local fpath
              fpath=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Write\") | .input.file_path // empty" 2>/dev/null)
              printf "  ${GREEN}%s${NC}  ${BOLD}Write${NC} %s\n" "$(date +%H:%M:%S)" "$fpath"
              ;;
            Bash)
              local cmd
              cmd=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Bash\") | .input.command // empty" 2>/dev/null | head -1 | head -c 120)
              printf "  ${MAGENTA}%s${NC}  ${BOLD}Bash${NC} %s\n" "$(date +%H:%M:%S)" "$cmd"
              ;;
            Grep)
              local pattern fpath
              pattern=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Grep\") | .input.pattern // empty" 2>/dev/null)
              fpath=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Grep\") | .input.path // \".\"" 2>/dev/null)
              printf "  ${CYAN}%s${NC}  ${BOLD}Grep${NC} /%s/ in %s\n" "$(date +%H:%M:%S)" "$pattern" "$fpath"
              ;;
            Glob)
              local pattern
              pattern=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Glob\") | .input.pattern // empty" 2>/dev/null)
              printf "  ${CYAN}%s${NC}  ${BOLD}Glob${NC} %s\n" "$(date +%H:%M:%S)" "$pattern"
              ;;
            Agent)
              local desc
              desc=$(echo "$line" | jq -r ".message.content[]? | select(.type == \"tool_use\" and .name == \"Agent\") | .input.description // .input.prompt[0:80] // empty" 2>/dev/null)
              printf "  ${RED}%s${NC}  ${BOLD}Agent${NC} %s\n" "$(date +%H:%M:%S)" "$desc"
              ;;
            *)
              printf "  ${DIM}%s${NC}  ${BOLD}%s${NC} %s\n" "$(date +%H:%M:%S)" "$tool_name" "$(echo "$tool_input" | head -c 100)"
              ;;
          esac
        elif [ -n "$content" ]; then
          # Text output — show first line, truncated
          local first_line
          first_line=$(echo "$content" | head -1 | head -c 140)
          if [ -n "$first_line" ]; then
            printf "  ${DIM}%s${NC}  %s\n" "$(date +%H:%M:%S)" "$first_line"
          fi
        fi
      done
      ;;

    result)
      local is_error duration cost
      is_error=$(echo "$line" | jq -r '.is_error // false' 2>/dev/null)
      duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null)
      cost=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)

      local duration_display=""
      if [ "$duration" -gt 0 ] 2>/dev/null; then
        duration_display="$(( duration / 1000 ))s"
      fi

      if [ "$is_error" = "true" ]; then
        local err_msg
        err_msg=$(echo "$line" | jq -r '.result // "unknown error"' 2>/dev/null | head -c 120)
        printf "\n  ${RED}%s  SESSION ERROR${NC} (%s): %s\n\n" "$(date +%H:%M:%S)" "$duration_display" "$err_msg"
      else
        printf "\n  ${GREEN}%s  SESSION COMPLETE${NC} (%s, \$%s)\n\n" "$(date +%H:%M:%S)" "$duration_display" "$cost"
      fi
      ;;
  esac
}

# --- Main ---

echo -e "${BOLD}FACTORY TAIL${NC} — live agent activity"
echo -e "${DIM}Watching: $FACTORY_DIR${NC}"
echo ""

last_phase=""
last_size=0

while true; do
  # Check which phase is active
  current_phase=$(get_current_phase)
  stream_file=$(get_stream_file "$current_phase")

  # Phase changed — reset tracking
  if [ "$current_phase" != "$last_phase" ]; then
    if [ -n "$last_phase" ] && [ "$last_phase" != "unknown" ]; then
      printf '%.0s─' $(seq 1 60); echo ""
    fi
    echo -e "${BOLD}Phase: ${CYAN}$current_phase${NC}"
    echo ""
    last_phase="$current_phase"
    last_size=0
  fi

  # If stream file exists, read new lines since last check
  if [ -f "$stream_file" ]; then
    current_size=$(wc -c < "$stream_file" 2>/dev/null | tr -d ' ')

    if [ "$current_size" -gt "$last_size" ]; then
      # Read only the new bytes
      tail -c +"$((last_size + 1))" "$stream_file" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Only process valid JSON lines
        if echo "$line" | jq -e '.' >/dev/null 2>&1; then
          render_event "$line"
        fi
      done
      last_size="$current_size"
    fi
  fi

  # Check for done — show message but keep tailing (don't exit)
  # The done file may be written prematurely by agents
  if [ -f "$FACTORY_DIR/done" ]; then
    # Only show the message once
    if [ "${done_shown:-}" != "true" ]; then
      echo ""
      echo -e "${GREEN}${BOLD}FACTORY COMPLETE${NC}"
      echo -e "${DIM}(Ctrl+C to exit, or waiting for more activity...)${NC}"
      done_shown=true
    fi
  else
    done_shown=false
  fi

  sleep 1
done
