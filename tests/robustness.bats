#!/usr/bin/env bats
#
# Robustness tests: half-installed cask reinstall with a way back, session
# lock races, environment values evaluated as numbers, dry-run leaving the
# state alone. Same fakes as tests/praetorian.bats (tests/stubs), plus a
# local brew wrapper for the cask reinstall.
#
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    STUBS="${BATS_TEST_DIRNAME}/stubs"
    export PATH="${STUBS}:${PATH}"
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls"
    export PORT_CALLS="${BATS_TEST_TMPDIR}/port_calls"
    export SUDO_CALLS="${BATS_TEST_TMPDIR}/sudo_calls"
    export OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    export CHOWN_CALLS="${BATS_TEST_TMPDIR}/chown_calls"
    export XCODEBUILD_CALLS="${BATS_TEST_TMPDIR}/xcodebuild_calls"
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    PHOME="${HOME}/praetorian"
    QUARANTINE="${PHOME}/quarantine.tsv"
    LOGS="${PHOME}/logs"
}

# Wraps the fake brew: "uninstall --cask" removes Caskroom/<cask>,
# "install --cask" creates Caskroom/<cask>/2.0 and exits with
# BREW_INSTALL_CASK_RC (default 0). Everything else goes to the fake.
with_cask_brew() {
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    cat >"${bin}/brew" <<EOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "uninstall --cask")
        printf '%s\n' "\$*" >>"\${BREW_CALLS}"
        rm -rf "\${BREW_CASKROOM}/\${!#}"
        exit 0
        ;;
    "install --cask")
        printf '%s\n' "\$*" >>"\${BREW_CALLS}"
        mkdir -p "\${BREW_CASKROOM}/\${!#}/2.0"
        exit "\${BREW_INSTALL_CASK_RC:-0}"
        ;;
esac
exec "${STUBS}/brew" "\$@"
EOF
    chmod +x "${bin}/brew"
    export PATH="${bin}:${PATH}"
    export BREW_CASKROOM="${BATS_TEST_TMPDIR}/Caskroom"
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1
    export BREW_CASK_OUTPUT="Error: It seems there is already a Font at '/x/Ubuntu.ttf'."
}

# --- Half-installed cask: Caskroom entry saved before the forced uninstall ---

@test "half-installed cask, reinstall OK → copy of the Caskroom entry removed" {
    with_cask_brew
    mkdir -p "${BREW_CASKROOM}/bar/1.0" "${BREW_CASKROOM}/bar/.metadata"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'uninstall --cask --force bar' "${BREW_CALLS}"
    grep -qx 'install --cask bar' "${BREW_CALLS}"
    [ -d "${BREW_CASKROOM}/bar/2.0" ]
    run find "${PHOME}" -maxdepth 1 -name '.cask_backup.*'
    [ -z "${output}" ]
}

@test "half-installed cask, reinstall fails → Caskroom entry put back, failure counted" {
    with_cask_brew
    export BREW_INSTALL_CASK_RC=1
    mkdir -p "${BREW_CASKROOM}/bar/1.0" "${BREW_CASKROOM}/bar/.metadata"
    echo cask >"${BREW_CASKROOM}/bar/.metadata/bar.json"
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"reinstall failed, its previous Caskroom entry was put back"* ]]
    [ -d "${BREW_CASKROOM}/bar/1.0" ]
    [ ! -e "${BREW_CASKROOM}/bar/2.0" ] # the failed install's leftovers are gone
    [ "$(cat "${BREW_CASKROOM}/bar/.metadata/bar.json")" = cask ]
    run find "${PHOME}" -maxdepth 1 -name '.cask_backup.*'
    [ -z "${output}" ]
}

@test "half-installed cask, Caskroom entry can't be saved → no forced uninstall" {
    with_cask_brew
    # No Caskroom/bar: nothing to copy.
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"couldn't be saved: not reinstalled"* ]]
    run grep -E '^(uninstall|install) ' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

# --- Environment values never evaluated as expressions -----------------------

@test "PRAETORIAN_MIN_FREE_GB with an expression: not run, default used" {
    export PRAETORIAN_MIN_FREE_GB="PATH[\$(touch ${BATS_TEST_TMPDIR}/pwned)]"
    run "${PRAETORIAN}" --dry-run
    [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
    [[ "${output}" == *"PRAETORIAN_MIN_FREE_GB is not a whole number"* ]]
    [ "${status}" -eq 0 ]
}

@test "PRAETORIAN_MIN_FREE_GB with a leading zero: read as decimal" {
    export PRAETORIAN_MIN_FREE_GB=08
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"unexpected error"* ]]
    [[ "${output}" != *"not a whole number"* ]]
}

# --- Session lock ------------------------------------------------------------

@test "lock without a PID, just created: another session is starting, blocked" {
    mkdir -p "${PHOME}/.lock"
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: couldn't take the session lock"* ]]
    [ ! -s "${BREW_CALLS}" ]
    [ -d "${PHOME}/.lock" ]
}

@test "lock without a PID, old: stale, taken over then released" {
    mkdir -p "${PHOME}/.lock"
    touch -t 202001010000 "${PHOME}/.lock"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Lock left by a session that ended abruptly (PID unknown"* ]]
    [ ! -e "${PHOME}/.lock" ]
    run find "${PHOME}" -maxdepth 1 -name '.lock*'
    [ -z "${output}" ]
}

@test "lock: PID written whole, no temporary file left" {
    run bash -c "source '${PRAETORIAN}'; DRY_RUN=true; acquire_lock; cat '${PHOME}/.lock/pid'; echo \$\$; ls -A '${PHOME}/.lock'"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "${lines[1]}" ]
    [ "${lines[2]}" = pid ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "lock: a lock that is not ours is left alone at exit" {
    run bash -c "source '${PRAETORIAN}'; acquire_lock; echo 1 >'${PHOME}/.lock/pid'; finish 0"
    [ "${status}" -eq 0 ]
    [ -d "${PHOME}/.lock" ]
}

# --- Dry-run changes no state ------------------------------------------------

@test "dry-run: old logs are counted, not removed" {
    mkdir -p "${LOGS}"
    local i
    for i in $(seq 1 35); do
        touch "${LOGS}/praetorian_20200101_0000$(printf '%02d' "${i}").log"
    done
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"old log file(s) would be removed"* ]]
    [ -e "${LOGS}/praetorian_20200101_000001.log" ]
    [ "$(find "${LOGS}" -name 'praetorian_2020*.log' | wc -l | tr -d ' ')" -eq 35 ]
}

# --- Toolchain recorded even without quarantine ------------------------------

@test ".toolchain written even when quarantine.tsv doesn't exist" {
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ ! -e "${QUARANTINE}" ]
    [ -s "${PHOME}/.toolchain" ]
}

@test "dry-run: .toolchain not written" {
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [ ! -e "${PHOME}/.toolchain" ]
}

# --- Formula names are never glob-expanded -----------------------------------

@test "failed build whose name looks like a glob: quarantined as is" {
    mkdir -p "${BATS_TEST_TMPDIR}/cwd"
    touch "${BATS_TEST_TMPDIR}/cwd/foo-decoy"
    cd "${BATS_TEST_TMPDIR}/cwd"
    export BREW_OUTDATED_FORMULA='foo*' BREW_UPGRADE_RC=1
    export BREW_UPGRADE_OUTPUT='Last 15 lines from /h/Library/Logs/Homebrew/foo*/01.configure:'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    run cut -f1 "${QUARANTINE}"
    [ "${output}" = 'foo*' ]
}
