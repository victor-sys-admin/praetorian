#!/usr/bin/env bats
#
# praetorian tests in interactive mode: praetorian runs under a
# pseudo-terminal (script), so that stdin is a terminal as when it's
# started by hand. The other test files run without a terminal, i.e.
# always in unattended mode.
#
# Needs script(1): BSD (macOS) or util-linux. Skipped without it (the
# Alpine/BusyBox bats container of ci/check has none: these tests run on
# macOS, through ci/macos-tests).
#
# "[[ … ]] || false": these tests only run under macOS's bash 3.2, where a
# failing [[ ]] that isn't a test's last command doesn't fail the test
# (bash < 4.1 doesn't trigger errexit for it). The other files also run
# under bash 5 in the Linux container, which catches them.
#
# Each @test runs in its own subshell: the exported variables are meant to
# stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
    if [[ "$(uname -s)" == Darwin ]]; then
        PTY_STYLE=bsd
    elif script --version 2>/dev/null | grep -q util-linux; then
        PTY_STYLE=util-linux
    else
        skip "no script(1) to provide a pseudo-terminal"
    fi
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

# Installs the fake port in the test's MacPorts prefix.
with_macports() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# in_pty cmd [args…]: runs the command under a pseudo-terminal, stdin of
# the pseudo-terminal fed from in_pty's stdin. Output without carriage
# returns nor colors; exit code of the command.
in_pty() {
    local rc=0 raw="${BATS_TEST_TMPDIR}/pty_out"
    if [[ "${PTY_STYLE}" == bsd ]]; then
        script -q /dev/null "$@" >"${raw}" 2>&1 || rc=$?
    else
        script -qec "$(printf '%q ' "$@")" /dev/null >"${raw}" 2>&1 || rc=$?
    fi
    tr -d '\r' <"${raw}" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
    return "${rc}"
}

# feed_line <ready file> <line> <done file>: once <ready file> exists,
# writes the line, then waits for <done file> (the pseudo-terminal would
# get an end of file otherwise). 30 s at most for each.
feed_line() {
    local i
    for ((i = 0; i < 150; i++)); do
        [[ -e "$1" ]] && break
        sleep 0.2
    done
    printf '%s\n' "$2"
    for ((i = 0; i < 150; i++)); do
        [[ -s "$3" && "$(wc -l <"$3")" -ge 2 ]] && break
        sleep 0.2
    done
}

@test "interactive: not unattended, MacPorts through sudo WITHOUT -n" {
    with_macports
    export PORT_OUTDATED=wget BREW_OUTDATED_CASK=bar
    run in_pty "${PRAETORIAN}" </dev/null
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Unattended"* ]] || false
    [[ "${output}" == *"Some apps will ask for "* ]] || false
    [[ "${output}" == *"MacPorts needs sudo"* ]] || false
    grep -qx "${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
    grep -qx "${PRAETORIAN_PORT_PREFIX}/bin/port -N -p upgrade wget" "${SUDO_CALLS}"
    run grep -q -- '^-n ' "${SUDO_CALLS}"
    [ "${status}" -eq 1 ]
    # From a terminal, a short session doesn't notify (see below).
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "interactive: session longer than PRAETORIAN_NOTIFY_AFTER → notification with a sound" {
    PRAETORIAN_NOTIFY_AFTER=0 run in_pty "${PRAETORIAN}" </dev/null
    [ "${status}" -eq 0 ]
    grep -qx 'Maintenance completed successfully.' "${OSASCRIPT_CALLS}"
    # The alert sound of System Settings > Sound (fake defaults: Tink).
    [ "$(tail -n 1 "${OSASCRIPT_CALLS}")" = Tink ]
}

@test "interactive + --notify, failure → notification with the same alert sound" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_OUTPUT='Error: foo: something broke'
    run in_pty "${PRAETORIAN}" --notify </dev/null
    [ "${status}" -eq 2 ]
    grep -q '^Finished with errors (' "${OSASCRIPT_CALLS}"
    [ "$(tail -n 1 "${OSASCRIPT_CALLS}")" = Tink ]
}

@test "interactive: the alert sound set in System Settings is used" {
    DEFAULTS_BEEP_SOUND=/System/Library/Sounds/Submarine.aiff run in_pty "${PRAETORIAN}" --notify </dev/null
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${OSASCRIPT_CALLS}")" = Submarine ]
}

@test "interactive: alert sound setting unreadable → Glass" {
    DEFAULTS_BEEP_SOUND="" run in_pty "${PRAETORIAN}" --notify </dev/null
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${OSASCRIPT_CALLS}")" = Glass ]
}

@test "interactive: PRAETORIAN_NOTIFY_AFTER not a number → default (no command run from it)" {
    local marker="${BATS_TEST_TMPDIR}/evaluated"
    PRAETORIAN_NOTIFY_AFTER="a[\$(touch ${marker})]" run in_pty "${PRAETORIAN}" </dev/null
    [ "${status}" -eq 0 ]
    [ ! -e "${marker}" ]
    # Default 300 s: a short session doesn't notify.
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "interactive: the terminal reaches the step's command (stdin, fd 3)" {
    export BREW_STDIN_FILE="${BATS_TEST_TMPDIR}/stdin"
    run in_pty "${PRAETORIAN}" < <(feed_line "${BREW_STDIN_FILE}.ready" "typed-by-hand" "${BREW_STDIN_FILE}")
    [ "${status}" -eq 0 ]
    [ "$(sed -n 1p "${BREW_STDIN_FILE}")" = tty ]
    [ "$(sed -n 2p "${BREW_STDIN_FILE}")" = "line=typed-by-hand" ]
}

@test "interactive + --unattended: sudo -n, casks deferred, notification" {
    with_macports
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1 BREW_CASK_OUTPUT='sudo: a password is required'
    run in_pty "${PRAETORIAN}" --unattended </dev/null
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Unattended: apps that need sudo will be deferred."* ]] || false
    [[ "${output}" == *"Deferred (needs sudo"* ]] || false
    grep -qx -- "-n ${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
    grep -qx 'Done. To do from a terminal (sudo): cask bar' "${OSASCRIPT_CALLS}"
}

@test "interactive: brew errors are summarized, colors only on a terminal" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_OUTPUT='Error: foo: something broke'
    local raw="${BATS_TEST_TMPDIR}/pty_out"
    run in_pty "${PRAETORIAN}" </dev/null
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Problems found in the brew / port output:"* ]] || false
    [[ "${output}" == *"- Error: foo: something broke"* ]] || false
    grep -q $'\033\\[' "${raw}"
}
