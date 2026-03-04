#!/bin/bash
# Uninstall the runaway process monitor
set -euo pipefail

PLIST_NAME="com.beveradb.check-runaway-processes"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SCRIPT_PATH="$HOME/.local/bin/check-runaway-processes.sh"

echo "Uninstalling macOS Runaway Process Monitor..."

# Unload the agent
if launchctl list | grep -q "$PLIST_NAME"; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    echo "Unloaded launchd agent."
fi

# Remove files
[ -f "$PLIST_PATH" ] && rm "$PLIST_PATH" && echo "Removed $PLIST_PATH"
[ -f "$SCRIPT_PATH" ] && rm "$SCRIPT_PATH" && echo "Removed $SCRIPT_PATH"
[ -f "/tmp/runaway-processes-seen.txt" ] && rm "/tmp/runaway-processes-seen.txt"
[ -f "/tmp/check-runaway-processes.err" ] && rm "/tmp/check-runaway-processes.err"

echo ""
echo "Done! Monitor has been completely removed."
