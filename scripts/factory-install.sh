#!/bin/bash
# factory-install.sh — Install factory as a macOS launchd service
#
# Creates a launchd plist that runs factory-heartbeat.sh as a persistent
# background service. Survives terminal closure, user logout (if configured),
# and process crashes (auto-restart via KeepAlive).
#
# Usage: ./scripts/factory-install.sh path/to/spec.json [project-dir]
#
# To uninstall: ./scripts/factory-install.sh --uninstall
#
# Inspired by OpenClaw's src/daemon/launchd.ts

set -euo pipefail

LABEL="com.software-factory.runner"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEARTBEAT_SCRIPT="$SCRIPT_DIR/factory-heartbeat.sh"

if [ "${1:-}" = "--uninstall" ]; then
  echo "Uninstalling factory service..."
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "Uninstalled."
  exit 0
fi

SPEC_INPUT="${1:?Usage: factory-install.sh <spec-file> [project-dir]}"
PROJECT_DIR="${2:-.}"

# Resolve absolute paths
SPEC_INPUT="$(cd "$(dirname "$SPEC_INPUT")" && pwd)/$(basename "$SPEC_INPUT")"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

echo "Installing factory as launchd service..."
echo "  Spec: $SPEC_INPUT"
echo "  Project: $PROJECT_DIR"
echo "  Plist: $PLIST_PATH"

# Unload existing if present
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Create plist
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${HEARTBEAT_SCRIPT}</string>
    <string>${SPEC_INPUT}</string>
    <string>${PROJECT_DIR}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${PROJECT_DIR}</string>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>ThrottleInterval</key>
  <integer>30</integer>

  <key>StandardOutPath</key>
  <string>${PROJECT_DIR}/.factory/logs/launchd-stdout.log</string>

  <key>StandardErrorPath</key>
  <string>${PROJECT_DIR}/.factory/logs/launchd-stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin:$HOME/.nvm/versions/node/$(node -v 2>/dev/null || echo "v20.0.0")/bin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
EOF

# Ensure log directory exists
mkdir -p "$PROJECT_DIR/.factory/logs"

# Load the service
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo ""
echo "Factory service installed and started!"
echo ""
echo "Commands:"
echo "  Status:    launchctl print gui/$(id -u)/$LABEL"
echo "  Stop:      launchctl bootout gui/$(id -u)/$LABEL"
echo "  Logs:      tail -f $PROJECT_DIR/.factory/logs/launchd-stdout.log"
echo "  Errors:    tail -f $PROJECT_DIR/.factory/logs/launchd-stderr.log"
echo "  Uninstall: $0 --uninstall"
echo ""
echo "Monitor progress:"
echo "  ./scripts/factory-status.sh $PROJECT_DIR"
