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
