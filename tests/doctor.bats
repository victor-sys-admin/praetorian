#!/usr/bin/env bats
#
# --doctor tests (lib/doctor.sh) and formula_external_users. Same fakes
# as the other files (tests/stubs), HOME in a temp directory, a fake
# Homebrew prefix (BREW_PREFIX) and a fake root for the system paths the
# doctor reads (PRAETORIAN_DOCTOR_ROOT). The PATH is reduced to the fakes
# and the system directories that exist: the doctor checks it.
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
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    export PRAETORIAN_DOCTOR_ROOT="${BATS_TEST_TMPDIR}/root"
    export BREW_PREFIX="${BATS_TEST_TMPDIR}/brew"
    export BREW_CASKROOM="${BREW_PREFIX}/Caskroom"
    mkdir -p "${BREW_PREFIX}/Cellar" "${BREW_PREFIX}/bin" "${BREW_PREFIX}/opt" "${PRAETORIAN_DOCTOR_ROOT}"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    VENVS="${HOME}/.local/pipx/venvs"
    # Only directories that exist: a missing /sbin in the container would
    # be reported as a dead PATH entry.
    TEST_PATH="${BATS_TEST_DIRNAME}/stubs"
    local d
    for d in /usr/bin /bin /usr/sbin /sbin; do
        [[ -d "${d}" ]] && TEST_PATH+=":${d}"
    done
}

# Installs the fake port in the test's MacPorts prefix.
with_macports() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# run_doctor [PATH]: praetorian --doctor with the reduced PATH.
run_doctor() {
    PATH="${1:-${TEST_PATH}}" run "${PRAETORIAN}" --doctor
}

# in_praetorian '<bash code>': runs code with praetorian's functions
# loaded (sourcing doesn't run main), reduced PATH.
in_praetorian() {
    PATH="${TEST_PATH}" bash -c "source '${PRAETORIAN}'; $1"
}

# pipx_venv <name> <python link target> <version> [package_or_url]: a
# pipx environment whose bin/python<minor> points to the target.
pipx_venv() {
    local v="${VENVS}/$1" minor=${3%.*}
    mkdir -p "${v}/bin"
    ln -s "$2" "${v}/bin/python${minor}"
    ln -s "python${minor}" "${v}/bin/python3"
    ln -s "python${minor}" "${v}/bin/python"
    printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\nexecutable = %s\n' \
        "${2%/*}" "$3" "$2" >"${v}/pyvenv.cfg"
    printf '{\n    "injected_packages": {\n        "x": {\n            "package_or_url": "injected"\n        }\n    },\n    "main_package": {\n        "package": "%s",\n        "package_or_url": "%s"\n    }\n}\n' \
        "$1" "${4:-$1}" >"${v}/pipx_metadata.json"
}

# An executable file (a Python, a JDK…).
fake_exe() {
    mkdir -p "${1%/*}"
    printf '#!/bin/sh\n' >"$1"
    chmod +x "$1"
}

# fake_pkgutil <CLT version>: a pkgutil answering --pkg-info with that
# version, in a directory of the test put first in TEST_PATH.
fake_pkgutil() {
    local bin="${BATS_TEST_TMPDIR}/fakebin"
    mkdir -p "${bin}"
    printf '#!/bin/sh\necho "package-id: com.apple.pkg.CLTools_Executables"\necho "version: %s"\n' "$1" >"${bin}/pkgutil"
    chmod +x "${bin}/pkgutil"
    TEST_PATH="${bin}:${TEST_PATH}"
}

# --- whole run -------------------------------------------------------------

@test "doctor: clean machine → code 0, no command that changes anything" {
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No problem found."* ]] || false
    [[ "${output}" == *"pipx: no environment"* ]] || false
    [[ "${output}" == *"PATH: every entry exists."* ]] || false
    [[ "${output}" == *"MacPorts not found: MacPorts checks skipped."* ]] || false
    run grep -vE '^(--prefix|--caskroom)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    [ ! -s "${SUDO_CALLS}" ]
    # Read-only mode: no lock taken.
    [ ! -e "${HOME}/praetorian/.lock" ]
}

@test "doctor: problems found → code 2, sudo never run" {
    mkdir -p "${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/usr/include/c++" \
        "${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1"
    mkdir -p "${BREW_PREFIX}/Cellar/openvpn"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"2 problem(s) found. praetorian changed nothing"* ]] || false
    [ ! -s "${SUDO_CALLS}" ]
    [ -d "${BREW_PREFIX}/Cellar/openvpn" ]
}

# --- a/b. pipx ---------------------------------------------------------------

@test "doctor pipx: Python gone → pipx reinstall with MacPorts' Python of the same version" {
    fake_exe "${PRAETORIAN_PORT_PREFIX}/bin/python3.14"
    pipx_venv ansible-core "${BREW_PREFIX}/opt/python@3.14/bin/python3.14" 3.14.6
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"pipx environment ansible-core is broken: its Python (${BREW_PREFIX}/opt/python@3.14/bin/python3.14) no longer exists"* ]] || false
    [[ "${output}" == *"pipx reinstall ansible-core --python ${PRAETORIAN_PORT_PREFIX}/bin/python3.14"* ]] || false
    [[ "${output}" != *"sudo port install"* ]] || false
}

@test "doctor pipx: no MacPorts Python of that version → install it first" {
    pipx_venv poetry "${BREW_PREFIX}/opt/python@3.12/bin/python3.12" 3.12.9
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"sudo port install python312"* ]] || false
    [[ "${output}" == *"pipx reinstall poetry --python ${PRAETORIAN_PORT_PREFIX}/bin/python3.12"* ]] || false
}

@test "doctor pipx: installed from a local folder that is gone → repair in place" {
    fake_exe "${PRAETORIAN_PORT_PREFIX}/bin/python3.13"
    pipx_venv boilerplates "${BREW_PREFIX}/opt/python@3.13/bin/python3.13" 3.13.11 /tmp/gone.XXXX/boilerplates-0.1.2
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Installed from a local folder that no longer exists (/tmp/gone.XXXX/boilerplates-0.1.2)"* ]] || false
    [[ "${output}" == *"ln -sfn ${PRAETORIAN_PORT_PREFIX}/bin/python3.13 ${VENVS}/boilerplates/bin/python3.13"* ]] || false
    [[ "${output}" == *"executable = ${PRAETORIAN_PORT_PREFIX}/bin/python3.13#"* ]] || false
    [[ "${output}" != *"pipx reinstall boilerplates"* ]] || false
}

@test "doctor pipx: working, but on Homebrew's Python → warning with the reinstall command" {
    fake_exe "${BREW_PREFIX}/Cellar/python@3.13/3.13.5/bin/python3.13"
    ln -s ../Cellar/python@3.13/3.13.5 "${BREW_PREFIX}/opt/python@3.13"
    pipx_venv poetry "${BREW_PREFIX}/opt/python@3.13/bin/python3.13" 3.13.5
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"pipx environment poetry runs on Homebrew's python@3.13: it breaks as soon as that formula is uninstalled."* ]] || false
    [[ "${output}" == *"pipx reinstall poetry --python ${PRAETORIAN_PORT_PREFIX}/bin/python3.13"* ]] || false
}

@test "doctor pipx: on MacPorts' Python, PIPX_HOME with a space → fine" {
    export PIPX_HOME="${HOME}/Library/Application Support/pipx"
    VENVS="${PIPX_HOME}/venvs"
    fake_exe "${PRAETORIAN_PORT_PREFIX}/bin/python3.14"
    pipx_venv sherlock "${PRAETORIAN_PORT_PREFIX}/bin/python3.14" 3.14.8
    # Shared libraries on a Python that is gone: pipx rebuilds them itself.
    mkdir -p "${PIPX_HOME}/shared/bin"
    ln -s "${BREW_PREFIX}/opt/python@3.14/bin/python3.14" "${PIPX_HOME}/shared/bin/python3"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pipx: 1 environment(s), all on a working Python outside Homebrew."* ]] || false
    [[ "${output}" == *"pipx rebuilds them by itself"* ]] || false
}

@test "doctor pipx: a hostile environment name is quoted in the printed command" {
    fake_exe "${PRAETORIAN_PORT_PREFIX}/bin/python3.14"
    pipx_venv "x; touch pwned" "${BREW_PREFIX}/opt/python@3.14/bin/python3.14" 3.14.6 x
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'pipx reinstall x\;\ touch\ pwned --python '* ]] || false
    [[ "${output}" != *"pipx reinstall x; touch"* ]] || false
}

# --- formula_external_users -----------------------------------------------------

@test "formula_external_users: pipx environments of that Python only" {
    fake_exe "${BREW_PREFIX}/Cellar/python@3.13/3.13.5/bin/python3.13"
    ln -s ../Cellar/python@3.13/3.13.5 "${BREW_PREFIX}/opt/python@3.13"
    pipx_venv poetry "${BREW_PREFIX}/opt/python@3.13/bin/python3.13" 3.13.5
    # Created through the Cellar path, broken since.
    pipx_venv ansible-core "${BREW_PREFIX}/Cellar/python@3.14/3.14.6/bin/python3.14" 3.14.6
    fake_exe "${PRAETORIAN_PORT_PREFIX}/bin/python3.13"
    pipx_venv exegol "${PRAETORIAN_PORT_PREFIX}/bin/python3.13" 3.13.16
    run in_praetorian 'formula_external_users python@3.13'
    [ "${status}" -eq 0 ]
    [ "${output}" = "pipx environment poetry (python3.13 from python@3.13)" ]
    run in_praetorian 'formula_external_users python@3.14'
    [ "${output}" = "pipx environment ansible-core (python3.14 from python@3.14)" ]
    run in_praetorian 'formula_external_users wget; echo "rc=$?"'
    [ "${output}" = "rc=0" ]
}

@test "formula_external_users: npm global packages for node, not npm itself" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/"{npm,corepack,typescript,@angular/cli}
    run in_praetorian 'formula_external_users node'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"npm global package typescript (in ${BREW_PREFIX}/lib/node_modules, runs on node)"* ]] || false
    [[ "${output}" == *"npm global package @angular/cli"* ]] || false
    [[ "${output}" != *"package npm "* ]] || false
    [[ "${output}" != *"corepack"* ]] || false
}

@test "formula_external_users: npm packages of a nodejs.org node in the prefix aren't node's users" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/"{npm,typescript}
    fake_exe "${BREW_PREFIX}/bin/node"
    run in_praetorian 'formula_external_users node; echo "rc=$?"'
    [ "${output}" = "rc=0" ]
}

@test "formula_external_users: nothing to look at → empty, code 0 (no pipx, no brew)" {
    run in_praetorian 'formula_external_users python@3.13; echo "rc=$?"'
    [ "${output}" = "rc=0" ]
    PATH="/usr/bin:/bin" run bash -c "source '${PRAETORIAN}'; formula_external_users node; echo \"rc=\$?\""
    [ "${output}" = "rc=0" ]
}

# --- c. ownership ------------------------------------------------------------

@test "doctor ownership: only what brew manages is checked (Cellar, opt, brew's links)" {
    fake_exe "${BREW_PREFIX}/Cellar/wget/1.25/bin/wget"
    ln -s ../Cellar/wget/1.25/bin/wget "${BREW_PREFIX}/bin/wget"
    fake_exe "${BREW_PREFIX}/bin/firebase"
    fake_exe "${BREW_PREFIX}/lib/vendor_sdk.so"
    fake_exe "${BREW_PREFIX}/podman/bin/podman"
    # As if all of it belonged to someone else (the fake id answers 4242).
    # shellcheck disable=SC2016  # expanded by the bash of in_praetorian
    run in_praetorian 'export FAKE_UID=4242; doctor_brew_ownership "${BREW_PREFIX}"; echo "problems=${DOCTOR_PROBLEMS}"'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sudo chown -R "*" ${BREW_PREFIX}/Cellar"* ]] || false
    [[ "${output}" == *"sudo chown -R "*" ${BREW_PREFIX}/bin/wget"* ]] || false
    [[ "${output}" != *"firebase"* ]] || false
    [[ "${output}" != *"vendor_sdk"* ]] || false
    [[ "${output}" != *"podman"* ]] || false
    [[ "${output}" == *"problems=3"* ]] # Cellar, opt, bin/wget
}

@test "doctor ownership: everything yours → nothing reported" {
    fake_exe "${BREW_PREFIX}/Cellar/wget/1.25/bin/wget"
    mkdir -p "${BREW_PREFIX}/lib/python3.13/site-packages/foo/__pycache__"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew prefix: everything brew manages belongs to you."* ]] || false
}

@test "doctor ownership: a root-owned __pycache__ in site-packages → sudo rm -rf of the directory" {
    local cache="${BREW_PREFIX}/lib/python3.13/site-packages/foo/__pycache__"
    mkdir -p "${cache}"
    # A file that isn't ours without being root: a hard link to a
    # root-owned file (macOS allows it, Linux usually doesn't).
    ln /etc/hosts "${cache}/foo.cpython-313.pyc" 2>/dev/null || skip "can't link a root-owned file here"
    [ "$(find "${cache}/foo.cpython-313.pyc" -user 0 | wc -l)" -eq 1 ] || skip "/etc/hosts doesn't belong to root"
    run_doctor
    [ "${status}" -eq 2 ]
    # "|| false": this test only runs on macOS, under bash 3.2, where a
    # failing [[ ]] that isn't the last command doesn't fail the test.
    [[ "${output}" == *"1 path(s) in ${BREW_PREFIX} don't belong to you"* ]] || false
    [[ "${output}" == *"sudo rm -rf ${cache}   (Python bytecode cache"* ]] || false
    [ ! -s "${SUDO_CALLS}" ]
}

@test "doctor ownership: an unreadable directory under the prefix doesn't stop the run" {
    [[ "$(id -u)" -ne 0 ]] || skip "root reads everything"
    mkdir -p "${BREW_PREFIX}/share/locked/sub" "${BREW_PREFIX}/Cellar/wget/1.25/locked"
    chmod 000 "${BREW_PREFIX}/share/locked" "${BREW_PREFIX}/Cellar/wget/1.25/locked"
    run_doctor
    chmod 755 "${BREW_PREFIX}/share/locked" "${BREW_PREFIX}/Cellar/wget/1.25/locked"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew prefix: everything brew manages belongs to you."* ]] || false
    [[ "${output}" == *"No problem found."* ]] || false
    [[ "${output}" != *"unexpected"* ]] || false
}

@test "doctor ownership: a file name with a newline can't forge a command line" {
    local d="${BREW_PREFIX}/Cellar/foo/1.0"
    mkdir -p "${d}"
    ln /etc/hosts "${d}/x"$'\n'"sudo rm -rf ~" 2>/dev/null || skip "can't link a root-owned file here"
    # One line per file found (the name itself holds a newline).
    [ "$(find "${d}" -type f -user 0 -exec echo found \; | wc -l)" -eq 1 ] || skip "/etc/hosts doesn't belong to root"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"1 path(s) in ${BREW_PREFIX} don't belong to you"* ]] || false
    [[ "${output}" == *"ls -la ${d}/\$'x\\nsudo rm -rf ~'"* || "${output}" == *"ls -la \$'${d}/x\\nsudo rm -rf ~'"* ]] || false
    run grep -c '^sudo rm -rf ~' <<<"${output}"
    [ "${output}" -eq 0 ]
}

# --- d. PATH -------------------------------------------------------------------

@test "doctor PATH: missing directory → the shell file and line" {
    # shellcheck disable=SC2016  # a literal $PATH, as in a real ~/.zshrc
    printf '# export PATH="/opt/openjdk@17/bin:$PATH"\nexport PATH="/opt/openjdk@17/bin:$PATH"\n' >"${HOME}/.zshrc"
    run_doctor "${TEST_PATH}:/opt/openjdk@17/bin"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"PATH: /opt/openjdk@17/bin doesn't exist."* ]] || false
    [[ "${output}" == *"Remove it from: ~/.zshrc:2"* ]] || false
    [[ "${output}" != *"~/.zshrc:1"* ]] || false
}

@test "doctor PATH: missing directory found in /etc/paths.d" {
    mkdir -p "${PRAETORIAN_DOCTOR_ROOT}/etc/paths.d"
    echo "/Applications/Gone.app/Contents/MacOS" >"${PRAETORIAN_DOCTOR_ROOT}/etc/paths.d/Gone"
    run_doctor "${TEST_PATH}:/Applications/Gone.app/Contents/MacOS"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Remove it from: ${PRAETORIAN_DOCTOR_ROOT}/etc/paths.d/Gone:1"* ]] || false
}

@test "doctor PATH: opt/<formula> of an uninstalled, migrated formula → MacPorts hint" {
    mkdir -p "${HOME}/praetorian"
    printf 'mysql-client\tmysql8\t1792236972\n' >"${HOME}/praetorian/migrated.tsv"
    echo "export PATH=\"${BREW_PREFIX}/opt/mysql-client/bin:\$PATH\"" >"${HOME}/.zprofile"
    run_doctor "${TEST_PATH}:${BREW_PREFIX}/opt/mysql-client/bin"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"PATH: ${BREW_PREFIX}/opt/mysql-client/bin belongs to the formula mysql-client, which isn't installed."* ]] || false
    [[ "${output}" == *"Remove it from: ~/.zprofile:1"* ]] || false
    [[ "${output}" == *"mysql-client was migrated to MacPorts (mysql8)"* ]] || false
}

@test "doctor PATH: formula names are compared as text, not as regular expressions" {
    mkdir -p "${HOME}/praetorian"
    printf 'python@3x12\twrong\t1\nsomeone/tap/libxml++\tlibxmlxx2\t2\npython@3.12\tpython312\t3\n' >"${HOME}/praetorian/migrated.tsv"
    run_doctor "${TEST_PATH}:${BREW_PREFIX}/opt/libxml++/bin:${BREW_PREFIX}/opt/python@3.12/bin"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"libxml++ was migrated to MacPorts (libxmlxx2)"* ]] || false
    [[ "${output}" == *"python@3.12 was migrated to MacPorts (python312)"* ]] || false
    [[ "${output}" != *"(wrong)"* ]] || false
}

@test "doctor PATH: an installed formula's opt directory is fine" {
    mkdir -p "${BREW_PREFIX}/Cellar/libpcap/1.10/bin"
    ln -s ../Cellar/libpcap/1.10 "${BREW_PREFIX}/opt/libpcap"
    run_doctor "${TEST_PATH}:${BREW_PREFIX}/opt/libpcap/bin"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATH: every entry exists."* ]] || false
}

# --- e. Java -------------------------------------------------------------------

@test "doctor Java: broken JDK link → sudo rm, a working one is left alone" {
    local jvm="${PRAETORIAN_DOCTOR_ROOT}/Library/Java/JavaVirtualMachines"
    mkdir -p "${jvm}" "${BATS_TEST_TMPDIR}/jdk17"
    ln -s "${BATS_TEST_TMPDIR}/jdk17" "${jvm}/openjdk17.jdk"
    ln -s "${BREW_PREFIX}/opt/openjdk@21/libexec/openjdk.jdk" "${jvm}/openjdk-21.jdk"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"sudo rm ${jvm}/openjdk-21.jdk"* ]] || false
    [[ "${output}" != *"openjdk17.jdk"* ]] || false
}

# --- f. empty Cellar directories --------------------------------------------------

@test "doctor Cellar: empty formula directory → rmdir, a real one is left alone" {
    mkdir -p "${BREW_PREFIX}/Cellar/openvpn" "${BREW_PREFIX}/Cellar/wget/1.25"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"rmdir ${BREW_PREFIX}/Cellar/openvpn"* ]] || false
    [[ "${output}" != *"Cellar/wget"* ]] || false
}

# --- g. npm ------------------------------------------------------------------------

@test "doctor npm: global packages without node → rm commands" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/"{npm,typescript/bin}
    ln -s ../lib/node_modules/typescript/bin/tsc "${BREW_PREFIX}/bin/tsc"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"npm: 2 global package(s)"*"but no node formula"* ]] || false
    [[ "${output}" == *"rm -rf ${BREW_PREFIX}/lib/node_modules/npm ${BREW_PREFIX}/lib/node_modules/typescript"* ]] || false
    [[ "${output}" == *"rm ${BREW_PREFIX}/bin/tsc"* ]] || false
    [[ "${output}" == *"npm install -g typescript"* ]] || false
    [ -d "${BREW_PREFIX}/lib/node_modules/typescript" ]
}

@test "doctor npm: hostile package names are quoted in the printed commands" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/a;b c"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'npm install -g a\;b\ c'* ]] || false
    [[ "${output}" == *'rm -rf '"${BREW_PREFIX}"'/lib/node_modules/a\;b\ c'* ]] || false
}

@test "doctor npm: an empty @scope directory is no package and doesn't stop the run" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/@empty"
    # shellcheck disable=SC2016  # expanded by the bash of in_praetorian
    run in_praetorian 'npm_global_packages "${BREW_PREFIX}"; echo "rc=$?"'
    [ "${output}" = "rc=0" ]
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"npm: no global package in"* ]] || false
}

@test "doctor npm: a nodejs.org node in the prefix (Intel's /usr/local) → its packages are left alone" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/npm/bin" "${BREW_PREFIX}/lib/node_modules/typescript"
    fake_exe "${BREW_PREFIX}/bin/node"
    ln -s ../lib/node_modules/npm/bin/npm-cli.js "${BREW_PREFIX}/bin/npm"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"belong to ${BREW_PREFIX}/bin/node (not Homebrew's node): left alone."* ]] || false
    [[ "${output}" != *"rm -rf"* ]] || false
    [[ "${output}" != *"rm ${BREW_PREFIX}/bin/npm"* ]] || false
}

@test "doctor npm: Homebrew's node link gone, another node in the PATH runs them → reported, no rm" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/typescript"
    ln -s ../Cellar/node/24.1/bin/node "${BREW_PREFIX}/bin/node"
    fake_exe "${BATS_TEST_TMPDIR}/othernode/node"
    run_doctor "${TEST_PATH}:${BATS_TEST_TMPDIR}/othernode"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"their commands run on ${BATS_TEST_TMPDIR}/othernode/node: left alone."* ]] || false
    [[ "${output}" != *"rm -rf"* ]] || false
}

@test "doctor npm: node installed → fine" {
    mkdir -p "${BREW_PREFIX}/lib/node_modules/typescript" "${BREW_PREFIX}/Cellar/node/24.1"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"have their node formula"* ]] || false
}

# --- h. migrated ports not requested ------------------------------------------------

@test "doctor MacPorts: migrated port marked as a dependency → sudo port setrequested" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'go\tgo\t1\nstep\tstep-cli,step-ca\t2\nwget\twget\t3\n' >"${HOME}/praetorian/migrated.tsv"
    export PORT_REQUESTED="wget step-cli" PORT_INSTALLED="go wget step-cli step-ca"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"2 migrated port(s) marked as a dependency only"* ]] || false
    [[ "${output}" == *"sudo port setrequested go step-ca"* ]] || false
    [ ! -s "${SUDO_CALLS}" ]
    run grep -c setrequested "${PORT_CALLS}"
    [ "${output}" -eq 0 ]
}

@test "doctor MacPorts: hostile port names in migrated.tsv are quoted" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'go\tgo;id\t1\n' >"${HOME}/praetorian/migrated.tsv"
    export PORT_REQUESTED="" PORT_INSTALLED=""
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sudo port install go\;id '* ]] || false
}

@test "doctor MacPorts: migrated ports requested → fine; one gone → reported" {
    with_macports
    mkdir -p "${HOME}/praetorian"
    printf 'go\tgo\t1\n' >"${HOME}/praetorian/migrated.tsv"
    export PORT_REQUESTED="go"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"the 1 migrated port(s) are installed and marked as requested"* ]] || false
    export PORT_REQUESTED="" PORT_INSTALLED=""
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"sudo port install go"* ]] || false
}

# --- i. untrusted taps ------------------------------------------------------------

@test "doctor casks: refused by Homebrew (untrusted tap) → brew trust / untap commands" {
    mkdir -p "${BREW_CASKROOM}/foo/.metadata" "${BREW_CASKROOM}/bar/.metadata"
    echo '{ "source": { "tap": "someone/tools", "version": "1.0" } }' >"${BREW_CASKROOM}/foo/.metadata/INSTALL_RECEIPT.json"
    echo '{ "source": { "tap": "homebrew/cask", "version": "2.0" } }' >"${BREW_CASKROOM}/bar/.metadata/INSTALL_RECEIPT.json"
    export BREW_INFO_CASK_RC=1
    export BREW_INFO_CASK_OUTPUT="Error: Refusing to load cask someone/tools/foo from untrusted tap someone/tools."
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"brew trust --cask someone/tools/foo"* ]] || false
    [[ "${output}" == *"brew uninstall --cask someone/tools/foo && brew untap someone/tools"* ]] || false
    grep -qx 'info --cask someone/tools/foo' "${BREW_CALLS}"
    # Official casks aren't asked about; nothing is trusted or removed.
    run grep -E '^(info --cask .*bar|trust|untap|uninstall)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "doctor casks: a hostile tap name from a receipt is quoted" {
    mkdir -p "${BREW_CASKROOM}/foo/.metadata"
    echo '{ "source": { "tap": "evil/x;touch pwned" } }' >"${BREW_CASKROOM}/foo/.metadata/INSTALL_RECEIPT.json"
    export BREW_INFO_CASK_RC=1 BREW_INFO_CASK_OUTPUT="Error: Refusing to load cask from untrusted tap."
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'brew trust --cask evil/x\;touch\ pwned/foo'* ]] || false
    [[ "${output}" == *'brew untap evil/x\;touch\ pwned'* ]] || false
}

@test "doctor casks: a cask without an install receipt doesn't stop the run" {
    mkdir -p "${BREW_CASKROOM}/old"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"too old to tell, not checked"* ]] || false
}

@test "doctor casks: third-party tap that loads → fine" {
    mkdir -p "${BREW_CASKROOM}/foo/.metadata"
    echo '{ "source": { "tap": "someone/tools" } }' >"${BREW_CASKROOM}/foo/.metadata/INSTALL_RECEIPT.json"
    export BREW_INFO_CASK_OUTPUT="==> someone/tools/foo: 1.0"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Casks: 1 from a third-party tap, none refused by Homebrew."* ]] || false
}

# --- j. Command Line Tools ---------------------------------------------------------

@test "doctor CLT: C++ headers with no newer ones in the SDK, old CLT → in use, not flagged" {
    local dir="${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/usr/include/c++"
    mkdir -p "${dir}/v1" "${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/SDKs/MacOSX14.sdk/usr/include"
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"are the ones in use"* ]] || false
    fake_pkgutil 15.3.0.0.1.1708646388
    run_doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"sudo rm -rf ${dir}"* ]] || false
}

@test "doctor CLT: stale C++ headers (CLT 16 or later) → sudo rm -rf" {
    local dir="${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/usr/include/c++"
    mkdir -p "${dir}/v1"
    fake_pkgutil 16.0.0.0.1.1724870825
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Command Line Tools 16 keep them in the SDK"* ]] || false
    [[ "${output}" == *"sudo rm -rf ${dir}"* ]] || false
    [ -d "${dir}/v1" ]
}

@test "doctor CLT: stale C++ headers (the SDK has its own) → sudo rm -rf" {
    local dir="${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/usr/include/c++"
    mkdir -p "${dir}/v1" "${PRAETORIAN_DOCTOR_ROOT}/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk/usr/include/c++/v1"
    run_doctor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"the SDK has its own (MacOSX15.sdk)"* ]] || false
    [[ "${output}" == *"sudo rm -rf ${dir}"* ]] || false
}

# --- tools missing -------------------------------------------------------------

@test "doctor: MacPorts only (no Homebrew) → Homebrew checks skipped" {
    if [[ -x /usr/local/bin/brew || -x /opt/homebrew/bin/brew ]]; then
        skip "a real Homebrew is installed on this machine"
    fi
    with_macports
    local stubs="${BATS_TEST_TMPDIR}/stubs_nobrew" f
    mkdir -p "${stubs}"
    for f in "${BATS_TEST_DIRNAME}"/stubs/*; do
        [[ "${f##*/}" == brew ]] || cp "${f}" "${stubs}/"
    done
    run_doctor "${TEST_PATH/"${BATS_TEST_DIRNAME}/stubs"/${stubs}}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew not found: Homebrew checks skipped."* ]] || false
    [ ! -s "${BREW_CALLS}" ]
}
