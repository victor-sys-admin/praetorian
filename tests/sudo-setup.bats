#!/usr/bin/env bats
#
# praetorian-sudo-setup tests, on a test file, never /etc/pam.d: id,
# chown and bioutil are replaced by the fakes in tests/stubs (FAKE_UID=0
# plays root, chown only records its call).
#
# Each @test runs in its own subshell: the exported variables are meant to
# stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
    export CHOWN_CALLS="${BATS_TEST_TMPDIR}/chown_calls"
    SUDO_SETUP="${BATS_TEST_DIRNAME}/../praetorian-sudo-setup"
    PAM="${BATS_TEST_TMPDIR}/sudo_local"
}

# Runs praetorian-sudo-setup as a fake root on ${PAM}.
sudo_setup() {
    FAKE_UID=0 SUDO_USER="" PRAETORIAN_SUDO_LOCAL="${PAM}" run "${SUDO_SETUP}" "$@"
}

@test "sudo-setup: --help prints the usage, no root needed" {
    run "${SUDO_SETUP}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: sudo "* ]] || false
    [[ "${output}" == *"--disable"* ]] || false
}

@test "sudo-setup: unknown option → code 1, nothing written" {
    sudo_setup --nope
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown option: --nope"* ]] || false
    [[ "${output}" == *"Usage: sudo "* ]] || false
    [ ! -e "${PAM}" ]
}

@test "sudo-setup: too many arguments → code 1" {
    sudo_setup --disable extra
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Too many arguments"* ]] || false
}

@test "sudo-setup: refuses without root" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    PRAETORIAN_SUDO_LOCAL="${PAM}" run "${SUDO_SETUP}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Run it with sudo"* ]] || false
    [ ! -e "${PAM}" ]
}

@test "sudo-setup: PRAETORIAN_SUDO_LOCAL refused under a real sudo" {
    FAKE_UID=0 SUDO_USER=someone PRAETORIAN_SUDO_LOCAL="${PAM}" run "${SUDO_SETUP}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"PRAETORIAN_SUDO_LOCAL is for the tests only"* ]] || false
    [ ! -e "${PAM}" ]
}

@test "sudo-setup: PRAETORIAN_SUDO_LOCAL refused under /etc, /usr, /System, relative or symlink" {
    local target
    for target in /etc/pam.d/sudo /private/etc/x /usr/local/x /System/x relative/x "${BATS_TEST_TMPDIR}/../etc/x"; do
        FAKE_UID=0 SUDO_USER="" PRAETORIAN_SUDO_LOCAL="${target}" run "${SUDO_SETUP}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"PRAETORIAN_SUDO_LOCAL is for the tests only"* ]] || false
    done
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${PAM}"
    sudo_setup
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"PRAETORIAN_SUDO_LOCAL is for the tests only"* ]] || false
    [ ! -e "${BATS_TEST_TMPDIR}/elsewhere" ]
}

@test "sudo-setup: refuses when no fingerprint is enrolled" {
    BIOUTIL_TEMPLATES=0 sudo_setup
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No fingerprint enrolled"* ]] || false
    [ ! -e "${PAM}" ]
}

@test "sudo-setup: no file → created with the pam_tid line, root:wheel 444" {
    sudo_setup
    [ "${status}" -eq 0 ]
    grep -qx 'auth       sufficient     pam_tid.so' "${PAM}"
    [ -n "$(find "${PAM}" -perm 444)" ]
    grep -qx "root:wheel ${PAM}" "${CHOWN_CALLS}"
    [ ! -e "${PAM}.tmp" ]
}

@test "sudo-setup: Apple's template → line uncommented, backup kept" {
    printf '# sudo_local: local config file\n# uncomment following line to enable Touch ID for sudo\n#auth       sufficient     pam_tid.so\n' >"${PAM}"
    sudo_setup
    [ "${status}" -eq 0 ]
    grep -qx 'auth       sufficient     pam_tid.so' "${PAM}"
    [ "$(grep -c pam_tid "${PAM}")" -eq 1 ]
    grep -qx '#auth       sufficient     pam_tid.so' "${PAM}".bak.*
    [ ! -e "${PAM}.tmp" ]
}

@test "sudo-setup: other content, no pam_reattach → line added on top, content kept" {
    printf '# local tweaks\nauth       optional       pam_something.so\n' >"${PAM}"
    sudo_setup
    [ "${status}" -eq 0 ]
    [ "$(cat "${PAM}")" = $'auth       sufficient     pam_tid.so\n# local tweaks\nauth       optional       pam_something.so' ]
    [ ! -e "${PAM}.tmp" ]
}

@test "sudo-setup: pam_reattach present → pam_tid added right after it" {
    printf '# tmux\nauth       optional       /opt/local/lib/pam/pam_reattach.so\nauth       optional       pam_other.so\n' >"${PAM}"
    sudo_setup
    [ "${status}" -eq 0 ]
    [ "$(cat "${PAM}")" = $'# tmux\nauth       optional       /opt/local/lib/pam/pam_reattach.so\nauth       sufficient     pam_tid.so\nauth       optional       pam_other.so' ]
    [ ! -e "${PAM}.tmp" ]
}

@test "sudo-setup: already on → nothing changed, no backup" {
    sudo_setup
    sudo_setup
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already on"* ]] || false
    run find "${BATS_TEST_TMPDIR}" -name 'sudo_local.bak.*'
    [ -z "${output}" ]
}

@test "sudo-setup: --disable → line commented, backup kept, re-enable works" {
    sudo_setup
    sudo_setup --disable
    [ "${status}" -eq 0 ]
    grep -qx '#auth       sufficient     pam_tid.so' "${PAM}"
    [ -n "$(find "${PAM}" -perm 444)" ]
    ls "${PAM}".bak.* >/dev/null
    sudo_setup
    grep -qx 'auth       sufficient     pam_tid.so' "${PAM}"
    [ "$(grep -c pam_tid "${PAM}")" -eq 1 ]
}

@test "sudo-setup: --disable when off → nothing to do" {
    sudo_setup --disable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"wasn't on"* ]] || false
    [ ! -e "${PAM}" ]
}
