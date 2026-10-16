#!/bin/bash
# Uninstall the runaway process monitor
set -euo pipefail

PLIST_NAME="com.beveradb.check-runaway-processes"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SCRIPT_PATH="$HOME/.local/bin/check-runaway-processes.sh"
CLI_PATH="$HOME/.local/bin/runaway-monitor"
STATE_DIR="${RUNAWAY_STATE_DIR:-/tmp/runaway-monitor-$(id -u)}"

echo "Uninstalling macOS Runaway Process Monitor..."

# Unload the agent
if launchctl list | grep -q "$PLIST_NAME"; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    echo "Unloaded launchd agent."
fi

# Never leave processes frozen behind us
if [ -f "$SCRIPT_PATH" ]; then
    bash "$SCRIPT_PATH" resume all || true
fi

# Remove files (config in ~/.config/runaway-monitor and the history log are kept)
[ -f "$PLIST_PATH" ] && rm "$PLIST_PATH" && echo "Removed $PLIST_PATH"
[ -f "$SCRIPT_PATH" ] && rm "$SCRIPT_PATH" && echo "Removed $SCRIPT_PATH"
[ -L "$CLI_PATH" ] && rm "$CLI_PATH" && echo "Removed $CLI_PATH"
[ -d "$STATE_DIR" ] && rm -rf "$STATE_DIR"
rm -f /tmp/runaway-processes-seen.txt /tmp/runaway-processes-strikes.txt /tmp/check-runaway-processes.err

echo ""
echo "Done! Monitor has been removed."
echo "Your config and rules are kept in ~/.config/runaway-monitor (delete it to remove them)."
