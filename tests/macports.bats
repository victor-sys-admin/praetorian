#!/usr/bin/env bats
#
# MacPorts and --migrate tests (lib/macports.sh, lib/migrate.sh): the
# branches tests/praetorian.bats doesn't reach. Same fakes as there
# (tests/stubs); brew is wrapped in BATS_TEST_TMPDIR when a test needs it
# to behave differently.
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
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    LOGS="${HOME}/praetorian/logs"
    # Fake MacPorts installed in every test of this file.
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# A formula ready to migrate: wget, same commands on both sides.
wget_formula() {
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget"
    export PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/wget"
}

# in_praetorian '<bash code>': runs code with praetorian's functions loaded
# (sourcing doesn't run main).
in_praetorian() {
    bash -c "source '${PRAETORIAN}'; $1"
}

# --- --migrate -----------------------------------------------------------------

@test "--migrate: running Homebrew service → refused, nothing installed" {
    wget_formula
    mkdir -p "${HOME}/Library/LaunchAgents"
    touch "${HOME}/Library/LaunchAgents/homebrew.mxcl.wget.plist"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: wget runs as a Homebrew service"* ]] || false
    [[ "${output}" == *"brew services stop wget"* ]] || false
    run grep -q -- '-N install' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: port not found → refused, search command suggested" {
    export BREW_LIST_FILES="/usr/local/Cellar/node/24.1/bin/node"
    export PORT_AVAILABLE="nodejs22"
    # Named explicitly: node alone is a known trap (see tests/migrate.bats).
    run "${PRAETORIAN}" --migrate node=node
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: no MacPorts port named node"* ]] || false
    [[ "${output}" == *"Error: Port node not found"* ]] || false
    [[ "${output}" == *"port search --name --glob 'nodejs*'"* ]] || false
    [[ "${output}" == *"praetorian --migrate node=<port-name>"* ]] || false
    run grep -q -- '-N install' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: port already installed and active → no install, formula uninstalled" {
    wget_formula
    export PORT_ACTIVE="wget"
    touch "${PRAETORIAN_PORT_PREFIX}/bin/wget"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"wget already installed and active in MacPorts"* ]] || false
    run grep -q -- ' install ' "${PORT_CALLS}" "${SUDO_CALLS}"
    [ "${status}" -eq 1 ]
    # Marked as requested: "port uninstall leaves" won't take it away.
    grep -qx -- '-N setrequested wget' "${PORT_CALLS}"
    grep -qx 'uninstall --formula wget' "${BREW_CALLS}"
}

@test "--migrate: brew uninstall failing → blocked, migrated.tsv not written" {
    wget_formula
    # brew that fails "uninstall" only; everything else goes to the fake.
    local wrap="${BATS_TEST_TMPDIR}/brew_wrap"
    mkdir -p "${wrap}"
    cat >"${wrap}/brew" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == uninstall ]]; then
    printf '%s\n' "\$*" >>"\${BREW_CALLS}"
    echo "Error: Permission denied @ apply2files - /usr/local/Cellar/wget"
    exit 1
fi
exec "${BATS_TEST_DIRNAME}/stubs/brew" "\$@"
EOF
    chmod +x "${wrap}/brew"
    PATH="${wrap}:${PATH}" run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: uninstalling wget from Homebrew failed"* ]] || false
    [[ "${output}" == *"Error: Permission denied"* ]] || false
    [[ "${output}" == *"installed twice"* ]] || false
    [[ "${output}" != *"migrated to MacPorts"* ]] || false
    grep -qx -- '-N install wget' "${PORT_CALLS}"
    [ ! -e "${HOME}/praetorian/migrated.tsv" ]
}

@test "--migrate: install failing on another macOS → MacPorts migration steps" {
    wget_formula
    export PORT_INSTALL_RC=1
    export PORT_INSTALL_OUTPUT='Error: Current platform "darwin 25" does not match expected platform "darwin 24"'
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: MacPorts was installed for another macOS version"* ]] || false
    [[ "${output}" != *"installing wget with MacPorts failed"* ]] || false
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: only one block per failure, steps after it not run" {
    wget_formula
    export BREW_USES="curl"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 2 ]
    [ "$(grep -c 'BLOCKED:' <<<"${output}")" -eq 1 ]
    [[ "${output}" != *"No service or shell startup file"* ]] || false
    run grep -q 'info' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

# --- MacPorts maintenance -----------------------------------------------------

@test "MacPorts: main.log named by port → archived in *_portlogs.tar.gz" {
    local mainlog="${BATS_TEST_TMPDIR}/logs/wget/main.log"
    mkdir -p "${mainlog%/*}"
    echo "build log of wget" >"${mainlog}"
    export PORT_OUTDATED="wget" PORT_OUTDATED_AFTER="wget" PORT_UPGRADE_RC=1
    export PORT_UPGRADE_OUTPUT=$'Error: Failed to build wget: command execution failed\nError: See '"${mainlog}"$' for details.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    local archive
    archive=$(find "${LOGS}" -name 'praetorian_*_portlogs.tar.gz')
    [ -n "${archive}" ]
    run tar -tzf "${archive}"
    [ "${output}" = "${mainlog#/}" ]
}

@test "MacPorts: unreadable main.log → no archive" {
    export PORT_OUTDATED="wget" PORT_OUTDATED_AFTER="wget" PORT_UPGRADE_RC=1
    export PORT_UPGRADE_OUTPUT=$'Error: Failed to build wget: command execution failed\nError: See /nonexistent/main.log for details.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [ -z "$(find "${LOGS}" -name 'praetorian_*_portlogs.tar.gz')" ]
}

@test "MacPorts: selfupdate refused for another macOS → blocked, no upgrade" {
    export PORT_SELFUPDATE_RC=1 PORT_OUTDATED="wget"
    export PORT_SELFUPDATE_OUTPUT='Error: Current platform "darwin 25" does not match expected platform "darwin 24"'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: MacPorts was installed for another macOS version"* ]] || false
    [[ "${output}" == *'Current platform "darwin 25"'* ]] || false
    [[ "${output}" != *"port selfupdate failed"* ]] || false
    run grep -q upgrade "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "side by side: Homebrew before MacPorts in the PATH → warned" {
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    mkdir -p "${BREW_PREFIX}/bin"
    PATH="${BREW_PREFIX}/bin:${PRAETORIAN_PORT_PREFIX}/bin:${PATH}" run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew comes before MacPorts in the PATH"* ]] || false
}

@test "side by side: MacPorts before Homebrew in the PATH → no warning" {
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    mkdir -p "${BREW_PREFIX}/bin"
    PATH="${PRAETORIAN_PORT_PREFIX}/bin:${BREW_PREFIX}/bin:${PATH}" run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew / MacPorts side by side"* ]] || false
    [[ "${output}" != *"Homebrew comes before MacPorts"* ]] || false
}

# --- Unit: sudo safety --------------------------------------------------------

@test "unit: default prefix, port not trusted → blocked, even with a non-system sudo" {
    # The fake sudo comes first in the PATH, as MacPorts' sudo port would
    # with /opt/local/bin first: the check must still apply.
    unset PRAETORIAN_PORT_PREFIX
    run in_praetorian 'port_bin_trusted() { return 1; }; port_sudo_safe && echo yes || echo no'
    [[ "${output}" == *"BLOCKED: /opt/local/bin/port can't be trusted with sudo"* ]] || false
    [ "${lines[${#lines[@]} - 1]}" = "no" ]
}

@test "unit: default prefix, port trusted → allowed" {
    unset PRAETORIAN_PORT_PREFIX
    run in_praetorian 'port_bin_trusted() { return 0; }; port_sudo_safe && echo yes || echo no'
    [ "${output}" = "yes" ]
}

@test "unit: test prefix with the fake sudo → check skipped" {
    run in_praetorian 'port_sudo_safe && echo yes || echo no'
    [ "${output}" = "yes" ]
}

@test "unit: test prefix with a real sudo → port not owned by root blocked" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run in_praetorian 'port_sudo_is_real() { return 0; }; port_sudo_safe && echo yes || echo no'
    [[ "${output}" == *"can't be trusted with sudo"* ]] || false
    [ "${lines[${#lines[@]} - 1]}" = "no" ]
}

@test "unit: port_sudo_is_real tells a setuid-root sudo from a script" {
    run in_praetorian 'port_sudo_is_real && echo yes || echo no'
    [ "${output}" = "no" ]
    [ -n "$(find -L /usr/bin/sudo -maxdepth 0 -user 0 -perm -4000 2>/dev/null)" ] ||
        skip "no setuid-root /usr/bin/sudo here"
    run in_praetorian 'SUDO_CMD=(/usr/bin/sudo); port_sudo_is_real && echo yes || echo no'
    [ "${output}" = "yes" ]
}

@test "unit: port_bin_trusted refuses a relative prefix and a writable parent" {
    PRAETORIAN_PORT_PREFIX=opt run in_praetorian 'port_bin_trusted && echo yes || echo no'
    [ "${output}" = "no" ]
    run in_praetorian 'port_bin_trusted && echo yes || echo no'
    [ "${output}" = "no" ]
}

# --- Unit: helpers -------------------------------------------------------------

@test "unit: path_index, no pathname expansion of PATH entries" {
    mkdir -p "${BATS_TEST_TMPDIR}/g/abc"
    # shellcheck disable=SC2016  # expanded by the inner bash
    run in_praetorian "cd '${BATS_TEST_TMPDIR}/g'; PATH='/x:a*:/y/'; path_index /y; path_index 'a*'; path_index /z"
    [ "${output}" = $'2\n1\n-1' ]
}

@test "unit: migration_notes without a Homebrew prefix → no shell notes" {
    # shellcheck disable=SC2016  # $PATH stays literal: it's the file's content
    printf 'export PATH=/opt/wget/bin:$PATH\n' >"${HOME}/.zshrc"
    run in_praetorian "migration_notes wget ''"
    [ "${output}" = "" ]
    # shellcheck disable=SC2016
    printf 'export PATH=/usr/local/opt/wget/bin:$PATH\n' >"${HOME}/.zshrc"
    run in_praetorian "migration_notes wget /usr/local"
    [ "${output}" = " [referenced in ~/.zshrc]" ]
}
