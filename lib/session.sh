# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — session plumbing
#
# Exits and Ctrl-C, run_step (runs a command with its output in the log),
# output analysis, prerequisites (root, package managers, Xcode, disk,
# power source, lock), sudo policy, platform notes and log rotation.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Exits, interruption and cleanup
#
# Every planned exit goes through finish, which marks it as expected. Any
# other non-zero exit is a failure praetorian didn't plan for (set -e
# stopped it): on_exit explains it as a block instead of letting the
# session die silently. An ERR trap can't do this: bash doesn't run it
# inside functions, where almost all the code is, unless errtrace is on,
# and errtrace would also fire inside command substitutions that are
# allowed to fail.
# ----------------------------------------------------------------------------
CLEAN_EXIT=false

# finish <code>: planned exit.
finish() {
    CLEAN_EXIT=true
    exit "$1"
}

# Ctrl-C: stop the WHOLE session. Before, only the current step died and
# every following step failed right away (code 130).
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "${child}"; done
    kill -TERM "$1" 2>/dev/null || true
}

on_interrupt() {
    # The command runs in the background (see run_step): it ignores
    # SIGINT, so it must be killed explicitly with all its children.
    [[ -n "${STEP_PID}" ]] && kill_tree "${STEP_PID}"
    loud ""
    loud "${C_YELLOW}!${C_RESET} Interrupted (Ctrl-C) — session stopped, the following steps were not run."
    if [[ -n "${CURRENT_STEP}" ]]; then
        loud "  Step cut short: ${CURRENT_STEP}"
        loud "  Safe: brew and MacPorts resume an interrupted install on the next try,"
        loud "  and praetorian repairs a cask cut off mid-upgrade on its next run."
    fi
    loud "Session log: ${C_DIM}${LOG_FILE}${C_RESET}"
    finish 130
}
trap on_interrupt INT TERM

STEP_TMP=""
SESSION_STAMP="" # stamp file: its mtime = session start
# Unplanned exit: say where it happened (function, file, command), then
# clean up as for any exit.
# shellcheck disable=SC2329  # called by trap
on_exit() {
    local rc=$? cmd=${BASH_COMMAND}
    if ((rc != 0)) && [[ "${CLEAN_EXIT}" != true ]]; then
        local where="${FUNCNAME[1]:-top level} (${BASH_SOURCE[1]##*/})"
        [[ -n "${BASH_SOURCE[1]:-}" ]] || where="top level (praetorian)"
        block "unexpected error in praetorian" \
            "A command failed where praetorian didn't plan for it: in ${where}, command: ${cmd} (code ${rc})${CURRENT_STEP:+, during: ${CURRENT_STEP}}. This is a praetorian defect, not necessarily a brew or MacPorts one." \
            "The session stopped there to stay safe: the following steps were not run. The cleanup still ran (temporary files, lock, formula unlinked for a build)." \
            "Read the end of the log, then run praetorian again." \
            "If it happens again: praetorian --dry-run shows where it stops; the function and command above locate the defect."
    fi
    [[ -n "${STEP_TMP}" ]] && rm -f "${STEP_TMP}"
    [[ -n "${SESSION_STAMP}" ]] && rm -f "${SESSION_STAMP}"
    # Cask reinstall cut short (see reinstall_cask): put its saved
    # Caskroom entry back.
    [[ -n "${CASK_BACKUP:-}" ]] && { restore_cask_backup || true; }
    # Formula unlinked for a build (see auto_fix): always link it back.
    # "|| true": set -e still applies here, a failed link must not skip
    # the lock removal below.
    [[ -n "${AUTO_RELINK:-}" ]] && { brew link "${AUTO_RELINK}" >/dev/null 2>&1 || true; }
    # Only our own lock: never one another session took over meanwhile.
    if [[ "${LOCK_HELD}" == true && "$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)" == "$$" ]]; then
        rm -rf "${LOCK_DIR}"
    fi
    # Stopped before the summary: notify (unattended), once the lock is
    # released. notify_stopped lives in lib/report.sh, loaded after this
    # file.
    if declare -F notify_stopped >/dev/null; then
        notify_stopped "${rc}" || true
    fi
    return 0
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# Running a step, with its full output in the log
# ----------------------------------------------------------------------------
# run_step "Readable label" cmd arg1 arg2 ...
# Does NOT make the script fail on error: records it and moves on.
run_step() {
    local label=$1
    shift
    log_detail "=== STEP: ${label} ==="
    log_detail "CMD: $*"

    if [[ "${DRY_RUN}" == true ]]; then
        info "${label} ${C_DIM}(dry-run, skipped)${C_RESET}"
        return 0
    fi

    # The command runs in the background, its output going to a temp file
    # (analyzed afterwards). While it runs:
    #   - the output is copied to the log as it comes (tail -f works);
    #   - a progress line shows the elapsed time and the current action
    #     (a build can run for an hour without printing anything).
    #     It only appears once the command has written something: before
    #     that, sudo may be waiting for a password in the terminal.
    # stdin stays the terminal (fd 3): sudo can ask for the password.
    [[ -n "${STEP_TMP}" ]] || STEP_TMP=$(mktemp -t praetorian)
    : >"${STEP_TMP}"
    CURRENT_STEP=${label}
    local rc=0 start offset=0 size elapsed current
    start=$(date +%s)
    set +e
    "$@" <&3 >"${STEP_TMP}" 2>&1 &
    STEP_PID=$!
    while kill -0 "${STEP_PID}" 2>/dev/null; do
        sleep 2
        size=$(wc -c <"${STEP_TMP}" | tr -d ' ')
        if ((size > offset)); then
            tail -c +$((offset + 1)) "${STEP_TMP}" | head -c $((size - offset)) >>"${LOG_FILE}"
            offset=${size}
        fi
        if [[ -t 1 && "${QUIET}" != true && "${SHOW_PROGRESS}" == true ]] && ((size > 0)); then
            elapsed=$(($(date +%s) - start))
            current=$(grep -E '^(==>|🍺|--->)' "${STEP_TMP}" | tail -n 1 | strip_ansi | cut -c1-70)
            printf '\r\033[K  %s%02d:%02d%s %s %s' "${C_DIM}" $((elapsed / 60)) $((elapsed % 60)) \
                "${C_RESET}" "${label}" "${C_DIM}${current:+— ${current}}${C_RESET}"
        fi
    done
    wait "${STEP_PID}"
    rc=$?
    STEP_PID=""
    set -e
    [[ -t 1 && "${QUIET}" != true && "${SHOW_PROGRESS}" == true ]] && printf '\r\033[K'
    tail -c +$((offset + 1)) "${STEP_TMP}" >>"${LOG_FILE}" 2>/dev/null || true
    STEP_OUT=$(cat "${STEP_TMP}" 2>/dev/null || true)

    # 130 = the command got SIGINT: stop everything, no cascade of steps.
    ((rc == 130)) && on_interrupt
    CURRENT_STEP=""

    collect_problems "${STEP_OUT}"

    if [[ ${rc} -eq 0 ]]; then
        ok "${label}"
        STEP_OK=$((STEP_OK + 1))
    else
        err "${label} ${C_DIM}(code ${rc})${C_RESET}"
        STEP_FAIL=$((STEP_FAIL + 1))
        FAILED_STEPS+=("${label}")
    fi
    log_detail "RC: ${rc}"
    return 0
}

# ----------------------------------------------------------------------------
# Output analysis: error extraction + learning
# ----------------------------------------------------------------------------
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# Number of non-empty lines.
count_lines() { sed '/^[[:space:]]*$/d' <<<"$1" | wc -l | tr -d ' '; }

add_problem() {
    local p=$1 existing
    for existing in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do
        [[ "${existing}" == "${p}" ]] && return 0
    done
    PROBLEMS+=("${p}")
}

# collect_problems "<brew or port output>"
collect_problems() {
    local out line name type cause detail
    out=$(strip_ansi <<<"$1")

    # 1. "Error:" lines (first line only, truncated).
    while IFS= read -r line; do
        add_problem "${line:0:160}"
    done < <(grep -E '^Error: ' <<<"${out}" || true)

    # 2. Failed builds (no "Error:" line, only
    #    "Last 15 lines from ~/Library/Logs/Homebrew/<name>/...").
    LAST_BUILD_FAILS=""
    while IFS= read -r name; do
        # Quarantine is decided by upgrade_formula, after the automatic
        # fixes have been tried.
        add_problem "Build of ${name} failed — brew logs saved next to the session log."
        LAST_BUILD_FAILS+="${LAST_BUILD_FAILS:+ }${name}"
    done < <(sed -nE 's#^Last [0-9]+ lines from .*/Logs/Homebrew/([^/]+)/.*#\1#p' <<<"${out}" | sort -u)

    # 3. Network drops (often caused by the Mac sleeping at night).
    if grep -qE 'nodename nor servname|Could not resolve host|Unable to connect to a repository|Connection timed out' <<<"${out}"; then
        add_problem "Network: download(s) failed (DNS/connection) — running again is usually enough."
    fi

    # 4. Structural causes → quarantine. A sudo refused for lack of
    #    authentication isn't one (deferred, see upgrade_cask).
    is_sudo_auth_failure "${out}" && return 0
    while IFS=$'\t' read -r name type cause detail; do
        [[ -n "${name}" ]] && quarantine_add "${name}" "${type}" "${cause}" "${detail}"
    done < <(awk '
        /: A full installation of Xcode\.app is required/ {
            split($0, a, ":"); culprit = a[1]; next
        }
        /^Error: [^ :]+: An unsatisfied requirement failed this build/ {
            n = $2; sub(/:$/, "", n)
            d = (culprit != "" && culprit != n) ? "full Xcode required (via " culprit ")" : "full Xcode required"
            print n "\tformula\txcode\t" d
        }
        /^Error: [^ :]+: Failure while executing; .*installer -pkg/ {
            n = $2; sub(/:$/, "", n)
            print n "\tcask\tpkg\tcask pkg script failed"
        }
    ' <<<"${out}")
}

# ----------------------------------------------------------------------------
# Xcode readiness
# ----------------------------------------------------------------------------
has_full_xcode() {
    [[ -d /Applications/Xcode.app ]] || [[ "$(xcode-select -p 2>/dev/null)" == *Xcode*.app* ]]
}

# Xcode installed but not ready (not selected, license not accepted, first
# launch not done): builds fail or hang waiting. Stop the session and say
# what to run.
check_xcode_ready() {
    has_full_xcode || return 0
    local selected problem=""
    selected=$(xcode-select -p 2>/dev/null || true)
    if [[ "${selected}" != *Xcode*.app* ]]; then
        problem="Xcode is installed but not selected (xcode-select -p = ${selected:-nothing})."
    elif ! xcodebuild -license check >/dev/null 2>&1; then
        problem="The Xcode license hasn't been accepted."
    elif ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        problem="Xcode's first launch isn't finished."
    fi
    [[ -z "${problem}" ]] && return 0

    log_detail "XCODE not ready: ${problem}"
    block "Xcode isn't ready" \
        "${problem} Homebrew and MacPorts would build with a half-configured Xcode: failures, or builds hanging forever (seen before: cmake at 0% CPU)." \
        "Nothing was done this session." \
        "Run these once (Touch ID / password requested), then run praetorian again:" \
        "  sudo xcode-select -s /Applications/Xcode.app" \
        "  sudo xcodebuild -license accept" \
        "  sudo xcodebuild -runFirstLaunch"
    finish 1
}

# ----------------------------------------------------------------------------
# Step counters shared by every part
# ----------------------------------------------------------------------------
# step_failed_since <counter before>: true if run_step counted a failure.
step_failed_since() { ((STEP_FAIL > $1)); }

# Cancels the last counted failure (it's about to be retried).
forget_last_failure() {
    STEP_FAIL=$((STEP_FAIL - 1))
    unset "FAILED_STEPS[$((${#FAILED_STEPS[@]} - 1))]"
}

# forget_failure "<label>": cancels the failure of THAT step (its last
# occurrence), even if other steps failed after it (auto-fix steps run
# between an upgrade and its retry).
forget_failure() {
    local label=$1 i found=-1
    local -a kept=()
    for ((i = 0; i < ${#FAILED_STEPS[@]}; i++)); do
        [[ "${FAILED_STEPS[i]}" == "${label}" ]] && found=${i}
    done
    ((found >= 0)) || return 0
    for ((i = 0; i < ${#FAILED_STEPS[@]}; i++)); do
        ((i == found)) || kept+=("${FAILED_STEPS[i]}")
    done
    FAILED_STEPS=("${kept[@]+"${kept[@]}"}")
    STEP_FAIL=$((STEP_FAIL - 1))
}

# ----------------------------------------------------------------------------
# sudo — security policy (CIS Apple macOS Benchmark, PCI DSS v4 8.6.2):
#   - no password stored (no file, no Keychain item, no variable);
#   - no sudo "keepalive" in the background: a CIS-hardened Mac enforces
#     timestamp_timeout=0, every sudo call authenticates;
#   - strong, secret-free authentication with Touch ID (pam_tid in
#     /etc/pam.d/sudo_local, see ./praetorian-sudo-setup);
#   - when unattended, sudo fails right away (SUDO_ASKPASS=/usr/bin/false,
#     which Homebrew passes to sudo -A; "sudo -n" for MacPorts): whatever
#     needs sudo is deferred to the next interactive session, never stuck.
# ----------------------------------------------------------------------------
touch_id_sudo_enabled() {
    grep -qsE '^[[:space:]]*auth[[:space:]].*pam_tid\.so' /etc/pam.d/sudo_local
}

sudo_notes() {
    if [[ "${UNATTENDED}" == true ]]; then
        info "Unattended: apps that need sudo will be deferred."
    elif touch_id_sudo_enabled; then
        info "Some apps will ask for Touch ID (sudo)."
    else
        info "Some apps will ask for the administrator password."
        info "${C_DIM}Tip: \"sudo ${PRAETORIAN_ROOT}/praetorian-sudo-setup\" turns on Touch ID for sudo.${C_RESET}"
    fi
}

# Output of a command whose sudo failed for lack of authentication.
is_sudo_auth_failure() {
    grep -qE 'sudo: (a password is required|no password was provided|a terminal is required|[0-9]+ incorrect password attempt)' <<<"$1"
}

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
# Homebrew and/or MacPorts. Under launchd the PATH is minimal: find brew
# at its standard locations rather than silently skipping all of Homebrew.
detect_managers() {
    local candidate
    if ! command -v brew >/dev/null 2>&1; then
        for candidate in /usr/local/bin/brew /opt/homebrew/bin/brew; do
            if [[ -x "${candidate}" ]]; then
                PATH="$(dirname "${candidate}"):${PATH}"
                export PATH
                log_detail "brew not in the PATH, found: ${candidate} (added to the PATH)"
                break
            fi
        done
    fi
    command -v brew >/dev/null 2>&1 && HAS_BREW=true
    [[ -x "${PORT_BIN}" ]] && HAS_PORT=true
    return 0
}

check_prerequisites() {
    # Never run Homebrew as root.
    if [[ "${EUID}" -eq 0 ]]; then
        block "praetorian was started as root" \
            "Homebrew refuses to run as root, and praetorian asks for sudo itself, one command at a time, only when MacPorts or a cask needs it." \
            "Nothing was done." \
            "Run it again without sudo: ${PRAETORIAN_ROOT}/praetorian"
        finish 1
    fi

    detect_managers
    if [[ "${HAS_BREW}" != true && "${HAS_PORT}" != true ]]; then
        local macports_hint="MacPorts: https://www.macports.org/install.php"
        [[ "$(uname -m)" == x86_64 ]] &&
            macports_hint="MacPorts (recommended on an Intel Mac: precompiled packages): https://www.macports.org/install.php"
        block "no package manager found" \
            "Neither brew (PATH, /usr/local/bin, /opt/homebrew/bin) nor MacPorts (${PORT_BIN})." \
            "Nothing was done." \
            "${macports_hint}" \
            "Homebrew: https://brew.sh"
        finish 1
    fi
    if [[ "${HAS_PORT}" != true && -d "${PORT_PREFIX}" ]]; then
        warn "${PORT_PREFIX} exists but ${PORT_BIN} is missing: incomplete MacPorts install?"
        say "    ${C_DIM}MacPorts part skipped. Reinstall the package: https://www.macports.org/install.php${C_RESET}"
    fi

    mkdir -p "${LOG_DIR}"
    # The logs hold the full brew/port output (paths, package list): for
    # this user only. Not a global umask: brew and port would inherit it.
    chmod 700 "${LOG_DIR}"
    SESSION_STAMP=$(mktemp -t praetorian_stamp)
    log_detail "praetorian ${PRAETORIAN_VERSION} — session start (mode ${MODE})"
    log_detail "brew: $(command -v brew 2>/dev/null || echo absent) — MacPorts: $([[ "${HAS_PORT}" == true ]] && echo "${PORT_BIN}" || echo absent)"
    log_detail "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    log_detail "arch: $(uname -m) — full Xcode: $(has_full_xcode && echo yes || echo no)"
}

# Disk space: a build (node, openjdk…) or a MacPorts upgrade can use
# several GB of temporary space.
check_disk_space() {
    local avail_kb gb min=${MIN_FREE_GB}
    # MIN_FREE_GB comes from the environment (PRAETORIAN_MIN_FREE_GB): a
    # non-number inside (( )) would be evaluated as an expression, which
    # can run commands ("a[$(cmd)]"). Digits only, read as decimal.
    if [[ "${min}" =~ ^[0-9]+$ ]]; then
        min=$((10#${min}))
    else
        warn "PRAETORIAN_MIN_FREE_GB is not a whole number of GB: default 5 GB used."
        min=5
    fi
    avail_kb=$(df -Pk "${HOME}" 2>/dev/null | awk 'NR == 2 {print $4}')
    if [[ ! "${avail_kb}" =~ ^[0-9]+$ ]]; then
        warn "Free disk space unknown (unreadable df output): check skipped."
        return 0
    fi
    gb=$((avail_kb / 1048576))
    log_detail "Free space: ${gb} GB"
    if ((gb < min)); then
        if [[ "${DRY_RUN}" == true ]]; then
            warn "Only ${gb} GB free: a real session would be blocked (minimum ${min} GB)."
            return 0
        fi
        block "not enough disk space (${gb} GB free, minimum ${min} GB)" \
            "A build or a MacPorts upgrade uses several GB of temporary space. A disk filling up mid-install leaves half-installed packages." \
            "Nothing was done." \
            "Free some space, for example:" \
            "  brew cleanup --prune=all     (Homebrew caches)" \
            "  sudo port reclaim            (MacPorts: inactive versions, sources)" \
            "  empty the Trash and ~/Library/Caches" \
            "then run praetorian again."
        finish 1
    elif ((gb < WARN_FREE_GB)); then
        warn "Only ${gb} GB free: a big build could fill the disk."
    fi
}

# --ac-power-only (set by praetorian-schedule): on battery, a session that
# compiles for hours would drain it, and the Mac could sleep or shut down
# mid-build (half-installed packages). Unknown power source (no pmset,
# unexpected output): not blocking, the check is skipped with a warning.
check_ac_power() {
    [[ "${AC_POWER_ONLY}" == true ]] || return 0
    local source
    if ! command -v pmset >/dev/null 2>&1; then
        warn "pmset not found: power source unknown, --ac-power-only check skipped."
        return 0
    fi
    source=$(pmset -g batt 2>/dev/null | sed -nE "s/^Now drawing from '([^']+)'.*/\1/p" | head -n 1 || true)
    log_detail "Power source: ${source:-unknown}"
    case "${source}" in
        "AC Power") return 0 ;;
        "Battery Power" | "UPS Power") ;;
        *)
            warn "Power source unknown (pmset -g batt): --ac-power-only check skipped."
            return 0
            ;;
    esac
    if [[ "${DRY_RUN}" == true ]]; then
        warn "On ${source}: a real session with --ac-power-only would be blocked."
        return 0
    fi
    block "the Mac is on ${source} (--ac-power-only)" \
        "Homebrew on an Intel Mac compiles from source: a session can take hours. On ${source} it would drain it, and the Mac could sleep or shut down in the middle of a build, leaving half-installed packages." \
        "Nothing was done this session." \
        "Plug the Mac in: the next scheduled run goes ahead." \
        "Or run it now from a terminal, plugged in: ${PRAETORIAN_ROOT}/praetorian"
    finish 1
}

# One session at a time. The lock is a directory (mkdir is atomic)
# holding the PID of the session that owns it.
#
# Races handled:
#   - the PID is written to a temporary file then renamed (atomic): a
#     reader never sees a half-written PID;
#   - a lock with no PID yet is a session that is just starting, unless
#     the directory is older than a minute (session killed between mkdir
#     and the PID write);
#   - a stale lock is renamed away (atomic) before it's deleted: of two
#     sessions taking it over at once, only one rename succeeds. The
#     renamed lock is checked again: if it isn't the one judged stale
#     (another session took it over first), it's put back.
LOCK_STALE_AGE_MIN=1

# lock_pid <dir>: the PID recorded in a lock directory, empty if none.
lock_pid() {
    cat "$1/pid" 2>/dev/null || true
}

# lock_is_recent <dir>: modified less than LOCK_STALE_AGE_MIN minutes ago.
lock_is_recent() {
    [[ -n "$(find "$1" -maxdepth 0 -mmin "-${LOCK_STALE_AGE_MIN}" 2>/dev/null)" ]]
}

lock_busy() {
    local pid=$1
    block "another praetorian session is already running (PID ${pid})" \
        "Two sessions in parallel would run brew or port at the same time on the same packages: corrupted installs, overwritten quarantine." \
        "This session did nothing." \
        "Wait for the other session to finish:  ps -p ${pid} -o command=" \
        "or stop it cleanly:                    kill ${pid}" \
        "If this PID is NOT praetorian (PID reused): rm -rf ${LOCK_DIR}"
    finish 1
}

lock_lost_race() {
    block "couldn't take the session lock" \
        "$1" \
        "This session did nothing." \
        "Try again in a moment."
    finish 1
}

acquire_lock() {
    mkdir -p "${PRAETORIAN_HOME}"
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        local pid stale="${LOCK_DIR}.stale.$$"
        pid=$(lock_pid "${LOCK_DIR}")
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            lock_busy "${pid}"
        fi
        if [[ -z "${pid}" ]] && lock_is_recent "${LOCK_DIR}"; then
            lock_lost_race "${LOCK_DIR} has no PID yet: another session has probably just started."
        fi
        rm -rf "${stale}"
        if ! mv "${LOCK_DIR}" "${stale}" 2>/dev/null; then
            lock_lost_race "${LOCK_DIR} was taken over in the meantime: another session has probably just started."
        fi
        # Not the lock judged stale: another session replaced it between
        # the check and the rename. Put it back untouched.
        if [[ "$(lock_pid "${stale}")" != "${pid}" ]] ||
            { [[ -z "${pid}" ]] && lock_is_recent "${stale}"; }; then
            [[ -e "${LOCK_DIR}" ]] || mv "${stale}" "${LOCK_DIR}" 2>/dev/null || true
            lock_lost_race "${LOCK_DIR} was taken over in the meantime: another session has probably just started."
        fi
        rm -rf "${stale}"
        warn "Lock left by a session that ended abruptly (PID ${pid:-unknown}, no longer running): taken over."
        if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
            lock_lost_race "${LOCK_DIR} was created again in the meantime: another session has probably just started."
        fi
    fi
    printf '%s\n' "$$" >"${LOCK_DIR}/pid.$$"
    mv -f "${LOCK_DIR}/pid.$$" "${LOCK_DIR}/pid"
    LOCK_HELD=true
}

# ----------------------------------------------------------------------------
# Platform specifics, reported at the start of the session.
# ----------------------------------------------------------------------------
platform_notes() {
    if [[ "$(uname -m)" == "x86_64" && "${HAS_BREW}" == true ]]; then
        warn "Intel Mac: Homebrew no longer ships bottles (tier 3 since Sept. 2026)."
        info "${C_DIM}Formulae are built from source: this can take hours.${C_RESET}"
        if ! has_full_xcode; then
            info "${C_DIM}Without full Xcode, some builds are impossible (quarantined).${C_RESET}"
        fi
        if [[ "${HAS_PORT}" == true ]]; then
            info "${C_DIM}MacPorts ships precompiled packages for this Mac: \"praetorian --migration-report\" lists what can move there.${C_RESET}"
        else
            info "${C_DIM}Long-term fix: MacPorts (precompiled packages for this Mac). \"praetorian --migration-report\" explains how.${C_RESET}"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Log rotation: only the N most recent are kept.
# ----------------------------------------------------------------------------
rotate_logs() {
    local pattern
    for pattern in 'praetorian_*[0-9].log' 'praetorian_*_buildlogs.tar.gz' 'praetorian_*_portlogs.tar.gz'; do
        rotate_pattern "${pattern}"
    done
}

rotate_pattern() {
    local pattern=$1 count
    count=$(find "${LOG_DIR}" -maxdepth 1 -name "${pattern}" -type f 2>/dev/null | wc -l | tr -d ' ')
    if ((count > LOG_RETENTION)) && [[ "${DRY_RUN}" == true ]]; then
        # Dry-run changes no state: only say what a real run would remove.
        info "Dry-run: $((count - LOG_RETENTION)) old log file(s) would be removed (only the last ${LOG_RETENTION} are kept)."
        log_detail "ROTATION (dry-run): ${pattern}: ${count} file(s), $((count - LOG_RETENTION)) would be removed"
    elif ((count > LOG_RETENTION)); then
        # Sorted by date, the oldest beyond the threshold are deleted.
        find "${LOG_DIR}" -maxdepth 1 -name "${pattern}" -type f -print0 2>/dev/null |
            xargs -0 ls -t 2>/dev/null |
            tail -n +$((LOG_RETENTION + 1)) |
            while IFS= read -r old; do
                rm -f "${old}" && log_detail "Log removed: ${old}"
            done
    fi
}
