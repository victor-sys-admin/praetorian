#!/usr/bin/env bats
#
# --sbom tests: CycloneDX 1.6 file built from fake inventories (brew,
# port, system_profiler, npm, pipx metadata), its permissions, the diff
# with the previous one, trivy's summary, rotation. The JSON is written by
# Python: without a python3 (the ci/check container has none), only the
# "no Python" block is tested, the others are skipped.
#
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    STUBS="${BATS_TEST_DIRNAME}/stubs"
    BIN="${BATS_TEST_TMPDIR}/bin"
    FIX="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${BIN}" "${FIX}"
    export PATH="${BIN}:${STUBS}:${PATH}"
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls"
    export PORT_CALLS="${BATS_TEST_TMPDIR}/port_calls"
    export SUDO_CALLS="${BATS_TEST_TMPDIR}/sudo_calls"
    export OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    export XCODEBUILD_CALLS="${BATS_TEST_TMPDIR}/xcodebuild_calls"
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    # Temporary files of the run land here: checked for leftovers.
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    LOGS="${HOME}/praetorian/logs"
    export PIPX_HOME="${HOME}/pipx"
    with_fakes
    write_fixtures
}

# python3 that runs (the same test sbom_python makes).
have_python() {
    command -v python3 >/dev/null 2>&1 && python3 -I -c 'import json' >/dev/null 2>&1
}

need_python() {
    have_python || skip "no python3 here (the SBOM is written by Python)"
}

# brew wrapper (brew info --json=v2 --installed → FAKE_BREW_INFO), fake
# port in the prefix (port installed active → FAKE_PORT_INSTALLED),
# system_profiler and npm printing their fixture.
with_fakes() {
    cat >"${BIN}/brew" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "info --json=v2 --installed" ]]; then
    printf '%s\n' "\$*" >>"\${BREW_CALLS}"
    cat "\${FAKE_BREW_INFO}"
    exit 0
fi
exec "${STUBS}/brew" "\$@"
EOF
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cat >"${PRAETORIAN_PORT_PREFIX}/bin/port" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PORT_CALLS:?}"
while [[ "${1:-}" == -* ]]; do shift; done
case "${1:-} ${2:-}" in
    "version "*) echo "Version: 2.12.0" ;;
    "installed active") cat "${FAKE_PORT_INSTALLED}" ;;
esac
exit 0
EOF
    printf '#!/bin/sh\ncat "%s"\n' "${FIX}/apps.json" >"${BIN}/system_profiler"
    printf '#!/bin/sh\ncat "%s"\nexit 1\n' "${FIX}/npm.json" >"${BIN}/npm"
    chmod +x "${BIN}/brew" "${PRAETORIAN_PORT_PREFIX}/bin/port" "${BIN}/system_profiler" "${BIN}/npm"
    export FAKE_BREW_INFO="${FIX}/brew.json" FAKE_PORT_INSTALLED="${FIX}/port.txt"
}

write_fixtures() {
    cat >"${FIX}/brew.json" <<'EOF'
{"formulae": [
  {"full_name": "wget", "desc": "Internet file retriever", "license": "GPL-3.0-or-later",
   "homepage": "https://www.gnu.org/software/wget/", "tap": "homebrew/core",
   "installed": [{"version": "1.25.0", "installed_on_request": true}]},
  {"full_name": "libfoo", "license": "Apache-2.0 OR MIT", "tap": "homebrew/core",
   "installed": [{"version": "2.0_1", "installed_on_request": false}]},
  {"full_name": "hashicorp/tap/terraform", "license": "BUSL-1.1", "tap": "hashicorp/tap",
   "installed": [{"version": "1.9.0", "installed_on_request": true}]}
 ],
 "casks": [
  {"token": "firefox", "full_token": "firefox", "installed": "131.0", "version": "131.0", "homepage": "https://www.mozilla.org/firefox/"}
 ]}
EOF
    cat >"${FIX}/port.txt" <<'EOF'
  curl @8.10.1_0+ssl+http2 (active)
  zlib @1.3.1_0 (active)
EOF
    cat >"${FIX}/apps.json" <<EOF
{"SPApplicationsDataType": [
  {"_name": "Foo", "version": "3.1", "path": "/Applications/Foo.app", "signed_by": ["Developer ID Application: Foo Inc", "Apple Root CA"], "obtained_from": "identified_developer"},
  {"_name": "Foo Helper", "version": "3.1", "path": "/Applications/Foo.app/Contents/Helpers/Foo Helper.app"},
  {"_name": "Mine", "version": "1.0", "path": "${HOME}/Applications/Mine.app"},
  {"_name": "Safari", "version": "18.0", "path": "/System/Applications/Safari.app"}
]}
EOF
    cat >"${FIX}/npm.json" <<'EOF'
{"name": "lib", "dependencies": {"@nestjs/cli": {"version": "12.0.8"}, "dclint": {"version": "3.1.0"}}}
EOF
    mkdir -p "${PIPX_HOME}/venvs/poetry"
    cat >"${PIPX_HOME}/venvs/poetry/pipx_metadata.json" <<'EOF'
{"main_package": {"package": "poetry", "package_version": "2.5.1"},
 "injected_packages": {"poetry_plugin_export": {"package": "poetry_plugin_export", "package_version": "1.8.0"}},
 "python_version": "Python 3.13.1"}
EOF
}

# sbom_file: the newest SBOM written.
sbom_file() {
    find "${LOGS}" -maxdepth 1 -name 'sbom_*.cdx.json' | sort | tail -n 1
}

@test "--sbom without a working Python → blocked with what to install, no file" {
    printf '#!/bin/sh\nexit 1\n' >"${BIN}/python3"
    chmod +x "${BIN}/python3"
    # /usr/bin/python3 is only tried with an existing developer directory.
    export XCODE_SELECT_PATH=/nonexistent/Xcode.app/Contents/Developer
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED: no Python 3 to write the SBOM"* ]] || false
    [[ "${output}" == *"xcode-select --install"* ]] || false
    [ -z "$(sbom_file)" ]
    [ ! -s "${BREW_CALLS}" ]
    # Unattended (no terminal), yet no "Stopped" notification: a read-only
    # mode answers on the screen.
    [ ! -s "${OSASCRIPT_CALLS}" ]
}

@test "--sbom: CycloneDX 1.6 with every source, purls, licenses, praetorian: properties" {
    need_python
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SBOM written: ${LOGS}/sbom_"*".cdx.json (12 components)"* ]] || false
    [[ "${output}" == *"Homebrew formulae 3, casks 1, MacPorts 2, apps 2, pipx 2, npm 2"* ]] || false
    [[ "${output}" == *"First SBOM"* ]] || false
    run python3 -I - "$(sbom_file)" "${HOME}" <<'PY'
import json, sys
bom = json.load(open(sys.argv[1]))
home = sys.argv[2]
assert bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.6", bom
assert bom["serialNumber"].startswith("urn:uuid:")
root = bom["metadata"]["component"]
assert root["type"] == "operating-system" and root["name"] == "macOS", root
by = {c["name"]: c for c in bom["components"]}
assert by["wget"]["purl"] == "pkg:brew/wget@1.25.0", by["wget"]
assert by["wget"]["licenses"] == [{"license": {"id": "GPL-3.0-or-later"}}]
assert by["libfoo"]["licenses"] == [{"expression": "Apache-2.0 OR MIT"}]
assert by["hashicorp/tap/terraform"]["purl"] == "pkg:brew/hashicorp%2Ftap%2Fterraform@1.9.0"
assert by["firefox"]["purl"] == "pkg:brew/cask/firefox@131.0"
assert by["curl"]["purl"] == "pkg:macports/curl@8.10.1_0"
props = {p["name"]: p["value"] for p in by["curl"]["properties"]}
assert props == {"praetorian:source": "macports", "praetorian:variants": "ssl,http2"}, props
assert by["poetry"]["purl"] == "pkg:pypi/poetry@2.5.1"
assert by["poetry_plugin_export"]["purl"] == "pkg:pypi/poetry-plugin-export@1.8.0"
assert by["poetry_plugin_export"]["type"] == "library"
assert by["@nestjs/cli"]["purl"] == "pkg:npm/%40nestjs/cli@12.0.8"
assert by["dclint"]["purl"] == "pkg:npm/dclint@3.1.0"
foo = {p["name"]: p["value"] for p in by["Foo"]["properties"]}
assert foo["praetorian:path"] == "/Applications/Foo.app" and foo["praetorian:signed_by"] == "Developer ID Application: Foo Inc", foo
assert "Mine" in by and "Foo Helper" not in by and "Safari" not in by
w = {p["name"]: p["value"] for p in by["wget"]["properties"]}
assert w["praetorian:on_request"] == "true" and w["praetorian:source"] == "homebrew-formula", w
for c in bom["components"]:
    assert all(p["name"].startswith("praetorian:") for p in c["properties"]), c
assert len({c["bom-ref"] for c in bom["components"]}) == len(bom["components"])
print("valid")
PY
    [ "${status}" -eq 0 ]
    [ "${output}" = valid ]
}

@test "--sbom: file mode 600 in the 700 logs directory, temporary files removed" {
    need_python
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "$(ls -l "$(sbom_file)")" == "-rw-------"* ]] || false
    [[ "$(ls -ld "${LOGS}")" == "drwx------"* ]] || false
    [ -z "$(find "${TMPDIR}" -name 'praetorian_sbom.*')" ]
}

@test "--sbom: changes since the previous SBOM (added, removed, version changed)" {
    need_python
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    mv "$(sbom_file)" "${LOGS}/sbom_20000101_000000.cdx.json"
    # wget upgraded, zlib gone, a new port.
    sed -i.bak 's/"1.25.0"/"1.26.0"/' "${FIX}/brew.json"
    printf '  curl @8.10.1_0+ssl+http2 (active)\n  jq @1.7.1_0 (active)\n' >"${FIX}/port.txt"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Since the previous SBOM (sbom_20000101_000000.cdx.json): 1 added, 1 removed, 1 version(s) changed."* ]] || false
    [[ "${output}" == *"- jq 1.7.1_0 (macports)"* ]] || false
    [[ "${output}" == *"- zlib 1.3.1_0 (macports)"* ]] || false
    [[ "${output}" == *"- wget 1.25.0 → 1.26.0 (homebrew-formula)"* ]] || false
    grep -q 'SBOM changed: wget 1.25.0 → 1.26.0' "${LOGS}"/praetorian_*.log
}

@test "--sbom: no change since the previous SBOM" {
    need_python
    run "${PRAETORIAN}" --sbom
    mv "$(sbom_file)" "${LOGS}/sbom_20000101_000000.cdx.json"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No change since the previous SBOM (sbom_20000101_000000.cdx.json)."* ]] || false
}

@test "--sbom: a source missing is skipped and said so (no MacPorts)" {
    need_python
    rm -rf "${PRAETORIAN_PORT_PREFIX}"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MacPorts not found: left out of the SBOM."* ]] || false
    [[ "${output}" == *"MacPorts 0,"* ]] || false
}

@test "--sbom: trivy's HIGH / CRITICAL findings summarized; a failing trivy doesn't fail the run" {
    need_python
    cat >"${BIN}/trivy" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == --output ]] && out=$2
    shift
done
[[ -z "${FAKE_TRIVY_FAIL:-}" ]] || exit 1
cat >"${out}" <<'JSON'
{"Results": [{"Target": "Python", "Vulnerabilities": [
  {"PkgName": "poetry", "InstalledVersion": "2.5.1", "VulnerabilityID": "CVE-2099-0001", "Severity": "HIGH", "FixedVersion": "2.5.2"}]}]}
JSON
EOF
    chmod +x "${BIN}/trivy"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trivy: 1 HIGH / CRITICAL vulnerability(ies), 0 critical"* ]] || false
    [[ "${output}" == *"- HIGH poetry 2.5.1: CVE-2099-0001 (fixed in 2.5.2)"* ]] || false
    export FAKE_TRIVY_FAIL=1
    rm -f "$(sbom_file)"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trivy failed (see the log): no vulnerability check. The SBOM is written all the same."* ]] || false
    [ -n "$(sbom_file)" ]
}

@test "--sbom: the last 30 SBOMs are kept" {
    need_python
    local i
    mkdir -p "${LOGS}"
    for i in $(seq -w 1 31); do
        echo '{}' >"${LOGS}/sbom_200001${i}_000000.cdx.json"
        touch -t "2020010100${i}" "${LOGS}/sbom_200001${i}_000000.cdx.json"
    done
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [ "$(find "${LOGS}" -name 'sbom_*.cdx.json' | wc -l | tr -d ' ')" -eq 30 ]
    [ ! -e "${LOGS}/sbom_20000101_000000.cdx.json" ]
}

@test "--sbom: read-only (no sudo, no brew or port change)" {
    need_python
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [ ! -s "${SUDO_CALLS}" ]
    run grep -E '^(update|upgrade|install|uninstall|reinstall|cleanup|autoremove|link|unlink)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -vE '^(-q )?(version|installed active)$' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--sbom: Python failing (unreadable inventory) → code 2, no partial file left" {
    need_python
    echo '{not json' >"${FIX}/brew.json"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"The SBOM couldn't be written (Python error, see the log)."* ]] || false
    [ -z "$(sbom_file)" ]
    [ -z "$(find "${LOGS}" -name '.sbom_*')" ]
    [ -z "$(find "${TMPDIR}" -name 'praetorian_sbom.*')" ]
}

@test "--sbom: a malformed previous SBOM only skips the comparison" {
    need_python
    mkdir -p "${LOGS}"
    echo '{"components": 5}' >"${LOGS}/sbom_20000101_000000.cdx.json"
    run "${PRAETORIAN}" --sbom
    [ "${status}" -eq 0 ]
    [ -n "$(sbom_file)" ]
    grep -q 'unreadable' "${LOGS}"/praetorian_*.log
}
