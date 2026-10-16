# Unattended alerts, memory footprint, rules & pause/throttle — 2026-10-16

**Project:** macos-runaway-process-monitor   **Branch/commit:** main @ 00a74a4 (PR #1, squash-merged)   **Status:** done, installed on Andrew's Mac

## Summary
Andrew's Mac had two processes pegging a core: `QLPreviewGenerationExtension` (Quick Look, 2.8 days uptime,
17 h CPU time, ~6.9 GB memory) and a VS Code `Code Helper` utility process. The monitor had only alerted for
`mediaanalysisd` (which was normal Photos analysis and idle by the time we looked). He asked why the other two
weren't caught, then asked for the gaps fixed plus rules for "always ignore" and "gracefully stop expected-but-
unwanted-right-now" processes, adoption of the previously-uncommitted work, and a full ship + reinstall.

Quick Look PID was killed manually (`kill 65210`, freed ~7 GB + a core); the VS Code helper exited by itself.

## Root causes found
1. **Swallowed alerts.** The PID was written to the "seen" file *before* the dialog, and the dialog used
   `giving up after 60`. One unattended alert silenced that PID forever. The Quick Look process almost
   certainly alerted once days earlier while Andrew was away. (Unprovable: the seen file prunes dead PIDs and
   there was no history log.)
2. **No memory check — and RSS would have missed it anyway.** `ps` RSS for the Quick Look process was
   ~188 MB while `top`/Activity Monitor showed 6877M (compressed/swapped pages).
3. VS Code helper had only ~5 min CPU time, so it probably hadn't hit the 2-strike (~10 min) bar yet. That's
   working as designed.

## What changed
- `check-runaway-processes.sh` rewritten (bash 3.2-compatible, sourceable for tests via `BASH_SOURCE` guard):
  - Unanswered or failed dialog → notification, plus re-ask next cycle. User idle > `IDLE_SECONDS`
    (ioreg `HIDIdleTime`) → notification instead of a dialog. After one unanswered dialog in a cycle, the
    rest of that cycle only notifies (no stacking).
  - "Ignore for now" → snooze `SNOOZE_MINUTES` (60), not forever.
  - Memory threshold `MEM_THRESHOLD_MB` (4096) using **max(RSS, top footprint)** via `process_snapshot()`
    (`top -l 1 -o mem -n 50 -stats pid,mem` merged with `ps -axo pid=,%cpu=,rss=,etime=,comm=` in awk;
    ~0.65 s).
  - Rules file `~/.config/runaway-monitor/rules` (`<action> <glob>`, matched against basename or full path,
    first match wins):
    - `ignore`
    - `throttle` (`taskpolicy -b`; undo `-B`)
    - `pause-on-battery` (SIGSTOP on battery, SIGCONT on AC; silent on AC)
  - Dialog buttons: Ignore for now / More… / Quit Process. Quit sends SIGTERM, then SIGKILL after
    `QUIT_GRACE_SECONDS`. "More…" opens a `choose from list` with these options:
    - throttle now
    - pause `PAUSE_MINUTES` (auto-resume)
    - always pause on battery
    - always throttle
    - always ignore
    - Activity Monitor
    - force kill
  - Failures on root-owned processes (throttle, pause, quit, kill) notify once and don't loop. Rule
    failures are recorded per PID (`failed` mode in `paused`; entry in `throttled`). Manual failures
    snooze instead.
  - Config file `~/.config/runaway-monitor/config` (sourced). History log
    `~/Library/Logs/runaway-monitor.log` (capped at 2000 lines, trimmed to 1000).
  - State moved to `$(getconf DARWIN_USER_TEMP_DIR)runaway-monitor/` (0700), not predictable `/tmp`.
  - CLI subcommands: `check` (default), `status`, `rules`, `ignore|throttle|pause-on-battery <glob>`,
    `unrule`, `resume [pid|all]` (numeric-validated), `log [n]`, `help`.
  - osascript text is passed via `argv`, so no quote-escaping is needed.
- `install.sh`: unloads any previous agent first, symlinks `~/.local/bin/runaway-monitor`, seeds `config` and
  `rules` from `config.example` / `rules.example` without overwriting existing files.
- `uninstall.sh`: runs `resume all` before removing files (never leaves processes SIGSTOPped), keeps config
  and history; honours `RUNAWAY_STATE_DIR`.
- Tests: 83 bats tests. They source the script through a wrapper that stubs `proc_alive`, `signal_proc`,
  `user_idle_seconds`, `now_epoch` and `sleep`. Mocks cover `ps`, `top`, `osascript` (answer queue via
  `MOCK_OSA_QUEUE`), `pmset`, `taskpolicy`, `launchctl`, `lsof` and `open`. `tests/mocks/kill` was removed
  (`kill` is a builtin, so a PATH mock never applied).
- README rewritten for the new behaviour.
- The previously-uncommitted work (strikes, detailed dialog, original bats suite) was committed as-is first,
  then built on.
- Shipped: local CodeRabbit (3 cycles, 7 findings fixed). PR #1 squash-merged (no CI in the repo).
  `./install.sh` run from main, then `runaway-monitor pause-on-battery mediaanalysisd` added. Old
  `/tmp/runaway-processes-{seen,strikes}.txt` were deleted.

## Decisions & rationale
- **Unanswered = re-ask, not snooze.** Missing a multi-day hog is worse than a repeated prompt when back.
- **Pause via SIGSTOP and throttle via `taskpolicy -b`.** Both are reversible and need no root for
  user-owned processes. `launchctl disable` for Apple daemons was avoided (SIP risk, not reversible per
  run).
- **Rule actions (throttle, pause-on-battery) act on the first hot cycle**, with no strike wait, because
  the user pre-declared them.
- **`pause-on-battery` is silent on AC.** The process is "expected", just unwanted on battery.
- **No default active rules in the public repo.** `rules.example` has commented examples only; Andrew's
  `mediaanalysisd` rule lives in his local config.

## Learnings / gotchas
- macOS `ps` RSS massively under-reports leaking processes. Use top's MEM (footprint) or Activity Monitor.
- `ps` %cpu on macOS is a decaying average. `ps -o time=` (CPU time used) distinguishes a fresh spike from a
  long burn. The dialog now shows it.
- launchd runs `/bin/bash` 3.2: no associative arrays, `${x,,}`, `mapfile`, etc.
- The main loop must read the process list on fd 3 (`read <&3 ... done 3<<<"$snapshot"`) so osascript and
  other commands can't eat stdin.
- `osascript -e 'on run argv' ... -e 'end run' arg1 arg2` avoids all AppleScript string escaping.
- `display dialog ... giving up after N` returns `gave up of r = true`. `choose from list` returns `false`
  on cancel.
- CodeRabbit CLI is authenticated as the Life360 account but works on this personal repo.

## Open threads & next steps
- None required. Optional ideas:
  - add a GitHub Actions workflow running `bats tests/` and `shellcheck` on macOS runners (no CI today);
  - consider `pause-on-battery photoanalysisd` if it shows up;
  - review `runaway-monitor log` after a few days to tune thresholds (4 GB / 80%).
- A `python` PID 57758 was at ~100% CPU at install time with 1 strike. If it stayed hot, it would have
  produced the first real dialog of the new version.

## Related docs
- PR: https://github.com/beveradb/macos-runaway-process-monitor/pull/1
- Agent memory: `reference_runaway_process_monitor.md` (nomadkaraoke workspace memory)
