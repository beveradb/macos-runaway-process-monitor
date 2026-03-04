# macOS Runaway Process Monitor

A lightweight background monitor for macOS that detects runaway processes (high CPU usage) and sends native macOS notifications.

Born out of frustration with `next-server` processes silently eating 130%+ CPU and gigabytes of RAM for hours.

## How It Works

A bash script runs every 5 minutes via macOS `launchd` (the native task scheduler). It:

1. Lists all running processes and their CPU usage via `ps`
2. Identifies any process using more than the configured CPU threshold (default: 80%)
3. Sends a macOS notification (with sound) for each new offending process
4. Tracks which PIDs have already been reported to avoid repeat alerts
5. Cleans up tracked PIDs when processes exit

The tracking file (`/tmp/runaway-processes-seen.txt`) lives in `/tmp`, so it resets on reboot — meaning you'll get a fresh alert for any process that's still misbehaving after a restart.

## Installation

```bash
git clone https://github.com/beveradb/macos-runaway-process-monitor.git
cd macos-runaway-process-monitor
chmod +x install.sh
./install.sh
```

This installs:
- `~/.local/bin/check-runaway-processes.sh` — the monitoring script
- `~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist` — the launchd agent config

## Uninstallation

```bash
./uninstall.sh
```

## Usage

Once installed, it runs automatically in the background. No action needed — you'll see macOS notifications when a runaway process is detected.

### Start / Stop / Restart

```bash
# Stop the monitor
launchctl unload ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist

# Start the monitor
launchctl load ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist

# Restart (stop + start)
launchctl unload ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
launchctl load ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
```

### Run Manually (for testing)

```bash
bash ~/.local/bin/check-runaway-processes.sh
```

This runs one check immediately — useful for verifying the script works. If any process is above the threshold, you'll get a notification right away.

## Configuration

Edit `~/.local/bin/check-runaway-processes.sh` to change settings:

### CPU Threshold

```bash
CPU_THRESHOLD=80  # Alert when a process uses more than this % CPU
```

Common values:
- `50` — aggressive, catches moderate CPU hogs early
- `80` — balanced default, catches genuinely runaway processes
- `150` — relaxed, only alerts on processes saturating multiple cores

Note: on macOS, CPU % is per-core, so a process can exceed 100% if using multiple cores. A value of 200% means two full cores.

### Check Interval

Edit the plist at `~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist`:

```xml
<key>StartInterval</key>
<integer>300</integer>  <!-- seconds between checks (300 = 5 minutes) -->
```

After editing, restart the agent:
```bash
launchctl unload ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
launchctl load ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
```

### Notification Sound

In the script, change the sound name in the `osascript` line:

```bash
osascript -e "... sound name \"Funk\""
```

Available sounds are in `/System/Library/Sounds/` (e.g., `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`).

## Debugging

### Check if the agent is running

```bash
launchctl list | grep beveradb
```

If it shows a line with the label, the agent is loaded. The first column is the PID (or `-` if not currently executing), the second is the last exit status (0 = success).

### Check for errors

```bash
cat /tmp/check-runaway-processes.err
```

### See which PIDs have been flagged

```bash
cat /tmp/runaway-processes-seen.txt
```

### Reset alerts (get notified again for currently-running processes)

```bash
rm /tmp/runaway-processes-seen.txt
```

### Test the notification system

```bash
osascript -e 'display notification "Test notification" with title "Runaway Process Monitor" sound name "Funk"'
```

If you don't see a notification, check **System Settings > Notifications > Script Editor** and make sure notifications are enabled.

### Agent not starting after reboot?

Verify the plist is valid:
```bash
plutil -lint ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
```

## How It Compares to Alternatives

| Tool | Pros | Cons |
|------|------|------|
| **This script** | Zero dependencies, native notifications, ~30 lines | Only checks periodically, no historical data |
| Activity Monitor | Built-in, visual | Manual, no alerts |
| `top`/`htop` | Real-time | Requires terminal, no alerts |
| iStat Menus | Rich UI, historical graphs | Paid ($12), heavyweight |

## License

MIT
