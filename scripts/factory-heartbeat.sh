#!/bin/bash
# factory-heartbeat.sh — Watchdog for the factory runner
#
# Monitors factory-runner.sh via heartbeat file. If the runner stalls
# (no heartbeat update in STALL_THRESHOLD seconds), kills and restarts it.
#
# Usage:
#   ./scripts/factory-heartbeat.sh path/to/spec.json [project-dir]
#
# For overnight runs:
#   tmux new-session -d -s factory './scripts/factory-heartbeat.sh path/to/spec.json'
#
# Inspired by OpenClaw's heartbeat-policy.ts and daemon restart-handoff patterns.

set -euo pipefail

SPEC_INPUT="${1:?Usage: factory-heartbeat.sh <spec-file> [project-dir]}"
PROJECT_DIR="${2:-.}"
FACTORY_DIR="$PROJECT_DIR/.factory"
HEARTBEAT_FILE="$FACTORY_DIR/heartbeat"
DONE_FILE="$FACTORY_DIR/done"
# Resolve the runner script — handle symlinks properly
# If we're invoked via symlink (e.g. ~/.local/bin/factory-heartbeat),
# follow the symlink to find the real script directory
SELF="$0"
if [ -L "$SELF" ]; then
  SELF="$(readlink "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RUNNER_SCRIPT="$SCRIPT_DIR/factory-runner.sh"

# Verify it exists
if [ ! -f "$RUNNER_SCRIPT" ]; then
  echo "ERROR: Cannot find factory-runner.sh at $RUNNER_SCRIPT"
  echo "Set FACTORY_HOME or run from the software-factory directory."
  exit 1
fi

# Configuration
STALL_THRESHOLD="${STALL_THRESHOLD:-300}"  # 5 minutes
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"      # Check every 30 seconds
MAX_RESTARTS="${MAX_RESTARTS:-5}"
LOG_FILE="$FACTORY_DIR/logs/heartbeat.log"

restart_count=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  local msg="[heartbeat $(date +%Y-%m-%dT%H:%M:%S)] $*"
  echo -e "${BLUE}${msg}${NC}"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
  local msg="[heartbeat $(date +%Y-%m-%dT%H:%M:%S)] WARN: $*"
  echo -e "${YELLOW}${msg}${NC}"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_err() {
  local msg="[heartbeat $(date +%Y-%m-%dT%H:%M:%S)] ERROR: $*"
  echo -e "${RED}${msg}${NC}"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_ok() {
  local msg="[heartbeat $(date +%Y-%m-%dT%H:%M:%S)] OK: $*"
  echo -e "${GREEN}${msg}${NC}"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

cleanup_orphans() {
  # OpenClaw pattern: find and kill orphaned claude processes from this factory
  local orphans
  orphans=$(pgrep -f "claude.*factory-" 2>/dev/null || true)
  if [ -n "$orphans" ]; then
    log_warn "Cleaning up orphaned claude processes: $orphans"
    echo "$orphans" | xargs kill 2>/dev/null || true
    sleep 2
    # Force kill if still running
    echo "$orphans" | xargs kill -9 2>/dev/null || true
  fi
}

get_heartbeat_age() {
  if [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "999999"
    return
  fi

  local last_beat now
  # macOS stat
  if stat -f %m "$HEARTBEAT_FILE" &>/dev/null; then
    last_beat=$(stat -f %m "$HEARTBEAT_FILE")
  else
    # Linux stat
    last_beat=$(stat -c %Y "$HEARTBEAT_FILE")
  fi
  now=$(date +%s)
  echo $(( now - last_beat ))
}

# Ensure factory dir exists
mkdir -p "$FACTORY_DIR/logs"

log "Starting factory watchdog"
log "Spec: $SPEC_INPUT"
log "Project: $PROJECT_DIR"
log "Stall threshold: ${STALL_THRESHOLD}s"
log "Max restarts: $MAX_RESTARTS"

# Main watchdog loop
while [ ! -f "$DONE_FILE" ] && [ "$restart_count" -lt "$MAX_RESTARTS" ]; do

  log "Starting factory runner (attempt $((restart_count + 1))/$MAX_RESTARTS)"

  # Start the runner in the background
  "$RUNNER_SCRIPT" "$SPEC_INPUT" "$PROJECT_DIR" &
  RUNNER_PID=$!
  log "Runner PID: $RUNNER_PID"

  # Monitor loop
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"

    # Check if done
    if [ -f "$DONE_FILE" ]; then
      log_ok "Factory completed! Done file found."
      wait "$RUNNER_PID" 2>/dev/null || true
      break 2
    fi

    # Check heartbeat
    age=$(get_heartbeat_age)

    if [ "$age" -gt "$STALL_THRESHOLD" ]; then
      log_warn "Factory stalled! No heartbeat for ${age}s (threshold: ${STALL_THRESHOLD}s)"
      log_warn "Killing runner PID $RUNNER_PID"

      kill "$RUNNER_PID" 2>/dev/null || true
      sleep 3
      kill -9 "$RUNNER_PID" 2>/dev/null || true

      cleanup_orphans
      restart_count=$((restart_count + 1))
      break
    fi

    # Log status periodically
    current_phase=$(jq -r '.current_phase // "unknown"' "$FACTORY_DIR/state.json" 2>/dev/null || echo "unknown")
    log "Heartbeat OK (age: ${age}s). Phase: $current_phase"
  done

  # If runner exited on its own (not killed by us)
  if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
    wait "$RUNNER_PID" 2>/dev/null
    exit_code=$?

    if [ -f "$DONE_FILE" ]; then
      log_ok "Factory completed successfully!"
      break
    elif [ "$exit_code" -eq 0 ]; then
      log_ok "Runner exited cleanly but no done file. Checking state..."
      current_phase=$(jq -r '.current_phase // "unknown"' "$FACTORY_DIR/state.json" 2>/dev/null || echo "unknown")
      if [ "$current_phase" = "done" ]; then
        touch "$DONE_FILE"
        break
      fi
      log_warn "Runner exited at phase: $current_phase. Restarting..."
      restart_count=$((restart_count + 1))
    else
      log_err "Runner exited with code $exit_code. Restarting..."
      restart_count=$((restart_count + 1))
    fi
  fi

  sleep 5
done

# Final report
echo ""
echo "================================"
if [ -f "$DONE_FILE" ]; then
  log_ok "FACTORY COMPLETE"
  echo ""
  echo "Results:"
  jq '{
    spec: .spec_file,
    phases: [.phases | to_entries[] | {phase: .key, status: .value.status, iterations: .value.iterations}],
    total_time: (if .completed_at and .started_at then "see timestamps" else "incomplete" end),
    verdict: .final_verdict
  }' "$FACTORY_DIR/state.json" 2>/dev/null || cat "$FACTORY_DIR/state.json"
else
  log_err "FACTORY DID NOT COMPLETE"
  log_err "Exhausted $MAX_RESTARTS restart attempts."
  echo ""
  echo "Current state:"
  jq '.phases | to_entries[] | "\(.key): \(.value.status) (iterations: \(.value.iterations))"' "$FACTORY_DIR/state.json" 2>/dev/null || true
  echo ""
  echo "To resume: ./scripts/factory-heartbeat.sh $SPEC_INPUT $PROJECT_DIR"
  exit 1
fi
