#!/bin/bash
# macOS Runaway Process Monitor
#
# With no arguments (or `check`), runs one monitoring cycle — launchd runs this
# every 5 minutes. Other subcommands manage rules and paused processes; run
# `runaway-monitor help` for the list.
#
# Must stay compatible with macOS's /bin/bash 3.2 (no associative arrays etc).

set -u

CONFIG_DIR="${RUNAWAY_CONFIG_DIR:-$HOME/.config/runaway-monitor}"
# Per-user, mode-0700 temp dir (not shared /tmp, where another user could pre-create it)
STATE_DIR="${RUNAWAY_STATE_DIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$HOME/Library/Caches/")runaway-monitor}"
HISTORY_LOG="${RUNAWAY_HISTORY_LOG:-$HOME/Library/Logs/runaway-monitor.log}"

# --- Defaults (override in $CONFIG_DIR/config) ---
CPU_THRESHOLD=80          # % of one core; >100 means multiple cores
MEM_THRESHOLD_MB=4096     # memory footprint (as Activity Monitor shows); 0 disables
STRIKES_TO_ALERT=2        # consecutive hot cycles before alerting (~10 min)
SNOOZE_MINUTES=60         # "Ignore" re-alerts after this long if still hot
PAUSE_MINUTES=60          # duration of a one-off "Pause" from the dialog
DIALOG_TIMEOUT=120        # seconds before an unanswered dialog gives up
IDLE_SECONDS=300          # user idle longer than this → notify, don't pop a dialog
QUIT_GRACE_SECONDS=10     # SIGTERM grace period before SIGKILL
SOUND="Funk"

# shellcheck source=/dev/null
[ -f "$CONFIG_DIR/config" ] && . "$CONFIG_DIR/config"

RULES="$CONFIG_DIR/rules"
STRIKES="$STATE_DIR/strikes"       # pid count
SNOOZED="$STATE_DIR/snoozed"       # pid until_epoch comm
PAUSED="$STATE_DIR/paused"         # pid mode until_epoch comm   (mode: battery|timed|failed)
THROTTLED="$STATE_DIR/throttled"   # pid comm

# --- Small helpers (overridable in tests) ---

now_epoch() { date +%s; }
proc_alive() { kill -0 "$1" 2>/dev/null; }
signal_proc() { kill "-$1" "$2" 2>/dev/null; }
on_battery() { pmset -g batt 2>/dev/null | head -1 | grep -q "Battery Power"; }

user_idle_seconds() {
    local ns
    ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
    case "$ns" in ''|*[!0-9]*) echo 0 ;; *) echo $((ns / 1000000000)) ;; esac
}

notify() { # title message
    osascript -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)' \
        -e 'end run' "$1" "$2" "$SOUND" >/dev/null 2>&1
}

log_event() {
    mkdir -p "$(dirname "$HISTORY_LOG")"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HISTORY_LOG"
    # Keep the history bounded
    if [ "$(wc -l < "$HISTORY_LOG" | tr -d ' ')" -gt 2000 ]; then
        tail -n 1000 "$HISTORY_LOG" > "$HISTORY_LOG.tmp" && mv "$HISTORY_LOG.tmp" "$HISTORY_LOG"
    fi
}

# State files: one line per PID, "pid field...". PIDs are matched exactly.
state_get() { # file pid -> prints fields after pid
    [ -f "$1" ] || return 1
    local line
    line=$(grep "^$2 " "$1" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    printf '%s\n' "${line#* }"
}
state_del() {
    [ -f "$1" ] || return 0
    grep -v "^$2 " "$1" > "$1.tmp" 2>/dev/null
    mv "$1.tmp" "$1"
}
state_set() { # file pid fields...
    local file=$1 pid=$2
    shift 2
    state_del "$file" "$pid"
    printf '%s %s\n' "$pid" "$*" >> "$file"
}
state_prune_dead() { # drop lines whose PID no longer exists
    [ -f "$1" ] || return 0
    local line
    while read -r line; do
        [ -n "$line" ] && proc_alive "${line%% *}" && printf '%s\n' "$line"
    done < "$1" > "$1.tmp"
    mv "$1.tmp" "$1"
}

fmt_mb() {
    if [ "$1" -ge 1024 ]; then
        awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'
    else
        echo "$1 MB"
    fi
}

fmt_etime() { # ps etime ([[dd-]hh:]mm:ss) -> "2d 3h 4m"
    local e=$1 d=0 h=0 m=0 rest
    case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
    rest=$e
    case "$rest" in
        *:*:*) h=${rest%%:*}; rest=${rest#*:}; m=${rest%%:*} ;;
        *:*) m=${rest%%:*} ;;
    esac
    d=$((10#$d)); h=$((10#$h)); m=$((10#$m))
    if [ "$d" -gt 0 ]; then echo "${d}d ${h}h ${m}m"
    elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
    else echo "${m}m"
    fi
}

# --- Rules: "<action> <glob>" per line; first match wins ---
# Actions: ignore | throttle | pause-on-battery
# The glob is matched against the process name and against its full path.

rule_for() { # comm -> prints action
    [ -f "$RULES" ] || return 1
    local comm=$1 base=${1##*/} action pattern
    while read -r action pattern; do
        case "$action" in ''|\#*) continue ;; esac
        [ -n "$pattern" ] || continue
        # shellcheck disable=SC2254  # pattern is intentionally a glob
        case "$base" in $pattern) echo "$action"; return 0 ;; esac
        # shellcheck disable=SC2254
        case "$comm" in $pattern) echo "$action"; return 0 ;; esac
    done < "$RULES"
    return 1
}

add_rule() { # action pattern
    mkdir -p "$CONFIG_DIR"
    touch "$RULES"
    remove_rule "$2"
    printf '%s %s\n' "$1" "$2" >> "$RULES"
}

remove_rule() { # pattern
    [ -f "$RULES" ] || return 0
    local action pattern
    while IFS= read -r line; do
        read -r action pattern <<< "$line"
        case "$action" in ''|\#*) printf '%s\n' "$line"; continue ;; esac
        [ "$pattern" = "$1" ] || printf '%s\n' "$line"
    done < "$RULES" > "$RULES.tmp"
    mv "$RULES.tmp" "$RULES"
}

# --- Actions on processes ---

do_throttle() { # pid comm why
    if taskpolicy -b -p "$1" >/dev/null 2>&1; then
        state_set "$THROTTLED" "$1" "$2"
        log_event "THROTTLE pid=$1 ($3) $2"
        notify "Runaway process throttled" "${2##*/} (PID $1) moved to background priority ($3)"
    else
        if [ "$3" = "rule" ]; then
            # Remember the failure so the rule doesn't retry (and re-notify) every cycle
            state_set "$THROTTLED" "$1" "$2"
        else
            # Manual throttle failed: keep alerting for it later (it may need quitting instead)
            snooze "$1" "$SNOOZE_MINUTES" "$2"
        fi
        log_event "THROTTLE-FAILED pid=$1 $2"
        notify "Couldn't throttle process" "${2##*/} (PID $1) — it may be owned by another user"
    fi
}

do_pause() { # pid mode(battery|timed) comm why
    local until=0
    [ "$2" = "timed" ] && until=$(( $(now_epoch) + PAUSE_MINUTES * 60 ))
    if signal_proc STOP "$1"; then
        state_set "$PAUSED" "$1" "$2" "$until" "$3"
        log_event "PAUSE pid=$1 mode=$2 ($4) $3"
        if [ "$2" = "battery" ]; then
            notify "Process paused on battery" "${3##*/} (PID $1) will resume when you plug in"
        else
            notify "Process paused" "${3##*/} (PID $1) paused for ${PAUSE_MINUTES} min"
        fi
    else
        # Remember the failure for this PID so we don't retry (and re-notify) every cycle
        state_set "$PAUSED" "$1" failed 0 "$3"
        log_event "PAUSE-FAILED pid=$1 $3"
        notify "Couldn't pause process" "${3##*/} (PID $1) — it may be owned by another user"
    fi
}

resume_pid() { # pid why
    local fields comm
    fields=$(state_get "$PAUSED" "$1") || return 0
    # A failed pause never stopped the process: just forget it
    if [ "${fields%% *}" = failed ]; then state_del "$PAUSED" "$1"; return 0; fi
    comm=${fields#* }; comm=${comm#* }
    signal_proc CONT "$1"
    state_del "$PAUSED" "$1"
    log_event "RESUME pid=$1 ($2) $comm"
}

unthrottle_pid() {
    state_get "$THROTTLED" "$1" >/dev/null || return 0
    taskpolicy -B -p "$1" >/dev/null 2>&1
    state_del "$THROTTLED" "$1"
    log_event "UNTHROTTLE pid=$1"
}

resume_due() { # resume timed pauses that expired, and battery pauses once on AC
    [ -f "$PAUSED" ] || return 0
    local now pid mode until comm charging=1
    now=$(now_epoch)
    on_battery && charging=0
    # Read a snapshot so resume_pid can rewrite the file
    local snapshot
    snapshot=$(cat "$PAUSED")
    while read -r pid mode until comm; do
        [ -n "$pid" ] || continue
        if [ "$mode" = "battery" ] && [ "$charging" = 1 ]; then
            resume_pid "$pid" "on AC power"
        elif [ "$mode" = "timed" ] && [ "$now" -ge "$until" ]; then
            resume_pid "$pid" "pause expired"
        fi
    done <<< "$snapshot"
}

quit_proc() { # pid comm — SIGTERM, then SIGKILL after a grace period
    if ! signal_proc TERM "$1"; then
        log_event "QUIT-FAILED pid=$1 $2"
        notify "Couldn't quit process" "${2##*/} (PID $1) — it may be owned by another user (try: sudo kill $1)"
        snooze "$1" "$SNOOZE_MINUTES" "$2"
        return
    fi
    local i=0
    while [ "$i" -lt "$QUIT_GRACE_SECONDS" ] && proc_alive "$1"; do
        sleep 1
        i=$((i + 1))
    done
    if proc_alive "$1"; then
        signal_proc KILL "$1"
        log_event "KILL pid=$1 (ignored SIGTERM) $2"
        notify "Process force-killed" "${2##*/} (PID $1) ignored SIGTERM and was killed"
    else
        log_event "QUIT pid=$1 $2"
        notify "Process quit" "${2##*/} (PID $1) exited"
    fi
}

snooze() { # pid minutes comm
    state_set "$SNOOZED" "$1" "$(( $(now_epoch) + $2 * 60 ))" "$3"
}

# --- Dialogs ---

show_dialog() { # details -> prints button name, or GAVE_UP / ERROR
    osascript \
        -e 'on run argv' \
        -e 'set r to display dialog (item 1 of argv) with title "Runaway Process Detected" buttons {"Ignore for now", "More…", "Quit Process"} default button "Ignore for now" with icon caution giving up after (item 2 of argv as integer)' \
        -e 'if gave up of r then return "GAVE_UP"' \
        -e 'return button returned of r' \
        -e 'end run' "$1" "$DIALOG_TIMEOUT" 2>/dev/null || echo "ERROR"
}

choose_action() { # name -> prints chosen item or CANCEL
    local name=$1
    osascript \
        -e 'on run argv' \
        -e 'set r to choose from list (items 2 thru -1 of argv) with title "Runaway Process" with prompt (item 1 of argv) default items {item 2 of argv}' \
        -e 'if r is false then return "CANCEL"' \
        -e 'return item 1 of r' \
        -e 'end run' \
        "What should happen to ${name}?" \
        "Throttle now (background priority)" \
        "Pause for ${PAUSE_MINUTES} min" \
        "Always pause ${name} while on battery" \
        "Always throttle ${name}" \
        "Always ignore ${name}" \
        "Open Activity Monitor" \
        "Force kill now" 2>/dev/null || echo "CANCEL"
}

handle_more() { # pid comm
    local pid=$1 comm=$2 name=${2##*/} choice
    choice=$(choose_action "$name")
    log_event "CHOICE pid=$pid \"$choice\" $comm"
    case "$choice" in
        "Throttle now"*)      do_throttle "$pid" "$comm" "manual" ;;
        "Pause for"*)         do_pause "$pid" timed "$comm" "manual" ;;
        "Always pause"*)
            add_rule pause-on-battery "$name"
            if on_battery; then do_pause "$pid" battery "$comm" "rule"; fi ;;
        "Always throttle"*)
            add_rule throttle "$name"
            do_throttle "$pid" "$comm" "rule" ;;
        "Always ignore"*)     add_rule ignore "$name" ;;
        "Open Activity Monitor") open -a "Activity Monitor"; snooze "$pid" "$SNOOZE_MINUTES" "$comm" ;;
        "Force kill now")
            if signal_proc KILL "$pid"; then
                log_event "KILL pid=$pid (manual) $comm"
            else
                log_event "KILL-FAILED pid=$pid $comm"
                notify "Couldn't kill process" "$name (PID $pid) — it may be owned by another user (try: sudo kill -9 $pid)"
                snooze "$pid" "$SNOOZE_MINUTES" "$comm"
            fi ;;
        *)                    snooze "$pid" "$SNOOZE_MINUTES" "$comm" ;;
    esac
}

# Set to 1 once the user looks away, so later alerts this cycle don't stack dialogs
USER_AWAY=0

alert() { # pid cpu mem_mb etime comm reason
    local pid=$1 cpu=$2 mem_mb=$3 etime=$4 comm=$5 reason=$6
    local name=${comm##*/} full_cmd ppid parent_cmd user cpu_time cwd details choice

    full_cmd=$(ps -o args= -p "$pid" 2>/dev/null); [ -n "$full_cmd" ] || full_cmd="$comm"
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    parent_cmd=$(ps -o args= -p "${ppid:-1}" 2>/dev/null | head -c 120)
    user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    cpu_time=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
    cwd=$(lsof -d cwd -a -p "$pid" -Fn 2>/dev/null | grep '^n/' | head -1 | sed 's/^n//')

    log_event "ALERT pid=$pid $reason $comm"

    if [ "$USER_AWAY" = 1 ] || [ "$(user_idle_seconds)" -ge "$IDLE_SECONDS" ]; then
        # Nobody's looking: leave a notification and alert again next cycle
        USER_AWAY=1
        notify "Runaway process: $name" "$reason (PID $pid) — will ask again when you're back"
        return
    fi

    details="${name} (PID ${pid})
Why: ${reason}
CPU: ${cpu}%  |  Memory: $(fmt_mb "$mem_mb")  |  CPU time used: ${cpu_time:-?}
Running for: $(fmt_etime "$etime")  |  User: ${user:-?}  |  Parent PID: ${ppid:-?}

Command:
${full_cmd}

Parent:
${parent_cmd:-unknown}

Working directory:
${cwd:-unknown}"

    choice=$(show_dialog "$details")
    log_event "CHOICE pid=$pid \"$choice\" $comm"
    case "$choice" in
        "Quit Process")   quit_proc "$pid" "$comm" ;;
        "More…")          handle_more "$pid" "$comm" ;;
        "Ignore for now") snooze "$pid" "$SNOOZE_MINUTES" "$comm" ;;
        *)
            # Dialog timed out or failed: don't swallow the alert — notify, re-ask next cycle
            USER_AWAY=1
            notify "Runaway process: $name" "$reason (PID $pid) — unanswered, will ask again"
            ;;
    esac
}

# --- One monitoring cycle ---

# Prints "pid %cpu mem_mb etime comm" for every process.
# Memory is the larger of RSS (ps) and the memory footprint from top, which —
# like Activity Monitor — includes compressed/swapped pages. RSS alone badly
# under-reports leaks: a 6.9 GB leaking process can show ~190 MB resident.
process_snapshot() {
    {
        top -l 1 -o mem -n 50 -stats pid,mem 2>/dev/null
        echo "--PS--"
        ps -axo pid=,%cpu=,rss=,etime=,comm= 2>/dev/null
    } | awk '
        !in_ps && $0 == "--PS--" { in_ps = 1; next }
        !in_ps {
            if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+[BKMG]?[+-]?$/) {
                m = $2; sub(/[+-]$/, "", m)
                unit = substr(m, length(m)); v = m + 0
                if (unit == "G") v *= 1024
                else if (unit == "K") v /= 1024
                else if (unit == "B") v /= 1048576
                footprint[$1] = int(v)
            }
            next
        }
        {
            mb = int($3 / 1024)
            if (($1 in footprint) && footprint[$1] > mb) mb = footprint[$1]
            $3 = mb
            print
        }'
}


check() {
    # shellcheck disable=SC2174  # only the leaf needs 0700; its parent is already private
    mkdir -p -m 700 "$STATE_DIR"
    touch "$STRIKES" "$SNOOZED" "$PAUSED" "$THROTTLED"

    resume_due

    local snapshot now hot_pids="" pid cpu mem_mb etime comm cpu_int reason action strikes until
    snapshot=$(process_snapshot)
    now=$(now_epoch)

    # Read via fd 3 so dialogs/subcommands can't consume the process list
    while read -r pid cpu mem_mb etime comm <&3; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "$$" ] && continue
        cpu_int=${cpu%.*}
        case "$cpu_int" in ''|*[!0-9]*) continue ;; esac
        case "$mem_mb" in ''|*[!0-9]*) mem_mb=0 ;; esac

        reason=""
        [ "$cpu_int" -ge "$CPU_THRESHOLD" ] && reason="CPU ${cpu}% (limit ${CPU_THRESHOLD}%)"
        if [ "$MEM_THRESHOLD_MB" -gt 0 ] && [ "$mem_mb" -ge "$MEM_THRESHOLD_MB" ]; then
            reason="${reason:+$reason, }memory $(fmt_mb "$mem_mb") (limit $(fmt_mb "$MEM_THRESHOLD_MB"))"
        fi
        [ -n "$reason" ] || continue

        # Already handled: paused or throttled by us
        state_get "$PAUSED" "$pid" >/dev/null && continue
        state_get "$THROTTLED" "$pid" >/dev/null && continue

        action=$(rule_for "$comm")
        case "$action" in
            ignore) continue ;;
            throttle) do_throttle "$pid" "$comm" "rule"; continue ;;
            pause-on-battery)
                # Expected work: pause it on battery, leave it alone on AC
                if on_battery; then do_pause "$pid" battery "$comm" "rule"; fi
                continue ;;
        esac

        hot_pids="$hot_pids $pid "
        strikes=$(state_get "$STRIKES" "$pid"); strikes=$(( ${strikes:-0} + 1 ))
        state_set "$STRIKES" "$pid" "$strikes"
        [ "$strikes" -ge "$STRIKES_TO_ALERT" ] || continue

        until=$(state_get "$SNOOZED" "$pid"); until=${until%% *}
        [ -n "$until" ] && [ "$now" -lt "$until" ] && continue

        alert "$pid" "$cpu" "$mem_mb" "$etime" "$comm" "$reason" </dev/null
    done 3<<< "$snapshot"

    # Strikes only count consecutive hot cycles
    local line
    while read -r line; do
        [ -n "$line" ] || continue
        case "$hot_pids" in *" ${line%% *} "*) printf '%s\n' "$line" ;; esac
    done < "$STRIKES" > "$STRIKES.tmp"
    mv "$STRIKES.tmp" "$STRIKES"

    state_prune_dead "$SNOOZED"
    state_prune_dead "$PAUSED"
    state_prune_dead "$THROTTLED"
}

# --- CLI ---

usage() {
    cat <<EOF
Usage: runaway-monitor [command]

  check                      Run one monitoring cycle (default; launchd runs this)
  status                     Show settings, rules, paused/throttled/snoozed processes, recent events
  rules                      List rules
  ignore <name|glob>         Never alert for matching processes
  throttle <name|glob>       Auto-demote matching processes to background priority when hot
  pause-on-battery <glob>    Auto-pause (SIGSTOP) matching hot processes on battery; resume on AC
  unrule <name|glob>         Remove rules for a pattern
  resume [pid|all]           Resume paused / un-throttle processes (default: all)
  log [n]                    Show the last n events (default 30)
  help                       Show this help

Config: $CONFIG_DIR/config   Rules: $RULES   Log: $HISTORY_LOG
EOF
}

status() {
    echo "Thresholds: CPU ${CPU_THRESHOLD}%, memory $(fmt_mb "$MEM_THRESHOLD_MB") (0 = off), alert after ${STRIKES_TO_ALERT} cycles"
    echo "Power: $(on_battery && echo battery || echo AC)"
    echo
    echo "Rules ($RULES):"
    grep -v '^[[:space:]]*\(#\|$\)' "$RULES" 2>/dev/null | sed 's/^/  /' || true
    local f label
    for f in PAUSED THROTTLED SNOOZED; do
        eval "label=\$$f"
        echo
        echo "$(echo "$f" | tr '[:upper:]' '[:lower:]'):"
        [ -s "$label" ] && sed 's/^/  /' "$label" || echo "  (none)"
    done
    echo
    echo "Recent events:"
    tail -n 10 "$HISTORY_LOG" 2>/dev/null | sed 's/^/  /'
}

resume_cmd() {
    local target=${1:-all} pid
    # shellcheck disable=SC2174  # only the leaf needs 0700; its parent is already private
    mkdir -p -m 700 "$STATE_DIR"
    touch "$PAUSED" "$THROTTLED"
    if [ "$target" = "all" ]; then
        # shellcheck disable=SC2013  # PIDs are single words
        for pid in $(cut -d' ' -f1 "$PAUSED") ; do resume_pid "$pid" "manual"; echo "Resumed $pid"; done
        # shellcheck disable=SC2013
        for pid in $(cut -d' ' -f1 "$THROTTLED"); do unthrottle_pid "$pid"; echo "Un-throttled $pid"; done
    else
        case "$target" in *[!0-9]*) echo "Invalid PID: $target" >&2; return 1 ;; esac
        resume_pid "$target" "manual"
        unthrottle_pid "$target"
        signal_proc CONT "$target"
        echo "Resumed $target"
    fi
}

main() {
    local cmd=${1:-check}
    [ $# -gt 0 ] && shift
    case "$cmd" in
        check) check ;;
        status) status ;;
        rules) grep -v '^[[:space:]]*\(#\|$\)' "$RULES" 2>/dev/null || echo "(no rules)" ;;
        ignore|throttle|pause-on-battery)
            [ $# -ge 1 ] || { usage >&2; exit 1; }
            add_rule "$cmd" "$*"; echo "Added rule: $cmd $*" ;;
        unrule)
            [ $# -ge 1 ] || { usage >&2; exit 1; }
            remove_rule "$*"; echo "Removed rules for: $*" ;;
        resume) resume_cmd "$@" ;;
        log) tail -n "${1:-30}" "$HISTORY_LOG" 2>/dev/null ;;
        help|-h|--help) usage ;;
        *) usage >&2; exit 1 ;;
    esac
}

# Allow tests to source this file without running a cycle
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
