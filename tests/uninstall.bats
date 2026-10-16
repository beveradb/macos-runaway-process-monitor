#!/usr/bin/env bats

# Tests for uninstall.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_DIR="$SCRIPT_DIR/mocks"

setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/fakehome"
    mkdir -p "$HOME"
    export MOCK_LOG="$TEST_TMP/mock-calls.log"
    export RUNAWAY_STATE_DIR="$TEST_TMP/state"
    touch "$MOCK_LOG"

    # Use mock launchctl
    export PATH="$MOCK_DIR:$PATH"

    # First install so there's something to uninstall
    bash "$PROJECT_DIR/install.sh" > /dev/null 2>&1

    # Create the tmp files that uninstall cleans up
    touch /tmp/runaway-processes-seen-test-$$.txt
}

teardown() {
    rm -rf "$TEST_TMP"
    rm -f /tmp/runaway-processes-seen-test-$$.txt
}

@test "uninstall removes plist file" {
    bash "$PROJECT_DIR/uninstall.sh"
    [ ! -f "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist" ]
}

@test "uninstall removes script file" {
    bash "$PROJECT_DIR/uninstall.sh"
    [ ! -f "$HOME/.local/bin/check-runaway-processes.sh" ]
}

@test "uninstall calls launchctl unload" {
    bash "$PROJECT_DIR/uninstall.sh"
    grep -q "launchctl: unload" "$MOCK_LOG"
}

@test "uninstall succeeds when files already missing" {
    # Remove everything first
    rm -f "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist"
    rm -f "$HOME/.local/bin/check-runaway-processes.sh"

    # Should not error
    run bash "$PROJECT_DIR/uninstall.sh"
    [ "$status" -eq 0 ]
}

@test "uninstall prints completion message" {
    run bash "$PROJECT_DIR/uninstall.sh"
    [[ "$output" == *"Done"* ]]
}

@test "uninstall removes the runaway-monitor CLI symlink" {
    bash "$PROJECT_DIR/uninstall.sh"
    [ ! -e "$HOME/.local/bin/runaway-monitor" ]
}

@test "uninstall resumes paused processes before removing the script" {
    mkdir -p "$RUNAWAY_STATE_DIR"
    sleep 30 &
    local pid=$!
    kill -STOP "$pid"
    echo "$pid battery 0 /bin/sleep" > "$RUNAWAY_STATE_DIR/paused"
    bash "$PROJECT_DIR/uninstall.sh"
    state=$(ps -o stat= -p "$pid")
    kill "$pid" 2>/dev/null || true
    [[ "$state" != T* ]]
}

@test "uninstall removes state dir but keeps config" {
    mkdir -p "$RUNAWAY_STATE_DIR"
    bash "$PROJECT_DIR/uninstall.sh"
    [ ! -d "$RUNAWAY_STATE_DIR" ]
    [ -f "$HOME/.config/runaway-monitor/rules" ]
}
