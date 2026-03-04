#!/bin/bash
# Install the runaway process monitor on macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.beveradb.check-runaway-processes"

echo "Installing macOS Runaway Process Monitor..."

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy the monitoring script
cp "$SCRIPT_DIR/check-runaway-processes.sh" "$INSTALL_DIR/check-runaway-processes.sh"
chmod +x "$INSTALL_DIR/check-runaway-processes.sh"
echo "Installed script to $INSTALL_DIR/check-runaway-processes.sh"

# Generate the launchd plist
mkdir -p "$PLIST_DIR"
cat > "$PLIST_DIR/${PLIST_NAME}.plist" <<EOF
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
EOF
echo "Installed launchd plist to $PLIST_DIR/${PLIST_NAME}.plist"

# Load the agent
launchctl load "$PLIST_DIR/${PLIST_NAME}.plist"
echo "Loaded launchd agent."

echo ""
echo "Done! The monitor is now running and will check every 5 minutes."
echo "You'll get a macOS notification if any process exceeds 80% CPU."
