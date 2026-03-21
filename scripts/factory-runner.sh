#!/bin/bash
# factory-runner.sh — Phase-by-phase factory orchestrator
#
# Runs each factory phase as a discrete `claude -p` invocation.
# State tracked in .factory/state.json. Resumable from last checkpoint.
#
# Usage:
#   ./scripts/factory-runner.sh path/to/spec.json [project-dir]
#   ./scripts/factory-runner.sh path/to/brief.md [project-dir]
#   ./scripts/factory-runner.sh "Add a payment methods page" [project-dir]
#
# The spec can be:
#   - A .json file (structured spec)
#   - A .md or .txt file (natural language brief)
#   - An inline string (natural language description)
#
# Set FACTORY_HOME to the software-factory repo root if templates are needed:
#   export FACTORY_HOME=/path/to/software-factory
#
# Inspired by OpenClaw's runCronIsolatedAgentTurn() pattern:
# - Fresh session per phase (no session reuse)
# - Per-phase timeout via --max-turns
# - Heartbeat file for watchdog monitoring
# - Auth pre-check before starting

set -euo pipefail

SPEC_INPUT="${1:?Usage: factory-runner.sh <spec-or-brief> [project-dir]}"
PROJECT_DIR="${2:-.}"
FACTORY_HOME="${FACTORY_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
FACTORY_DIR="$PROJECT_DIR/.factory"
STATE_FILE="$FACTORY_DIR/state.json"
HEARTBEAT_FILE="$FACTORY_DIR/heartbeat"
LOG_DIR="$FACTORY_DIR/logs"
MAX_TURNS="${MAX_TURNS:-}"  # empty = unlimited (watchdog handles runaway protection). Set MAX_TURNS=200 to cap.
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-3600}"      # 1 hour per phase default
FACTORY_TIMEOUT="${FACTORY_TIMEOUT:-14400}" # 4 hours total default

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${BLUE}[factory $(date +%H:%M:%S)]${NC} $*"
}

log_ok() {
  echo -e "${GREEN}[factory $(date +%H:%M:%S)] OK:${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[factory $(date +%H:%M:%S)] WARN:${NC} $*"
}

log_err() {
  echo -e "${RED}[factory $(date +%H:%M:%S)] ERROR:${NC} $*"
}

# --- Pre-flight checks ---

check_auth_expiry() {
  local cred_file="$HOME/.claude/.credentials.json"
  if [ ! -f "$cred_file" ]; then
    log_warn "No credentials file found. Skipping auth check."
    return 0
  fi

  local expires
  expires=$(jq -r '.expiresAt // 0' "$cred_file" 2>/dev/null || echo "0")
  if [ "$expires" = "0" ] || [ "$expires" = "null" ]; then
    return 0
  fi

  local now
  now=$(date +%s)
  local remaining=$(( (expires / 1000) - now ))

  if (( remaining < 7200 )); then
    log_err "Auth token expires in ${remaining}s (< 2 hours). Re-authenticate first."
    log_err "Run: claude auth login"
    exit 1
  fi

  log "Auth token valid for $((remaining / 3600))h $((remaining % 3600 / 60))m"
}

check_claude_cli() {
  if ! command -v claude &>/dev/null; then
    log_err "claude CLI not found. Install Claude Code first."
    exit 1
  fi
}

# --- State management ---

init_factory() {
  log "Initializing factory for input: $SPEC_INPUT"

  mkdir -p "$FACTORY_DIR/artifacts/tasks" "$LOG_DIR"

  # Remove stale done file from previous runs
  rm -f "$FACTORY_DIR/done"

  # Initialize state file if not exists
  if [ ! -f "$STATE_FILE" ]; then
    if [ -f "$FACTORY_HOME/templates/state.json" ]; then
      cp "$FACTORY_HOME/templates/state.json" "$STATE_FILE"
    else
      # Inline default state (works from any directory)
      cat > "$STATE_FILE" << 'STATEEOF'
{"factory_version":"1.0.0","spec_file":"","project_dir":"","current_phase":"intake","phases":{"intake":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""},"research":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""},"design":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":"","pen_file":"","screens_generated":0,"path":""},"architecture":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""},"planning":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""},"implementation":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":"","tasks_total":0,"tasks_completed":0},"verification":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""},"pr_assembly":{"status":"pending","session_id":"","iterations":0,"started_at":"","completed_at":""}},"gates":{"research":{"passed":false,"feedback":"","evaluated_at":""},"design":{"passed":false,"feedback":"","evaluated_at":""},"architecture":{"passed":false,"feedback":"","evaluated_at":""},"plan":{"passed":false,"feedback":"","evaluated_at":""},"implementation":{"passed":false,"feedback":"","evaluated_at":""},"verification":{"passed":false,"feedback":"","evaluated_at":""}},"reroutes":[],"alerts":[],"cycle_detection":{},"max_iterations_per_phase":5,"started_at":"","updated_at":"","completed_at":"","final_verdict":""}
STATEEOF
    fi
    # Store just a short reference, not the full content
    local spec_ref
    if [ -f "$SPEC_INPUT" ]; then
      spec_ref="$SPEC_INPUT"
    else
      spec_ref="(inline)"
    fi
    jq --arg spec "$spec_ref" \
       --arg dir "$PROJECT_DIR" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.spec_file = $spec | .project_dir = $dir | .started_at = $ts | .updated_at = $ts' \
       "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  # Normalize the input into .factory/spec.json
  # Skip if spec.json already exists (resume case — don't overwrite patched specs)
  if [ -f "$FACTORY_DIR/spec.json" ]; then
    log "Resuming: spec.json already exists, skipping normalization"
  elif [ -f "$SPEC_INPUT" ]; then
    # Input is a file
    case "$SPEC_INPUT" in
      *.json)
        cp "$SPEC_INPUT" "$FACTORY_DIR/spec.json"
        log "Input: JSON spec"
        ;;
      *.md|*.txt)
        # Save original and create a wrapper spec
        cp "$SPEC_INPUT" "$FACTORY_DIR/original-brief$(echo "$SPEC_INPUT" | grep -o '\.[^.]*$')"
        jq -n --arg desc "$(cat "$SPEC_INPUT")" \
              --arg name "$(basename "$SPEC_INPUT" | sed 's/\.[^.]*$//' | tr '-' ' ')" \
              '{name: $name, description: $desc}' > "$FACTORY_DIR/spec.json"
        log "Input: markdown/text brief → normalized to spec.json"
        ;;
      *)
        # Unknown file type, treat as text
        cp "$SPEC_INPUT" "$FACTORY_DIR/original-input.txt"
        jq -n --arg desc "$(cat "$SPEC_INPUT")" '{name: "feature", description: $desc}' > "$FACTORY_DIR/spec.json"
        log "Input: text file → normalized to spec.json"
        ;;
    esac
  else
    # Input is an inline string (natural language description)
    jq -n --arg desc "$SPEC_INPUT" '{name: "feature", description: $desc}' > "$FACTORY_DIR/spec.json"
    echo "$SPEC_INPUT" > "$FACTORY_DIR/original-input.txt"
    log "Input: inline description → normalized to spec.json"
  fi

  touch "$HEARTBEAT_FILE"
}

update_state() {
  local phase="$1"
  local status="$2"
  local session_id="${3:-}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq --arg phase "$phase" \
     --arg status "$status" \
     --arg session "$session_id" \
     --arg ts "$ts" \
     '.phases[$phase].status = $status |
      .phases[$phase].session_id = $session |
      .updated_at = $ts |
      if $status == "in_progress" then .current_phase = $phase | .phases[$phase].started_at = $ts
      elif $status == "completed" then .phases[$phase].completed_at = $ts
      else . end |
      if $status == "in_progress" then .phases[$phase].iterations = (.phases[$phase].iterations + 1)
      else . end' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

update_gate() {
  local gate="$1"
  local passed="$2"
  local feedback="${3:-}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq --arg gate "$gate" \
     --argjson passed "$passed" \
     --arg feedback "$feedback" \
     --arg ts "$ts" \
     '.gates[$gate].passed = $passed | .gates[$gate].feedback = $feedback | .gates[$gate].evaluated_at = $ts' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

next_pending_phase() {
  local phases=("intake" "research" "design" "architecture" "planning" "implementation" "verification" "pr_assembly")

  for phase in "${phases[@]}"; do
    # Skip design phase if no design/stitch config in spec
    if [ "$phase" = "design" ]; then
      local has_design
      has_design=$(jq -r '.design // .stitch // empty' "$FACTORY_DIR/spec.json" 2>/dev/null)
      if [ -z "$has_design" ]; then
        local design_status
        design_status=$(jq -r '.phases.design.status' "$STATE_FILE" 2>/dev/null || echo "pending")
        if [ "$design_status" != "completed" ]; then
          update_state "design" "completed"
          update_gate "design" true "Skipped: no design config in spec"
        fi
        continue
      fi
    fi

    local status
    status=$(jq -r ".phases.\"$phase\".status" "$STATE_FILE" 2>/dev/null || echo "pending")
    if [ "$status" != "completed" ]; then
      echo "$phase"
      return 0
    fi
  done

  return 1  # All phases complete
}

get_iterations() {
  local phase="$1"
  jq -r ".phases.\"$phase\".iterations // 0" "$STATE_FILE" 2>/dev/null || echo "0"
}

write_alert() {
  local alert_type="$1"
  local message="$2"
  local phase="${3:-unknown}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq --arg type "$alert_type" \
     --arg msg "$message" \
     --arg phase "$phase" \
     --arg ts "$ts" \
     '.alerts = (.alerts // []) + [{"type": $type, "message": $msg, "phase": $phase, "timestamp": $ts}]' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  log_err "ALERT [$alert_type]: $message"
}

# --- Phase execution ---

# Retry config for transient API errors (529 overloaded, 500 server error, etc.)
API_RETRY_MAX="${API_RETRY_MAX:-5}"
API_RETRY_INITIAL_WAIT="${API_RETRY_INITIAL_WAIT:-30}"  # seconds

is_transient_api_error() {
  local output_file="$1"
  if [ ! -f "$output_file" ]; then
    return 1
  fi
  # Check for known transient errors in stream or json output
  if grep -qE '"overloaded_error"|"529"|"500"|"rate_limit"|"capacity"|"too_many_requests"|"server_error"' "$output_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

run_phase() {
  local phase="$1"
  local prompt="$2"
  local log_file="$LOG_DIR/${phase}.log"
  local stream_file="$LOG_DIR/${phase}.stream"
  local api_attempt=0
  local wait_time="$API_RETRY_INITIAL_WAIT"

  update_state "$phase" "in_progress" ""

  while [ "$api_attempt" -lt "$API_RETRY_MAX" ]; do
    api_attempt=$((api_attempt + 1))
    local session_name="factory-${phase}-$(date +%s)"

    if [ "$api_attempt" -gt 1 ]; then
      log_warn "API retry $api_attempt/$API_RETRY_MAX for phase: $phase (waiting ${wait_time}s)" >&2
      sleep "$wait_time"
      wait_time=$((wait_time * 2))  # exponential backoff
      if [ "$wait_time" -gt 300 ]; then
        wait_time=300  # cap at 5 minutes
      fi
    fi

    log "Starting phase: $phase (session: $session_name, attempt: $api_attempt)" >&2
    touch "$HEARTBEAT_FILE"

    # Clear previous attempt's files
    > "$stream_file" 2>/dev/null || true
    > "$log_file" 2>/dev/null || true

    # Stream output to file in real-time using stream-json format.
    # The stream file gets newline-delimited JSON events as they happen,
    # which factory-tail, factory-watch, and the frontend can tail for live feedback.
    #
    # IMPORTANT: We redirect directly to the stream file (no pipe to tee/jq).
    # Piping through tee | jq caused buffering delays where output would stall
    # for minutes at a time because libc buffers pipes in 4-8KB chunks.
    # The .log (plain text) is generated after the phase completes instead.
    # Build allowed tools list — add Pencil MCP tools for design phase, read-only for arch/impl
    local allowed_tools="Bash,Read,Edit,Write,Glob,Grep,Agent,WebSearch,WebFetch"
    if [ "$phase" = "design" ]; then
      allowed_tools="$allowed_tools,mcp__pencil__batch_design,mcp__pencil__batch_get,mcp__pencil__export_nodes,mcp__pencil__find_empty_space_on_canvas,mcp__pencil__get_editor_state,mcp__pencil__get_guidelines,mcp__pencil__get_screenshot,mcp__pencil__get_style_guide,mcp__pencil__get_style_guide_tags,mcp__pencil__get_variables,mcp__pencil__open_document,mcp__pencil__replace_all_matching_properties,mcp__pencil__search_all_unique_properties,mcp__pencil__set_variables,mcp__pencil__snapshot_layout"
    elif [ "$phase" = "architecture" ] || [ "$phase" = "implementation" ]; then
      if [ -f "$FACTORY_DIR/artifacts/design.pen" ]; then
        allowed_tools="$allowed_tools,mcp__pencil__batch_get,mcp__pencil__get_variables,mcp__pencil__get_screenshot,mcp__pencil__search_all_unique_properties,mcp__pencil__snapshot_layout,mcp__pencil__export_nodes,mcp__pencil__open_document"
      fi
    fi

    claude -p "$prompt" \
      --name "$session_name" \
      --dangerously-skip-permissions \
      --allowedTools "$allowed_tools" \
      $([ -n "$MAX_TURNS" ] && echo "--max-turns $MAX_TURNS") \
      --verbose \
      --output-format stream-json \
      2>"$log_file.stderr" \
      >> "$stream_file" &

    local claude_pid=$!

    # Heartbeat while claude runs — also detect output staleness
    local stream_stale_threshold=180  # kill claude if stream hasn't grown in 3 minutes
    if [ "$phase" = "design" ]; then
      stream_stale_threshold=300  # 5 minutes — Pencil runs locally, faster than remote APIs
    elif [ "$phase" = "architecture" ] || [ "$phase" = "planning" ]; then
      stream_stale_threshold=420  # 7 minutes — these phases need extended thinking time to produce large documents
    elif [ "$phase" = "implementation" ]; then
      stream_stale_threshold=300  # 5 minutes — builds, installs, and test runs can be slow
    fi
    local last_stream_size=0
    local stream_stale_since
    stream_stale_since=$(date +%s)
    local phase_start_ts
    phase_start_ts=$(date +%s)

    while kill -0 "$claude_pid" 2>/dev/null; do
      touch "$HEARTBEAT_FILE"

      # Phase wall-clock timeout
      local phase_elapsed=$(( $(date +%s) - phase_start_ts ))
      if [ "$phase_elapsed" -ge "$PHASE_TIMEOUT" ]; then
        log_warn "Phase '$phase' exceeded wall-clock timeout (${PHASE_TIMEOUT}s). Killing."
        kill "$claude_pid" 2>/dev/null || true
        sleep 3
        kill -9 "$claude_pid" 2>/dev/null || true
        write_alert "phase_timeout" "Phase '$phase' exceeded ${PHASE_TIMEOUT}s wall-clock limit" "$phase"
        break
      fi

      # Check if stream file is still growing
      local current_stream_size=0
      if [ -f "$stream_file" ]; then
        current_stream_size=$(wc -c < "$stream_file" | tr -d ' ')
      fi

      if [ "$current_stream_size" -gt "$last_stream_size" ]; then
        # Stream is growing — agent is active
        last_stream_size="$current_stream_size"
        stream_stale_since=$(date +%s)
      else
        # Stream hasn't grown — check how long
        local now
        now=$(date +%s)
        local stale_duration=$(( now - stream_stale_since ))

        if [ "$stale_duration" -ge "$stream_stale_threshold" ]; then
          log_warn "Agent output stale for ${stale_duration}s (stream stuck at ${current_stream_size} bytes). Killing hung claude process (PID $claude_pid)."
          kill "$claude_pid" 2>/dev/null || true
          sleep 3
          kill -9 "$claude_pid" 2>/dev/null || true
          break
        fi
      fi

      sleep 10
    done

    wait "$claude_pid" 2>/dev/null || true
    touch "$HEARTBEAT_FILE"

    # Extract plain text log from stream (post-processing, non-blocking)
    if [ -f "$stream_file" ]; then
      jq -r 'select(.type == "assistant" and .message.content != null) | .message.content[] | select(.type == "text") | .text // empty' \
        "$stream_file" > "$log_file" 2>/dev/null || true
    fi

    # Check stderr for fatal CLI errors (not API errors)
    if [ -s "$log_file.stderr" ] && grep -qE "^Error:" "$log_file.stderr" 2>/dev/null; then
      local cli_err
      cli_err=$(head -1 "$log_file.stderr")
      log_err "CLI error: $cli_err" >&2
    fi

    # Check if this was a transient API error
    if is_transient_api_error "$stream_file" || is_transient_api_error "$log_file.stderr"; then
      local err_type
      err_type=$(grep -oE '"overloaded_error"|"rate_limit"|"server_error"|"529"|"500"' "$stream_file" 2>/dev/null | head -1 || echo "unknown")
      log_warn "Transient API error ($err_type) on attempt $api_attempt/$API_RETRY_MAX" >&2

      if [ "$api_attempt" -ge "$API_RETRY_MAX" ]; then
        log_err "Exhausted $API_RETRY_MAX API retries for phase: $phase" >&2
        echo "api_error"
        return
      fi
      continue  # retry
    fi

    # Not a transient error — we got a real response (success or agent failure)
    break
  done

  # Extract session_id from stream
  local session_id
  session_id=$(grep -m1 '"session_id"' "$stream_file" 2>/dev/null | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

  echo "$session_id"
}

# --- Phase prompts ---

prompt_for_phase() {
  local phase="$1"
  local iterations
  iterations=$(get_iterations "$phase")
  local feedback
  feedback=$(jq -r ".gates.\"$phase\".feedback // \"\"" "$STATE_FILE" 2>/dev/null || echo "")

  local retry_context=""
  if [ "$iterations" -gt 0 ] && [ -n "$feedback" ]; then
    retry_context="IMPORTANT: This is retry #$iterations. Previous attempt failed with feedback: $feedback. Address this feedback specifically."
  fi

  case "$phase" in
    intake)
      echo "You are the factory orchestrator. Initialize the factory pipeline.
Read the spec at .factory/spec.json. Validate it has at least a name and description.
Create a git branch named factory/\$(feature-name-kebab-case).
Do NOT modify .factory/state.json — the runner manages pipeline state.

STOP CONDITION: Once the git branch is created and you have validated the spec, you are DONE.
Do NOT proceed to research, architecture, or any other phase. Do NOT read the codebase.
Do NOT spawn any agents. Just validate the spec, create the branch, and stop.
$retry_context"
      ;;
    research)
      # Check if design is configured — if so, researcher must also produce Required Screens section
      local design_context_research=""
      local has_design_for_research
      has_design_for_research=$(jq -r '.design // .stitch // empty' "$FACTORY_DIR/spec.json" 2>/dev/null)
      if [ -n "$has_design_for_research" ]; then
        design_context_research="
IMPORTANT: This project uses Pencil design integration. Your research.md MUST include a '## Required Screens' section.
Analyze the spec and determine every UI screen/page needed. For each screen, document:
- Screen name (kebab-case slug, e.g., 'therapist-dashboard')
- Description (1-2 sentences of what it shows)
- Key UI elements (tables, forms, cards, charts, modals, etc.)
- Which spec requirement it satisfies
Format as a markdown table. This list drives the design generation phase."
      fi
      echo "You are the researcher agent. Explore this codebase and produce research findings.
Read .factory/spec.json to understand what feature we're building.
Analyze the codebase conventions, patterns, and constraints.
Write detailed findings to .factory/artifacts/research.md.
Include specific file paths and code examples for every convention you document.
$design_context_research
STOP CONDITION: Once you have written .factory/artifacts/research.md, you are DONE.
Do NOT proceed to architecture, planning, or implementation. Do NOT design solutions.
Do NOT write any code. Just produce the research document and stop.
$retry_context"
      ;;
    design)
      local pen_file
      pen_file=$(jq -r '.design.penFile // .stitch.penFile // ""' "$FACTORY_DIR/spec.json" 2>/dev/null)
      local topic
      topic=$(jq -r '.design.topic // "web-app"' "$FACTORY_DIR/spec.json" 2>/dev/null)
      local style_tags
      style_tags=$(jq -r '.design.styleTags // [] | join(", ")' "$FACTORY_DIR/spec.json" 2>/dev/null)
      local style_guide
      style_guide=$(jq -r '.design.styleGuide // ""' "$FACTORY_DIR/spec.json" 2>/dev/null)
      local design_brief
      design_brief=$(jq -r '.design.designBrief // .stitch.designBrief // ""' "$FACTORY_DIR/spec.json" 2>/dev/null)

      if [ -n "$pen_file" ]; then
        # Path B: Ingest existing .pen file
        echo "You are the designer agent. Ingest designs from an existing Pencil file.
Read .factory/spec.json for the feature requirements.
Read .factory/artifacts/research.md for codebase context and the Required Screens section.

Existing Pencil file: $pen_file
Topic: $topic
${style_tags:+Style tags: $style_tags}

Follow the Path B (Ingest + Validate) protocol from your AGENT.md:
1. Open the existing document via mcp__pencil__open_document with the pen file path
2. Discover all existing screens/frames via mcp__pencil__batch_get
3. Extract design variables via mcp__pencil__get_variables
4. Validate that all Required Screens from research.md are covered
5. Generate any missing screens via mcp__pencil__batch_design
6. Copy the source .pen file to .factory/artifacts/design.pen
7. Validate screens visually via mcp__pencil__get_screenshot, then export to disk via mcp__pencil__export_nodes
8. Write .factory/artifacts/design-system.md from Pencil variables and properties
9. Write .factory/artifacts/design-manifest.json with all screen metadata and node IDs
${design_brief:+
Additional design direction: $design_brief}

Touch .factory/heartbeat before each Pencil operation. Print progress between calls.
STOP CONDITION: Once all 4 artifacts are written (design.pen, design-system.md, design-manifest.json, screenshots), you are DONE.
Do NOT proceed to architecture. Do NOT design the solution. Just produce design artifacts and stop.
$retry_context"
      else
        # Path A: Generate new designs
        echo "You are the designer agent. Generate designs from scratch using Pencil.
Read .factory/spec.json for the feature requirements.
Read .factory/artifacts/research.md for codebase context and the Required Screens section.

Topic: $topic
${style_tags:+Style tags: $style_tags}
${style_guide:+Style guide: $style_guide}

Follow the Path A (Generate) protocol from your AGENT.md:
1. Get design guidelines via mcp__pencil__get_guidelines for topic '$topic'
2. Get style guide via mcp__pencil__get_style_guide${style_tags:+ with tags: $style_tags}
3. Open a new document directly at .factory/artifacts/design.pen via mcp__pencil__open_document (all batch_design calls auto-save to this file)
4. Set design variables (colors, typography, spacing) via mcp__pencil__set_variables
5. Design all screens from the Required Screens section via mcp__pencil__batch_design (max 25 ops per call)
6. Validate each screen visually via mcp__pencil__get_screenshot (inline preview only)
7. Export screenshots to disk via mcp__pencil__export_nodes for each screen to .factory/artifacts/screens/{name}/
8. Write .factory/artifacts/design-system.md from Pencil variables and properties
9. Write .factory/artifacts/design-manifest.json with all screen metadata and node IDs
${design_brief:+
Additional design direction: $design_brief}

Touch .factory/heartbeat before each Pencil operation. Print progress between calls.
STOP CONDITION: Once all 4 artifacts are written (design.pen, design-system.md, design-manifest.json, screenshots), you are DONE.
Do NOT proceed to architecture. Do NOT design the solution. Just produce design artifacts and stop.
$retry_context"
      fi
      ;;
    architecture)
      # Check if design artifacts exist (Pencil design integration was used)
      local design_context=""
      if [ -f "$FACTORY_DIR/artifacts/design-system.md" ]; then
        design_context="
IMPORTANT: Pencil design artifacts exist. Read these for design reference:
- .factory/artifacts/design-system.md — the canonical design system (colors, typography, spacing)
- .factory/artifacts/design-manifest.json — screen-to-requirement mapping with screen names, node IDs, and descriptions
- .factory/artifacts/screens/*/screenshot.png — view screenshots for visual reference
Use the design system as your Visual Design reference. Do NOT invent a new design system.
Reference screen names from the manifest when mapping components.
If you need precise CSS values (colors, fonts, spacing), query the Pencil file:
- Use mcp__pencil__open_document to open .factory/artifacts/design.pen
- Use mcp__pencil__batch_get with node IDs from the manifest to inspect specific elements
- Use mcp__pencil__search_all_unique_properties to extract all colors/fonts/spacing used
- Use mcp__pencil__get_variables for design token values"
      fi
      echo "You are the architect agent. Design the solution for this feature.
Read .factory/spec.json for the feature requirements.
Read .factory/artifacts/research.md for codebase conventions and patterns.
Design the data model, API contracts, frontend components, and integration points.

IMPORTANT: Write your architecture document EARLY. Do not spend excessive time reading files.
Read what you need, then write .factory/artifacts/architecture.md as your FIRST and PRIMARY action.
The document should cover: data model, API routes, component tree, AI pipeline, auth flow, and tech decisions.
$design_context
STOP CONDITION: Once you have written .factory/artifacts/architecture.md, you are DONE.
Do NOT proceed to planning or implementation. Do NOT write code or tests.
Do NOT decompose into tasks. Just produce the architecture document and stop.
$retry_context"
      ;;
    planning)
      echo "You are the architect agent. Decompose the architecture into implementation tasks.
Read .factory/artifacts/architecture.md for the design. If architecture.md does not exist (it may have
been force-advanced), use .factory/artifacts/research.md and .factory/spec.json as your architectural
source — they contain the technical decisions, data model, and integration points needed.
Break it into ordered tasks with dependencies, acceptance criteria, and TDD specs.
Each task should be independently testable.
Write the plan to .factory/artifacts/plan.md.

STOP CONDITION: Once you have written .factory/artifacts/plan.md, you are DONE.
Do NOT proceed to implementation. Do NOT write code or tests.
Just produce the plan document and stop.
$retry_context"
      ;;
    implementation)
      # Check which tasks are already done so the agent can skip them
      local done_tasks=""
      if [ -d "$FACTORY_DIR/artifacts/tasks" ]; then
        done_tasks=$(ls "$FACTORY_DIR/artifacts/tasks"/task-*-complete.md 2>/dev/null \
          | sed 's/.*task-\(.*\)-complete\.md/\1/' \
          | tr '\n' ', ' \
          | sed 's/,$//')
      fi
      local resume_context=""
      if [ -n "$done_tasks" ]; then
        resume_context="IMPORTANT: Tasks [$done_tasks] are already completed. Check .factory/artifacts/tasks/ for their completion reports. Skip these and continue with the NEXT uncompleted task. Do NOT redo work that is already done."
      fi
      # Check if Pencil design screenshots exist for design reference
      local design_impl_context=""
      if [ -d "$FACTORY_DIR/artifacts/screens" ] && [ "$(find "$FACTORY_DIR/artifacts/screens/" -name "screenshot.png" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
        design_impl_context="
IMPORTANT: Pencil design references exist:
- Screenshots at .factory/artifacts/screens/*/screenshot.png — view for visual reference
- Design system at .factory/artifacts/design-system.md — use for design tokens
- Design manifest at .factory/artifacts/design-manifest.json — screen-to-node mapping
Before implementing each frontend component, view the corresponding screenshot for visual reference.
For precise design values, query the Pencil file (.factory/artifacts/design.pen):
- Use mcp__pencil__open_document to open the .pen file
- Use mcp__pencil__batch_get with the screen's node ID from the manifest to get structure and properties
- Use mcp__pencil__search_all_unique_properties for exact color/font/spacing values
The implementation should be visually faithful to the Pencil designs."
      fi
      echo "You are the implementer. Execute ALL tasks in .factory/artifacts/plan.md.
Read research.md for conventions. Read architecture.md if it exists, otherwise use research.md for architectural guidance.
$design_impl_context
For each task in dependency order:
1. Write failing tests first (Red)
2. Implement to make them pass (Green)
3. Refactor for cleanliness
4. Write completion report to .factory/artifacts/tasks/task-{id}-complete.md

Run tests after each task. All tests must pass.
You MUST complete EVERY task in the plan. Do not stop early.

CRITICAL BUILD ERROR RULES:
- If a build or install command fails, try to fix it ONCE with a targeted approach.
- If the same build error persists after 3 attempts, MOVE ON to the next task. Do not enter a retry loop.
- Write the task completion report noting the build issue, then proceed.
- Never downgrade major framework versions (e.g. Next.js 15 → 14) to fix build issues. Fix the root cause or skip the build verification step.
- For Next.js projects: avoid running 'next build' as a verification step during scaffolding. Use 'next dev' or 'tsc --noEmit' for type-checking instead.

STOP CONDITION: Once every task has a completion report in .factory/artifacts/tasks/ and all tests pass, you are DONE.
Do NOT proceed to verification or review. Do NOT write review.md. Just implement and stop.
$resume_context
$retry_context"
      ;;
    verification)
      echo "You are the reviewer agent. Review all implementation work.
Read research.md for conventions. Read architecture.md for design if it exists, otherwise use research.md. Read plan.md for acceptance criteria.
Run the full test suite, linter, and type checker.
Check for security issues, convention violations, and missing test coverage.
Write your review to .factory/artifacts/review.md with a PASS or FAIL verdict.

STOP CONDITION: Once you have written .factory/artifacts/review.md with your verdict, you are DONE.
Do NOT fix code. Do NOT create PRs. Do NOT modify any source files. Just review and stop.
$retry_context"
      ;;
    pr_assembly)
      echo "You are the orchestrator. Assemble the final deliverables.
All phases are complete and verified. Now:

1. Create a README.md at the project root with:
   - Project name and one-paragraph description
   - Prerequisites (languages, tools, versions needed)
   - Environment variables: list EVERY env var the app needs with descriptions and example values. Check .env.example, config files, docker-compose.yml, and source code for all references to env vars.
   - Setup instructions: step-by-step to get running locally. If a Makefile exists, the primary instructions should use make commands (make setup, make dev, make test). Also document manual steps for users without make.
   - How to run: the exact commands to start the app. If a Makefile exists, lead with 'make dev'. For multi-service projects, document how to run services individually too.
   - How to run tests: the exact commands. If a Makefile exists, lead with 'make test'.
   - Available make targets: if a Makefile exists, include the output of 'make help' or list all targets with descriptions.
   - API documentation: list all endpoints with method, path, auth requirements, and brief description
   - Architecture overview: brief description of the system components and how they connect

2. Create a QA.md at the project root with:
   - Manual testing checklist: step-by-step scenarios to verify the app works (with expected results)
   - Test accounts or seed data needed
   - Known limitations or incomplete features
   - What was auto-generated vs what needs human attention

3. Stage all changes with git add (do NOT add .factory/ directory)
4. Create clean commits with descriptive messages
5. Do NOT push or create a PR — just commit locally

STOP CONDITION: Once README.md and QA.md are created and changes are committed, you are DONE.
Do NOT write to .factory/done — the runner handles that.
$retry_context"
      ;;
  esac
}

# --- Gate evaluation ---

evaluate_gate() {
  local phase="$1"

  case "$phase" in
    intake)
      if [ -f "$FACTORY_DIR/spec.json" ]; then
        update_gate "intake" true ""
        return 0
      fi
      update_gate "intake" false "Spec file not found in .factory/"
      return 1
      ;;
    research)
      if [ -f "$FACTORY_DIR/artifacts/research.md" ]; then
        local size
        size=$(wc -c < "$FACTORY_DIR/artifacts/research.md" | tr -d ' ')
        if [ "$size" -gt 500 ]; then
          # If design is configured, verify Required Screens section exists
          local has_design_research
          has_design_research=$(jq -r '.design // .stitch // empty' "$FACTORY_DIR/spec.json" 2>/dev/null)
          if [ -n "$has_design_research" ]; then
            if ! grep -q "Required Screens\|## Required Screens" "$FACTORY_DIR/artifacts/research.md"; then
              update_gate "research" false "research.md missing Required Screens section (needed for design integration)"
              return 1
            fi
          fi
          update_gate "research" true ""
          return 0
        fi
        update_gate "research" false "research.md is too short ($size bytes). Need detailed findings with file paths."
        return 1
      fi
      update_gate "research" false "research.md artifact not found"
      return 1
      ;;
    design)
      if [ ! -f "$FACTORY_DIR/artifacts/design.pen" ]; then
        update_gate "design" false "design.pen not found in .factory/artifacts/"
        return 1
      fi
      local manifest="$FACTORY_DIR/artifacts/design-manifest.json"
      if [ ! -f "$manifest" ]; then
        update_gate "design" false "design-manifest.json not found"
        return 1
      fi
      if [ ! -f "$FACTORY_DIR/artifacts/design-system.md" ]; then
        update_gate "design" false "design-system.md not found"
        return 1
      fi
      local ds_size
      ds_size=$(wc -c < "$FACTORY_DIR/artifacts/design-system.md" | tr -d ' ')
      if [ "$ds_size" -lt 200 ]; then
        update_gate "design" false "design-system.md too short ($ds_size bytes). Need color tokens, typography, spacing."
        return 1
      fi
      local screen_count
      screen_count=$(find "$FACTORY_DIR/artifacts/screens/" -name "screenshot.png" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$screen_count" -eq 0 ]; then
        update_gate "design" false "No screen screenshots found in .factory/artifacts/screens/"
        return 1
      fi
      update_gate "design" true ""
      return 0
      ;;
    architecture)
      if [ -f "$FACTORY_DIR/artifacts/architecture.md" ]; then
        local size
        size=$(wc -c < "$FACTORY_DIR/artifacts/architecture.md" | tr -d ' ')
        if [ "$size" -gt 500 ]; then
          update_gate "architecture" true ""
          return 0
        fi
        update_gate "architecture" false "architecture.md is too short. Need data model, API contracts, and integration points."
        return 1
      fi
      update_gate "architecture" false "architecture.md artifact not found"
      return 1
      ;;
    planning)
      if [ -f "$FACTORY_DIR/artifacts/plan.md" ]; then
        if grep -q "Task\|task" "$FACTORY_DIR/artifacts/plan.md"; then
          update_gate "plan" true ""
          return 0
        fi
        update_gate "plan" false "plan.md doesn't contain task definitions"
        return 1
      fi
      update_gate "plan" false "plan.md artifact not found"
      return 1
      ;;
    implementation)
      local task_count
      task_count=$(find "$FACTORY_DIR/artifacts/tasks/" -name "task-*-complete.md" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$task_count" -eq 0 ]; then
        # Check if meaningful code was written despite no completion reports
        # (agent may have done work but crashed before writing reports)
        local src_files
        src_files=$(find "$PROJECT_DIR/src" -name "*.ts" -o -name "*.tsx" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$src_files" -gt 20 ]; then
          update_gate "implementation" false "No task completion reports found, but $src_files source files exist. Agent may have crashed before writing reports. Resume to write completion reports for finished work."
        else
          update_gate "implementation" false "No task completion reports found in .factory/artifacts/tasks/. Ensure each completed task writes task-{id}-complete.md."
        fi
        return 1
      fi
      # Check how many tasks the plan defined vs how many are done
      local planned_tasks
      planned_tasks=$(grep -cE "^###? Task [0-9]" "$FACTORY_DIR/artifacts/plan.md" 2>/dev/null || echo "0")
      if [ "$planned_tasks" -gt 0 ] && [ "$task_count" -lt "$planned_tasks" ]; then
        update_gate "implementation" false "Only $task_count of $planned_tasks tasks completed. Missing tasks need implementation."
        return 1
      fi
      update_gate "implementation" true ""
      return 0
      ;;
    verification)
      if [ -f "$FACTORY_DIR/artifacts/review.md" ]; then
        # Check the verdict line — agents may format as "## Verdict: PASS" or "**Verdict: PASS**"
        if grep -qiE "Verdict.*PASS" "$FACTORY_DIR/artifacts/review.md" && ! grep -qiE "Verdict.*FAIL" "$FACTORY_DIR/artifacts/review.md"; then
          update_gate "verification" true ""
          return 0
        fi
        local fixes
        fixes=$(grep -A5 "Required Fixes\|Required for PASS\|Summary" "$FACTORY_DIR/artifacts/review.md" 2>/dev/null | tail -10 || echo "See review.md")
        update_gate "verification" false "Review verdict: FAIL. $fixes"
        return 1
      fi
      update_gate "verification" false "review.md artifact not found"
      return 1
      ;;
    pr_assembly)
      # Check that README.md and QA.md were created
      if [ -f "$PROJECT_DIR/README.md" ] && [ -f "$PROJECT_DIR/QA.md" ]; then
        return 0
      fi
      local missing=""
      [ ! -f "$PROJECT_DIR/README.md" ] && missing="README.md "
      [ ! -f "$PROJECT_DIR/QA.md" ] && missing="${missing}QA.md"
      update_gate "pr_assembly" false "Missing deliverables: $missing"
      return 1
      ;;
  esac
}

# --- Main loop ---

main() {
  check_claude_cli
  check_auth_expiry
  init_factory

  log "Factory started. Input: $SPEC_INPUT"

  local factory_start_ts
  factory_start_ts=$(date +%s)

  while true; do
    # Factory-level wall-clock timeout
    local factory_elapsed=$(( $(date +%s) - factory_start_ts ))
    if [ "$factory_elapsed" -ge "$FACTORY_TIMEOUT" ]; then
      log_err "Factory exceeded wall-clock timeout (${FACTORY_TIMEOUT}s / $((FACTORY_TIMEOUT / 3600))h). Halting."
      write_alert "timeout" "Factory exceeded $((FACTORY_TIMEOUT / 3600))h wall-clock limit after ${factory_elapsed}s" "factory"
      break
    fi

    local phase
    if ! phase=$(next_pending_phase); then
      log_ok "All phases complete!"

      # Stop preview process if running
      if [ -f "$FACTORY_DIR/preview.json" ]; then
        preview_pid=$(jq -r '.pid // ""' "$FACTORY_DIR/preview.json" 2>/dev/null)
        if [ -n "$preview_pid" ] && kill -0 "$preview_pid" 2>/dev/null; then
          log "Stopping preview (PID $preview_pid)"
          kill "$preview_pid" 2>/dev/null || true
        fi
      fi

      touch "$FACTORY_DIR/done"
      break
    fi

    local iterations
    iterations=$(get_iterations "$phase")
    if [ "$iterations" -ge "$MAX_ITERATIONS" ]; then
      log_err "Phase '$phase' exceeded max iterations ($MAX_ITERATIONS). Skipping."
      write_alert "max_iterations" "Phase '$phase' exceeded $MAX_ITERATIONS iterations — force-advancing" "$phase"
      update_state "$phase" "completed"
      continue
    fi

    log "Phase: $phase (iteration $((iterations + 1))/$MAX_ITERATIONS)"

    # Get the prompt for this phase
    local prompt
    prompt=$(prompt_for_phase "$phase")

    # Run the phase
    local session_id
    session_id=$(run_phase "$phase" "$prompt")

    # Check for API-level failure (all retries exhausted)
    if [ "$session_id" = "api_error" ]; then
      log_err "Phase '$phase' failed due to API errors (all retries exhausted). Will retry on next loop."
      update_state "$phase" "failed" ""
      # Don't count this against the phase iteration limit — it's not the agent's fault
      jq --arg phase "$phase" \
         '.phases[$phase].iterations = ([.phases[$phase].iterations - 1, 0] | max)' \
         "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      # Wait before retrying the whole phase (API might still be overloaded)
      log "Waiting 60s before retrying phase '$phase'..."
      sleep 60
      continue
    fi

    # Evaluate the gate
    if evaluate_gate "$phase"; then
      log_ok "Phase '$phase' PASSED gate check"
      update_state "$phase" "completed" "$session_id"
    else
      local feedback
      feedback=$(jq -r ".gates.\"$phase\".feedback // \"Unknown failure\"" "$STATE_FILE")
      log_warn "Phase '$phase' FAILED gate check: $feedback"
      update_state "$phase" "failed" "$session_id"

      # Check for reroute file
      if [ -f "$FACTORY_DIR/reroute.json" ]; then
        local target
        target=$(jq -r '.to' "$FACTORY_DIR/reroute.json")
        local reason
        reason=$(jq -r '.reason' "$FACTORY_DIR/reroute.json")
        log_warn "Reroute requested: back to '$target' — $reason"
        update_state "$target" "pending"
        rm "$FACTORY_DIR/reroute.json"
      fi

      # Cycle detection: if same feedback as last iteration, increment stuck counter
      local prev_cycle_count
      prev_cycle_count=$(jq -r ".cycle_detection.\"$phase\".count // 0" "$STATE_FILE" 2>/dev/null || echo "0")
      local prev_cycle_feedback
      prev_cycle_feedback=$(jq -r ".cycle_detection.\"$phase\".feedback // \"\"" "$STATE_FILE" 2>/dev/null || echo "")

      if [ "$feedback" = "$prev_cycle_feedback" ] && [ -n "$feedback" ]; then
        prev_cycle_count=$((prev_cycle_count + 1))
      else
        prev_cycle_count=1
      fi

      # Store current feedback and count for next iteration comparison
      jq --arg phase "$phase" --argjson count "$prev_cycle_count" --arg fb "$feedback" \
         '.cycle_detection[$phase] = {"count": $count, "feedback": $fb}' \
         "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

      if [ "$prev_cycle_count" -ge 3 ]; then
        log_err "Phase '$phase' stuck in cycle: same failure $prev_cycle_count consecutive times. Force-advancing."
        write_alert "cycle" "Phase '$phase' failing with same error $prev_cycle_count times — force-advancing" "$phase"
        update_state "$phase" "completed"
        continue
      fi

      # Auto-reroute: when verification fails, route back to implementation
      # to fix the issues instead of re-running the reviewer on unchanged code
      if [ "$phase" = "verification" ]; then
        log_warn "Verification failed — routing back to implementation to fix issues"
        update_state "implementation" "pending"
        # Store the review feedback so the implementer knows what to fix
        jq --arg fb "$feedback" '.gates.implementation.feedback = $fb | .gates.implementation.passed = false' \
          "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      fi
    fi
  done

  # Final status
  if [ -f "$FACTORY_DIR/done" ]; then
    jq '.final_verdict = "pass" | .completed_at = (now | todate)' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log_ok "Factory completed successfully!"
  else
    log_err "Factory did not complete. Check .factory/state.json for status."
    exit 1
  fi
}

main "$@"
