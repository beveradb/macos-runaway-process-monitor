#!/usr/bin/env bats

# Tests for install.sh

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
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "install creates ~/.local/bin directory" {
    bash "$PROJECT_DIR/install.sh"
    [ -d "$HOME/.local/bin" ]
}

@test "install copies script to ~/.local/bin" {
    bash "$PROJECT_DIR/install.sh"
    [ -f "$HOME/.local/bin/check-runaway-processes.sh" ]
}

@test "installed script is executable" {
    bash "$PROJECT_DIR/install.sh"
    [ -x "$HOME/.local/bin/check-runaway-processes.sh" ]
}

@test "installed script matches source" {
    bash "$PROJECT_DIR/install.sh"
    diff "$PROJECT_DIR/check-runaway-processes.sh" "$HOME/.local/bin/check-runaway-processes.sh"
}

@test "install creates LaunchAgents directory" {
    bash "$PROJECT_DIR/install.sh"
    [ -d "$HOME/Library/LaunchAgents" ]
}

@test "install creates plist file" {
    bash "$PROJECT_DIR/install.sh"
    [ -f "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist" ]
}

@test "plist contains correct label" {
    bash "$PROJECT_DIR/install.sh"
    grep -q "com.beveradb.check-runaway-processes" "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist"
}

@test "plist contains correct script path" {
    bash "$PROJECT_DIR/install.sh"
    grep -q "$HOME/.local/bin/check-runaway-processes.sh" "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist"
}

@test "plist has 300-second interval" {
    bash "$PROJECT_DIR/install.sh"
    grep -q "<integer>300</integer>" "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist"
}

@test "plist is valid XML" {
    bash "$PROJECT_DIR/install.sh"
    xmllint --noout "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist" 2>/dev/null
}

@test "install calls launchctl load" {
    bash "$PROJECT_DIR/install.sh"
    grep -q "launchctl: load" "$MOCK_LOG"
}
