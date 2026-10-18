#!/usr/bin/env bats
#
# --status tests: read-only summary built from what brew and port answer
# (migrated, still in Homebrew and why, leftovers, counts) and from the
# session logs. Same fakes as tests/praetorian.bats, plus a local brew
# wrapper and a local fake port that answer the "list"/"echo" queries.
#
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    STUBS="${BATS_TEST_DIRNAME}/stubs"
    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${BIN}"
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
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    PHOME="${HOME}/praetorian"
    LOGS="${PHOME}/logs"
    mkdir -p "${LOGS}"
    with_status_brew
}

# Wraps the fake brew: the "list" queries of --status answer
#   FAKE_BREW_ALL          brew list --formula -1
#   FAKE_BREW_ON_REQUEST   brew list --formula --installed-on-request -1
#   FAKE_BREW_CASKS        brew list --cask -1
# (space-separated). Everything else goes to the fake.
with_status_brew() {
    cat >"${BIN}/brew" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "list --formula -1" | "list --formula --installed-on-request -1" | "list --cask -1")
        printf '%s\n' "\$*" >>"\${BREW_CALLS}"
        case "\$*" in
            *on-request*) list=\${FAKE_BREW_ON_REQUEST:-} ;;
            *--cask*) list=\${FAKE_BREW_CASKS:-} ;;
            *) list=\${FAKE_BREW_ALL:-} ;;
        esac
        for n in \${list}; do echo "\${n}"; done
        exit 0
        ;;
esac
exec "${STUBS}/brew" "\$@"
EOF
    chmod +x "${BIN}/brew"
}

# Fake port answering the queries of --status (space-separated lists):
#   FAKE_PORT_ACTIVE / FAKE_PORT_REQUESTED / FAKE_PORT_LEAVES / FAKE_PORT_ALL
with_status_port() {
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cat >"${PRAETORIAN_PORT_PREFIX}/bin/port" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PORT_CALLS:?}"
while [[ "${1:-}" == -* ]]; do shift; done
case "${1:-} ${2:-}" in
    "version "*) echo "Version: 2.12.0" ;;
    "echo active") list=${FAKE_PORT_ACTIVE:-} ;;
    "echo requested") list=${FAKE_PORT_REQUESTED:-} ;;
    "echo leaves") list=${FAKE_PORT_LEAVES:-} ;;
    "echo all") list=${FAKE_PORT_ALL:-} ;;
esac
for p in ${list:-}; do printf '%-30s @1.0_0\n' "${p}"; done
exit 0
EOF
    chmod +x "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# fake_log <timestamp YYYYmmdd_HHMMSS> <lines…>: a session log, each line
# prefixed with the time of the timestamp plus its index in seconds.
fake_log() {
    local ts=$1 i=0 line
    shift
    local day="${ts:0:4}-${ts:4:2}-${ts:6:2}" h=${ts:9:2} m=${ts:11:2}
    for line in "$@"; do
        printf '[%s %s:%s:%02d] %s\n' "${day}" "${h}" "${m}" "${i}" "${line}"
        i=$((i + 1))
    done >"${LOGS}/praetorian_${ts}.log"
}

@test "--status: migrated formulae checked against brew and port, inconsistencies flagged" {
    with_status_port
    printf 'wget\twget\t1\ngit\tgit\t2\nfoo\tfoo-port\t3\nbar\tbar\t4\nstep\tstep-cli,step-ca\t5\nmake\tgmake\t6\n' >"${PHOME}/migrated.tsv"
    export FAKE_BREW_ALL="git" FAKE_PORT_ACTIVE="wget git bar step-cli gmake" FAKE_PORT_REQUESTED="wget git step-cli gmake"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"✓ 2 formula(e) migrated and consistent"* ]] || false
    [[ "${output}" == *"    wget, make→gmake"* ]] || false
    [[ "${output}" == *"! 4 migrated formula(e) not in the expected state:"* ]] || false
    [[ "${output}" == *"- git → git: formula still installed in Homebrew"* ]] || false
    [[ "${output}" == *"- foo → foo-port: port foo-port not installed or not active"* ]] || false
    [[ "${output}" == *"- bar → bar: port bar not marked requested"* ]] || false
    [[ "${output}" == *"- step → step-cli,step-ca: port step-ca not installed or not active"* ]] || false
}

@test "--status: the last entry of a formula migrated twice counts" {
    with_status_port
    printf 'wget\twget-old\t1\nwget\twget\t2\n' >"${PHOME}/migrated.tsv"
    export FAKE_PORT_ACTIVE="wget" FAKE_PORT_REQUESTED="wget"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"✓ 1 formula(e) migrated and consistent"* ]] || false
    [[ "${output}" != *"wget-old"* ]] || false
}

@test "--status: no migrated.tsv yet" {
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No formula migrated by praetorian yet."* ]] || false
}

@test "--status: formulae still in Homebrew with a reason, port echo all run once" {
    with_status_port
    printf 'qfoo\tformula\t%s\tbuild\tbuild failed\n' "$(date +%s)" >"${PHOME}/quarantine.tsv"
    export FAKE_BREW_ON_REQUEST="mysql-client nonesuch qfoo wget" FAKE_BREW_ALL="mysql-client nonesuch qfoo wget"
    export FAKE_PORT_ALL="wget mysql8 qfoo"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"• 4 formula(e):"* ]] || false
    [[ "${output}" == *"- wget — same-name port: praetorian --migrate wget"* ]] || false
    [[ "${output}" == *"- mysql-client — no same-name port; maybe: mysql8"* ]] || false
    [[ "${output}" == *"- nonesuch — no port found"* ]] || false
    [[ "${output}" == *"- qfoo — quarantined (build failed)"* ]] || false
    [ "$(grep -c 'echo all' "${PORT_CALLS}")" -eq 1 ]
}

@test "--status: known traps → the table's spec, not the same-name port" {
    with_status_port
    export FAKE_BREW_ON_REQUEST="cmake mysql-client" FAKE_BREW_ALL="cmake mysql-client"
    export FAKE_PORT_ALL="cmake cmake-devel mysql8 mysql-innovation"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"- cmake — known trap: praetorian --migrate cmake=cmake-devel"* ]] || false
    [[ "${output}" == *"- mysql-client — known trap: praetorian --migrate mysql-client=mysql-innovation"* ]] || false
    [[ "${output}" != *"--migrate cmake "* ]] || false
    [[ "${output}" != *"maybe: mysql8"* ]] || false
}

@test "--status: nothing left on request → no port echo all" {
    with_status_port
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"None: Homebrew only keeps casks and dependencies."* ]] || false
    run grep -c 'echo all' "${PORT_CALLS}"
    [ "${output}" -eq 0 ]
}

@test "--status: leftovers = brew leaves not installed on request, hint --prune" {
    export FAKE_BREW_ON_REQUEST="wget" FAKE_BREW_ALL="wget libfoo libbar" BREW_LEAVES=$'wget\nlibfoo\nhomebrew/tap/libbar'
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"! 2 formula(e) nothing needs and nobody asked for:"* ]] || false
    [[ "${output}" == *"libbar, libfoo"* ]] || false
    [[ "${output}" == *"praetorian --prune"* ]] || false
}

@test "--status: counts of casks, formulae and ports" {
    with_status_port
    export FAKE_BREW_CASKS="firefox iterm2" FAKE_BREW_ON_REQUEST="wget" FAKE_BREW_ALL="wget libfoo libbar"
    export FAKE_PORT_ACTIVE="a b c" FAKE_PORT_REQUESTED="a" FAKE_PORT_LEAVES="c" FAKE_PORT_ALL="wget"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Homebrew: 2 cask(s) (they stay in Homebrew), 3 formula(e) (1 on request, 2 dependencies)."* ]] || false
    [[ "${output}" == *"MacPorts: 3 active port(s), 1 requested, 1 leaves"* ]] || false
    # Never "port uninstall leaves": it would take migrated ports along.
    [[ "${output}" != *"uninstall leaves"* ]] || false
    [[ "${output}" == *"praetorian --dry-run --prune"* ]] || false
}

@test "--status: without MacPorts, nothing checked on the port side" {
    printf 'wget\twget\t1\n' >"${PHOME}/migrated.tsv"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MacPorts unavailable: the ports of the migrated formulae weren't checked."* ]] || false
    [[ "${output}" == *"✓ 1 formula(e) migrated and gone from Homebrew:"* ]] || false
    [[ "${output}" == *"MacPorts isn't installed."* ]] || false
}

@test "--status: last sessions from the logs, newest first, colours stripped" {
    local esc=$'\033'
    fake_log 20261001_100000 "praetorian 1.3.0 — session start (mode migrate)" \
        "OUT: ${esc}[1m${esc}[34m── Migration: make (Homebrew) → gmake (MacPorts) ${esc}[0m" \
        "OUT: ${esc}[32m✓${esc}[0m make migrated to MacPorts (gmake)." \
        "OUT: Steps passed: ${esc}[32m2${esc}[0m   failed: ${esc}[31m0${esc}[0m   blocked: ${esc}[31m0${esc}[0m"
    fake_log 20261002_100000 "praetorian 1.3.0 — session start (mode migrate)" \
        "OUT: ── Migration: ffmpeg (Homebrew) → ffmpeg (MacPorts) " \
        "OUT: ${esc}[31m${esc}[1m✗ BLOCKED: ffmpeg (MacPorts) doesn't provide every command of ffmpeg${esc}[0m" \
        "OUT: ✗ Finished with errors."
    fake_log 20261003_100000 "praetorian 1.3.0 — session start (mode maintain)" \
        "OUT: Steps passed: 4   failed: 1   blocked: 0" "x" "x" "OUT: ✗ Finished with errors."
    fake_log 20261004_100000 "praetorian 1.3.0 — session start (mode maintain)" \
        "OUT: Steps passed: 5   failed: 0   blocked: 0" "OUT: ✓ Maintenance completed successfully."
    fake_log 20261005_100000 "praetorian 1.3.0 — session start (mode maintain)" \
        "OUT: ! Interrupted (Ctrl-C) — session stopped, the following steps were not run."
    fake_log 20261006_100000 "praetorian 1.3.0 — session start (mode status)"
    fake_log 20261007_100000 "OUT: ✗ --doctor can't be combined with another mode option"
    fake_log 20261008_100000 "praetorian 1.3.0 — session start (mode report)" "OUT: x"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${esc}["* ]] || false
    local s
    s=$(sed -n '/Last sessions/,$p' <<<"${output}")
    [ "$(grep -c '^    2026-' <<<"${s}")" -eq 6 ]
    [[ "$(sed -n 2p <<<"${s}")" == "    2026-10-08 10:00  report   — done (1 s)" ]] || false
    [[ "${s}" == *"2026-10-05 10:00  maintain — ! interrupted (Ctrl-C)"* ]] || false
    [[ "${s}" == *"2026-10-04 10:00  maintain — ✓ ok, 5 step(s) (2 s)"* ]] || false
    [[ "${s}" == *"2026-10-03 10:00  maintain — ✗ 1 step(s) failed, 4 passed (4 s)"* ]] || false
    [[ "${s}" == *"2026-10-02 10:00  migrate  ffmpeg — ✗ blocked: ffmpeg (MacPorts) doesn't provide every command of ffmpeg (3 s)"* ]] || false
    [[ "${s}" == *"2026-10-01 10:00  migrate  make→gmake — ✓ migrated: make (3 s)"* ]] || false
    [[ "${s}" != *"2026-10-06"* && "${s}" != *"2026-10-07"* ]] || false
}

@test "--status: at most 10 sessions listed" {
    local i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        fake_log "202610${i}_100000" "praetorian 1.3.0 — session start (mode report)"
    done
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^    2026-10-.* report ' <<<"${output}")" -eq 10 ]
    [[ "${output}" == *"2026-10-12 10:00"* ]] || false
    [[ "${output}" != *"2026-10-02 10:00"* ]] || false
}

@test "--status: read-only (no sudo, no brew or port change, no lock)" {
    with_status_port
    printf 'wget\twget\t1\n' >"${PHOME}/migrated.tsv"
    export FAKE_BREW_ON_REQUEST="foo" FAKE_PORT_ALL="foo"
    run "${PRAETORIAN}" --status
    [ "${status}" -eq 0 ]
    [ ! -s "${SUDO_CALLS}" ]
    run grep -E '^(update|upgrade|install|uninstall|reinstall|cleanup|autoremove|link|unlink)' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -vE '^(-q )?(version|echo)( |$)' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    [ ! -e "${PHOME}/.lock" ]
}
