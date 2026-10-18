#!/usr/bin/env bats
#
# praetorian-schedule tests: launchctl is the fake of tests/stubs (the
# real launchd is never touched), HOME is a temp directory, so the plist
# lands in a temp ~/Library/LaunchAgents. plutil is the real one on macOS
# (the generated plist is really checked) and a minimal fake on Linux.
#
# Each @test runs in its own subshell: the exported variables are meant to
# stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
    export LAUNCHCTL_CALLS="${BATS_TEST_TMPDIR}/launchctl_calls"
    : >"${LAUNCHCTL_CALLS}"
    unset PRAETORIAN_HOME
    SCHEDULE="${BATS_TEST_DIRNAME}/../praetorian-schedule"
    REPO=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    LABEL=io.github.victor-sys-admin.praetorian
    PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
    DOMAIN="gui/$(id -u)"
}

# Copies praetorian, praetorian-schedule and lib/ into <dir> (mode 755
# for the directory, as a fresh clone).
scratch_repo() {
    local dir=$1
    mkdir -p "${dir}"
    chmod 755 "${dir}"
    cp "${REPO}/praetorian" "${REPO}/praetorian-schedule" "${dir}/"
    cp -R "${REPO}/lib" "${dir}/lib"
    chmod 755 "${dir}/praetorian" "${dir}/praetorian-schedule" "${dir}/lib"
    chmod 644 "${dir}"/lib/*.sh
}

# plist_args: the ProgramArguments of the installed plist, one per line.
plist_args() {
    sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "${PLIST}" |
        sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p'
}

# plist_after <key>: the line following <key> (its value), trimmed.
plist_after() {
    sed -n "/<key>$1<\\/key>/{n;p;}" "${PLIST}" | head -n 1 | sed -E 's/^[[:space:]]+//'
}

no_leftovers() {
    run find "${HOME}/Library/LaunchAgents" -name ".${LABEL}.*" -o -name "*.previous.*"
    [ -z "${output}" ]
}

# --- Arguments ----------------------------------------------------------------------

@test "schedule: --help prints the usage" {
    run "${SCHEDULE}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"install [--at HH:MM] [--weekday DAY] [--dry-run]"* ]] || false
    [[ "${output}" == *"uninstall"* ]] || false
    [[ "${output}" == *"status"* ]] || false
}

@test "schedule: no command or unknown command → code 1, usage, nothing done" {
    run "${SCHEDULE}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Usage:"* ]] || false
    run "${SCHEDULE}" start
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown command: start"* ]] || false
    [ ! -s "${LAUNCHCTL_CALLS}" ]
}

@test "schedule: unknown option, or an install option on another command → code 1" {
    run "${SCHEDULE}" install --every-hour
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown option for install: --every-hour"* ]] || false
    run "${SCHEDULE}" status --at 03:00
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown option for status: --at"* ]] || false
    [ ! -e "${PLIST}" ]
}

@test "schedule: invalid --at → code 1, nothing written" {
    local at
    for at in 24:00 7:60 3:5 abc 12:30:00 "" "03:30;id"; do
        run "${SCHEDULE}" install --at "${at}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"is not a time between 00:00 and 23:59"* ]] || false
    done
    run "${SCHEDULE}" install --at
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--at expects a time"* ]] || false
    [ ! -e "${PLIST}" ]
    [ ! -s "${LAUNCHCTL_CALLS}" ]
}

@test "schedule: invalid --weekday → code 1, nothing written" {
    run "${SCHEDULE}" install --weekday someday
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'unknown day "someday"'* ]] || false
    run "${SCHEDULE}" install --weekday 8
    [ "${status}" -eq 1 ]
    [ ! -e "${PLIST}" ]
}

@test "schedule: refuses root" {
    FAKE_UID=0 run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Don't run it with sudo"* ]] || false
    [ ! -e "${PLIST}" ]
    [ ! -s "${LAUNCHCTL_CALLS}" ]
}

@test "schedule: no launchctl (not macOS) → refused" {
    if PATH=${PATH//${BATS_TEST_DIRNAME}\/stubs:/} command -v launchctl >/dev/null 2>&1; then
        skip "a real launchctl is installed on this machine"
    fi
    local stubs="${BATS_TEST_TMPDIR}/stubs_nolaunchctl" f
    mkdir -p "${stubs}"
    for f in "${BATS_TEST_DIRNAME}"/stubs/*; do
        [[ "${f##*/}" == launchctl ]] || cp "${f}" "${stubs}/"
    done
    PATH="${stubs}:${PATH//${BATS_TEST_DIRNAME}\/stubs:/}" run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"launchctl not found: praetorian-schedule is for macOS only."* ]] || false
    [ ! -e "${PLIST}" ]
}

# --- install ------------------------------------------------------------------------

@test "schedule: install → plist 644 with the job, loaded in the gui domain" {
    run "${SCHEDULE}" install
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Installed: praetorian runs every day at 03:30"* ]] || false
    [ -f "${PLIST}" ]
    [ -n "$(find "${PLIST}" -perm 644)" ]
    run plist_args
    [ "${lines[0]}" = "${REPO}/praetorian" ]
    [ "${lines[1]}" = --unattended ]
    [ "${lines[2]}" = --ac-power-only ]
    [ "${#lines[@]}" -eq 3 ]
    [ "$(plist_after Hour)" = "<integer>3</integer>" ]
    [ "$(plist_after Minute)" = "<integer>30</integer>" ]
    run grep -c '<key>Weekday</key>' "${PLIST}"
    [ "${output}" -eq 0 ]
    [ "$(plist_after RunAtLoad)" = "<false/>" ]
    [ "$(plist_after PRAETORIAN_HOME)" = "<string>${HOME}/praetorian</string>" ]
    [ "$(plist_after StandardErrorPath)" = "<string>${HOME}/praetorian/logs/launchd.stderr.log</string>" ]
    grep -qx "bootstrap ${DOMAIN} ${PLIST}" "${LAUNCHCTL_CALLS}"
    # The logs directory exists (launchd opens the stderr file in it), for
    # this user only.
    [ -n "$(find "${HOME}/praetorian/logs" -maxdepth 0 -perm 700)" ]
    plutil -lint "${PLIST}"
    no_leftovers
}

@test "schedule: the real plutil reads the expected values (macOS)" {
    command -v /usr/bin/plutil >/dev/null 2>&1 || skip "no real plutil (not macOS)"
    "${SCHEDULE}" install --at 23:05 --weekday sun
    [ "$(/usr/bin/plutil -extract Label raw -o - "${PLIST}")" = "${LABEL}" ]
    [ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "${PLIST}")" = "${REPO}/praetorian" ]
    [ "$(/usr/bin/plutil -extract StartCalendarInterval.Hour raw -o - "${PLIST}")" = 23 ]
    [ "$(/usr/bin/plutil -extract StartCalendarInterval.Minute raw -o - "${PLIST}")" = 5 ]
    [ "$(/usr/bin/plutil -extract StartCalendarInterval.Weekday raw -o - "${PLIST}")" = 0 ]
    [ "$(/usr/bin/plutil -extract ProcessType raw -o - "${PLIST}")" = Standard ]
    [ "$(/usr/bin/plutil -extract EnvironmentVariables.PATH raw -o - "${PLIST}")" = /usr/bin:/bin:/usr/sbin:/sbin ]
}

@test "schedule: --at and --weekday (name, any case, or number)" {
    run "${SCHEDULE}" install --at 23:05 --weekday SUN
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"every Sunday at 23:05"* ]] || false
    [ "$(plist_after Hour)" = "<integer>23</integer>" ]
    [ "$(plist_after Minute)" = "<integer>5</integer>" ]
    [ "$(plist_after Weekday)" = "<integer>0</integer>" ]
    run "${SCHEDULE}" install --weekday 7 --at 00:00
    [ "$(plist_after Weekday)" = "<integer>0</integer>" ]
    [ "$(plist_after Hour)" = "<integer>0</integer>" ]
    run "${SCHEDULE}" install --weekday wednesday --at 09:08
    [[ "${output}" == *"every Wednesday at 09:08"* ]] || false
    [ "$(plist_after Weekday)" = "<integer>3</integer>" ]
    [ "$(plist_after Minute)" = "<integer>8</integer>" ]
}

@test "schedule: install again → old job booted out first, one plist, no leftovers" {
    "${SCHEDULE}" install
    run "${SCHEDULE}" install --at 04:15
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^bootout' "${LAUNCHCTL_CALLS}")" -eq 1 ]
    [ "$(grep -c '^bootstrap' "${LAUNCHCTL_CALLS}")" -eq 2 ]
    # bootout comes before the second bootstrap.
    [ "$(grep -E '^(bootout|bootstrap)' "${LAUNCHCTL_CALLS}" | sed -n 2p)" = "bootout ${DOMAIN}/${LABEL}" ]
    [ "$(plist_after Hour)" = "<integer>4</integer>" ]
    no_leftovers
}

@test "schedule: --dry-run prints the plist, writes and loads nothing" {
    run "${SCHEDULE}" install --dry-run --at 01:02
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dry-run: nothing is installed. Job every day at 01:02"* ]] || false
    [[ "${output}" == *"<string>${REPO}/praetorian</string>"* ]] || false
    [[ "${output}" == *"<string>--ac-power-only</string>"* ]] || false
    [ ! -e "${PLIST}" ]
    [ ! -e "${HOME}/praetorian" ]
    run grep -E '^(bootstrap|bootout|enable)' "${LAUNCHCTL_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "schedule: bootstrap fails on a fresh install → code 1, no plist left" {
    LAUNCHCTL_BOOTSTRAP_RC=5 run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Not installed: launchctl bootstrap failed (code 5): Bootstrap failed: 5: Input/output error"* ]] || false
    [[ "${output}" == *"not over SSH"* ]] || false
    [ ! -e "${PLIST}" ]
    no_leftovers
}

@test "schedule: bootstrap fails on a replacement → previous job put back and reloaded" {
    "${SCHEDULE}" install --at 02:45
    cp "${PLIST}" "${BATS_TEST_TMPDIR}/before"
    LAUNCHCTL_BOOTSTRAP_RC=5 run "${SCHEDULE}" install --at 05:00
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The previous job was put back."* ]] || false
    cmp "${PLIST}" "${BATS_TEST_TMPDIR}/before"
    no_leftovers
}

@test "schedule: plist fails plutil -lint → code 1, nothing installed nor loaded" {
    PLUTIL_LINT_RC=1 run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"doesn't pass plutil -lint"* ]] || false
    [ ! -e "${PLIST}" ]
    run grep -q '^bootstrap' "${LAUNCHCTL_CALLS}"
    [ "${status}" -eq 1 ]
    no_leftovers
}

@test "schedule: job turned off in Login Items → turned back on by install" {
    LAUNCHCTL_DISABLED=1 run "${SCHEDULE}" install
    [ "${status}" -eq 0 ]
    grep -qx "enable ${DOMAIN}/${LABEL}" "${LAUNCHCTL_CALLS}"
}

@test "schedule: started through a symbolic link → the real praetorian path" {
    local copy="${BATS_TEST_TMPDIR}/src/praetorian"
    scratch_repo "${copy}"
    mkdir -p "${HOME}/bin"
    ln -s "${copy}/praetorian-schedule" "${HOME}/bin/praetorian-schedule"
    run "${HOME}/bin/praetorian-schedule" install
    [ "${status}" -eq 0 ]
    run plist_args
    [ "${lines[0]}" = "$(cd "${copy}" && pwd -P)/praetorian" ]
}

@test "schedule: praetorian or its directory writable by others → refused" {
    local copy="${BATS_TEST_TMPDIR}/src/praetorian"
    scratch_repo "${copy}"
    chmod g+w "${copy}/praetorian"
    run "${copy}/praetorian-schedule" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"praetorian is writable by group or others"* ]] || false
    chmod g-w "${copy}/praetorian"
    chmod o+w "${copy}"
    run "${copy}/praetorian-schedule" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is writable by group or others"* ]] || false
    [ ! -e "${PLIST}" ]
    [ ! -s "${LAUNCHCTL_CALLS}" ]
}

@test "schedule: praetorian missing next to the script → refused" {
    local copy="${BATS_TEST_TMPDIR}/src/praetorian"
    scratch_repo "${copy}"
    rm "${copy}/praetorian"
    run "${copy}/praetorian-schedule" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"praetorian not found next to this script"* ]] || false
    [ ! -e "${PLIST}" ]
}

@test "schedule: repository in ~/Documents (kept from background jobs) → refused" {
    local copy="${HOME}/Documents/praetorian"
    scratch_repo "${copy}"
    run "${copy}/praetorian-schedule" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"a folder macOS keeps from background jobs"* ]] || false
    [[ "${output}" == *"Operation not permitted"* ]] || false
    [ ! -e "${PLIST}" ]
}

@test "schedule: PRAETORIAN_HOME relative or in ~/Downloads → refused" {
    PRAETORIAN_HOME=relative/dir run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"PRAETORIAN_HOME must be an absolute path"* ]] || false
    PRAETORIAN_HOME="${HOME}/Downloads/state" run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"PRAETORIAN_HOME (${HOME}/Downloads/state) is in a folder macOS keeps"* ]] || false
    [ ! -e "${PLIST}" ]
}

@test "schedule: PRAETORIAN_HOME passed to the job, XML special characters escaped" {
    local state="${BATS_TEST_TMPDIR}/state <a&b>"
    PRAETORIAN_HOME="${state}" run "${SCHEDULE}" install
    [ "${status}" -eq 0 ]
    [ "$(plist_after PRAETORIAN_HOME)" = "<string>${BATS_TEST_TMPDIR}/state &lt;a&amp;b&gt;</string>" ]
    [ -d "${state}/logs" ]
    plutil -lint "${PLIST}"
    if [[ -x /usr/bin/plutil ]]; then
        [ "$(/usr/bin/plutil -extract EnvironmentVariables.PRAETORIAN_HOME raw -o - "${PLIST}")" = "${state}" ]
    fi
}

@test "schedule: plist path is a symbolic link → refused, link target untouched" {
    mkdir -p "${HOME}/Library/LaunchAgents"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${PLIST}"
    run "${SCHEDULE}" install
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is a symbolic link"* ]] || false
    [ ! -e "${BATS_TEST_TMPDIR}/elsewhere" ]
}

# --- The installed job, run as launchd would ------------------------------------------

@test "schedule: the job's command line runs praetorian unattended, notification at the end" {
    "${SCHEDULE}" install
    local -a args=()
    local a
    while IFS= read -r a; do args+=("${a}"); done < <(plist_args)
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls" OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    : >"${BREW_CALLS}"
    # launchd's environment: only what the plist sets (plus the fakes, and
    # this machine's bash, which may live outside /usr/bin:/bin).
    run env -i HOME="${HOME}" \
        PATH="${BATS_TEST_DIRNAME}/stubs:$(dirname "$(command -v bash)"):$(sed -n '/<key>PATH<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "${PLIST}")" \
        PRAETORIAN_HOME="${HOME}/praetorian" PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt" \
        PRAETORIAN_CAFFEINATED=1 BREW_CALLS="${BREW_CALLS}" OSASCRIPT_CALLS="${OSASCRIPT_CALLS}" \
        "${args[@]}" </dev/null
    [ "${status}" -eq 0 ]
    grep -qx 'update' "${BREW_CALLS}"
    # Notified although the session was short: it ran unattended (no
    # terminal under launchd), silently (no sound).
    grep -qx 'Maintenance completed successfully.' "${OSASCRIPT_CALLS}"
    run grep -qxE 'Tink|Glass' "${OSASCRIPT_CALLS}"
    [ "${status}" -eq 1 ]
    ls "${HOME}"/praetorian/logs/praetorian_*.log >/dev/null
}

# --- uninstall ----------------------------------------------------------------------

@test "schedule: uninstall → booted out, plist removed; again → nothing to do" {
    "${SCHEDULE}" install
    run "${SCHEDULE}" uninstall
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Uninstalled"* ]] || false
    grep -qx "bootout ${DOMAIN}/${LABEL}" "${LAUNCHCTL_CALLS}"
    [ ! -e "${PLIST}" ]
    run "${SCHEDULE}" uninstall
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Nothing to uninstall"* ]] || false
}

@test "schedule: uninstall when bootout fails → code 1, plist kept" {
    "${SCHEDULE}" install
    LAUNCHCTL_BOOTOUT_RC=1 run "${SCHEDULE}" uninstall
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the job is still loaded, the plist was kept"* ]] || false
    [ -f "${PLIST}" ]
}

@test "schedule: uninstall keeps logs and quarantine" {
    "${SCHEDULE}" install
    echo x >"${HOME}/praetorian/quarantine.tsv"
    "${SCHEDULE}" uninstall
    [ -f "${HOME}/praetorian/quarantine.tsv" ]
    [ -d "${HOME}/praetorian/logs" ]
}

# --- status -----------------------------------------------------------------------

@test "schedule: status, not installed → code 3" {
    run "${SCHEDULE}" status
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"Not installed."* ]] || false
}

@test "schedule: status, installed and loaded → code 0, schedule, last run" {
    "${SCHEDULE}" install --at 03:05 --weekday sat
    mkdir -p "${HOME}/praetorian/logs"
    : >"${HOME}/praetorian/logs/praetorian_20261016_030500.log"
    run "${SCHEDULE}" status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Schedule    : every Saturday at 03:05"* ]] || false
    [[ "${output}" == *"Command     : ${REPO}/praetorian"* ]] || false
    [[ "${output}" == *"launchd     : loaded, not running, last exit code 0"* ]] || false
    [[ "${output}" == *"Last log    : ${HOME}/praetorian/logs/praetorian_20261016_030500.log"* ]] || false
}

@test "schedule: status explains the last exit code" {
    "${SCHEDULE}" install
    LAUNCHCTL_LAST_EXIT=2 run "${SCHEDULE}" status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"finished with errors (code 2)"* ]] || false
    LAUNCHCTL_LAST_EXIT=1 run "${SCHEDULE}" status
    [[ "${output}" == *"stopped on a block (code 1)"* ]] || false
}

@test "schedule: status shows the stderr log when it has something" {
    "${SCHEDULE}" install
    echo "early failure" >"${HOME}/praetorian/logs/launchd.stderr.log"
    run "${SCHEDULE}" status
    [[ "${output}" == *"stderr log  : ${HOME}/praetorian/logs/launchd.stderr.log"* ]] || false
    [[ "${output}" == *"    early failure"* ]] || false
}

@test "schedule: status, not loaded or praetorian moved → code 1 with what to do" {
    "${SCHEDULE}" install
    rm -f "${LAUNCHCTL_CALLS}.loaded"
    run "${SCHEDULE}" status
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not loaded"* ]] || false
    "${SCHEDULE}" install
    sed "s#<string>${REPO}/praetorian</string>#<string>/nonexistent/praetorian</string>#" "${PLIST}" >"${PLIST}.new"
    mv "${PLIST}.new" "${PLIST}"
    run "${SCHEDULE}" status
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"praetorian is no longer there"* ]] || false
}

@test "schedule: status, turned off in Login Items → code 1" {
    "${SCHEDULE}" install
    LAUNCHCTL_DISABLED=1 run "${SCHEDULE}" status
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Turned off in System Settings > General > Login Items"* ]] || false
}

@test "schedule: status, loaded but plist gone → code 1" {
    "${SCHEDULE}" install
    rm -f "${PLIST}"
    run "${SCHEDULE}" status
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is missing"* ]] || false
}
