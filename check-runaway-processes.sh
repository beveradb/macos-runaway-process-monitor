#!/bin/bash
# Alert on processes using >80% CPU for sustained periods
# Runs via launchd every 5 minutes

CPU_THRESHOLD=80
STRIKES_TO_ALERT=2  # consecutive cycles before alerting (~10 min at 5-min intervals)
LOG="/tmp/runaway-processes-seen.txt"
STRIKES="/tmp/runaway-processes-strikes.txt"
touch "$LOG" "$STRIKES"

# Track which PIDs are hot this cycle (for cleanup)
hot_pids=""

# Get processes over threshold (skip header, skip this script)
ps -eo pid,%cpu,etime,comm --no-headers 2>/dev/null || \
ps -eo pid,%cpu,etime,comm | tail -n +2 | while read -r pid cpu etime comm; do
    # Remove decimal from cpu for integer comparison
    cpu_int=${cpu%.*}
    if [ "$cpu_int" -ge "$CPU_THRESHOLD" ] 2>/dev/null; then
        # Already alerted for this PID — skip
        if grep -q "^${pid} " "$LOG" 2>/dev/null; then
            continue
        fi

        # Increment strike count for this PID
        current_strikes=$(grep "^${pid} " "$STRIKES" 2>/dev/null | awk '{print $2}')
        current_strikes=${current_strikes:-0}
        new_strikes=$((current_strikes + 1))

        # Update strikes file
        grep -v "^${pid} " "$STRIKES" > "$STRIKES.tmp" 2>/dev/null || true
        echo "${pid} ${new_strikes}" >> "$STRIKES.tmp"
        mv "$STRIKES.tmp" "$STRIKES"

        # Only alert after enough consecutive cycles
        if [ "$new_strikes" -lt "$STRIKES_TO_ALERT" ]; then
            continue
        fi

        # Gather detailed process info
        full_cmd=$(ps -o args= -p "$pid" 2>/dev/null || echo "unknown")
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        parent_cmd=$(ps -o args= -p "$ppid" 2>/dev/null | head -c 120 || echo "unknown")
        user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        mem=$(ps -o %mem= -p "$pid" 2>/dev/null | tr -d ' ')
        cwd=$(lsof -d cwd -a -p "$pid" -Fn 2>/dev/null | grep '^n/' | head -1 | sed 's/^n//' || echo "unknown")
        [ -z "$cwd" ] && cwd="unknown"
        open_files=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ')

        # Convert etime to human-readable (e.g. "05-02:32:20" -> "5d 2h 32m")
        human_time="$etime"
        if [[ "$etime" == *-* ]]; then
            days=${etime%%-*}
            rest=${etime#*-}
            hours=${rest%%:*}; rest=${rest#*:}
            mins=${rest%%:*}
            human_time="$((10#$days))d $((10#$hours))h $((10#$mins))m"
        elif [[ "$etime" == *:*:* ]]; then
            hours=${etime%%:*}; rest=${etime#*:}
            mins=${rest%%:*}
            human_time="$((10#$hours))h $((10#$mins))m"
        else
            human_time="${etime}m"
        fi

        # Use basename for the header, full path shown below
        short_name=$(basename "$comm")

        echo "${pid} ${cpu}% ${etime} ${comm}" >> "$LOG"

        details="${short_name} (PID ${pid})
CPU: ${cpu}%  |  Memory: ${mem}%  |  Uptime: ${human_time}
User: ${user}  |  Open files: ${open_files}  |  Parent PID: ${ppid}

Command:
${full_cmd}

Parent:
${parent_cmd}

Working directory:
${cwd}"

        # Sanitize for osascript (escape backslashes, quotes)
        safe_details=$(printf '%s' "$details" | sed 's/\\/\\\\/g; s/"/\\"/g')

        action=$(osascript -e "
            set theChoice to button returned of (display dialog \"${safe_details}\" with title \"Runaway Process Detected\" buttons {\"Ignore\", \"Activity Monitor\", \"Kill Process\"} default button \"Ignore\" with icon caution giving up after 60)
            return theChoice
        " 2>/dev/null)
        case "$action" in
            "Kill Process")
                kill -9 "$pid" 2>/dev/null
                osascript -e "display notification \"Killed ${comm} (PID ${pid})\" with title \"Process Killed\""
                ;;
            "Activity Monitor")
                open -a "Activity Monitor"
                ;;
        esac
    fi
done

# Clean up PIDs that no longer exist from seen file
if [ -f "$LOG" ]; then
    tmp=$(mktemp)
    while read -r line; do
        pid=${line%% *}
        kill -0 "$pid" 2>/dev/null && echo "$line"
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"
fi

# Clean up strikes for PIDs that are no longer hot or no longer exist
if [ -f "$STRIKES" ]; then
    tmp=$(mktemp)
    while read -r line; do
        pid=${line%% *}
        # Keep only if process still exists AND is still over threshold
        if kill -0 "$pid" 2>/dev/null; then
            current_cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
            cpu_int=${current_cpu%.*}
            if [ "$cpu_int" -ge "$CPU_THRESHOLD" ] 2>/dev/null; then
                echo "$line"
            fi
        fi
    done < "$STRIKES" > "$tmp"
    mv "$tmp" "$STRIKES"
fi
