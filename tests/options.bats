#!/usr/bin/env bats
#
# praetorian tests: options, prerequisites, signals and end-of-session
# reports that tests/praetorian.bats doesn't cover. Same setup: fakes of
# tests/stubs in front of the PATH, HOME in a temp directory, no terminal
# (unattended mode, see tests/interactive.bats for the terminal side).
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
    # No MacPorts by default (see with_macports).
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    QUARANTINE="${HOME}/praetorian/quarantine.tsv"
    LOGS="${HOME}/praetorian/logs"
}

teardown() {
    # A failed signal test may leave the hanging fake brew behind.
    local brew_pid child_pid
    if [[ -f "${BREW_CALLS}.hang" ]]; then
        read -r brew_pid child_pid <"${BREW_CALLS}.hang"
        kill "${brew_pid}" "${child_pid}" 2>/dev/null || true
    fi
    [[ -z "${PRAETORIAN_PID:-}" ]] || kill "${PRAETORIAN_PID}" 2>/dev/null || true
}

# Installs the fake port in the test's MacPorts prefix.
with_macports() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# Skips the test when a real Homebrew sits at a standard location:
# praetorian looks there too, outside the PATH.
skip_if_real_brew() {
    if [[ -x /usr/local/bin/brew || -x /opt/homebrew/bin/brew ]]; then
        skip "a real Homebrew is installed on this machine"
    fi
}

# PATH without the fake brew (the other fakes stay).
path_without_brew() {
    local stubs="${BATS_TEST_TMPDIR}/stubs_nobrew" f
    mkdir -p "${stubs}"
    for f in "${BATS_TEST_DIRNAME}"/stubs/*; do
        [[ "${f##*/}" == brew ]] || cp "${f}" "${stubs}/"
    done
    printf '%s' "${stubs}:${PATH//${BATS_TEST_DIRNAME}\/stubs:/}"
}

# Is the process gone (or a zombie waiting to be reaped)?
process_gone() {
    local pid=$1 i
    for ((i = 0; i < 50; i++)); do
        kill -0 "${pid}" 2>/dev/null || return 0
        if [[ -r "/proc/${pid}/stat" ]] && [[ "$(awk '{print $3}' "/proc/${pid}/stat")" == Z ]]; then
            return 0
        fi
        [[ "$(ps -o stat= -p "${pid}" 2>/dev/null)" == Z* ]] && return 0
        sleep 0.2
    done
    return 1
}

# --- Options ---------------------------------------------------------------------

@test "--quiet: nothing on screen for a clean session, everything in the log" {
    export BREW_OUTDATED_FORMULA=foo
    run "${PRAETORIAN}" --quiet
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    grep -qx 'upgrade --formula foo' "${BREW_CALLS}"
    grep -q 'OUT: .*Maintenance completed successfully.' "${LOGS}"/praetorian_*[0-9].log
}

@test "--quiet: failed steps stay silent, blocks are still shown" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1
    run "${PRAETORIAN}" --quiet
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    export PRAETORIAN_MIN_FREE_GB=999999999
    run "${PRAETORIAN}" --quiet
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: not enough disk space"* ]] || false
    [[ "${output}" == *"What to do"* ]] || false
}

@test "casks: --greedy by default" {
    export BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'outdated --cask --greedy --quiet' "${BREW_CALLS}"
    grep -qx 'upgrade --cask --greedy bar' "${BREW_CALLS}"
}

@test "--no-greedy: casks listed and upgraded without --greedy" {
    export BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}" --no-greedy
    [ "${status}" -eq 0 ]
    grep -qx 'outdated --cask --quiet' "${BREW_CALLS}"
    grep -qx 'upgrade --cask bar' "${BREW_CALLS}"
    run grep -q -- --greedy "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--retry-quarantined: quarantined formula and cask retried, entries kept" {
    mkdir -p "${HOME}/praetorian"
    printf 'foo\tformula\t%s\tbuild\tbuild failed\nbar\tcask\t%s\tpkg\tx\n' "$(date +%s)" "$(date +%s)" >"${QUARANTINE}"
    export BREW_OUTDATED_FORMULA=foo BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}" --retry-quarantined
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Quarantine ignored (--retry-quarantined)"* ]] || false
    [[ "${output}" != *"in quarantine, skipped"* ]] || false
    grep -qx 'upgrade --formula foo' "${BREW_CALLS}"
    grep -qx 'upgrade --cask --greedy bar' "${BREW_CALLS}"
    [ "$(wc -l <"${QUARANTINE}" | tr -d ' ')" -eq 2 ]
}

@test "--unattended without a terminal: same behavior, notification sent" {
    with_macports
    export BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}" --unattended
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Unattended: apps that need sudo will be deferred."* ]] || false
    grep -q -- "^-n ${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
    grep -qx 'Maintenance completed successfully.' "${OSASCRIPT_CALLS}"
}

@test "--dry-run: no notification" {
    run "${PRAETORIAN}" --dry-run --unattended
    [ "${status}" -eq 0 ]
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

# --- Prerequisites ---------------------------------------------------------------

@test "no package manager at all: blocked, nothing done" {
    skip_if_real_brew
    PATH=$(path_without_brew) run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: no package manager found"* ]] || false
    [[ "${output}" == *"https://www.macports.org/install.php"* ]] || false
    [[ "${output}" == *"https://brew.sh"* ]] || false
    [[ "${output}" != *"unexpected error"* ]] || false
    [ ! -e "${HOME}/praetorian/.lock" ]
}

@test "MacPorts prefix without port: incomplete install reported, Homebrew part runs" {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${PRAETORIAN_PORT_PREFIX} exists but ${PRAETORIAN_PORT_PREFIX}/bin/port is missing"* ]] || false
    grep -qx 'update' "${BREW_CALLS}"
}

# Copies praetorian and lib/ into a scratch directory owned by whoever
# runs the test (as root: owned by root, like a root-owned install).
scratch_copy() {
    SCRATCH="${BATS_TEST_TMPDIR}/copy"
    mkdir -p "${SCRATCH}"
    cp "${PRAETORIAN}" "${SCRATCH}/praetorian"
    cp -R "${BATS_TEST_DIRNAME}/../lib" "${SCRATCH}/lib"
    chmod 755 "${SCRATCH}/lib"
    chmod 644 "${SCRATCH}"/lib/*.sh
}

@test "started as root: blocked before anything runs" {
    # EUID can't be faked: real root, or root in a user namespace (Linux).
    local -a as_root=()
    if [[ "$(id -u)" -eq 0 ]]; then
        as_root=()
    elif command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
        as_root=(unshare -r)
    else
        skip "can't run as root here (not root, no unshare -r)"
    fi
    # A copy owned by the user running the test: as real root, a repository
    # owned by someone else is refused earlier, by the lib/ check.
    scratch_copy
    run "${as_root[@]+"${as_root[@]}"}" "${SCRATCH}/praetorian"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: praetorian was started as root"* ]] || false
    [[ "${output}" == *"Run it again without sudo"* ]] || false
    [[ "${output}" != *"unexpected error"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

@test "lib/: file owned by another user → refused" {
    # Only root can give a file away (chown); not root in a user namespace,
    # where no other user exists.
    [ "$(id -u)" -eq 0 ] || skip "needs root to chown a file to another user"
    scratch_copy
    # command -p: the real chown, not the fake one of tests/stubs.
    command -p chown 65534 "${SCRATCH}/lib/report.sh"
    run "${SCRATCH}/praetorian" --help
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"lib/report.sh belongs to another user"* ]] || false
}

# --- caffeinate --------------------------------------------------------------------

# Fake caffeinate in front of the PATH: records its arguments in
# $CAFFEINATE_CALLS, then runs the command (like the real one, -i dropped).
with_fake_caffeinate() {
    local dir="${BATS_TEST_TMPDIR}/caffeinate_bin"
    export CAFFEINATE_CALLS="${BATS_TEST_TMPDIR}/caffeinate_calls"
    : >"${CAFFEINATE_CALLS}"
    mkdir -p "${dir}"
    cat >"${dir}/caffeinate" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CAFFEINATE_CALLS}"
[[ "${1:-}" == -i ]] && shift
exec "$@"
EOF
    chmod 755 "${dir}/caffeinate"
    export PATH="${dir}:${PATH}"
    unset PRAETORIAN_CAFFEINATED
}

@test "caffeinate: session run once under caffeinate -i, options passed on, no loop" {
    with_fake_caffeinate
    export BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}" --no-greedy
    [ "${status}" -eq 0 ]
    [ "$(wc -l <"${CAFFEINATE_CALLS}" | tr -d ' ')" -eq 1 ]
    [ "$(cat "${CAFFEINATE_CALLS}")" = "-i ${PRAETORIAN} --no-greedy" ]
    grep -qx 'upgrade --cask bar' "${BREW_CALLS}"
    [ "$(grep -cx 'update' "${BREW_CALLS}")" -eq 1 ]
}

@test "caffeinate: not used for --dry-run nor --migration-report" {
    with_fake_caffeinate
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    run "${PRAETORIAN}" --migration-report
    [ ! -s "${CAFFEINATE_CALLS}" ]
}

# --- Interruption --------------------------------------------------------------------

@test "SIGTERM during a step: code 130, step's processes killed, lock released" {
    # caffeinate (macOS) would take the signal instead of praetorian.
    export PRAETORIAN_CAFFEINATED=1
    export BREW_HANG_ON=update BREW_OUTDATED_FORMULA=foo
    local out="${BATS_TEST_TMPDIR}/out" i rc=0 brew_pid child_pid
    "${PRAETORIAN}" >"${out}" 2>&1 </dev/null &
    PRAETORIAN_PID=$!
    for ((i = 0; i < 100; i++)); do
        [[ -s "${BREW_CALLS}.hang" ]] && break
        sleep 0.2
    done
    [ -s "${BREW_CALLS}.hang" ]
    read -r brew_pid child_pid <"${BREW_CALLS}.hang"
    [ -d "${HOME}/praetorian/.lock" ]
    kill -TERM "${PRAETORIAN_PID}"
    wait "${PRAETORIAN_PID}" || rc=$?
    cat "${out}"
    [ "${rc}" -eq 130 ]
    grep -q 'Interrupted (Ctrl-C) — session stopped' "${out}"
    grep -q 'Step cut short: Updating the index (brew update)' "${out}"
    run grep -q 'unexpected error' "${out}"
    [ "${status}" -eq 1 ]
    [ ! -e "${HOME}/praetorian/.lock" ]
    process_gone "${brew_pid}"
    process_gone "${child_pid}"
    # The following steps were not run.
    run grep -E '^(outdated|fetch|upgrade|doctor)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    # Interrupted on purpose: no "Stopped" notification.
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

# --- Output analysis and reports ---------------------------------------------------

@test "brew doctor warnings: reported and counted, not a failure" {
    export BREW_DOCTOR_RC=1
    export BREW_DOCTOR_OUTPUT=$'Warning: Some installed formulae are deprecated.\n\nWarning: Unbrewed dylibs were found in /usr/local/lib.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"brew doctor reports 2 warning(s)"* ]] || false
    [[ "${output}" != *"Failed steps"* ]] || false
    [[ "${output}" == *"Maintenance completed successfully."* ]] || false
    grep -q 'Unbrewed dylibs were found' "${LOGS}"/praetorian_*[0-9].log
}

@test "brew doctor clean: healthy" {
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"System healthy — no warning."* ]] || false
}

@test "cask pkg script failing → cask quarantined (pkg), hint shown, skipped next time" {
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1
    # shellcheck disable=SC2016  # literal backquotes, as brew prints them
    export BREW_CASK_OUTPUT='Error: bar: Failure while executing; `/usr/bin/sudo -u root -E -- /usr/sbin/installer -pkg /x/Caskroom/bar/1.0/bar.pkg -target /` exited with 1.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    run cut -f1,2,4,5 "${QUARANTINE}"
    [ "${output}" = $'bar\tcask\tpkg\tcask pkg script failed' ]
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 package(s) in quarantine"* ]] || false
    [[ "${output}" == *"- bar"*"run brew upgrade --cask <name> by hand"* ]] || false
    [ "$(grep -cx 'upgrade --cask --greedy bar' "${BREW_CALLS}")" -eq 1 ]
}

@test "network failure: reported in the summary, not quarantined" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1
    export BREW_UPGRADE_OUTPUT='curl: (6) Could not resolve host: ghcr.io'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Network: download(s) failed (DNS/connection)"* ]] || false
    [[ "${output}" == *"- Upgrading formula foo"* ]] || false
    [ ! -s "${QUARANTINE}" ]
}

@test "unused apps section shown without error" {
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"── Unused apps (> 6 months)"* ]] || false
    [[ "${output}" == *"No app unused for more than 6 months."* ||
        "${output}" == *"app(s) not used for more than 6 months:"* ||
        "${output}" == *"Folder /Applications not found, step skipped."* ]]
    [[ "${output}" != *"unexpected error"* ]] || false
}

@test "build logs written during the session → archived before brew cleanup" {
    command -v tar >/dev/null || skip "tar not available"
    local brew_logs="${HOME}/Library/Logs/Homebrew"
    mkdir -p "${brew_logs}/old"
    touch -t 202001010000 "${brew_logs}/old"
    export BREW_OUTDATED_FORMULA=foo BREW_BUILD_LOG=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    local archive
    archive=$(find "${LOGS}" -name 'praetorian_*_buildlogs.tar.gz')
    [ -n "${archive}" ]
    run tar -tzf "${archive}"
    [[ "${output}" == *"foo/01.make.log"* ]] || false
    [[ "${output}" != *"old"* ]] || false
}

@test "no build log written during the session → no archive" {
    mkdir -p "${HOME}/Library/Logs/Homebrew/old"
    touch -t 202001010000 "${HOME}/Library/Logs/Homebrew/old"
    export BREW_OUTDATED_FORMULA=foo
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ -z "$(find "${LOGS}" -name 'praetorian_*_buildlogs.tar.gz')" ]
}

@test "network: unattended, no network → blocked, explained, nothing run" {
    export CURL_DOWN_FOR=99 CURL_CALLS="${BATS_TEST_TMPDIR}/curl_calls"
    PRAETORIAN_NETWORK_WAIT=0 run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: no network (github.com unreachable after 0 s)"* ]] || false
    [[ "${output}" == *"The next scheduled run goes ahead."* ]] || false
    [[ "${output}" != *"unexpected error"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
    [ ! -e "${HOME}/praetorian/.lock" ]
}

@test "network: back after a retry → session runs, wait logged" {
    export CURL_DOWN_FOR=1 CURL_CALLS="${BATS_TEST_TMPDIR}/curl_calls"
    PRAETORIAN_NETWORK_WAIT=1 run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'update' "${BREW_CALLS}"
    grep -q 'Network: back after 1 s' "${LOGS}"/praetorian_*.log
}

@test "network: --dry-run without network → warning only" {
    export CURL_DOWN_FOR=99 CURL_CALLS="${BATS_TEST_TMPDIR}/curl_calls"
    PRAETORIAN_NETWORK_WAIT=0 run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No network (github.com unreachable): a real session would be blocked."* ]] || false
}

@test "network: invalid PRAETORIAN_NETWORK_WAIT → default used, never evaluated" {
    # Single quotes on purpose: the $(…) must reach praetorian unexpanded.
    # shellcheck disable=SC2016
    PRAETORIAN_NETWORK_WAIT='a[$(touch "${BATS_TEST_TMPDIR}/pwned")]' run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PRAETORIAN_NETWORK_WAIT is not a whole number of seconds"* ]] || false
    [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
}
