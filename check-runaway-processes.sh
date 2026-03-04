#!/bin/bash
# Alert on processes using >80% CPU for sustained periods
# Runs via launchd every 5 minutes

CPU_THRESHOLD=80
LOG="/tmp/runaway-processes-seen.txt"
touch "$LOG"

# Get processes over threshold (skip header, skip this script)
ps -eo pid,%cpu,etime,comm --no-headers 2>/dev/null || \
ps -eo pid,%cpu,etime,comm | tail -n +2 | while read -r pid cpu etime comm; do
    # Remove decimal from cpu for integer comparison
    cpu_int=${cpu%.*}
    if [ "$cpu_int" -ge "$CPU_THRESHOLD" ] 2>/dev/null; then
        # Only alert once per PID (reset on reboot via /tmp)
        if ! grep -q "^${pid}$" "$LOG" 2>/dev/null; then
            echo "$pid" >> "$LOG"
            osascript -e "display notification \"${comm} (PID ${pid}) at ${cpu}% CPU for ${etime}\" with title \"Runaway Process Detected\" sound name \"Funk\""
        fi
    fi
done

# Clean up PIDs that no longer exist
if [ -f "$LOG" ]; then
    tmp=$(mktemp)
    while read -r pid; do
        kill -0 "$pid" 2>/dev/null && echo "$pid"
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"
fi
