#!/usr/bin/env bats
#
# --prune tests (lib/prune.sh). Same fakes as the other files: the fake
# brew answers brew leaves / brew list --installed-on-request from
# BREW_LEAVES / BREW_ON_REQUEST, and remembers what "brew uninstall
# --formula" removed (BREW_LEAVES_NEXT: what that frees for the next
# round).
#
# Without a terminal praetorian is unattended, and --prune then removes
# nothing. The confirmation is tested by calling prune_run with fd 3 (the
# terminal, see main) fed from a file: portable, no pseudo-terminal.
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
    unset PIPX_HOME
    export PRAETORIAN_CAFFEINATED=1
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    mkdir -p "${BREW_PREFIX}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    ANSWERS="${BATS_TEST_TMPDIR}/answers"
    : >"${ANSWERS}"
}

# Installs the fake port in the test's MacPorts prefix.
with_macports() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# prune_interactive: prune_run as from a terminal, answers read from
# ANSWERS (one line per question), then the summary.
prune_interactive() {
    bash -c "source '${PRAETORIAN}'; check_prerequisites; UNATTENDED=false; exec 3<'${ANSWERS}'
        prune_run; set +e; summary; echo \"rc=\$?\""
}

uninstalls() {
    grep '^uninstall' "${BREW_CALLS}" || true
}

@test "prune --dry-run: first round listed, nothing removed" {
    export BREW_LEAVES=$'wget\nlibfoo\nlibbar' BREW_ON_REQUEST="wget"
    run "${PRAETORIAN}" --dry-run --prune
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Round 1: 2 formula(e) nothing uses"* ]] || false
    [[ "${output}" == *"    libfoo libbar"* ]] || false
    [[ "${output}" == *"more rounds may follow"* ]] || false
    [ -z "$(uninstalls)" ]
}

@test "prune unattended: nothing removed, deferred in the summary" {
    export BREW_LEAVES=$'wget\nlibfoo' BREW_ON_REQUEST="wget"
    run "${PRAETORIAN}" --prune
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Unattended: nothing removed"* ]] || false
    [[ "${output}" == *"Deferred"* ]] || false
    [[ "${output}" == *"--prune: 1 unused Homebrew formula(e) (libfoo)"* ]] || false
    [ -z "$(uninstalls)" ]
}

@test "prune: confirmed rounds until nothing is left, never a formula installed on request" {
    export BREW_LEAVES=$'wget\nlibfoo' BREW_ON_REQUEST="wget" BREW_LEAVES_NEXT="libbaz"
    printf 'y\nyes\n' >"${ANSWERS}"
    run prune_interactive
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Round 1: 1 formula(e)"* ]] || false
    [[ "${output}" == *"Round 2: 1 formula(e)"* ]] || false
    [[ "${output}" == *"Nothing left to prune after 2 round(s)."* ]] || false
    [ "$(uninstalls)" = $'uninstall --formula libfoo\nuninstall --formula libbaz' ]
    [[ "${output}" == *"Steps passed: 2"* ]] || false
    [[ "${output}" == *"rc=0"* ]] || false
}

@test "prune: no answer, \"n\" or end of input → nothing removed" {
    export BREW_LEAVES=$'wget\nlibfoo' BREW_ON_REQUEST="wget"
    local answer
    for answer in "" "n" "maybe"; do
        printf '%s\n' "${answer}" >"${ANSWERS}"
        run prune_interactive
        [[ "${output}" == *"[y/N]"* ]] || false
        [[ "${output}" == *"Nothing removed."* ]] || false
    done
    : >"${ANSWERS}"
    run prune_interactive
    [[ "${output}" == *"Nothing removed."* ]] || false
    [ -z "$(uninstalls)" ]
}

@test "prune: a formula a pipx environment runs on is kept, with why" {
    mkdir -p "${BREW_PREFIX}/Cellar/python@3.13/3.13.5/bin"
    printf '#!/bin/sh\n' >"${BREW_PREFIX}/Cellar/python@3.13/3.13.5/bin/python3.13"
    chmod +x "${BREW_PREFIX}/Cellar/python@3.13/3.13.5/bin/python3.13"
    ln -s ../Cellar/python@3.13/3.13.5 "${BREW_PREFIX}/opt/python@3.13"
    local v="${HOME}/.local/pipx/venvs/poetry"
    mkdir -p "${v}/bin"
    ln -s "${BREW_PREFIX}/opt/python@3.13/bin/python3.13" "${v}/bin/python3.13"
    printf 'home = %s\nversion = 3.13.5\n' "${BREW_PREFIX}/opt/python@3.13/bin" >"${v}/pyvenv.cfg"
    export BREW_LEAVES=$'python@3.13\nlibfoo' BREW_ON_REQUEST=""
    printf 'y\n' >"${ANSWERS}"
    run prune_interactive
    [[ "${output}" == *"Kept: python@3.13 — used outside Homebrew: pipx environment poetry (python3.13 from python@3.13)"* ]] || false
    [ "$(uninstalls)" = "uninstall --formula libfoo" ]
}

@test "prune: a formula named in the shell startup files is kept" {
    echo "export PATH=\"${BREW_PREFIX}/opt/libpq/bin:\$PATH\"" >"${HOME}/.zshrc"
    export BREW_LEAVES="libpq" BREW_ON_REQUEST=""
    run prune_interactive
    [[ "${output}" == *"Kept: libpq — named in ~/.zshrc:1"* ]] || false
    [[ "${output}" == *"No unused Homebrew dependency"* ]] || false
    [ -z "$(uninstalls)" ]
}

@test "prune: brew can't list what was installed on request → nothing removed" {
    export BREW_LEAVES=$'wget\nlibfoo' BREW_ON_REQUEST_RC=1
    printf 'y\n' >"${ANSWERS}"
    run prune_interactive
    [[ "${output}" == *"can't tell what you installed yourself, nothing removed"* ]] || false
    [ -z "$(uninstalls)" ]
}

@test "prune: failed uninstall → no further round, counted as a failure" {
    export BREW_LEAVES="libfoo" BREW_ON_REQUEST="" BREW_UNINSTALL_RC=1
    printf 'y\ny\n' >"${ANSWERS}"
    run prune_interactive
    [[ "${output}" == *"brew uninstall failed (see the log): stopped"* ]] || false
    [ "$(uninstalls | wc -l | tr -d ' ')" -eq 1 ]
    [[ "${output}" == *"rc=2"* ]] || false
}

@test "prune: hard cap on the number of rounds" {
    # brew that always has a new leftover: dep<number of uninstalls so far>.
    local wrap="${BATS_TEST_TMPDIR}/brew_wrap"
    mkdir -p "${wrap}"
    cat >"${wrap}/brew" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    leaves) echo "dep\$(grep -c '^uninstall' "\${BREW_CALLS}")"; exit 0 ;;
esac
exec "${BATS_TEST_DIRNAME}/stubs/brew" "\$@"
EOF
    chmod +x "${wrap}/brew"
    yes y | head -n 20 >"${ANSWERS}"
    PATH="${wrap}:${PATH}" run prune_interactive
    [[ "${output}" == *"Stopped after 10 rounds"* ]] || false
    [ "$(uninstalls | wc -l | tr -d ' ')" -eq 10 ]
}

@test "prune MacPorts: leaves reported with the exact command, migrated ones flagged, nothing run" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'go\tgo\t1\n' >"${HOME}/praetorian/migrated.tsv"
    export PORT_LEAVES="libcbor go" BREW_LEAVES=""
    run "${PRAETORIAN}" --prune
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"To remove exactly these: sudo port uninstall libcbor"* ]] || false
    [[ "${output}" == *"1 port(s) you migrated to are marked as dependencies"* ]] || false
    [[ "${output}" == *"sudo port setrequested go"* ]] || false
    [ ! -s "${SUDO_CALLS}" ]
    run grep -E 'uninstall|setrequested' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "prune MacPorts: hostile port names are quoted in the printed commands" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'go\tgo;id\t1\n' >"${HOME}/praetorian/migrated.tsv"
    export PORT_LEAVES='lib;x go;id' BREW_LEAVES=""
    run "${PRAETORIAN}" --prune
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'sudo port uninstall lib\;x'* ]] || false
    [[ "${output}" == *'sudo port setrequested go\;id'* ]] || false
}

@test "prune: an unreadable shell startup file doesn't stop the run" {
    [[ "$(id -u)" -ne 0 ]] || skip "root reads everything"
    echo "export PATH=\"${BREW_PREFIX}/opt/libpq/bin:\$PATH\"" >"${HOME}/.zshrc"
    chmod 000 "${HOME}/.zshrc"
    export BREW_LEAVES="libfoo" BREW_ON_REQUEST=""
    run "${PRAETORIAN}" --dry-run --prune
    chmod 644 "${HOME}/.zshrc"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Round 1: 1 formula(e) nothing uses"* ]] || false
}
