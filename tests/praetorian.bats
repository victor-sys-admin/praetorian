#!/usr/bin/env bats
#
# praetorian tests on Linux (bats container, see ci/check): brew, port,
# sudo and mktemp are replaced by the fakes in tests/stubs, nothing is
# installed. Without a terminal, praetorian switches to unattended mode on
# its own. ci/macos-tests runs the same file on macOS under /bin/bash 3.2.
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

# Installs the fake port in the test's MacPorts prefix.
with_macports() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

@test "--help prints the usage" {
    run "${PRAETORIAN}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: praetorian"* ]] || false
}

@test "version: --help shows PRAETORIAN_VERSION, a X.Y.Z version" {
    local version
    version=$(sed -nE 's/^readonly PRAETORIAN_VERSION="([^"]*)"$/\1/p' "${BATS_TEST_DIRNAME}/../praetorian")
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || false
    run "${PRAETORIAN}" --help
    [[ "${output}" == *"praetorian ${version} "* ]] || false
}

@test "version: README's latest release and CHANGELOG's top entry match PRAETORIAN_VERSION" {
    local root="${BATS_TEST_DIRNAME}/.." version readme changelog
    version=$(sed -nE 's/^readonly PRAETORIAN_VERSION="([^"]*)"$/\1/p' "${root}/praetorian")
    readme=$(sed -n '/^## Latest release/,/^## /p' "${root}/README.md" | sed -nE 's/^### ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)
    changelog=$(sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+) .*/\1/p' "${root}/CHANGELOG.md" | head -n 1)
    [ "${readme}" = "${version}" ]
    [ "${changelog}" = "${version}" ]
}

@test "unknown option: code 1" {
    run "${PRAETORIAN}" --nope
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown option: --nope"* ]] || false
}

@test "dry-run: no brew command that changes the system" {
    export BREW_OUTDATED_FORMULA=foo BREW_OUTDATED_CASK=bar
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Maintenance completed successfully."* ]] || false
    run grep -E '^(update|upgrade|fetch|install|uninstall|reinstall|cleanup|autoremove|link|unlink)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "full Xcode required: formula quarantined, code 2" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1
    export BREW_UPGRADE_OUTPUT=$'foo: A full installation of Xcode.app is required to compile\nthis software. Installing just the Command Line Tools is not sufficient.\nError: foo: An unsatisfied requirement failed this build.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Quarantined"* ]] || false
    run cut -f1,2,4 "${QUARANTINE}"
    [ "${output}" = $'foo\tformula\txcode' ]
}

@test "quarantined formula: skipped by the next session" {
    mkdir -p "${HOME}/praetorian"
    # "build", not "xcode": an xcode entry is lifted on a Mac with Xcode.
    printf 'foo\tformula\t%s\tbuild\tbuild failed\n' "$(date +%s)" >"${QUARANTINE}"
    export BREW_OUTDATED_FORMULA=foo
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 package(s) in quarantine"* ]] || false
    run grep -E '^(fetch|upgrade --formula)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "expired quarantine: the formula is retried" {
    mkdir -p "${HOME}/praetorian"
    printf 'foo\tformula\t%s\txcode\tfull Xcode required\n' "$(($(date +%s) - 31 * 86400))" >"${QUARANTINE}"
    export BREW_OUTDATED_FORMULA=foo
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'upgrade --formula foo' "${BREW_CALLS}"
    [ ! -s "${QUARANTINE}" ]
}

@test "cask needing sudo without a terminal: deferred, not failed" {
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1
    export BREW_CASK_OUTPUT='sudo: a password is required'
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Deferred (needs sudo"* ]] || false
    [[ "${output}" == *"cask bar"* ]] || false
    [ ! -s "${QUARANTINE}" ]
}

# --- Fail-safe: lock and disk space -------------------------------------------

@test "another session running: blocked with an explanation, nothing run" {
    mkdir -p "${HOME}/praetorian/.lock"
    sleep 60 &
    local pid=$!
    echo "${pid}" >"${HOME}/praetorian/.lock/pid"
    run "${PRAETORIAN}"
    kill "${pid}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: another praetorian session is already running (PID ${pid})"* ]] || false
    [[ "${output}" == *"What to do"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
    [ -d "${HOME}/praetorian/.lock" ] # the other session's lock stays
}

@test "lock of a dead session: taken over, then released at the end" {
    mkdir -p "${HOME}/praetorian/.lock"
    echo 999999 >"${HOME}/praetorian/.lock/pid"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Lock left by a session that ended abruptly"* ]] || false
    [ ! -e "${HOME}/praetorian/.lock" ]
}

@test "disk almost full: blocked before any command" {
    export PRAETORIAN_MIN_FREE_GB=999999999
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: not enough disk space"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

# --- MacPorts ------------------------------------------------------------------

@test "MacPorts: selfupdate then upgrade of the outdated ports, through sudo" {
    with_macports
    # sudo "available" while unattended: simulates a NOPASSWD rule.
    export PORT_OUTDATED="wget curl"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx -- '-N selfupdate' "${PORT_CALLS}"
    grep -qx -- '-N -p upgrade curl wget' "${PORT_CALLS}"
    grep -q -- "-n ${PRAETORIAN_PORT_PREFIX}/bin/port -N selfupdate" "${SUDO_CALLS}"
}

@test "MacPorts: port still outdated after upgrade → quarantined with the failing phase" {
    with_macports
    export PORT_OUTDATED="wget curl" PORT_OUTDATED_AFTER="wget" PORT_UPGRADE_RC=1
    export PORT_UPGRADE_OUTPUT=$'Error: Failed to build wget: command execution failed\nError: See /nonexistent/main.log for details.'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"1 port(s) upgraded, 1 failed: wget"* ]] || false
    run cut -f1,2,4,5 "${QUARANTINE}"
    [ "${output}" = $'wget\tport\tbuild\tfailed at the "build" phase' ]
}

@test "MacPorts: quarantined port left out of the upgrade" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'wget\tport\t%s\tbuild\tx\n' "$(date +%s)" >"${QUARANTINE}"
    export PORT_OUTDATED="wget curl"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx -- '-N -p upgrade curl' "${PORT_CALLS}"
}

@test "MacPorts without sudo: the whole part deferred, nothing changed" {
    with_macports
    export SUDO_DENY=1 PORT_OUTDATED="wget"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MacPorts deferred"* ]] || false
    [[ "${output}" == *"MacPorts (selfupdate + upgrade; 1 port(s) outdated"* ]] || false
    run grep -E 'selfupdate|upgrade|uninstall' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "MacPorts: selfupdate failed → no upgrade, block explained" {
    with_macports
    export PORT_SELFUPDATE_RC=1 PORT_OUTDATED="wget"
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: port selfupdate failed"* ]] || false
    [[ "${output}" == *"No port was upgraded"* ]] || false
    run grep -q upgrade "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "MacPorts installed for another macOS: blocked with the migration steps" {
    with_macports
    export PORT_VERSION_RC=1
    export PORT_VERSION_OUTPUT='Error: Current platform "darwin 25" does not match expected platform "darwin 24"'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: MacPorts was installed for another macOS version"* ]] || false
    [[ "${output}" == *"trac.macports.org/wiki/Migration"* ]] || false
    run grep -q selfupdate "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "MacPorts only (no Homebrew in the PATH): maintenance still runs" {
    # praetorian also looks at the standard locations, outside the PATH.
    if [[ -x /usr/local/bin/brew || -x /opt/homebrew/bin/brew ]]; then
        skip "a real Homebrew is installed on this machine"
    fi
    with_macports
    local stubs="${BATS_TEST_TMPDIR}/stubs_nobrew"
    mkdir -p "${stubs}"
    cp "${BATS_TEST_DIRNAME}/stubs/sudo" "${BATS_TEST_DIRNAME}/stubs/mktemp" \
        "${BATS_TEST_DIRNAME}/stubs/osascript" "${BATS_TEST_DIRNAME}/stubs/curl" "${stubs}/"
    PATH="${stubs}:${PATH//${BATS_TEST_DIRNAME}\/stubs:/}" run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew not found"* ]] || false
    grep -qx -- '-N selfupdate' "${PORT_CALLS}"
}

# --- Homebrew → MacPorts migration --------------------------------------------

@test "--migration-report without MacPorts: blocked, explains how to install it" {
    run "${PRAETORIAN}" --migration-report
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: MacPorts isn't installed"* ]] || false
    [[ "${output}" == *"macports.org/install.php"* ]] || false
}

@test "--migration-report: sorts the formulae, changes nothing" {
    with_macports
    export BREW_LEAVES=$'wget\npython@3.12\nnode\nobscure-tool\nhashicorp/tap/terraform\nimagemagick\nnumpy\npostgresql@15'
    export PORT_AVAILABLE="wget python312 python313 nodejs20 nodejs22 curl terraform terraform-1.9 terraform-1.16 ImageMagick ImageMagick7 py-numpy postgresql15 postgresql93"
    run "${PRAETORIAN}" --migration-report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Same name in MacPorts (1)"* ]] || false
    # Known names (known_port_spec): the exact spec, nothing else.
    [[ "${output}" == *"python@3.12 → python312 (praetorian --migrate python@3.12=python312)"$'\n'* ]] || false
    [[ "${output}" == *"node → nodejs20, nodejs22"* ]] || false
    [[ "${output}" == *"hashicorp/tap/terraform → terraform-1.16 (praetorian --migrate hashicorp/tap/terraform=terraform-1.16)"* ]] || false
    [[ "${output}" == *"imagemagick → ImageMagick7 (praetorian --migrate imagemagick=ImageMagick7)"* ]] || false
    [[ "${output}" == *"numpy → py-numpy"* ]] || false
    [[ "${output}" == *"postgresql@15 → postgresql15 (praetorian --migrate postgresql@15=postgresql15)"$'\n'* ]] || false
    [[ "${output}" == *"Not found under this name (1)"* ]] || false
    run grep -E '^(-N|install|uninstall|selfupdate)' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -E '^(uninstall|install|upgrade)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: installs the port, checks, then uninstalls the formula" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget"
    export PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/wget ${PRAETORIAN_PORT_PREFIX}/share/man/man1/wget.1"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"wget migrated to MacPorts (wget)."* ]] || false
    grep -qx -- '-N install wget' "${PORT_CALLS}"
    grep -qx 'uninstall --formula wget' "${BREW_CALLS}"
    run cut -f1,2 "${HOME}/praetorian/migrated.tsv"
    [ "${output}" = $'wget\twget' ]
}

@test "--migrate: only the keg's bin/ counts, not libexec/bin or lib/…/bin" {
    with_macports
    export BREW_LIST_FILES=$'/usr/local/Cellar/pipx/1.18.2/bin/pipx\n/usr/local/Cellar/pipx/1.18.2/libexec/bin/python3\n/usr/local/Cellar/pipx/1.18.2/lib/tool/bin/helper'
    export PORT_AVAILABLE="pipx"
    export PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/pipx"
    run "${PRAETORIAN}" --migrate pipx
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Commands provided by pipx: pipx "* ]] || false
    [[ "${output}" == *"pipx migrated to MacPorts (pipx)."* ]] || false
    grep -qx 'uninstall --formula pipx' "${BREW_CALLS}"
}

@test "--migrate: command missing on the MacPorts side → Homebrew formula kept" {
    with_macports
    export BREW_LIST_FILES=$'/usr/local/Cellar/python@3.12/3.12.9/bin/python3\n/usr/local/Cellar/python@3.12/3.12.9/bin/python3.12'
    export PORT_AVAILABLE="python312"
    export PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/python3.12"
    run "${PRAETORIAN}" --migrate python@3.12=python312
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"doesn't provide every command of python@3.12"* ]] || false
    [[ "${output}" == *"Missing in ${PRAETORIAN_PORT_PREFIX}/bin and sbin: python3 "* ]] || false
    [[ "${output}" == *"was NOT uninstalled"* ]] || false
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: formula other formulae depend on → refused, nothing installed" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/openssl@3/3.5/bin/openssl"
    export BREW_USES=$'curl\nwget'
    export PORT_AVAILABLE="openssl3"
    run "${PRAETORIAN}" --migrate openssl@3=openssl3
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: other Homebrew formulae depend on openssl@3"* ]] || false
    [[ "${output}" == *"curl wget"* ]] || false
    run grep -q install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: Homebrew path in ~/.zshrc → refused, line quoted" {
    with_macports
    export BREW_PREFIX=/usr/local
    export BREW_LIST_FILES="/usr/local/Cellar/mysql-client/9.4/bin/mysql"
    export PORT_AVAILABLE="mysql8"
    # shellcheck disable=SC2016  # $PATH stays literal: it's the file's content
    printf '# /usr/local/opt/mysql-client in a comment: ignored\nexport PATH="/usr/local/opt/mysql-client/bin:$PATH"\nexport X=/usr/local/opt/mysql-client-extra\n' >"${HOME}/.zshrc"
    run "${PRAETORIAN}" --migrate mysql-client=mysql8
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: your shell uses Homebrew paths of mysql-client"* ]] || false
    # shellcheck disable=SC2016  # literal $PATH, as printed by praetorian
    [[ "${output}" == *'~/.zshrc:2: export PATH="/usr/local/opt/mysql-client/bin:$PATH"'* ]] || false
    [[ "${output}" != *"~/.zshrc:1"* ]] || false
    [[ "${output}" != *"~/.zshrc:3"* ]] || false
    run grep -q install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: MacPorts install failed → Homebrew untouched" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" PORT_INSTALL_RC=1
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: installing wget with MacPorts failed"* ]] || false
    [[ "${output}" == *"wget stays installed with Homebrew"* ]] || false
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate --dry-run: checks without installing or uninstalling anything" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget"
    run "${PRAETORIAN}" --dry-run --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not run in dry-run"* ]] || false
    # "port installed" (read-only) is allowed, "port install" isn't.
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: invalid name refused" {
    run "${PRAETORIAN}" --migrate 'wget;rm -rf /'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--migrate expects a formula name"* ]] || false
    run "${PRAETORIAN}" --migrate '../etc=wget'
    [ "${status}" -eq 1 ]
    run "${PRAETORIAN}" --migrate 'wget=a/b'
    [ "${status}" -eq 1 ]
}

@test "--migrate: tap formula → port named without the tap" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget"
    run "${PRAETORIAN}" --dry-run --migrate example/tap/wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Migration: example/tap/wget (Homebrew) → wget (MacPorts)"* ]] || false
    [[ "${output}" == *"sudo port -N install wget"* ]] || false
}

# --- Code in lib/: safety check before loading ----------------------------

# Copies praetorian and lib/ into a scratch directory the test can damage.
scratch_copy() {
    SCRATCH="${BATS_TEST_TMPDIR}/copy"
    mkdir -p "${SCRATCH}"
    cp "${PRAETORIAN}" "${SCRATCH}/praetorian"
    cp -R "${BATS_TEST_DIRNAME}/../lib" "${SCRATCH}/lib"
    chmod 755 "${SCRATCH}/lib"
    chmod 644 "${SCRATCH}"/lib/*.sh
}

@test "lib/: intact copy runs" {
    scratch_copy
    run "${SCRATCH}/praetorian" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: praetorian"* ]] || false
}

@test "lib/: file writable by others → refused before anything runs" {
    scratch_copy
    chmod o+w "${SCRATCH}/lib/brew.sh"
    run "${SCRATCH}/praetorian"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: praetorian's code in lib/ can't be trusted"* ]] || false
    [[ "${output}" == *"lib/brew.sh is writable by group or others"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

@test "lib/: directory writable by group → refused" {
    scratch_copy
    chmod g+w "${SCRATCH}/lib"
    run "${SCRATCH}/praetorian" --help
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"lib/ is writable by group or others"* ]] || false
}

@test "lib/: missing file → refused, names it" {
    scratch_copy
    rm "${SCRATCH}/lib/macports.sh"
    run "${SCRATCH}/praetorian" --help
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"lib/macports.sh is missing"* ]] || false
    [[ "${output}" == *"checkout -- lib/"* ]] || false
}

@test "lib/: symbolic link → refused" {
    scratch_copy
    mv "${SCRATCH}/lib/ui.sh" "${BATS_TEST_TMPDIR}/ui.sh"
    ln -s "${BATS_TEST_TMPDIR}/ui.sh" "${SCRATCH}/lib/ui.sh"
    run "${SCRATCH}/praetorian" --help
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"lib/ui.sh is a symbolic link"* ]] || false
}

@test "praetorian called through a symbolic link finds its lib/" {
    ln -s "${PRAETORIAN}" "${BATS_TEST_TMPDIR}/praetorian-link"
    run "${BATS_TEST_TMPDIR}/praetorian-link" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: praetorian"* ]] || false
}

# --- Unplanned exits are explained ---------------------------------------------

@test "unexpected failure inside a function: explained as a block, lock released" {
    with_macports
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" BREW_PREFIX_RC=1
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"BLOCKED: unexpected error in praetorian"* ]] || false
    [[ "${output}" == *"in migrate_check_usage (migrate.sh)"* ]] || false
    [[ "${output}" == *"brew --prefix"* ]] || false
    [ ! -e "${HOME}/praetorian/.lock" ]
    run grep -q install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "planned exits are not reported as unexpected" {
    run "${PRAETORIAN}" --nope
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"unexpected error"* ]] || false
    export PRAETORIAN_MIN_FREE_GB=999999999
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"unexpected error"* ]] || false
}

# --- Unit tests: single functions, praetorian sourced ---------------------------

# in_praetorian '<bash code>': runs code with praetorian's functions loaded
# (sourcing doesn't run main).
in_praetorian() {
    bash -c "source '${PRAETORIAN}'; $1"
}

@test "unit: port_candidates" {
    local all=$'wget\npython311\npython312\nnodejs8\nnodejs20\nnodejs22\nterraform\nImageMagick\ngmake\npy-numpy\ngnupg1\ngnupg2\npy-gnupg\npostgresql15\npostgresql93'
    run in_praetorian "port_candidates python@3.12 '${all}'"
    [ "${output}" = "python312" ]
    run in_praetorian "port_candidates node '${all}'"
    [ "${output}" = "nodejs8, nodejs20, nodejs22" ]
    run in_praetorian "port_candidates hashicorp/tap/terraform '${all}'"
    [ "${output}" = "terraform" ]
    run in_praetorian "port_candidates imagemagick '${all}'"
    [ "${output}" = "ImageMagick" ]
    run in_praetorian "port_candidates make '${all}'"
    [ "${output}" = "gmake" ]
    run in_praetorian "port_candidates numpy '${all}'"
    [ "${output}" = "py-numpy" ]
    run in_praetorian "port_candidates gnupg '${all}'"
    [ "${output}" = "gnupg1, gnupg2" ]
    run in_praetorian "port_candidates postgresql@15 '${all}'"
    [ "${output}" = "postgresql15" ]
    run in_praetorian "port_candidates obscure-tool '${all}'"
    [ "${output}" = "" ]
}

@test "unit: port_candidates caps versioned ports at 6" {
    local all
    all=$(printf 'nodejs%s\n' 8 10 12 14 16 18 20 22)
    run in_praetorian "port_candidates node '${all}'"
    [ "${output}" = "…, nodejs12, nodejs14, nodejs16, nodejs18, nodejs20, nodejs22 (8 versions: port echo 'nodejs*')" ]
}

@test "unit: valid_migrate_spec" {
    local spec
    for spec in wget python@3.12=python312 hashicorp/tap/terraform gtk+3 c++filt=cxxfilt; do
        run in_praetorian "valid_migrate_spec '${spec}' && echo yes || echo no"
        [ "${output}" = "yes" ] || {
            echo "rejected: ${spec}"
            false
        }
    done
    for spec in '' '-rf' 'wget;ls' 'a b' '../x' 'x=a/b' 'tap/' 'wget=' '=wget' 'a/..'; do
        run in_praetorian "valid_migrate_spec '${spec}' && echo yes || echo no"
        [ "${output}" = "no" ] || {
            echo "accepted: ${spec}"
            false
        }
    done
}

@test "unit: count_lines and filter_out" {
    run in_praetorian "count_lines ''"
    [ "${output}" = "0" ]
    run in_praetorian "count_lines \$'a\n\n  \nb'"
    [ "${output}" = "2" ]
    run in_praetorian "filter_out \$'a\nb\nc' \$'b'"
    [ "${output}" = $'a\nc' ]
}

# --- Dry-run changes nothing ---------------------------------------------------

@test "dry-run: quarantine.tsv left untouched, even with expired entries" {
    mkdir -p "${HOME}/praetorian"
    printf 'foo\tformula\t%s\tpkg\tx\n' "$(($(date +%s) - 40 * 86400))" >"${QUARANTINE}"
    cp "${QUARANTINE}" "${BATS_TEST_TMPDIR}/before"
    run "${PRAETORIAN}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dry-run: 1 quarantine entry(ies) would be lifted"* ]] || false
    cmp "${QUARANTINE}" "${BATS_TEST_TMPDIR}/before"
}

# --- Homebrew: auto-fixes and retries -----------------------------------------

@test "auto-fix: download failure → fetch --force, 2nd try passes, no failure left" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_RC2=0 BREW_UPGRADE_OUTPUT2=""
    export BREW_UPGRADE_OUTPUT='Error: foo: Failed to download resource "foo--patch"'
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'fetch --formula --deps --force foo' "${BREW_CALLS}"
    [ "$(grep -cx 'upgrade --formula foo' "${BREW_CALLS}")" -eq 2 ]
    [[ "${output}" != *"Failed steps"* ]] || false
}

@test "auto-fix: a fix step that fails stays counted, the retried upgrade doesn't" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_RC2=0 BREW_UPGRADE_OUTPUT2=""
    export BREW_UPGRADE_OUTPUT=$'Error: foo: Failed to download resource "x"\ndyld: Library not loaded\n  Referenced from: <0A1B> /usr/local/Cellar/merve/1.0/lib/libmerve.dylib'
    export BREW_REINSTALL_RC=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Steps passed: 6   failed: 1"* ]] || false
    [[ "${output}" == *"- Rebuilding merve (linked against an outdated library)"* ]] || false
    [[ "${output}" != *"- Upgrading formula foo"* ]] || false
}

@test "auto-fix: formula asking for brew unlink → unlinked for the build, linked back" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1 BREW_UPGRADE_RC2=0 BREW_UPGRADE_OUTPUT2=""
    export BREW_UPGRADE_OUTPUT='Error: foo cannot be built while boost is linked: brew unlink boost'
    export BREW_LIST_FILES=/usr/local/Cellar/boost/1.0/lib/libboost.dylib
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ "$(grep -nx 'unlink boost' "${BREW_CALLS}" | cut -d: -f1)" -lt "$(grep -nx 'link boost' "${BREW_CALLS}" | cut -d: -f1)" ]
}

@test "auto-fix: Metal Toolchain missing → downloaded, 2nd try passes, no failure left" {
    export BREW_OUTDATED_FORMULA=openjdk BREW_UPGRADE_RC=1 BREW_UPGRADE_RC2=0 BREW_UPGRADE_OUTPUT2=""
    export BREW_UPGRADE_OUTPUT="error: XCode tool 'metal' neither found in the toolchain nor in the SDK"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx -- '-downloadComponent MetalToolchain' "${XCODEBUILD_CALLS}"
    [ "$(grep -cx 'upgrade --formula openjdk' "${BREW_CALLS}")" -eq 2 ]
    [[ "${output}" == *"✓ Installing the Metal Toolchain (Xcode)"* ]] || false
    [[ "${output}" != *"Failed steps"* ]] || false
}

@test "auto-fix: Metal Toolchain download failing → no 2nd try, both failures counted" {
    export BREW_OUTDATED_FORMULA=openjdk BREW_UPGRADE_RC=1 XCODEBUILD_DOWNLOAD_RC=1
    export BREW_UPGRADE_OUTPUT="error: XCode tool 'metal' neither found in the toolchain nor in the SDK"
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    [ "$(grep -cx 'upgrade --formula openjdk' "${BREW_CALLS}")" -eq 1 ]
    [[ "${output}" == *"- Upgrading formula openjdk"* ]] || false
    [[ "${output}" == *"- Installing the Metal Toolchain (Xcode)"* ]] || false
}

@test "Xcode selected but its license not accepted → blocked before anything runs" {
    export XCODE_SELECT_PATH=/Applications/Xcode.app/Contents/Developer XCODEBUILD_LICENSE_RC=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: Xcode isn't ready"* ]] || false
    [[ "${output}" == *"sudo xcodebuild -license accept"* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}

@test "brew error but the new version is installed → success with a warning" {
    export BREW_OUTDATED_FORMULA=foo BREW_OUTDATED_FORMULA_AFTER="" BREW_UPGRADE_RC=1
    export BREW_UPGRADE_OUTPUT='Error: Failed to fix install linkage'
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"foo is installed despite a brew error"* ]] || false
    [ ! -s "${QUARANTINE}" ]
}

@test "dependency build failure → the dependency and the formula quarantined" {
    export BREW_OUTDATED_FORMULA=foo BREW_UPGRADE_RC=1
    export BREW_UPGRADE_OUTPUT=$'Last 15 lines from /x/Library/Logs/Homebrew/bar/01.cmake:\ncmake: error'
    run "${PRAETORIAN}"
    [ "${status}" -eq 2 ]
    run cut -f1,2,4 "${QUARANTINE}"
    [ "${output}" = $'bar\tformula\tbuild\nfoo\tformula\tbuild' ]
}

# --- Homebrew: casks -----------------------------------------------------------

@test "half-installed cask → forced uninstall then reinstall" {
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1
    export BREW_CASK_OUTPUT="Error: It seems there is already a Font at '/x/Ubuntu.ttf'."
    # The Caskroom entry is backed up before the forced uninstall.
    export BREW_CASKROOM="${BATS_TEST_TMPDIR}/Caskroom"
    mkdir -p "${BREW_CASKROOM}/bar/1.0"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'uninstall --cask --force bar' "${BREW_CALLS}"
    grep -qx 'install --cask bar' "${BREW_CALLS}"
}

@test "interrupted cask upgrade (.upgrading) → directory moved back" {
    export BREW_CASKROOM="${BATS_TEST_TMPDIR}/Caskroom"
    mkdir -p "${BREW_CASKROOM}/bar/1.0.upgrading" "${BREW_CASKROOM}/baz/2.0" "${BREW_CASKROOM}/baz/2.0.upgrading"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ -d "${BREW_CASKROOM}/bar/1.0" ] && [ ! -e "${BREW_CASKROOM}/bar/1.0.upgrading" ]
    # Both versions there: nothing moved, checked by hand.
    [ -d "${BREW_CASKROOM}/baz/2.0.upgrading" ]
    [[ "${output}" == *"Cask baz: leftover from an interrupted upgrade"* ]] || false
}

@test "Homebrew on its development branch → developer off, back to stable" {
    command -v git >/dev/null || skip "git not available"
    export BREW_REPOSITORY="${BATS_TEST_TMPDIR}/brewrepo"
    git init -q "${BREW_REPOSITORY}"
    git -C "${BREW_REPOSITORY}" symbolic-ref HEAD refs/heads/main
    unset HOMEBREW_DEVELOPER
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'developer off' "${BREW_CALLS}"
    grep -qx 'update --force' "${BREW_CALLS}"
}

# --- Logs ------------------------------------------------------------------------

@test "logs: only the 30 most recent kept, directory private" {
    mkdir -p "${LOGS}"
    local i
    for i in $(seq 10 40); do
        touch -t "2020010100${i}" "${LOGS}/praetorian_20200101_0000${i}.log"
    done
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ "$(find "${LOGS}" -name 'praetorian_*[0-9].log' | wc -l | tr -d ' ')" -eq 30 ]
    [ ! -e "${LOGS}/praetorian_20200101_000010.log" ]
    [ ! -e "${LOGS}/praetorian_20200101_000011.log" ]
    [ -e "${LOGS}/praetorian_20200101_000040.log" ]
    [ -n "$(find "${LOGS}" -maxdepth 0 -perm 700)" ]
}

@test "logs: beyond 30 but less than 7 days old → kept (migration loop)" {
    mkdir -p "${LOGS}"
    local i
    for i in $(seq 10 45); do
        touch "${LOGS}/praetorian_20261017_1300${i}.log"
    done
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [ "$(find "${LOGS}" -name 'praetorian_*[0-9].log' | wc -l | tr -d ' ')" -eq 37 ]
    [ -e "${LOGS}/praetorian_20261017_130010.log" ]
}

@test "unattended: notification with the message passed as an argument" {
    export BREW_OUTDATED_CASK=bar BREW_CASK_RC=1 BREW_CASK_OUTPUT='sudo: a password is required'
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx 'on run argv' "${OSASCRIPT_CALLS}"
    grep -qx 'Done. To do from a terminal (sudo): cask bar' "${OSASCRIPT_CALLS}"
}

# --- MacPorts: inactive versions, side by side, root-owned binary ---------------

@test "MacPorts: old inactive versions removed only when there are some" {
    with_macports
    export PORT_INACTIVE="wget"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    grep -qx -- '-N uninstall inactive' "${PORT_CALLS}"
}

@test "MacPorts: no inactive version → no uninstall (no sudo prompt for nothing)" {
    with_macports
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    run grep -q uninstall "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "side by side: command installed by both reported" {
    with_macports
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    mkdir -p "${BREW_PREFIX}/bin"
    touch "${BREW_PREFIX}/bin/wget" "${PRAETORIAN_PORT_PREFIX}/bin/wget"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    # A plain file (not a link into the Cellar): another installer's.
    [[ "${output}" == *"No formula you could migrate has its commands installed twice."* ]] || false
    [[ "${output}" == *"1 command(s) in ${BREW_PREFIX}/bin not installed by Homebrew also exist in MacPorts: wget"* ]] || false
    [[ "${output}" != *"praetorian --migrate"* ]] || false
}

@test "side by side: leaf formula listed, dependencies summed up in one line" {
    with_macports
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    export BREW_LEAVES="wget"
    mkdir -p "${BREW_PREFIX}/bin"
    ln -s ../Cellar/wget/1.25/bin/wget "${BREW_PREFIX}/bin/wget"
    ln -s ../Cellar/dav1d/1.5/bin/dav1d "${BREW_PREFIX}/bin/dav1d"
    ln -s ../Cellar/brotli/1.1/bin/brotli "${BREW_PREFIX}/bin/brotli"
    touch "${PRAETORIAN_PORT_PREFIX}/bin/wget" "${PRAETORIAN_PORT_PREFIX}/bin/dav1d" "${PRAETORIAN_PORT_PREFIX}/bin/brotli"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 Homebrew formula(e) that nothing else needs also come with MacPorts"* ]] || false
    [[ "${output}" == *"- wget (wget"* ]] || false
    [[ "${output}" == *"2 command(s) from 2 Homebrew dependencies also exist in MacPorts"* ]] || false
    [[ "${output}" != *"- dav1d"* ]] || false
}

@test "side by side: only dependencies duplicated → no warning" {
    with_macports
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    export BREW_LEAVES="scrcpy"
    mkdir -p "${BREW_PREFIX}/bin"
    ln -s ../Cellar/dav1d/1.5/bin/dav1d "${BREW_PREFIX}/bin/dav1d"
    touch "${PRAETORIAN_PORT_PREFIX}/bin/dav1d"
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No formula you could migrate has its commands installed twice."* ]] || false
    [[ "${output}" == *"1 command(s) from 1 Homebrew dependencies also exist in MacPorts"* ]] || false
    [[ "${output}" != *"praetorian --migrate"* ]] || false
}

@test "side by side: brew --prefix failing → no false duplicates" {
    with_macports
    export BREW_PREFIX_RC=1
    run "${PRAETORIAN}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"commands installed twice not checked"* ]] || false
    [[ "${output}" != *"installed by both"* ]] || false
}

@test "unit: port_bin_trusted refuses a port binary not owned by root" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    with_macports
    run in_praetorian 'port_bin_trusted && echo yes || echo no'
    [ "${output}" = "no" ]
}

@test "unit: forget_failure removes that step only" {
    # shellcheck disable=SC2016  # expanded by the inner bash
    run in_praetorian 'FAILED_STEPS=(a b c); STEP_FAIL=3; forget_failure b; echo "${STEP_FAIL} ${FAILED_STEPS[*]}"; forget_failure zz; echo "${STEP_FAIL}"'
    [ "${output}" = $'2 a c\n2' ]
}
