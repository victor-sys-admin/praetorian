# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — status (--status)
#
# Read-only summary built from the real state (brew, port, migrated.tsv,
# logs): what is migrated, what is left and why, the last sessions.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# --status
#
# Every section is checked against what brew and port answer now, not
# against the logs: on 2026-10-17 a summary built from the logs alone
# claimed formulae were gone that were still installed. The logs only
# feed the last section (the sessions themselves).
#
# Read-only: no sudo, nothing installed or removed, no lock. The slow
# "port echo all" (several seconds) runs at most once, and only when some
# formula is left to compare with MacPorts.
# ----------------------------------------------------------------------------
readonly STATUS_SESSIONS=10 # sessions listed
readonly STATUS_NAMES=15    # names shown on screen per list (all in the log)

# The state, read once by status_run and shared by the sections (one name
# per line, tap prefix removed from formula names).
ST_FORMULAE=""    # every installed formula
ST_ON_REQUEST=""  # formulae installed on request
ST_LEAVES=""      # brew leaves
ST_CASKS=""       # casks
ST_ACTIVE=""      # active ports
ST_REQUESTED=""   # requested ports
ST_PORT_LEAVES="" # ports nothing needs any more (port echo leaves)
ST_PORT_OK=false  # MacPorts answered

status_run() {
    section "Status (read-only)"
    status_read_state
    status_migrated
    status_homebrew
    status_leftovers
    status_counts
    status_sessions
    return 0
}

# Only the names: drops "tap/" and anything after the first blank.
status_names() { awk 'NF { n = $1; sub(/.*\//, "", n); print n }' | sort -u; }

status_read_state() {
    if [[ "${HAS_BREW}" == true ]]; then
        ST_FORMULAE=$(brew list --formula -1 2>>"${LOG_FILE}" | status_names || true)
        ST_ON_REQUEST=$(brew list --formula --installed-on-request -1 2>>"${LOG_FILE}" | status_names || true)
        ST_LEAVES=$(brew leaves 2>>"${LOG_FILE}" | status_names || true)
        ST_CASKS=$(brew list --cask -1 2>>"${LOG_FILE}" | status_names || true)
    fi
    [[ "${HAS_PORT}" == true ]] || return 0
    port_health || return 0
    ST_PORT_OK=true
    port_ro -q echo active || warn "port echo active failed (see the log): active ports unknown."
    ST_ACTIVE=$(status_names <<<"${PORT_LAST_OUT}")
    port_ro -q echo requested || warn "port echo requested failed (see the log): requested ports unknown."
    ST_REQUESTED=$(status_names <<<"${PORT_LAST_OUT}")
    port_ro -q echo leaves || true
    ST_PORT_LEAVES=$(status_names <<<"${PORT_LAST_OUT}")
}

# in_list <name> "<list>": the name is a line of the list.
in_list() { grep -qxF -- "$1" <<<"$2"; }

# say_names "<list>": the names on one folded, dimmed line, at most
# STATUS_NAMES of them (all of them in the log).
say_names() {
    local list n shown line
    list=$(sed '/^$/d' <<<"$1")
    n=$(count_lines "${list}")
    ((n > 0)) || return 0
    log_detail "Names: $(tr '\n' ' ' <<<"${list}")"
    shown=$(head -n "${STATUS_NAMES}" <<<"${list}" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
    ((n > STATUS_NAMES)) && shown+=" … ($((n - STATUS_NAMES)) more, see the log)"
    while IFS= read -r line; do
        say "    ${C_DIM}${line}${C_RESET}"
    done < <(fold -s -w 96 <<<"${shown}" | sed 's/ *$//')
}

# a. Formulae praetorian migrated (migrated.tsv), checked against brew and
#    port: formula really gone, every port active and requested.
status_migrated() {
    say ""
    say "${C_BOLD}Migrated to MacPorts${C_RESET} ${C_DIM}(${MIGRATED_FILE})${C_RESET}"
    if [[ ! -s "${MIGRATED_FILE}" ]]; then
        info "No formula migrated by praetorian yet."
        return 0
    fi
    # Last entry of each formula (migrated again after a reinstall), in
    # the order of the file.
    local entries f p q problems good="" n_good=0
    local -a bad=()
    entries=$(awk -F'\t' 'NF >= 2 && $1 != "" { if (!($1 in last)) order[++n] = $1; last[$1] = $2 }
        END { for (i = 1; i <= n; i++) print order[i] "\t" last[order[i]] }' "${MIGRATED_FILE}")
    while IFS=$'\t' read -r f p; do
        [[ -n "${f}" ]] || continue
        problems=""
        in_list "${f##*/}" "${ST_FORMULAE}" && problems+="; formula still installed in Homebrew"
        if [[ "${ST_PORT_OK}" == true ]]; then
            while IFS= read -r q; do
                [[ -n "${q}" ]] || continue
                if ! in_list "${q}" "${ST_ACTIVE}"; then
                    problems+="; port ${q} not installed or not active"
                elif ! in_list "${q}" "${ST_REQUESTED}"; then
                    problems+="; port ${q} not marked requested"
                fi
            done < <(tr ',' '\n' <<<"${p}")
        fi
        if [[ -n "${problems}" ]]; then
            bad+=("${f} → ${p}: ${problems#; }")
        else
            n_good=$((n_good + 1))
            if [[ "${f##*/}" == "${p}" ]]; then
                good+="${f}"$'\n'
            else
                good+="${f}→${p}"$'\n'
            fi
        fi
    done <<<"${entries}"

    if [[ "${ST_PORT_OK}" != true ]]; then
        warn "MacPorts unavailable: the ports of the migrated formulae weren't checked."
    fi
    if ((n_good > 0)); then
        if [[ "${ST_PORT_OK}" == true ]]; then
            ok "${n_good} formula(e) migrated and consistent (gone from Homebrew, port active and requested):"
        else
            ok "${n_good} formula(e) migrated and gone from Homebrew:"
        fi
        say_names "${good}"
    fi
    if ((${#bad[@]} > 0)); then
        warn "${#bad[@]} migrated formula(e) not in the expected state:"
        local item
        for item in "${bad[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
        say "    ${C_DIM}Formula still installed: brew uninstall --formula <formula> (once the MacPorts command works).${C_RESET}"
        say "    ${C_DIM}Port missing: sudo port install <port>   Not requested: sudo port setrequested <port>${C_RESET}"
        say "    ${C_DIM}(a port left as a dependency goes away with \"port uninstall leaves\").${C_RESET}"
    fi
}

# b. Formulae still installed on request, each with what keeps it there
#    when that is cheap to know.
status_homebrew() {
    say ""
    say "${C_BOLD}Still in Homebrew${C_RESET} ${C_DIM}(formulae installed on request)${C_RESET}"
    if [[ "${HAS_BREW}" != true ]]; then
        info "Homebrew isn't installed."
        return 0
    fi
    if [[ -z "${ST_ON_REQUEST}" ]]; then
        ok "None: Homebrew only keeps casks and dependencies."
        return 0
    fi
    local all="" f reason cands detail known kports
    if [[ "${ST_PORT_OK}" == true ]]; then
        if port_ro -q echo all; then
            all=$(awk 'NF {print $1}' <<<"${PORT_LAST_OUT}" | sort -u)
        else
            warn "port echo all failed (see the log): formulae not compared with MacPorts."
        fi
    fi
    info "$(count_lines "${ST_ON_REQUEST}") formula(e):"
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        detail=""
        [[ -f "${QUARANTINE_FILE}" ]] &&
            detail=$(awk -F'\t' -v n="${f}" '$1 == n && $2 == "formula" { print $5; exit }' "${QUARANTINE_FILE}")
        if [[ -n "${detail}" ]]; then
            reason="quarantined (${detail})"
        elif [[ -z "${all}" ]]; then
            reason="not compared with MacPorts"
        elif known=$(known_port_spec "${f}" "${all}") && kports=${known%%$'\t'*} &&
            [[ -n "${known}" ]] && in_list "${kports%%,*}" "${all}"; then
            # A known trap (as in migration_classify): the table's spec,
            # never the same-name port.
            reason="known trap: praetorian --migrate ${f}=${kports}"
        elif in_list "${f}" "${all}"; then
            reason="same-name port: praetorian --migrate ${f}"
        else
            cands=$(port_candidates "${f}" "${all}")
            if [[ -n "${cands}" ]]; then
                reason="no same-name port; maybe: ${cands}"
            else
                reason="no port found"
            fi
        fi
        say "    ${C_DIM}-${C_RESET} ${f} ${C_DIM}— ${reason}${C_RESET}"
    done <<<"${ST_ON_REQUEST}"
}

# c. Leaves nobody asked for: dependencies left behind (what brew
#    autoremove misses).
status_leftovers() {
    [[ "${HAS_BREW}" == true ]] || return 0
    local left n
    left=$(comm -23 <(sed '/^$/d' <<<"${ST_LEAVES}") <(sed '/^$/d' <<<"${ST_ON_REQUEST}") || true)
    n=$(count_lines "${left}")
    say ""
    say "${C_BOLD}Leftovers${C_RESET} ${C_DIM}(brew leaves not installed on request)${C_RESET}"
    if ((n == 0)); then
        ok "None."
        return 0
    fi
    warn "${n} formula(e) nothing needs and nobody asked for:"
    say_names "${left}"
    info "To review and remove them: praetorian --prune (with --dry-run: list only)."
}

# d. Counts.
status_counts() {
    say ""
    say "${C_BOLD}Counts${C_RESET}"
    if [[ "${HAS_BREW}" == true ]]; then
        local nf nr
        nf=$(count_lines "${ST_FORMULAE}")
        nr=$(count_lines "${ST_ON_REQUEST}")
        info "Homebrew: $(count_lines "${ST_CASKS}") cask(s) (they stay in Homebrew), ${nf} formula(e) (${nr} on request, $((nf - nr)) dependencies)."
    fi
    if [[ "${ST_PORT_OK}" == true ]]; then
        # Not "sudo port uninstall leaves": it would also remove the ports
        # migrated to that are still marked as dependencies. --prune prints
        # the exact command without them, and the setrequested for those.
        info "MacPorts: $(count_lines "${ST_ACTIVE}") active port(s), $(count_lines "${ST_REQUESTED}") requested, $(count_lines "${ST_PORT_LEAVES}") leaves (unrequested, unused)."
        if [[ -n "$(sed '/^$/d' <<<"${ST_PORT_LEAVES}")" ]]; then
            say "    ${C_DIM}To review them: praetorian --dry-run --prune (prints the exact sudo port uninstall, without the ports you migrated to, and the setrequested that keeps those).${C_RESET}"
        fi
    elif [[ "${HAS_PORT}" != true ]]; then
        info "MacPorts isn't installed."
    fi
}

# e. Last sessions, from their logs (newest first). One line each:
#    date, mode, migration target(s), outcome, duration. The --status
#    sessions themselves (this one included) and the runs stopped at the
#    options (no "session start" line: nothing was run) are left out.
status_sessions() {
    say ""
    say "${C_BOLD}Last sessions${C_RESET} ${C_DIM}(${LOG_DIR})${C_RESET}"
    local logs file line shown=0 ts mode targets outcome secs when
    logs=$(find "${LOG_DIR}" -maxdepth 1 -name 'praetorian_*[0-9].log' -type f 2>/dev/null | sort -r)
    while IFS= read -r file; do
        [[ -n "${file}" && "${file}" != "${LOG_FILE}" ]] || continue
        line=$(strip_ansi <"${file}" | session_outcome)
        [[ -n "${line}" ]] || continue
        IFS=$'\t' read -r mode targets outcome secs <<<"${line}"
        [[ "${mode}" != status ]] || continue
        ts=${file##*/praetorian_}
        ts=${ts%.log}
        when="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}"
        if [[ "${targets}" == - ]]; then targets=""; else targets=" ${targets}"; fi
        if [[ "${secs}" =~ ^[0-9]+$ ]]; then
            secs=" ${C_DIM}($(format_duration "${secs}"))${C_RESET}"
        else
            secs=""
        fi
        ((${#outcome} <= 110)) || outcome="${outcome:0:107}…"
        say "    ${C_DIM}${when}${C_RESET}  $(printf '%-8s' "${mode}")${targets} — ${outcome}${secs}"
        shown=$((shown + 1))
        ((shown < STATUS_SESSIONS)) || break
    done <<<"${logs}"
    ((shown > 0)) || info "No session log yet."
}

# Reads one log (colours stripped) on stdin, prints
# "mode<TAB>targets<TAB>outcome<TAB>seconds", nothing if the session
# never started. Targets: "formula→port" of each migration ("-": none).
session_outcome() {
    awk '
        function secs(s) { return substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2) }
        /^\[[0-9-]+ [0-9:]+\]/ {
            if (first == "") first = substr($0, 2, 19)
            last = substr($0, 2, 19)
        }
        /session start \(mode / {
            m = $0; sub(/.*session start \(mode /, "", m); sub(/\).*/, "", m); mode = m
        }
        /OUT: ── Migration: / {
            t = $0; sub(/.*── Migration: /, "", t)
            split(t, a, " ")
            p = t; sub(/.*\(Homebrew\) → /, "", p); sub(/ \(MacPorts\).*/, "", p)
            t = (a[1] == p) ? a[1] : a[1] "→" p
            if (index(" " targets " ", " " t " ") == 0) targets = targets (targets == "" ? "" : " ") t
        }
        /OUT: ✓ .* migrated to MacPorts/ {
            t = $0; sub(/.*OUT: ✓ /, "", t); sub(/ migrated to MacPorts.*/, "", t)
            migrated = migrated (migrated == "" ? "" : ", ") t
        }
        /OUT: ✗ BLOCKED: / {
            nb++
            if (block == "") { block = $0; sub(/.*✗ BLOCKED: /, "", block) }
        }
        /OUT: Steps passed: / {
            n = split($0, w, " ")
            for (i = 1; i < n; i++) {
                if (w[i] == "passed:") passed = w[i + 1]
                if (w[i] == "failed:") failed = w[i + 1]
            }
        }
        /OUT: .*Interrupted \(Ctrl-C\)/ { interrupted = 1 }
        /OUT: .*Dry-run mode: no change will be applied/ { dry = 1 }
        /OUT: .*Finished with errors\./ { errors = 1 }
        /OUT: .*completed successfully\./ { success = 1 }
        END {
            if (mode == "") exit
            out = ""
            if (migrated != "") out = "✓ migrated: " migrated
            if (nb > 0) {
                b = "✗ blocked: " block (nb > 1 ? " (+" (nb - 1) " more)" : "")
                out = out (out == "" ? "" : "; ") b
            }
            if (interrupted) out = out (out == "" ? "" : "; ") "! interrupted (Ctrl-C)"
            if (failed + 0 > 0) out = out (out == "" ? "" : "; ") "✗ " failed " step(s) failed, " passed " passed"
            if (dry) out = out (out == "" ? "" : "; ") "dry-run"
            if (out == "" || out == "dry-run") {
                pre = out; out = ""
                if (success) out = "✓ ok" (passed != "" ? ", " passed " step(s)" : "")
                else if (errors) out = "✗ finished with errors"
                else if (mode == "report" || mode == "doctor" || mode == "sbom") out = "done"
                else out = "? no summary (stopped early, see the log)"
                if (pre != "") out = pre ": " out
            }
            d = "-"
            if (first != "" && last != "") {
                d = secs(last) - secs(first)
                if (substr(first, 1, 10) != substr(last, 1, 10)) d += 86400
                if (d < 0) d = "-"
            }
            print mode "\t" (targets == "" ? "-" : targets) "\t" out "\t" d
        }'
}
