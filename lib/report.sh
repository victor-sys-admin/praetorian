# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — end-of-session reports
#
# brew doctor, unused apps, how to unblock quarantined packages, the
# summary and the macOS notification (also sent by on_exit when a session
# stops before its summary).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Diagnostics: brew doctor.
# brew doctor returns non-zero for any warning, even a harmless one.
# Everything is logged and reported, without counting it as a failure.
# ----------------------------------------------------------------------------
diagnostics() {
    [[ "${HAS_BREW}" == true ]] || return 0
    section "Diagnostics (brew doctor)"

    if [[ "${DRY_RUN}" == true ]]; then
        info "brew doctor ${C_DIM}(dry-run, skipped)${C_RESET}"
        return 0
    fi

    local doctor_out rc=0
    set +e
    doctor_out=$(brew doctor 2>&1)
    rc=$?
    set -e

    printf '%s\n' "${doctor_out}" >>"${LOG_FILE}"

    if [[ ${rc} -eq 0 ]]; then
        ok "System healthy — no warning."
    else
        # Counts the "Warning:" lines to give an idea of the volume.
        local nwarn
        nwarn=$(grep -c '^Warning:' <<<"${doctor_out}" || true)
        warn "brew doctor reports ${nwarn} warning(s). Details in the log."
        info "${C_DIM}doctor warnings are often harmless (see the log).${C_RESET}"
    fi
}

# ----------------------------------------------------------------------------
# Apps not used in more than 6 months.
# Relies on Spotlight metadata (kMDItemLastUsedDate).
# ----------------------------------------------------------------------------
find_unused_apps() {
    section "Unused apps (> 6 months)"

    if [[ ! -d "${APP_DIR}" ]]; then
        warn "Folder ${APP_DIR} not found, step skipped."
        return 0
    fi

    local now threshold
    now=$(date +%s)
    threshold=$((now - UNUSED_THRESHOLD_DAYS * 86400))

    local -a unused=()
    local -a untracked=()
    local app name last_used last_epoch

    # Top-level .app bundles only.
    while IFS= read -r -d '' app; do
        name=$(basename "${app}" .app)

        # Last-used date from Spotlight.
        last_used=$(mdls -name kMDItemLastUsedDate -raw "${app}" 2>/dev/null || echo "")

        if [[ -z "${last_used}" || "${last_used}" == "(null)" ]]; then
            untracked+=("${name}")
            log_detail "APP without a usage date: ${name}"
            continue
        fi

        # Spotlight date (e.g. 2025-01-15 10:30:00 +0000) to epoch.
        last_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "${last_used}" +%s 2>/dev/null || echo "")
        if [[ -z "${last_epoch}" ]]; then
            log_detail "APP unreadable date (${last_used}): ${name}"
            continue
        fi

        if ((last_epoch < threshold)); then
            local days_ago=$(((now - last_epoch) / 86400))
            unused+=("${name} (${days_ago} d)")
            log_detail "APP unused: ${name} — last used ${last_used} (${days_ago} d)"
        fi
    done < <(find "${APP_DIR}" -maxdepth 1 -name '*.app' -print0 2>/dev/null)

    if ((${#unused[@]} == 0)); then
        ok "No app unused for more than 6 months."
    else
        warn "${#unused[@]} app(s) not used for more than 6 months:"
        local item
        for item in "${unused[@]}"; do
            say "    ${C_DIM}-${C_RESET} ${item}"
        done
        info "${C_DIM}Suggestion: consider uninstalling them to free some space.${C_RESET}"
    fi

    if ((${#untracked[@]} > 0)); then
        log_detail "${#untracked[@]} app(s) without a Spotlight usage date (not listed on screen)."
    fi
}

# ----------------------------------------------------------------------------
# Concrete advice depending on what is quarantined.
# ----------------------------------------------------------------------------
# quarantine_list <cause> <type>: space-separated names of the quarantine
# entries with that cause and type ("" matches any), no trailing space.
quarantine_list() {
    awk -F'\t' -v c="$1" -v t="$2" '(c == "" || $4 == c) && (t == "" || $2 == t) {
        s = s (s == "" ? "" : " ") $1 } END { printf "%s", s }' "${QUARANTINE_FILE}"
}

remediation_hints() {
    [[ -s "${QUARANTINE_FILE}" ]] || return 0
    local xcode_pkgs pkg_casks build_pkgs port_pkgs
    xcode_pkgs=$(quarantine_list xcode "")
    pkg_casks=$(quarantine_list pkg "")
    build_pkgs=$(quarantine_list build formula)
    port_pkgs=$(quarantine_list "" port)
    [[ -n "${xcode_pkgs}${pkg_casks}${build_pkgs}${port_pkgs}" ]] || return 0

    info "To unblock:"
    if [[ -n "${xcode_pkgs}" ]]; then
        say "    ${C_DIM}-${C_RESET} ${xcode_pkgs}: install Xcode (App Store), then"
        say "      ${C_DIM}sudo xcode-select -s /Applications/Xcode.app${C_RESET} — or uninstall them if you no longer use them."
    fi
    if [[ -n "${pkg_casks}" ]]; then
        say "    ${C_DIM}-${C_RESET} ${pkg_casks}: run ${C_DIM}brew upgrade --cask <name>${C_RESET} by hand to see the error,"
        say "      otherwise ${C_DIM}brew uninstall --cask --force <name> && brew install --cask <name>${C_RESET}."
    fi
    if [[ -n "${build_pkgs}" ]]; then
        say "    ${C_DIM}-${C_RESET} ${build_pkgs}: build failing despite the automatic fixes;"
        say "      see the *_buildlogs.tar.gz archive. Automatic retry in ${QUARANTINE_BUILD_DAYS} d, the installed version still works."
        [[ "${HAS_PORT}" == true ]] &&
            say "      Long-term fix: ${C_DIM}praetorian --migrate <formula>${C_RESET} (precompiled MacPorts package)."
    fi
    if [[ -n "${port_pkgs}" ]]; then
        say "    ${C_DIM}-${C_RESET} ${port_pkgs} (MacPorts): ${C_DIM}port log <name>${C_RESET} or the *_portlogs.tar.gz archive;"
        say "      ${C_DIM}sudo port clean <name>${C_RESET} then try again. The old version stays active and usable."
        say "      Persistent bug: MacPorts still supports this Mac, report it at https://trac.macports.org"
    fi
    say "    ${C_DIM}-${C_RESET} then ${C_DIM}praetorian --retry-quarantined${C_RESET} (or empty ${QUARANTINE_FILE})."
}

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------
summary() {
    section "Summary"
    say "Steps passed: ${C_GREEN}${STEP_OK}${C_RESET}   failed: ${C_RED}${STEP_FAIL}${C_RESET}   blocked: ${C_RED}${#BLOCKERS[@]}${C_RESET}"

    if ((STEP_FAIL > 0)); then
        warn "Failed steps:"
        local s
        for s in "${FAILED_STEPS[@]}"; do
            say "    ${C_DIM}-${C_RESET} ${s}"
        done
    fi

    if ((${#PROBLEMS[@]} > 0)); then
        warn "Problems found in the brew / port output:"
        local p i=0
        for p in "${PROBLEMS[@]}"; do
            ((i++ < 12)) || {
                say "    ${C_DIM}… $((${#PROBLEMS[@]} - 12)) more, see the log${C_RESET}"
                break
            }
            say "    ${C_DIM}-${C_RESET} ${p}"
        done
    fi

    if ((${#NEWLY_QUARANTINED[@]} > 0)); then
        warn "Quarantined (skipped ${QUARANTINE_BUILD_DAYS} d for a build failure, otherwise ${QUARANTINE_DAYS} d):"
        local q
        for q in "${NEWLY_QUARANTINED[@]}"; do
            say "    ${C_DIM}-${C_RESET} ${q}"
        done
    fi

    if ((${#DEFERRED[@]} > 0)); then
        warn "Deferred (needs sudo, nothing was changed):"
        local d
        for d in "${DEFERRED[@]}"; do
            say "    ${C_DIM}-${C_RESET} ${d}"
        done
        say "    ${C_DIM}→ run praetorian again from a terminal.${C_RESET}"
    fi

    # Blocks are shown even with --quiet: they need an action.
    if ((${#BLOCKERS[@]} > 0)); then
        loud "${C_RED}${C_BOLD}${#BLOCKERS[@]} block(s) — explanation and steps above (and in the log):${C_RESET}"
        local b
        for b in "${BLOCKERS[@]}"; do
            loud "    - ${b}"
        done
    fi

    [[ "${MODE}" == maintain ]] && remediation_hints

    say "Session log: ${C_DIM}${LOG_FILE}${C_RESET}"

    local took
    took=$(format_duration $(($(date +%s) - SESSION_START)))
    if ((STEP_FAIL > 0 || ${#BLOCKERS[@]} > 0)); then
        err "Finished with errors."
        notify "${STEP_FAIL} failure(s), ${#BLOCKERS[@]} block(s)$( ((${#DEFERRED[@]} > 0)) && echo ", ${#DEFERRED[@]} deferred") — see the log." \
            "Finished with errors (${took})" failure
        return 2
    fi
    ok "Maintenance completed successfully."
    if ((${#DEFERRED[@]} > 0)); then
        notify "Done. To do from a terminal (sudo): ${DEFERRED[*]}" "Done in ${took}, sudo needed" success
    else
        notify "Maintenance completed successfully." "Done in ${took}" success
    fi
    return 0
}

# ----------------------------------------------------------------------------
# macOS notification at the end of the session
#
# When (--notify / --no-notify override it):
#   - unattended: always, nobody is watching the terminal;
#   - from a terminal: only when the session took at least NOTIFY_AFTER
#     seconds (you went to do something else); a short one doesn't need it;
#   - never for --dry-run or --migration-report.
# Sound only when someone is at the Mac: an unattended night run stays
# silent (the notification waits in the Notification Center).
# ----------------------------------------------------------------------------
NOTIFIED=false

# format_duration <seconds>: "42 s", "12 min", "1 h 05 min".
format_duration() {
    local s=$1
    if ((s < 60)); then
        echo "${s} s"
    elif ((s < 3600)); then
        echo "$((s / 60)) min"
    else
        printf '%d h %02d min\n' $((s / 3600)) $((s % 3600 / 60))
    fi
}

notify_wanted() {
    case "${NOTIFY}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    # Read-only modes (the report, --status, --doctor, --sbom) answer on
    # the screen: their exit code isn't an event to be told about later.
    case "${MODE}" in
        report | status | doctor | sbom) return 1 ;;
    esac
    [[ "${DRY_RUN}" != true ]] || return 1
    [[ "${UNATTENDED}" != true ]] || return 0
    # PRAETORIAN_NOTIFY_AFTER comes from the environment: digits only,
    # read as decimal, before it goes near (( )) (see check_disk_space).
    local after=${NOTIFY_AFTER}
    if [[ "${after}" =~ ^[0-9]+$ ]]; then
        after=$((10#${after}))
    else
        log_if_started "PRAETORIAN_NOTIFY_AFTER is not a whole number of seconds: default 300 used."
        after=300
    fi
    (($(date +%s) - SESSION_START >= after))
}

# log_detail, but only once the session has its log directory: a session
# stopped by check_home (unusable PRAETORIAN_HOME) must not create one.
log_if_started() {
    [[ ! -d "${LOG_DIR}" ]] || log_detail "$@"
}

# The alert sound chosen in System Settings > Sound (its name, e.g.
# "Tink"), so praetorian sounds like the rest of the Mac. Glass when the
# setting can't be read. A name macOS doesn't know plays its default
# alert sound, so a stray value is harmless.
alert_sound() {
    local path name
    path=$(defaults read -g com.apple.sound.beep.sound 2>/dev/null || true)
    name=${path##*/}
    name=${name%.*}
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] || name=Glass
    echo "${name}"
}

# notify <message> <subtitle> <success|failure>
notify() {
    notify_wanted || return 0
    NOTIFIED=true
    local -a sound=()
    [[ "${UNATTENDED}" == true ]] || sound=("$(alert_sound)")
    log_if_started "NOTIFICATION: $2 — $1"
    # The texts go in as arguments, never inside the AppleScript source:
    # no quoting to get right, no code injection. Bounded: a stuck
    # osascript must not keep the session (and its lock) alive.
    run_bounded 15 osascript -e 'on run argv' \
        -e 'if (count of argv) > 2 then' \
        -e 'display notification (item 1 of argv) with title "praetorian" subtitle (item 2 of argv) sound name (item 3 of argv)' \
        -e 'else' \
        -e 'display notification (item 1 of argv) with title "praetorian" subtitle (item 2 of argv)' \
        -e 'end if' \
        -e 'end run' "$1" "$2" "${sound[@]+"${sound[@]}"}"
}

# Session stopped before its summary (block + finish 1, unplanned error):
# called by on_exit, so a night run that couldn't even start doesn't go
# unnoticed. Ctrl-C (130) is left out: whoever pressed it is there.
notify_stopped() {
    local rc=$1
    ((rc != 0 && rc != 130)) || return 0
    [[ "${NOTIFIED}" != true ]] || return 0
    if ((${#BLOCKERS[@]} > 0)); then
        notify "Blocked: ${BLOCKERS[${#BLOCKERS[@]} - 1]}. Nothing more was done — see the log." "Stopped" failure
    else
        notify "Stopped with code ${rc} — see the log." "Stopped" failure
    fi
}

# run_bounded <seconds> cmd…: runs the command, output discarded, and
# kills it if it's still running after <seconds>. Always returns 0.
run_bounded() {
    local limit=$1 pid i
    shift
    "$@" >/dev/null 2>&1 &
    pid=$!
    for ((i = 0; i < limit * 5; i++)); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.2
    done
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    return 0
}
