#!/bin/bash
# Install the runaway process monitor on macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.beveradb.check-runaway-processes"
PLIST_PATH="$PLIST_DIR/${PLIST_NAME}.plist"
CONFIG_DIR="$HOME/.config/runaway-monitor"

echo "Installing macOS Runaway Process Monitor..."

# Stop a previous version first so the reload picks up the new script/plist
if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# Install the monitoring script, plus a friendlier CLI name
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/check-runaway-processes.sh" "$INSTALL_DIR/check-runaway-processes.sh"
chmod +x "$INSTALL_DIR/check-runaway-processes.sh"
ln -sf "$INSTALL_DIR/check-runaway-processes.sh" "$INSTALL_DIR/runaway-monitor"
echo "Installed script to $INSTALL_DIR/check-runaway-processes.sh (CLI: runaway-monitor)"

# Seed config + rules (never overwrite the user's edits)
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
    cp "$SCRIPT_DIR/config.example" "$CONFIG_DIR/config"
    echo "Created $CONFIG_DIR/config"
fi
if [ ! -f "$CONFIG_DIR/rules" ]; then
    cp "$SCRIPT_DIR/rules.example" "$CONFIG_DIR/rules"
    echo "Created $CONFIG_DIR/rules"
fi

# Generate the launchd plist
mkdir -p "$PLIST_DIR"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/check-runaway-processes.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/check-runaway-processes.err</string>
</dict>
</plist>
PLIST
echo "Installed launchd plist to $PLIST_PATH"

launchctl load "$PLIST_PATH"
echo "Loaded launchd agent."

echo ""
echo "Done! The monitor checks every 5 minutes."
echo "Run 'runaway-monitor status' to see settings, or 'runaway-monitor help' for commands."
