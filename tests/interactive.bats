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
    [[ "${output}" != *"Unattended"* ]]
    [[ "${output}" == *"Some apps will ask for "* ]]
    [[ "${output}" == *"MacPorts needs sudo"* ]]
    grep -qx "${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
    grep -qx "${PRAETORIAN_PORT_PREFIX}/bin/port -N -p upgrade wget" "${SUDO_CALLS}"
    run grep -q -- '^-n ' "${SUDO_CALLS}"
    [ "${status}" -eq 1 ]
    # Notification: unattended mode only.
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
    [[ "${output}" == *"Unattended: apps that need sudo will be deferred."* ]]
    [[ "${output}" == *"Deferred (needs sudo"* ]]
    grep -qx -- "-n ${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
    grep -qx 'Done. To do from a terminal (sudo): cask bar' "${OSASCRIPT_CALLS}"
}

@test "interactive: brew errors are summarized, colors only on a terminal" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_OUTPUT='Error: foo: something broke'
    local raw="${BATS_TEST_TMPDIR}/pty_out"
    run in_pty "${PRAETORIAN}" </dev/null
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Problems found in the brew / port output:"* ]]
    [[ "${output}" == *"- Error: foo: something broke"* ]]
    grep -q $'\033\\[' "${raw}"
}
