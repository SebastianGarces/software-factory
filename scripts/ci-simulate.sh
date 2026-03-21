#!/bin/bash
# ci-simulate.sh — Run CI checks against the project
#
# Detects the project type and runs appropriate lint, typecheck, and test commands.
# Called by the reviewer agent and gate-check hook.
#
# Usage: ./scripts/ci-simulate.sh [project-dir]
# Exit code: 0 = all pass, 1 = failures found

set -uo pipefail

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
RESULTS=""

run_check() {
  local name="$1"
  local cmd="$2"

  echo "Running: $name"
  if eval "$cmd" > /tmp/ci-simulate-output.txt 2>&1; then
    RESULTS="${RESULTS}\n  PASS: $name"
    PASS=$((PASS + 1))
  else
    RESULTS="${RESULTS}\n  FAIL: $name"
    FAIL=$((FAIL + 1))
    echo "  Output:"
    head -20 /tmp/ci-simulate-output.txt | sed 's/^/    /'
    if [ "$(wc -l < /tmp/ci-simulate-output.txt)" -gt 20 ]; then
      echo "    ... (truncated, $(wc -l < /tmp/ci-simulate-output.txt | tr -d ' ') total lines)"
    fi
  fi
}

echo "=== CI Simulation ==="
echo "Project: $PROJECT_DIR"
echo ""

# Detect project type and run appropriate checks

# Node.js / TypeScript
if [ -f "package.json" ]; then
  echo "Detected: Node.js project"

  # Install deps if needed
  if [ ! -d "node_modules" ] && [ -f "package-lock.json" ]; then
    echo "Installing dependencies..."
    npm ci --quiet 2>/dev/null || npm install --quiet 2>/dev/null || true
  fi

  # Lint
  if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
    run_check "Lint (npm run lint)" "npm run lint"
  elif [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f "eslint.config.js" ]; then
    run_check "Lint (npx eslint)" "npx eslint . --max-warnings=0"
  fi

  # Type check
  if [ -f "tsconfig.json" ]; then
    run_check "TypeScript (tsc --noEmit)" "npx tsc --noEmit"
  fi

  # Tests
  if jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    run_check "Tests (npm test)" "npm test"
  elif [ -f "jest.config.js" ] || [ -f "jest.config.ts" ] || [ -f "vitest.config.ts" ]; then
    run_check "Tests (npx vitest)" "npx vitest run"
  fi

  # Build
  if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
    run_check "Build (npm run build)" "npm run build"
  fi
fi

# Python
if [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ]; then
  echo "Detected: Python project"

  # Lint
  if command -v ruff &>/dev/null; then
    run_check "Lint (ruff check)" "ruff check ."
  elif command -v flake8 &>/dev/null; then
    run_check "Lint (flake8)" "flake8 ."
  fi

  # Type check
  if command -v mypy &>/dev/null; then
    run_check "Type check (mypy)" "mypy ."
  fi

  # Tests
  if command -v pytest &>/dev/null; then
    run_check "Tests (pytest)" "pytest"
  fi
fi

# Go
if [ -f "go.mod" ]; then
  echo "Detected: Go project"

  run_check "Vet (go vet)" "go vet ./..."
  run_check "Tests (go test)" "go test ./..."

  if command -v golangci-lint &>/dev/null; then
    run_check "Lint (golangci-lint)" "golangci-lint run"
  fi
fi

# Report
echo ""
echo "=== Results ==="
echo -e "$RESULTS"
echo ""
echo "Passed: $PASS, Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All checks passed!"
  exit 0
fi
