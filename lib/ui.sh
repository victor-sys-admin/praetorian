# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — terminal output and logging
#
# Colors, the session log, the say/info/ok/warn/err helpers, and block,
# which explains every block (why, impact, what to do, log).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Colors (only when the output is an interactive terminal)
# ----------------------------------------------------------------------------
# shellcheck disable=SC2034  # C_DIM is used by the other lib/ files
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_CYAN=$'\033[36m'
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" \
        C_YELLOW="" C_BLUE="" C_CYAN=""
fi

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
# log_detail: writes ONLY to the log file (technical detail).
log_detail() {
    # Makes sure the log directory exists before any write, even when
    # log_detail is called early (argument parsing, help, early error).
    [[ -d "${LOG_DIR}" ]] || mkdir -p "${LOG_DIR}" 2>/dev/null || return 0
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

# say: prints on screen (unless --quiet) AND logs.
say() {
    [[ "${QUIET}" == true ]] || printf '%s\n' "$*"
    log_detail "OUT: $*"
}

# loud: always printed, even with --quiet (on stderr): a block must never
# go unnoticed.
loud() {
    printf '%s\n' "$*" >&2
    log_detail "OUT: $*"
}

# Semantic display helpers
info() { say "${C_CYAN}•${C_RESET} $*"; }
ok() { say "${C_GREEN}✓${C_RESET} $*"; }
warn() { say "${C_YELLOW}!${C_RESET} $*"; }
err() { say "${C_RED}✗${C_RESET} $*"; }
section() {
    say ""
    say "${C_BOLD}${C_BLUE}── $* ${C_RESET}"
}

# block "title" "why" "impact" ["what to do" …]
# Explains a block in full: what happened, why, what was NOT done, and
# how to unblock. Doesn't exit: the caller decides (finish 1 for a
# prerequisite, return for a single phase).
block() {
    local title=$1 why=$2 impact=$3 line
    shift 3
    BLOCKERS+=("${title}")
    loud ""
    loud "${C_RED}${C_BOLD}✗ BLOCKED: ${title}${C_RESET}"
    loud "    ${C_BOLD}Why        :${C_RESET} ${why}"
    loud "    ${C_BOLD}Impact     :${C_RESET} ${impact}"
    if (($# > 0)); then
        loud "    ${C_BOLD}What to do :${C_RESET}"
        for line in "$@"; do
            loud "        ${line}"
        done
    fi
    loud "    ${C_BOLD}Log        :${C_RESET} ${LOG_FILE}"
    loud ""
}
