# macOS Runaway Process Monitor

A lightweight background monitor for macOS that catches runaway processes — hogging CPU **or memory** — and asks you what to do about them.

Born out of frustration with `next-server` processes silently eating 130%+ CPU and gigabytes of RAM for hours (and, later, a Quick Look preview extension that burned a core and 7 GB of RAM for three days).

## How It Works

A bash script runs every 5 minutes via macOS `launchd`. Each check it:

1. Lists all processes with their CPU (`ps`) and memory footprint (`top` — includes compressed memory, like Activity Monitor; plain RSS badly under-reports leaks)
2. Flags any process above the CPU threshold (default 80% of a core) **or** the memory threshold (default 4 GB)
3. Applies your [rules](#rules) first — ignore it, throttle it, or pause it while on battery
4. Otherwise, after 2 consecutive hot checks (~10 min), shows a dialog with the process details:
   - **Ignore for now** — snoozes for 60 min, then asks again if it's *still* hot
   - **Quit Process** — `SIGTERM`, then `SIGKILL` if it hasn't exited after 10 s
   - **More…** — throttle now, pause for an hour, always pause on battery, always throttle, always ignore, open Activity Monitor, or force kill
5. Never silently drops an alert: if you're away (idle > 5 min) or the dialog times out unanswered, it posts a notification (kept in Notification Center) and asks again on the next check
6. Resumes paused processes when their pause expires or when you plug back in
7. Records every alert and action in `~/Library/Logs/runaway-monitor.log`

## Installation

```bash
git clone https://github.com/beveradb/macos-runaway-process-monitor.git
cd macos-runaway-process-monitor
./install.sh
```

This installs:
- `~/.local/bin/check-runaway-processes.sh` — the monitoring script, plus a `runaway-monitor` CLI symlink
- `~/.config/runaway-monitor/config` and `rules` — your settings (only created if they don't already exist)
- `~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist` — the launchd agent

Re-running `./install.sh` upgrades in place: it reloads the agent and keeps your config and rules.

## Uninstallation

```bash
./uninstall.sh
```

Resumes anything the monitor paused, then removes the script, CLI, agent and state. Your `~/.config/runaway-monitor` and history log are kept.

## Usage

Once installed it runs automatically. The `runaway-monitor` CLI (in `~/.local/bin`) manages it:

```bash
runaway-monitor status                        # settings, rules, paused/throttled/snoozed processes, recent events
runaway-monitor log 50                        # last 50 events
runaway-monitor pause-on-battery mediaanalysisd
runaway-monitor throttle 'Code Helper*'
runaway-monitor ignore '*ffmpeg*'
runaway-monitor unrule mediaanalysisd
runaway-monitor rules
runaway-monitor resume all                    # resume everything paused / throttled (or: resume <pid>)
runaway-monitor check                         # run one check now
```

### Rules

Rules live in `~/.config/runaway-monitor/rules`, one per line: `<action> <name or glob>`. The pattern matches the process name (`mediaanalysisd`) or its full path (`/usr/bin/run*`). First match wins.

| Action | Effect |
|--------|--------|
| `ignore` | Never alert |
| `throttle` | When hot, demote to background priority (`taskpolicy -b`: efficiency cores, low I/O) with a notification instead of a dialog. Undo with `runaway-monitor resume <pid>` |
| `pause-on-battery` | When hot on battery, pause it (`SIGSTOP`); resumed automatically on AC power. Left alone (no alert) on AC. Good for expected-but-expensive background work like `mediaanalysisd` / `photoanalysisd` |

Processes owned by root (e.g. `mds_stores`) can't be throttled, paused or quit without root; the monitor notifies once and doesn't retry.

### Start / Stop

```bash
launchctl unload ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist   # stop
launchctl load ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist     # start
```

## Configuration

Settings live in `~/.config/runaway-monitor/config` (sourced as bash; uncomment a line to override):

```bash
CPU_THRESHOLD=80          # % of one core; 200 = two full cores
MEM_THRESHOLD_MB=4096     # memory footprint (as Activity Monitor shows); 0 disables
STRIKES_TO_ALERT=2        # consecutive 5-min checks before alerting
SNOOZE_MINUTES=60         # "Ignore for now" asks again after this long if still hot
PAUSE_MINUTES=60          # length of a one-off "Pause" from the dialog
DIALOG_TIMEOUT=120        # seconds before an unanswered dialog gives up (it re-asks next check)
IDLE_SECONDS=300          # if you've been idle this long, post a notification instead of a dialog
QUIT_GRACE_SECONDS=10     # "Quit Process" waits this long after SIGTERM before SIGKILL
SOUND="Funk"              # any name from /System/Library/Sounds
```

The check interval is `StartInterval` (seconds) in the launchd plist; stop and start the agent after editing it.

## Debugging

```bash
launchctl list | grep beveradb                 # loaded? (PID or "-", then last exit status)
cat /tmp/check-runaway-processes.err           # script errors
runaway-monitor log                            # what was flagged, and what you chose
ls "$(getconf DARWIN_USER_TEMP_DIR)runaway-monitor"           # state: strikes, snoozed, paused, throttled
rm "$(getconf DARWIN_USER_TEMP_DIR)runaway-monitor/snoozed"   # un-snooze everything
plutil -lint ~/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist
```

State lives in your private per-user temp directory (`getconf DARWIN_USER_TEMP_DIR`); entries for exited processes are pruned every check. If you don't see notifications, check **System Settings → Notifications → Script Editor**.

## Development

Tests use [bats](https://github.com/bats-core/bats-core) with mocked `ps`, `osascript`, `pmset`, `taskpolicy`, `launchctl`, `lsof` and `open`:

```bash
brew install bats-core shellcheck
bats tests/
shellcheck *.sh
```

The script must stay compatible with macOS's built-in `/bin/bash` 3.2.

## How It Compares to Alternatives

| Tool | Pros | Cons |
|------|------|------|
| **This script** | Zero dependencies, native dialogs, rules, pause/throttle | Only checks every 5 minutes |
| Activity Monitor | Built-in, visual | Manual, no alerts |
| `top`/`htop` | Real-time | Requires terminal, no alerts |
| iStat Menus | Rich UI, historical graphs | Paid ($12), heavyweight |

## License

MIT
