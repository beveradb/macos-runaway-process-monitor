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

@test "install creates runaway-monitor CLI symlink" {
    bash "$PROJECT_DIR/install.sh"
    [ -L "$HOME/.local/bin/runaway-monitor" ]
    [ "$(readlink "$HOME/.local/bin/runaway-monitor")" = "$HOME/.local/bin/check-runaway-processes.sh" ]
}

@test "install seeds config and rules from examples" {
    bash "$PROJECT_DIR/install.sh"
    diff "$PROJECT_DIR/config.example" "$HOME/.config/runaway-monitor/config"
    diff "$PROJECT_DIR/rules.example" "$HOME/.config/runaway-monitor/rules"
}

@test "reinstall does not overwrite existing config or rules" {
    mkdir -p "$HOME/.config/runaway-monitor"
    echo "CPU_THRESHOLD=150" > "$HOME/.config/runaway-monitor/config"
    echo "ignore foo" > "$HOME/.config/runaway-monitor/rules"
    bash "$PROJECT_DIR/install.sh"
    grep -q "CPU_THRESHOLD=150" "$HOME/.config/runaway-monitor/config"
    grep -q "^ignore foo$" "$HOME/.config/runaway-monitor/rules"
}

@test "reinstall unloads the previous agent before loading" {
    bash "$PROJECT_DIR/install.sh"
    > "$MOCK_LOG"
    bash "$PROJECT_DIR/install.sh"
    [ "$(head -1 "$MOCK_LOG")" = "launchctl: unload $HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist" ]
    grep -q "launchctl: load" "$MOCK_LOG"
}

@test "plist passes plutil lint" {
    bash "$PROJECT_DIR/install.sh"
    plutil -lint "$HOME/Library/LaunchAgents/com.beveradb.check-runaway-processes.plist"
}

@test "installed CLI runs help" {
    bash "$PROJECT_DIR/install.sh"
    run "$HOME/.local/bin/runaway-monitor" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pause-on-battery"* ]]
}
