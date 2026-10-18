#!/usr/bin/env bats
#
# Xcode readiness (check_xcode_ready): only the command for the problem
# found, and the macOS update named when it's why the first launch has to
# run again. Same fakes as tests/praetorian.bats (xcode-select,
# xcodebuild), plus a local sw_vers.
#
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${BIN}"
    export PATH="${BIN}:${BATS_TEST_DIRNAME}/stubs:${PATH}"
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls"
    export PORT_CALLS="${BATS_TEST_TMPDIR}/port_calls"
    export SUDO_CALLS="${BATS_TEST_TMPDIR}/sudo_calls"
    export OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    export XCODEBUILD_CALLS="${BATS_TEST_TMPDIR}/xcodebuild_calls"
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    PHOME="${HOME}/praetorian"
    VERSION_FILE="${PHOME}/.macos_version"
    # Xcode selected: has_full_xcode is true even without
    # /Applications/Xcode.app (Linux).
    export XCODE_SELECT_PATH=/Applications/Xcode.app/Contents/Developer
    fake_sw_vers 15.8.1
}

# fake_sw_vers <version>: what "sw_vers -productVersion" answers.
fake_sw_vers() {
    printf '#!/bin/sh\necho %s\n' "$1" >"${BIN}/sw_vers"
    chmod +x "${BIN}/sw_vers"
}

@test "Xcode license not accepted → only the license command" {
    export XCODEBUILD_LICENSE_RC=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: Xcode isn't ready"* ]] || false
    [[ "${output}" == *"The Xcode license hasn't been accepted."* ]] || false
    [[ "${output}" == *"sudo xcodebuild -license accept"* ]] || false
    [[ "${output}" != *"xcode-select -s"* ]] || false
    [[ "${output}" != *"-runFirstLaunch"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

@test "Xcode first launch not finished, same macOS → only -runFirstLaunch, no macOS update named" {
    export XCODEBUILD_FIRSTLAUNCH_RC=1
    mkdir -p "${PHOME}"
    echo 15.8.1 >"${VERSION_FILE}"
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Xcode's first launch isn't finished."* ]] || false
    [[ "${output}" == *"sudo xcodebuild -runFirstLaunch"* ]] || false
    [[ "${output}" != *"-license accept"* ]] || false
    [[ "${output}" != *"xcode-select -s"* ]] || false
    [[ "${output}" != *"macOS was updated"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

@test "Xcode first launch not finished after a macOS update → the update is named, version kept" {
    export XCODEBUILD_FIRSTLAUNCH_RC=1
    mkdir -p "${PHOME}"
    echo 15.7.4 >"${VERSION_FILE}"
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"macOS was updated (15.7.4 → 15.8.1): Xcode has to reinstall its system components"* ]] || false
    [[ "${output}" == *"sudo xcodebuild -runFirstLaunch"* ]] || false
    # Still the old version: the next session explains the block the same way.
    [ "$(cat "${VERSION_FILE}")" = 15.7.4 ]
    run "${PRAETORIAN}"
    [[ "${output}" == *"macOS was updated (15.7.4 → 15.8.1)"* ]] || false
}

@test "Xcode first launch not finished, first session (no recorded version) → no macOS update named" {
    export XCODEBUILD_FIRSTLAUNCH_RC=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Xcode's first launch isn't finished."* ]] || false
    [[ "${output}" != *"macOS was updated"* ]] || false
}

@test "Xcode ready → the session goes on and records the macOS version" {
    mkdir -p "${PHOME}"
    echo 15.7.4 >"${VERSION_FILE}"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Xcode isn't ready"* ]] || false
    [ "$(cat "${VERSION_FILE}")" = 15.8.1 ]
}

@test "Xcode installed but not selected → only xcode-select -s" {
    mkdir -p "${PHOME}/logs"
    export XCODE_SELECT_PATH=/Library/Developer/CommandLineTools
    run bash -c "source '${PRAETORIAN}'; has_full_xcode() { return 0; }; check_xcode_ready"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Xcode is installed but not selected (xcode-select -p = /Library/Developer/CommandLineTools)."* ]] || false
    [[ "${output}" == *"sudo xcode-select -s /Applications/Xcode.app"* ]] || false
    [[ "${output}" != *"-license accept"* ]] || false
    [[ "${output}" != *"-runFirstLaunch"* ]] || false
}

@test "no full Xcode → no block, macOS version recorded all the same" {
    mkdir -p "${PHOME}/logs"
    run bash -c "source '${PRAETORIAN}'; has_full_xcode() { return 1; }; check_xcode_ready; echo done"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"done"* ]] || false
    [ "$(cat "${VERSION_FILE}")" = 15.8.1 ]
}

@test "dry-run: the macOS version isn't recorded" {
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [ ! -e "${VERSION_FILE}" ]
}
