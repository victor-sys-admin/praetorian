# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — quarantine
#
# Packages failing for a cause that won't go away on its own are set
# aside in quarantine.tsv and skipped until their entry expires.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Quarantine for packages failing for a structural cause
# ----------------------------------------------------------------------------
# quarantine_add name type cause detail
quarantine_add() {
    local name=$1 type=$2 cause=$3 detail=$4
    if [[ -f "${QUARANTINE_FILE}" ]] &&
        awk -F'\t' -v n="${name}" -v t="${type}" '$1==n && $2==t {f=1} END {exit !f}' "${QUARANTINE_FILE}"; then
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${type}" "$(date +%s)" "${cause}" "${detail}" >>"${QUARANTINE_FILE}"
    NEWLY_QUARANTINED+=("${name} (${type}) — ${detail}")
    SESSION_QUARANTINED+=" ${name}"
    log_detail "QUARANTINE + ${name} (${type}): ${detail}"
}

# Removes expired entries, and Xcode entries once Xcode is installed.
quarantine_prune() {
    local now min_epoch min_build xcode=0 tmp toolchain previous
    now=$(date +%s)
    min_epoch=$((now - QUARANTINE_DAYS * 86400))
    min_build=$((now - QUARANTINE_BUILD_DAYS * 86400))
    has_full_xcode && xcode=1

    # Toolchain changed (e.g. Xcode was just installed): build failures
    # recorded with the previous one no longer apply. Recorded even with
    # no quarantine yet: otherwise .toolchain would stay stale, and build
    # failures quarantined later with the current toolchain would be
    # lifted for a change that happened before them.
    toolchain=$( ((xcode)) && echo xcode || echo clt)
    previous=$(cat "${TOOLCHAIN_FILE}" 2>/dev/null || echo "${toolchain}")
    [[ "${DRY_RUN}" == true ]] || printf '%s\n' "${toolchain}" >"${TOOLCHAIN_FILE}"
    [[ -f "${QUARANTINE_FILE}" ]] || return 0
    if [[ "${previous}" != "${toolchain}" ]]; then
        min_build=${now}
        info "Toolchain changed (${previous} → ${toolchain}): build failures will be retried."
    fi
    tmp=$(mktemp -t praetorian_q)
    awk -F'\t' -v m="${min_epoch}" -v b="${min_build}" -v x="${xcode}" \
        '$3 >= m && !($4 == "build" && $3 < b) && !(x && $4 == "xcode")' \
        "${QUARANTINE_FILE}" >"${tmp}"
    if cmp -s "${tmp}" "${QUARANTINE_FILE}"; then
        rm -f "${tmp}"
    elif [[ "${DRY_RUN}" == true ]]; then
        # Dry-run changes nothing: the entries that a real session would
        # lift are only reported (they are still skipped this session).
        info "Dry-run: $(($(wc -l <"${QUARANTINE_FILE}") - $(wc -l <"${tmp}"))) quarantine entry(ies) would be lifted (expired, or cause gone)."
        rm -f "${tmp}"
    else
        log_detail "QUARANTINE: expired/lifted entries removed."
        mv "${tmp}" "${QUARANTINE_FILE}"
    fi
}

# quarantined_names type → one name per line
quarantined_names() {
    [[ "${RETRY_QUARANTINED}" == true || ! -f "${QUARANTINE_FILE}" ]] && return 0
    awk -F'\t' -v t="$1" '$2 == t {print $1}' "${QUARANTINE_FILE}"
}

# filter_out "<list>" "<to exclude>" → list without the excluded names.
# Compared on the short name too: brew outdated lists a tap formula as
# user/tap/foo, while a quarantine entry read from its build log, or from
# an earlier version, says foo (a core and a tap formula of one name can't
# both be installed: they share Cellar/<name>).
filter_out() {
    if [[ -z "$2" ]]; then
        printf '%s\n' "$1" | sed '/^$/d'
    else
        awk 'NR == FNR {x[$0] = 1; s = $0; sub(/.*\//, "", s); x[s] = 1; next}
            $0 == "" {next}
            {s = $0; sub(/.*\//, "", s)}
            !($0 in x) && !(s in x)' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
    fi
}

# ----------------------------------------------------------------------------
# Showing the active quarantine.
# ----------------------------------------------------------------------------
show_quarantine() {
    [[ -s "${QUARANTINE_FILE}" ]] || return 0
    if [[ "${RETRY_QUARANTINED}" == true ]]; then
        info "Quarantine ignored (--retry-quarantined): retrying everything."
        return 0
    fi
    local n
    n=$(wc -l <"${QUARANTINE_FILE}" | tr -d ' ')
    warn "${n} package(s) in quarantine, skipped this session:"
    local name type cause detail
    while IFS=$'\t' read -r name type _ cause detail; do
        say "    ${C_DIM}-${C_RESET} ${name} ${C_DIM}(${type}, ${detail})${C_RESET}"
    done <"${QUARANTINE_FILE}"
}
