#!/usr/bin/env bats

# Tests for check-runaway-processes.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$PROJECT_DIR/check-runaway-processes.sh"
MOCK_DIR="$SCRIPT_DIR/mocks"

setup() {
    TEST_TMP="$(mktemp -d)"
    export RUNAWAY_CONFIG_DIR="$TEST_TMP/config"
    export RUNAWAY_STATE_DIR="$TEST_TMP/state"
    export RUNAWAY_HISTORY_LOG="$TEST_TMP/history.log"
    export MOCK_LOG="$TEST_TMP/mock-calls.log"
    export MOCK_OSA_QUEUE="$TEST_TMP/osa-queue"
    mkdir -p "$RUNAWAY_CONFIG_DIR"
    touch "$MOCK_LOG"
    export PATH="$MOCK_DIR:$PATH"

    STRIKES="$RUNAWAY_STATE_DIR/strikes"
    SNOOZED="$RUNAWAY_STATE_DIR/snoozed"
    PAUSED="$RUNAWAY_STATE_DIR/paused"
    THROTTLED="$RUNAWAY_STATE_DIR/throttled"
    RULES="$RUNAWAY_CONFIG_DIR/rules"

    # Wrapper: source the script, stub out process signalling / clock / idle time
    RUNNER="$TEST_TMP/run.sh"
    cat > "$RUNNER" <<EOF
#!/bin/bash
source "$SCRIPT"
proc_alive() {
    case " \${MOCK_DEAD_PIDS:-} \$(cat "$TEST_TMP/died" 2>/dev/null) " in *" \$1 "*) return 1 ;; esac
    return 0
}
signal_proc() {
    echo "signal: \$1 \$2" >> "\$MOCK_LOG"
    [ "\${MOCK_SIGNAL_FAIL:-0}" = 1 ] && return 1
    [ "\$1" = TERM ] && [ "\${MOCK_TERM_EXITS:-1}" = 1 ] && echo "\$2" >> "$TEST_TMP/died"
    return 0
}
user_idle_seconds() { echo "\${MOCK_IDLE:-0}"; }
now_epoch() { echo "\${MOCK_NOW:-1000000}"; }
sleep() { :; }
main "\$@"
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Run one check cycle with the given process listing ("pid %cpu rss_kb etime comm")
run_cycle() {
    export MOCK_PS_OUTPUT="$1"
    bash "$RUNNER" check 2>/dev/null
}

run_cycles() {
    local i
    for ((i = 0; i < $1; i++)); do run_cycle "$2"; done
}

# Queue dialog answers (one per osascript dialog call)
answer() { printf '%s\n' "$@" >> "$MOCK_OSA_QUEUE"; }

dialogs() { grep -c "Runaway Process Detected" "$MOCK_LOG" || true; }
notifications() { grep -c "display notification" "$MOCK_LOG" || true; }

HOT="12345 95.0 10240 00:10:00 /usr/bin/runaway"

# --- CPU threshold ---

@test "ignores processes below CPU threshold" {
    run_cycles 3 "12345 50.0 10240 00:10:00 /usr/bin/low-cpu"
    [ "$(dialogs)" -eq 0 ]
}

@test "ignores processes at 79.9% CPU" {
    run_cycles 3 "12345 79.9 10240 00:10:00 /usr/bin/borderline"
    [ "$(dialogs)" -eq 0 ]
}

@test "alerts at exactly 80% CPU after 2 cycles" {
    run_cycles 2 "12345 80.0 10240 00:10:00 /usr/bin/hot-process"
    [ "$(dialogs)" -eq 1 ]
}

@test "handles integer CPU values without decimal" {
    run_cycles 2 "12345 100 10240 00:10:00 /usr/bin/maxcpu"
    [ "$(dialogs)" -eq 1 ]
}

@test "CPU threshold can be overridden in config file" {
    echo "CPU_THRESHOLD=150" > "$RUNAWAY_CONFIG_DIR/config"
    run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 0 ]
    run_cycles 2 "12345 160.0 10240 00:10:00 /usr/bin/runaway"
    [ "$(dialogs)" -eq 1 ]
}

# --- Memory threshold ---

@test "alerts on high memory even with low CPU" {
    run_cycles 2 "65210 1.0 7042000 02-18:54:07 /System/QLPreviewGenerationExtension"
    [ "$(dialogs)" -eq 1 ]
    grep -q "memory 6.7 GB" "$MOCK_LOG"
}

@test "memory check can be disabled with MEM_THRESHOLD_MB=0" {
    echo "MEM_THRESHOLD_MB=0" > "$RUNAWAY_CONFIG_DIR/config"
    run_cycles 2 "65210 1.0 7042000 02-18:54:07 /System/QLPreviewGenerationExtension"
    [ "$(dialogs)" -eq 0 ]
}

@test "reason lists both CPU and memory when both exceeded" {
    run_cycles 2 "65210 99.6 7042000 02-18:54:07 /System/QLPreviewGenerationExtension"
    grep -q "CPU 99.6% (limit 80%), memory 6.7 GB" "$MOCK_LOG"
}

# --- Strikes ---

@test "does not alert on first hot cycle" {
    run_cycle "$HOT"
    [ "$(dialogs)" -eq 0 ]
    grep -q "^12345 1$" "$STRIKES"
}

@test "strikes reset when process stops being hot" {
    run_cycle "$HOT"
    run_cycle "12345 5.0 10240 00:15:00 /usr/bin/runaway"
    ! grep -q "^12345 " "$STRIKES"
    run_cycle "$HOT"
    [ "$(dialogs)" -eq 0 ]
}

# --- Dialog content ---

@test "dialog shows name, PID, reason, CPU time, uptime and working directory" {
    run_cycles 2 "12345 95.0 10240 02-18:54:07 /usr/bin/runaway"
    grep -q "runaway (PID 12345)" "$MOCK_LOG"
    grep -q "Why: CPU 95.0% (limit 80%)" "$MOCK_LOG"
    grep -q "CPU time used: 1020:37.86" "$MOCK_LOG"
    grep -q "Running for: 2d 18h 54m" "$MOCK_LOG"
    grep -q "/Users/test/project" "$MOCK_LOG"
}

@test "handles process names with spaces" {
    run_cycles 2 "12345 85.0 10240 00:10:00 /Applications/My App.app/Contents/MacOS/My App"
    grep -q "My App (PID 12345)" "$MOCK_LOG"
}

# --- Ignore / snooze ---

@test "'Ignore for now' snoozes instead of silencing forever" {
    answer "Ignore for now"
    run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 1 ]
    grep -q "^12345 " "$SNOOZED"

    # Still hot, inside the snooze window: no new dialog
    MOCK_NOW=1001000 run_cycle "$HOT"
    [ "$(dialogs)" -eq 1 ]

    # Snooze (60 min) expired: asks again
    MOCK_NOW=1003700 run_cycle "$HOT"
    [ "$(dialogs)" -eq 2 ]
}

# --- Unattended alerts (the bug that hid a 3-day runaway) ---

@test "unanswered dialog is not swallowed: re-asks next cycle" {
    answer "GAVE_UP"
    run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 1 ]
    [ ! -s "$SNOOZED" ]
    [ "$(notifications)" -ge 1 ]

    answer "Ignore for now"
    run_cycle "$HOT"
    [ "$(dialogs)" -eq 2 ]
}

@test "after one unanswered dialog, other hot processes get notifications, not stacked dialogs" {
    answer "GAVE_UP"
    run_cycles 2 "$(printf '%s\n%s' "$HOT" "12346 90.0 10240 00:10:00 /usr/bin/other")"
    [ "$(dialogs)" -eq 1 ]
    grep -q "display notification.*other" "$MOCK_LOG"
}

@test "osascript failure is treated like an unanswered dialog" {
    answer "ERROR"
    run_cycles 2 "$HOT"
    [ ! -s "$SNOOZED" ]
}

@test "when the user is idle, posts a notification instead of a dialog" {
    MOCK_IDLE=900 run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 0 ]
    grep -q "display notification.*will ask again when you're back" "$MOCK_LOG"
    [ ! -s "$SNOOZED" ]

    # Back at the keyboard: dialog shows
    MOCK_IDLE=0 run_cycle "$HOT"
    [ "$(dialogs)" -eq 1 ]
}

# --- Quit ---

@test "'Quit Process' sends SIGTERM and does not SIGKILL if it exits" {
    answer "Quit Process"
    run_cycles 2 "$HOT"
    grep -q "signal: TERM 12345" "$MOCK_LOG"
    ! grep -q "signal: KILL 12345" "$MOCK_LOG"
}

@test "'Quit Process' escalates to SIGKILL if SIGTERM is ignored" {
    answer "Quit Process"
    MOCK_TERM_EXITS=0 run_cycles 2 "$HOT"
    grep -q "signal: TERM 12345" "$MOCK_LOG"
    grep -q "signal: KILL 12345" "$MOCK_LOG"
}

@test "'Quit Process' failure (e.g. root-owned) notifies" {
    answer "Quit Process"
    MOCK_SIGNAL_FAIL=1 run_cycles 2 "$HOT"
    grep -q "display notification.*Couldn't quit" "$MOCK_LOG"
}

# --- "More…" actions ---

@test "More → Always ignore adds a rule and stops alerting" {
    answer "More…" "Always ignore runaway"
    run_cycles 2 "$HOT"
    grep -q "^ignore runaway$" "$RULES"
    run_cycles 3 "$HOT"
    [ "$(dialogs)" -eq 1 ]
}

@test "More → Throttle now demotes to background priority" {
    answer "More…" "Throttle now (background priority)"
    run_cycles 2 "$HOT"
    grep -q "taskpolicy: -b -p 12345" "$MOCK_LOG"
    grep -q "^12345 " "$THROTTLED"
    run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 1 ]
}

@test "More → Always throttle adds rule and throttles" {
    answer "More…" "Always throttle runaway"
    run_cycles 2 "$HOT"
    grep -q "^throttle runaway$" "$RULES"
    grep -q "taskpolicy: -b -p 12345" "$MOCK_LOG"
}

@test "More → Pause pauses and resumes when the pause expires" {
    answer "More…" "Pause for 60 min"
    run_cycles 2 "$HOT"
    grep -q "signal: STOP 12345" "$MOCK_LOG"
    grep -q "^12345 timed 1003600 " "$PAUSED"

    MOCK_NOW=1002000 run_cycle "$HOT"
    ! grep -q "signal: CONT 12345" "$MOCK_LOG"

    MOCK_NOW=1003600 run_cycle "12345 0.0 10240 01:10:00 /usr/bin/runaway"
    grep -q "signal: CONT 12345" "$MOCK_LOG"
    [ ! -s "$PAUSED" ]
}

@test "More → Always pause on battery adds rule and pauses now when on battery" {
    answer "More…" "Always pause runaway while on battery"
    MOCK_ON_BATTERY=1 run_cycles 2 "$HOT"
    grep -q "^pause-on-battery runaway$" "$RULES"
    grep -q "signal: STOP 12345" "$MOCK_LOG"
}

@test "More → Force kill sends SIGKILL" {
    answer "More…" "Force kill now"
    run_cycles 2 "$HOT"
    grep -q "signal: KILL 12345" "$MOCK_LOG"
}

@test "More → Cancel snoozes" {
    answer "More…" "CANCEL"
    run_cycles 2 "$HOT"
    grep -q "^12345 " "$SNOOZED"
}

# --- Rules ---

@test "ignore rule matches by glob on the full path" {
    echo "ignore /usr/bin/run*" > "$RULES"
    run_cycles 3 "$HOT"
    [ "$(dialogs)" -eq 0 ]
}

@test "throttle rule acts immediately with no dialog, once per PID" {
    echo "throttle runaway" > "$RULES"
    run_cycles 3 "$HOT"
    [ "$(dialogs)" -eq 0 ]
    [ "$(grep -c "taskpolicy: -b -p 12345" "$MOCK_LOG")" -eq 1 ]
}

@test "failed throttle is not retried every cycle" {
    echo "throttle runaway" > "$RULES"
    MOCK_TASKPOLICY_FAIL=1 run_cycles 3 "$HOT"
    [ "$(grep -c "taskpolicy: -b" "$MOCK_LOG")" -eq 1 ]
}

@test "pause-on-battery leaves the process alone (and silent) on AC" {
    echo "pause-on-battery mediaanalysisd" > "$RULES"
    MOCK_ON_BATTERY=0 run_cycles 3 "53537 172.5 50000 08:51:04 /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd"
    [ "$(dialogs)" -eq 0 ]
    ! grep -q "signal: STOP" "$MOCK_LOG"
}

@test "pause-on-battery pauses on battery and resumes on AC" {
    echo "pause-on-battery mediaanalysisd" > "$RULES"
    local mad="53537 172.5 50000 08:51:04 /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd"
    MOCK_ON_BATTERY=1 run_cycle "$mad"
    grep -q "signal: STOP 53537" "$MOCK_LOG"
    grep -q "^53537 battery 0 " "$PAUSED"

    MOCK_ON_BATTERY=1 run_cycle "$mad"
    ! grep -q "signal: CONT 53537" "$MOCK_LOG"

    MOCK_ON_BATTERY=0 run_cycle "53537 0.0 50000 08:56:04 /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd"
    grep -q "signal: CONT 53537" "$MOCK_LOG"
    [ ! -s "$PAUSED" ]
}

@test "comment lines and blank lines in rules are ignored" {
    printf '# ignore runaway\n\n' > "$RULES"
    run_cycles 2 "$HOT"
    [ "$(dialogs)" -eq 1 ]
}

# --- State cleanup ---

@test "state for dead PIDs is pruned" {
    answer "Ignore for now"
    run_cycles 2 "$HOT"
    grep -q "^12345 " "$SNOOZED"
    MOCK_DEAD_PIDS="12345" run_cycle ""
    [ ! -s "$SNOOZED" ]
}

@test "events are written to the history log" {
    answer "Ignore for now"
    run_cycles 2 "$HOT"
    grep -q "ALERT pid=12345 CPU 95.0%" "$RUNAWAY_HISTORY_LOG"
    grep -q 'CHOICE pid=12345 "Ignore for now"' "$RUNAWAY_HISTORY_LOG"
}

# --- Edge cases ---

@test "handles empty ps output" {
    run run_cycle ""
    [ "$status" -eq 0 ]
}

@test "handles non-numeric CPU values" {
    run run_cycles 2 "12345 N/A 10240 00:10:00 /usr/bin/weird"
    [ "$status" -eq 0 ]
    [ "$(dialogs)" -eq 0 ]
}

@test "PID matching is exact (does not match substrings)" {
    mkdir -p "$RUNAWAY_STATE_DIR"
    echo "123 9999999999 /usr/bin/short-pid" > "$SNOOZED"
    run_cycles 2 "1234 90.0 10240 00:10:00 /usr/bin/different-process"
    [ "$(dialogs)" -eq 1 ]
}

# --- CLI ---

@test "cli: ignore / rules / unrule manage the rules file" {
    bash "$RUNNER" ignore "*ffmpeg*"
    bash "$RUNNER" pause-on-battery mediaanalysisd
    run bash "$RUNNER" rules
    [[ "$output" == *"ignore *ffmpeg*"* ]]
    [[ "$output" == *"pause-on-battery mediaanalysisd"* ]]
    bash "$RUNNER" unrule "*ffmpeg*"
    ! grep -q "ffmpeg" "$RULES"
    grep -q "^pause-on-battery mediaanalysisd$" "$RULES"
}

@test "cli: adding a rule for an existing pattern replaces it" {
    bash "$RUNNER" ignore mediaanalysisd
    bash "$RUNNER" throttle mediaanalysisd
    [ "$(grep -c mediaanalysisd "$RULES")" -eq 1 ]
    grep -q "^throttle mediaanalysisd$" "$RULES"
}

@test "cli: unrule keeps comments" {
    printf '# a comment\nignore foo\n' > "$RULES"
    bash "$RUNNER" unrule foo
    grep -q "^# a comment$" "$RULES"
}

@test "cli: resume all resumes paused and un-throttles" {
    mkdir -p "$RUNAWAY_STATE_DIR"
    echo "111 battery 0 /usr/bin/a" > "$PAUSED"
    echo "222 /usr/bin/b" > "$THROTTLED"
    bash "$RUNNER" resume all
    grep -q "signal: CONT 111" "$MOCK_LOG"
    grep -q "taskpolicy: -B -p 222" "$MOCK_LOG"
    [ ! -s "$PAUSED" ]
    [ ! -s "$THROTTLED" ]
}

@test "cli: status runs and shows thresholds" {
    run bash "$RUNNER" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"CPU 80%"* ]]
}

@test "cli: unknown command fails with usage" {
    run bash "$RUNNER" bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "cli: rule commands require a pattern" {
    run bash "$RUNNER" ignore
    [ "$status" -eq 1 ]
}

# --- Formatting helpers ---

@test "fmt_etime formats ps elapsed times" {
    source "$SCRIPT"
    [ "$(fmt_etime 02-18:54:07)" = "2d 18h 54m" ]
    [ "$(fmt_etime 08:51:04)" = "8h 51m" ]
    [ "$(fmt_etime 34:13)" = "34m" ]
    [ "$(fmt_etime 00:05)" = "0m" ]
}

@test "fmt_mb formats megabytes" {
    source "$SCRIPT"
    [ "$(fmt_mb 512)" = "512 MB" ]
    [ "$(fmt_mb 4096)" = "4.0 GB" ]
}

@test "sourcing the script does not run a check" {
    MOCK_PS_OUTPUT="$HOT" bash -c "source '$SCRIPT'"
    [ ! -d "$RUNAWAY_STATE_DIR" ]
}
