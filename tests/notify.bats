#!/usr/bin/env bats
#
# praetorian tests: end-of-session notification (--notify, --no-notify,
# notification of a session stopped before its summary) and
# --ac-power-only. Same setup as tests/options.bats: fakes of tests/stubs
# in front of the PATH (osascript and pmset among them), HOME in a temp
# directory, no terminal (unattended mode; see tests/interactive.bats for
# the terminal side: sound, PRAETORIAN_NOTIFY_AFTER).
#
# Each @test runs in its own subshell: the exported variables are meant to
# stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls"
    export PORT_CALLS="${BATS_TEST_TMPDIR}/port_calls"
    export SUDO_CALLS="${BATS_TEST_TMPDIR}/sudo_calls"
    export OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    export XCODEBUILD_CALLS="${BATS_TEST_TMPDIR}/xcodebuild_calls"
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    : >"${OSASCRIPT_CALLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
}

# The fake osascript writes one argument per line: the AppleScript lines
# ("-e" and its text), then message, subtitle and sound when there's one.
# notification_args: just the arguments after "end run".
notification_args() {
    sed -n '/^end run$/,$p' "${OSASCRIPT_CALLS}" | sed 1d
}

@test "notify: unattended success → message, subtitle with the duration, no sound" {
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'on run argv' "${OSASCRIPT_CALLS}"
    run notification_args
    [ "${lines[0]}" = "Maintenance completed successfully." ]
    [[ "${lines[1]}" =~ ^Done\ in\ [0-9]+\ s$ ]] || false
    [ "${#lines[@]}" -eq 2 ]
}

@test "notify: unattended failure → errors counted, 'Finished with errors' subtitle" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_OUTPUT='Error: foo: something broke'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    run notification_args
    [[ "${lines[0]}" == *"failure(s), 0 block(s) — see the log." ]] || false
    [[ "${lines[1]}" == "Finished with errors ("*")" ]] || false
}

@test "notify: --no-notify → none, even unattended" {
    run "${PRAETORIAN}" --no-notify
    [ "${status}" -eq 0 ]
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "notify: --dry-run --notify → sent (to check notifications get through)" {
    run "${PRAETORIAN}" --dry-run --notify
    [ "${status}" -eq 0 ]
    run notification_args
    [ "${lines[0]}" = "Maintenance completed successfully." ]
}

@test "notify: --migration-report → none, even unattended" {
    run "${PRAETORIAN}" --migration-report
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "notify: blocked before the summary (lock) → 'Stopped' notification naming the block" {
    mkdir -p "${HOME}/praetorian/.lock"
    sleep 60 &
    local pid=$!
    echo "${pid}" >"${HOME}/praetorian/.lock/pid"
    run "${PRAETORIAN}"
    kill "${pid}"
    [ "${status}" -eq 1 ]
    run notification_args
    [ "${lines[0]}" = "Blocked: another praetorian session is already running (PID ${pid}). Nothing more was done — see the log." ]
    [ "${lines[1]}" = "Stopped" ]
    # Only one notification.
    [ "$(grep -cx 'on run argv' "${OSASCRIPT_CALLS}")" -eq 1 ]
}

@test "notify: --no-notify also silences the 'Stopped' notification" {
    mkdir -p "${HOME}/praetorian/.lock"
    sleep 60 &
    local pid=$!
    echo "${pid}" >"${HOME}/praetorian/.lock/pid"
    run "${PRAETORIAN}" --no-notify
    kill "${pid}"
    [ "${status}" -eq 1 ]
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "notify: summary shows a notification once, not again on exit" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_OUTPUT='Error: foo: something broke'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [ "$(grep -cx 'on run argv' "${OSASCRIPT_CALLS}")" -eq 1 ]
}

@test "notify: logged in the session log" {
    run "${PRAETORIAN}"
    grep -q 'NOTIFICATION: Done in .* — Maintenance completed successfully.' "${HOME}"/praetorian/logs/praetorian_*.log
}

# --- Unit tests -------------------------------------------------------------------

@test "run_bounded: a stuck command is killed after the limit, returns 0" {
    run bash -c "source '${PRAETORIAN}'; s=\$(date +%s); run_bounded 1 sleep 30; echo \$((\$(date +%s) - s))"
    [ "${status}" -eq 0 ]
    [ "${lines[${#lines[@]} - 1]}" -le 4 ]
}

@test "run_bounded: a failing command doesn't fail the caller" {
    run bash -c "source '${PRAETORIAN}'; set -e; run_bounded 5 false; echo reached"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *reached* ]] || false
}

@test "format_duration: seconds, minutes, hours" {
    run bash -c "source '${PRAETORIAN}'; format_duration 42; format_duration 600; format_duration 3725"
    [ "${lines[0]}" = "42 s" ]
    [ "${lines[1]}" = "10 min" ]
    [ "${lines[2]}" = "1 h 02 min" ]
}

# --- --ac-power-only ----------------------------------------------------------------

@test "--ac-power-only on AC power: session runs" {
    PMSET_SOURCE="AC Power" run "${PRAETORIAN}" --ac-power-only
    [ "${status}" -eq 0 ]
    grep -qx 'update' "${BREW_CALLS}"
    grep -q 'Power source: AC Power' "${HOME}"/praetorian/logs/praetorian_*.log
}

@test "--ac-power-only on battery: blocked, explained, nothing run, notified" {
    PMSET_SOURCE="Battery Power" run "${PRAETORIAN}" --ac-power-only
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: the Mac is on Battery Power (--ac-power-only)"* ]] || false
    [[ "${output}" == *"Plug the Mac in"* ]] || false
    [[ "${output}" != *"unexpected error"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
    [ ! -e "${HOME}/praetorian/.lock" ]
    run notification_args
    [ "${lines[0]}" = "Blocked: the Mac is on Battery Power (--ac-power-only). Nothing more was done — see the log." ]
}

@test "--ac-power-only on UPS power: blocked too" {
    PMSET_SOURCE="UPS Power" run "${PRAETORIAN}" --ac-power-only
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: the Mac is on UPS Power"* ]] || false
}

@test "--ac-power-only, unknown power source: warning, session runs" {
    PMSET_SOURCE="Something New" run "${PRAETORIAN}" --ac-power-only
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Power source unknown (pmset -g batt): --ac-power-only check skipped."* ]] || false
    grep -qx 'update' "${BREW_CALLS}"
}

@test "--ac-power-only --dry-run on battery: warning only" {
    PMSET_SOURCE="Battery Power" run "${PRAETORIAN}" --ac-power-only --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"a real session with --ac-power-only would be blocked"* ]] || false
}

@test "without --ac-power-only: battery doesn't matter, pmset not even asked" {
    PMSET_SOURCE="Battery Power" run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    run grep -q 'Power source' "${HOME}"/praetorian/logs/praetorian_*.log
    [ "${status}" -eq 1 ]
}

@test "--help lists the new options" {
    run "${PRAETORIAN}" --help
    [[ "${output}" == *"--notify"* ]] || false
    [[ "${output}" == *"--no-notify"* ]] || false
    [[ "${output}" == *"--ac-power-only"* ]] || false
}

@test "notify: --notify with an unusable PRAETORIAN_HOME → no log directory created" {
    cd "${BATS_TEST_TMPDIR}"
    PRAETORIAN_HOME=relative/state run "${PRAETORIAN}" --notify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"PRAETORIAN_HOME is not usable"* ]] || false
    [ ! -e "${BATS_TEST_TMPDIR}/relative" ]
}
