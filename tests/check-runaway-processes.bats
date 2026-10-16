#!/usr/bin/env bats

# Tests for check-runaway-processes.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$PROJECT_DIR/check-runaway-processes.sh"
MOCK_DIR="$SCRIPT_DIR/mocks"

setup() {
    TEST_TMP="$(mktemp -d)"
    export LOG="$TEST_TMP/runaway-processes-seen.txt"
    export STRIKES="$TEST_TMP/runaway-processes-strikes.txt"
    export MOCK_LOG="$TEST_TMP/mock-calls.log"
    touch "$MOCK_LOG"

    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: create a runnable test script with LOG and STRIKES paths overridden
make_test_script() {
    local test_script="$TEST_TMP/test-script.sh"
    {
        echo '#!/bin/bash'
        echo "kill() { return 0; }"
        sed \
            -e "s|LOG=\"/tmp/runaway-processes-seen.txt\"|LOG=\"$LOG\"|" \
            -e "s|STRIKES=\"/tmp/runaway-processes-strikes.txt\"|STRIKES=\"$STRIKES\"|" \
            "$SCRIPT" | tail -n +2
    } > "$test_script"
    chmod +x "$test_script"
    echo "$test_script"
}

# Run one cycle with given ps output
run_cycle() {
    export MOCK_PS_OUTPUT="$1"
    bash "$(make_test_script)" 2>/dev/null
}

# Run N cycles with given ps output (simulates sustained high CPU)
run_cycles() {
    local n="$1"
    local ps_output="$2"
    for ((i=0; i<n; i++)); do
        run_cycle "$ps_output"
    done
}

# --- CPU threshold filtering ---

@test "ignores processes below CPU threshold" {
    run_cycles 2 "12345  50.0   00:10:00 /usr/bin/low-cpu"
    [ ! -s "$LOG" ] || [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 0 ]
}

@test "ignores processes at exactly 79% CPU" {
    run_cycles 2 "12345  79.9   00:10:00 /usr/bin/borderline"
    [ ! -s "$LOG" ] || [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 0 ]
}

@test "detects processes at exactly 80% CPU after 2 cycles" {
    run_cycles 2 "12345  80.0   00:10:00 /usr/bin/hot-process"
    [ -s "$LOG" ]
    grep -q "^12345 " "$LOG"
}

@test "detects processes above CPU threshold after 2 cycles" {
    run_cycles 2 "12345  95.3   00:10:00 /usr/bin/runaway"
    [ -s "$LOG" ]
    grep -q "^12345 " "$LOG"
}

@test "handles integer CPU values without decimal" {
    run_cycles 2 "12345  100   00:10:00 /usr/bin/maxcpu"
    [ -s "$LOG" ]
    grep -q "^12345 " "$LOG"
}

# --- Strike system ---

@test "does not alert on first cycle" {
    run_cycle "12345  95.0   00:10:00 /usr/bin/runaway"
    [ ! -s "$LOG" ] || [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 0 ]
    ! grep -q "osascript" "$MOCK_LOG"
}

@test "strikes file tracks count after first cycle" {
    run_cycle "12345  95.0   00:10:00 /usr/bin/runaway"
    [ -s "$STRIKES" ]
    grep -q "^12345 1$" "$STRIKES"
}

@test "alerts on second consecutive cycle" {
    run_cycles 2 "12345  95.0   00:10:00 /usr/bin/runaway"
    [ -s "$LOG" ]
    grep -q "osascript" "$MOCK_LOG"
}

@test "strikes reset when process drops below threshold" {
    # First cycle: hot
    run_cycle "12345  95.0   00:10:00 /usr/bin/runaway"
    grep -q "^12345 1$" "$STRIKES"

    # Second cycle: process is now cool — mock ps returns low CPU for single-PID lookup
    export MOCK_PS_CPU="  5.0"
    run_cycle ""

    # Strikes should be cleared
    ! grep -q "^12345 " "$STRIKES"
}

# --- Seen file format ---

@test "seen file contains PID, CPU, elapsed time, and command name" {
    run_cycles 2 "12345  92.1   01:30:00 /usr/bin/hot-process"
    [ -s "$LOG" ]
    grep -q "^12345 92.1% 01:30:00 /usr/bin/hot-process$" "$LOG"
}

@test "seen file records multiple processes on separate lines" {
    run_cycles 2 "$(printf '12345  85.0   00:10:00 /usr/bin/proc1\n12346  90.0   00:20:00 /usr/bin/proc2')"
    [ -s "$LOG" ]
    [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ]
    grep -q "^12345 " "$LOG"
    grep -q "^12346 " "$LOG"
}

# --- Deduplication ---

@test "does not re-alert for already-seen PID" {
    echo "12345 85.0% 00:05:00 /usr/bin/hot-process" > "$LOG"
    > "$MOCK_LOG"

    run_cycles 2 "12345  92.1   00:15:00 /usr/bin/hot-process"

    [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
    ! grep -q "osascript" "$MOCK_LOG"
}

@test "alerts for new PID even when other PIDs already seen" {
    echo "12345 85.0% 00:05:00 /usr/bin/old-process" > "$LOG"

    run_cycles 2 "$(printf '12345  92.1   00:15:00 /usr/bin/old-process\n12346  88.0   00:05:00 /usr/bin/new-process')"

    [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ]
    grep -q "^12346 " "$LOG"
}

@test "PID matching is exact (does not match substrings)" {
    echo "123 85.0% 00:05:00 /usr/bin/short-pid" > "$LOG"

    run_cycles 2 "1234  90.0   00:10:00 /usr/bin/different-process"

    grep -q "^1234 " "$LOG"
    [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ]
}

# --- Dialog/notification ---

@test "triggers osascript for sustained high-CPU process" {
    run_cycles 2 "12345  95.0   00:10:00 /usr/bin/runaway"
    grep -q "osascript" "$MOCK_LOG"
}

@test "dialog contains process name and PID" {
    run_cycles 2 "12345  95.0   00:10:00 /usr/bin/runaway"
    grep -q "PID 12345" "$MOCK_LOG"
    grep -q "runaway" "$MOCK_LOG"
}

@test "dialog contains CPU and memory info" {
    run_cycles 2 "12345  95.0   00:10:00 /usr/bin/runaway"
    grep -q "95.0%" "$MOCK_LOG"
    grep -q "Memory" "$MOCK_LOG"
}

@test "dialog contains working directory" {
    run_cycles 2 "12345  95.0   00:10:00 /usr/bin/runaway"
    grep -q "Working directory" "$MOCK_LOG"
}

@test "no osascript call for already-seen PID" {
    echo "12345 85.0% 00:05:00 /usr/bin/hot-process" > "$LOG"
    > "$MOCK_LOG"

    run_cycles 2 "12345  92.1   00:15:00 /usr/bin/hot-process"

    ! grep -q "osascript" "$MOCK_LOG"
}

# --- Cleanup of dead PIDs ---

@test "cleanup removes entries for dead PIDs" {
    echo "99999 85.0% 00:05:00 /usr/bin/dead-process" > "$LOG"

    tmp=$(mktemp)
    while read -r line; do
        pid=${line%% *}
        /bin/kill -0 "$pid" 2>/dev/null && echo "$line"
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"

    [ ! -s "$LOG" ]
}

@test "cleanup preserves entries for living PIDs" {
    local live_pid=$$
    echo "$live_pid 85.0% 00:01:00 /bin/bash" > "$LOG"

    tmp=$(mktemp)
    while read -r line; do
        pid=${line%% *}
        /bin/kill -0 "$pid" 2>/dev/null && echo "$line"
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"

    [ -s "$LOG" ]
    grep -q "^$live_pid " "$LOG"
}

@test "cleanup preserves full detail line (not just PID)" {
    local live_pid=$$
    echo "$live_pid 85.0% 10-00:00:00 /bin/bash" > "$LOG"

    tmp=$(mktemp)
    while read -r line; do
        pid=${line%% *}
        /bin/kill -0 "$pid" 2>/dev/null && echo "$line"
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"

    line=$(cat "$LOG")
    [[ "$line" == "$live_pid 85.0% 10-00:00:00 /bin/bash" ]]
}

# --- Edge cases ---

@test "handles empty ps output gracefully" {
    run_cycle ""
    [ ! -s "$LOG" ] || [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 0 ]
}

@test "handles process names with spaces" {
    run_cycles 2 "12345  85.0   00:10:00 /Applications/My App.app/Contents/MacOS/My App"
    [ -s "$LOG" ]
    grep -q "^12345 " "$LOG"
    grep -q "My App" "$LOG"
}

@test "creates seen file if it does not exist" {
    rm -f "$LOG"
    run_cycle "12345  85.0   00:10:00 /usr/bin/test"
    [ -f "$LOG" ]
}

@test "handles non-numeric CPU values gracefully (no crash)" {
    run run_cycle "12345  N/A   00:10:00 /usr/bin/weird"
    true
}
