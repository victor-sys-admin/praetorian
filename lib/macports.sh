# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — MacPorts maintenance
#
# selfupdate, upgrade with the result checked, inactive versions, and
# the report of commands installed by both Homebrew and MacPorts.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# MacPorts
#
# Strategy:
#   - always the absolute path ${PORT_BIN}, under sudo too;
#   - read-only commands (version, outdated, installed, contents, echo,
#     info) run without sudo; commands that change something go through
#     sudo, one call per step and only when there is work to do (CIS
#     timestamp_timeout=0: one Touch ID prompt each);
#   - upgrades in a single "port -p upgrade <list>": -p keeps going after
#     a failed port, so one broken port doesn't block the others (same
#     reason as brew's one-at-a-time), without a sudo prompt per port;
#   - the result is checked with a second "port outdated": whatever is
#     still outdated failed, whatever the exit code said;
#   - never upgrade after a failed "port selfupdate" (ports tree possibly
#     half-synced);
#   - macOS upgraded without reinstalling MacPorts: everything is blocked
#     and the official migration steps are printed.
# ----------------------------------------------------------------------------
# shellcheck disable=SC2034  # also used by migrate.sh
readonly -a MACPORTS_INSTALL_HINT=(
    "1. Xcode (already here) or the Command Line Tools: required by MacPorts."
    "2. Download the MacPorts package for YOUR macOS version (sw_vers -productVersion): https://www.macports.org/install.php"
    "3. Install it (double-click), then open a NEW terminal (it adds /opt/local/bin to the PATH)."
    "4. sudo port selfupdate"
    "5. praetorian --migration-report"
    "praetorian never installs MacPorts itself: it's a system package, to be installed knowingly."
)

# port_ro args…: read-only port command (no sudo). Output in
# PORT_LAST_OUT (and its start in the log), port's exit code returned.
port_ro() {
    local rc=0
    PORT_LAST_OUT=$("${PORT_BIN}" "$@" 2>&1) || rc=$?
    log_detail "port $* (rc ${rc})"
    head -n 200 <<<"${PORT_LAST_OUT}" >>"${LOG_FILE}" 2>/dev/null || true
    return "${rc}"
}

# MacPorts' message when macOS moved to a new major version since it was
# installed: 'Current platform "darwin 25" does not match expected
# platform "darwin 24"'.
port_platform_mismatch() { grep -q 'does not match expected platform' <<<"$1"; }

block_port_platform() {
    local line
    line=$(strip_ansi <<<"$1" | grep -m 1 'does not match expected platform' || true)
    [[ -n "${line}" ]] || line="macOS moved to a new major version since MacPorts was installed."
    block "MacPorts was installed for another macOS version" \
        "${line} MacPorts must be reinstalled for every major macOS version, and all ports with it." \
        "No MacPorts command was run. Installed ports may not work until the migration is done." \
        "Official procedure (details: https://trac.macports.org/wiki/Migration):" \
        "  1. Xcode / Command Line Tools up to date for the new macOS version" \
        "  2. install the MacPorts package for that version: https://www.macports.org/install.php" \
        "  3. port -qv installed > ~/myports.txt" \
        "     port echo requested | cut -d ' ' -f 1 | uniq > ~/requested.txt" \
        "  4. sudo port -f uninstall installed && sudo port reclaim" \
        "  5. reinstall with the restore_ports.tcl script from the Migration page" \
        "then run praetorian again."
}

# The first 3 "Error:" lines of an output (otherwise the last 3 lines).
port_error_lines() {
    local out lines
    out=$(strip_ansi <<<"$1")
    lines=$(grep -E '^Error: ' <<<"${out}" | head -n 3 | tr '\n' ' ' || true)
    [[ -n "${lines}" ]] || lines=$(sed '/^[[:space:]]*$/d' <<<"${out}" | tail -n 3 | tr '\n' ' ' || true)
    [[ -n "${lines}" ]] || lines="no error message"
    printf '%s' "${lines}"
}

# Is MacPorts responding? Otherwise: explained block, non-zero code.
port_health() {
    if port_ro version; then
        log_detail "MacPorts: ${PORT_LAST_OUT}"
        return 0
    fi
    if port_platform_mismatch "${PORT_LAST_OUT}"; then
        block_port_platform "${PORT_LAST_OUT}"
    else
        block "MacPorts isn't responding (port version failed)" \
            "$(port_error_lines "${PORT_LAST_OUT}")" \
            "No MacPorts command was run this session." \
            "Details: ${PORT_BIN} -d version" \
            "Broken install: reinstall the MacPorts package (https://www.macports.org/install.php)."
    fi
    return 1
}

# Fills OUTDATED_PORTS (one name per line); non-zero if port fails.
# MacPorts format: "name   1.0_0 < 1.1_0".
port_refresh_outdated() {
    OUTDATED_PORTS=""
    port_ro outdated || return 1
    OUTDATED_PORTS=$(awk '/ < / && $1 ~ /^[A-Za-z0-9]/ {print $1}' <<<"${PORT_LAST_OUT}" | sort -u)
}

port_is_active() {
    port_ro installed "$1" || return 1
    grep -q '(active)' <<<"${PORT_LAST_OUT}"
}

# Can sudo be used? Always true when interactive (sudo will ask); when
# unattended, only if sudo needs no authentication.
port_sudo_available() {
    [[ "${UNATTENDED}" == true && "${DRY_RUN}" != true ]] || return 0
    sudo -n true 2>/dev/null
}

# Can PORT_BIN be trusted with root? It must belong to root and be
# writable by root only, like every directory above it up to / (links
# followed). Otherwise anyone able to set PRAETORIAN_PORT_PREFIX or to
# write there would get a command of their choice run under sudo.
port_bin_trusted() {
    local p=${PORT_BIN}
    # A relative prefix: nothing to walk up to /, never trusted.
    [[ "${p}" == /* ]] || return 1
    while :; do
        [[ -n "$(find -L "${p}" -maxdepth 0 -user 0 ! -perm -0020 ! -perm -0002 2>/dev/null)" ]] || return 1
        [[ "${p}" != / ]] || return 0
        p=$(dirname "${p}")
    done
}

# Is the sudo praetorian would run able to give root? Only a setuid-root
# file can (/usr/bin/sudo, or /opt/local/bin/sudo from MacPorts' sudo port
# when /opt/local/bin comes first in the PATH). The tests' fake sudo is
# a plain script.
port_sudo_is_real() {
    local s
    s=$(command -v "${SUDO_CMD[0]}" 2>/dev/null) || return 1
    [[ -n "$(find -L "${s}" -maxdepth 0 -user 0 -perm -4000 2>/dev/null)" ]]
}

# Rule, kept simple on purpose:
#   - default prefix (/opt/local): port_bin_trusted always applies,
#     whatever sudo comes first in the PATH;
#   - test prefix (PRAETORIAN_PORT_PREFIX): skipped only when sudo can't
#     give root (the tests' fake sudo and fake port belong to the test
#     user); with a real sudo, it applies and blocks.
# A non-setuid "sudo" wrapper first in the PATH could still call the real
# one: whoever controls your PATH already controls every sudo you type.
# Otherwise: explained block, non-zero code.
port_sudo_safe() {
    if [[ "${PORT_PREFIX}" != /opt/local ]] && ! port_sudo_is_real; then
        return 0
    fi
    port_bin_trusted && return 0
    block "${PORT_BIN} can't be trusted with sudo" \
        "It (or one of the directories above it) doesn't belong to root, or can be modified by someone other than root. praetorian would run it as root." \
        "No MacPorts command was run under sudo. Nothing was changed on the MacPorts side." \
        "Check: ls -ld / $(dirname "${PORT_PREFIX}") ${PORT_PREFIX} $(dirname "${PORT_BIN}") ${PORT_BIN}" \
        "PRAETORIAN_PORT_PREFIX is for tests only: unset it (env | grep PRAETORIAN)." \
        "A genuine MacPorts install belongs to root: reinstall it from https://www.macports.org/install.php"
    return 1
}

# Position of a directory in the PATH (-1 if absent).
path_index() {
    local target=$1 dir i=0
    local -a dirs=()
    # read -a: no pathname expansion of the PATH entries (unlike a bare
    # ${PATH} split on ":").
    IFS=: read -r -a dirs <<<"${PATH}"
    for dir in "${dirs[@]+"${dirs[@]}"}"; do
        if [[ "${dir%/}" == "${target}" ]]; then
            echo "${i}"
            return 0
        fi
        i=$((i + 1))
    done
    echo -1
}

# Does the terminal's PATH include the MacPorts commands?
port_path_check() {
    [[ "${UNATTENDED}" == true ]] && return 0 # launchd: minimal PATH, expected
    if (($(path_index "${PORT_PREFIX}/bin") < 0)); then
        warn "${PORT_PREFIX}/bin isn't in your PATH: the commands installed by MacPorts are invisible in the terminal."
        say "    ${C_DIM}The MacPorts installer normally adds it to ~/.zprofile. If it's there, a later line probably${C_RESET}"
        say "    ${C_DIM}overwrites the PATH (e.g. export PATH=\"…\" without \$PATH in ~/.zshrc). Otherwise add:${C_RESET}"
        say "    ${C_DIM}export PATH=\"${PORT_PREFIX}/bin:${PORT_PREFIX}/sbin:\$PATH\"${C_RESET}"
    fi
}

# Port step failure caused by sudo (cancelled / unattended) or by a changed
# macOS: deferred or blocked here, true if so.
port_step_blocked() {
    local what=$1
    # shellcheck disable=SC2153  # STEP_OUT is set by run_step (session.sh)
    if is_sudo_auth_failure "${STEP_OUT}"; then
        forget_last_failure
        DEFERRED+=("MacPorts (${what})")
        warn "MacPorts deferred (${what}): sudo couldn't be obtained (cancelled, or nobody there for Touch ID)."
        say "    ${C_DIM}Nothing was changed on the MacPorts side at this step; run praetorian again from a terminal.${C_RESET}"
        return 0
    fi
    if port_platform_mismatch "${STEP_OUT}"; then
        block_port_platform "${STEP_OUT}"
        return 0
    fi
    return 1
}

# Copies the main.log files MacPorts points to ("Error: See …/main.log for
# details."): "sudo port clean" or the next attempt deletes them.
save_port_logs() {
    [[ "${DRY_RUN}" == true ]] && return 0
    local -a rel=()
    local path
    while IFS= read -r path; do
        [[ -r "${path}" ]] && rel+=("${path#/}")
    done < <(strip_ansi <<<"$1" | sed -nE 's#^Error: See (/[^ ]+/main\.log) for details\.?#\1#p' | sort -u)
    ((${#rel[@]} > 0)) || return 0
    local archive="${LOG_DIR}/praetorian_${RUN_TS}_portlogs.tar.gz"
    if tar -czf "${archive}" -C / "${rel[@]}" 2>>"${LOG_FILE}"; then
        log_detail "MacPorts logs saved: ${archive}"
    else
        warn "MacPorts logs not archived (see the log): \"port log <name>\" shows them until the port is cleaned."
    fi
}

# After "port -p upgrade": whatever is still outdated failed.
# port_check_upgrade <counter before> port…
port_check_upgrade() {
    local before=$1 step_out=${STEP_OUT} p pairs culprits detail
    shift
    if step_failed_since "${before}" && port_step_blocked "port upgrade"; then
        return 0
    fi
    save_port_logs "${step_out}"
    if ! port_refresh_outdated; then
        warn "Result can't be checked: port outdated failed after the upgrade (see the log)."
        return 0
    fi

    local -a failed=()
    for p in "$@"; do
        grep -qxF "${p}" <<<"${OUTDATED_PORTS}" && failed+=("${p}")
    done

    if ((${#failed[@]} == 0)); then
        if step_failed_since "${before}"; then
            forget_last_failure
            STEP_OK=$((STEP_OK + 1))
            warn "port returned an error, but every requested port is up to date (see the log)."
        fi
        return 0
    fi

    # port said "OK" while some ports are still outdated: count it as a
    # failure, the real state is what matters.
    if ! step_failed_since "${before}"; then
        STEP_OK=$((STEP_OK - 1))
        STEP_FAIL=$((STEP_FAIL + 1))
        FAILED_STEPS+=("MacPorts upgrade (ports still outdated)")
    fi

    # "Error: Failed to build foo: …", "Error: Failed to configure foo, …",
    # "Error: Processing of port foo failed" → name<TAB>phase
    pairs=$(strip_ansi <<<"${step_out}" | awk '
        $1 == "Error:" && $2 == "Failed" && $3 == "to" { n = $5; sub(/[:,.]$/, "", n); print n "\t" $4 }
        $1 == "Error:" && $2 == "Processing" && $3 == "of" && $4 == "port" { print $5 "\t?" }
    ' | sort -u)
    culprits=$(cut -f1 <<<"${pairs}" | sed '/^$/d' | sort -u | tr '\n' ' ')

    warn "$(($# - ${#failed[@]})) port(s) upgraded, ${#failed[@]} failed: ${failed[*]}"
    for p in "${failed[@]}"; do
        local phase
        phase=$(awk -F'\t' -v n="${p}" '$1 == n && $2 != "?" {print $2; exit}' <<<"${pairs}")
        if [[ -n "${phase}" ]]; then
            detail="failed at the \"${phase}\" phase"
        elif [[ " ${culprits} " == *" ${p} "* ]]; then
            detail="upgrade failed"
        elif [[ -n "${culprits// /}" ]]; then
            detail="failed dependency: ${culprits% }"
        else
            detail="still outdated after port upgrade (see the log)"
        fi
        quarantine_add "${p}" port build "${detail}"
    done
}

maintenance_macports() {
    section "MacPorts maintenance"
    port_health || return 0
    port_path_check

    # Unattended: nobody there for Touch ID, and no password stored.
    if ! port_sudo_available; then
        local n=0
        port_refresh_outdated && n=$(count_lines "${OUTDATED_PORTS}")
        DEFERRED+=("MacPorts (selfupdate + upgrade; ${n} port(s) outdated according to the local index)")
        warn "MacPorts deferred: every MacPorts command that changes the system needs sudo."
        say "    ${C_DIM}Unattended, nobody can approve Touch ID or type the password, and praetorian${C_RESET}"
        say "    ${C_DIM}stores none (CIS timestamp_timeout=0, PCI DSS 8.6.2). Nothing was changed on the MacPorts side.${C_RESET}"
        say "    ${C_DIM}→ run praetorian again from a terminal.${C_RESET}"
        return 0
    fi
    port_sudo_safe || return 0
    info "MacPorts needs sudo: one Touch ID / password prompt per step that changes something (3 at most)."

    local before=${STEP_FAIL}
    run_step "Updating MacPorts and its ports tree (port selfupdate)" \
        "${SUDO_CMD[@]}" "${PORT_BIN}" -N selfupdate
    if step_failed_since "${before}"; then
        port_step_blocked "selfupdate" && return 0
        block "port selfupdate failed" \
            "$(port_error_lines "${STEP_OUT}")" \
            "No port was upgraded: praetorian doesn't upgrade from a ports tree that may be half-synced." \
            "Check the network, then run praetorian again." \
            "Details: sudo ${PORT_BIN} -d selfupdate"
        return 0
    fi

    if ! port_refresh_outdated; then
        block "couldn't list outdated ports (port outdated failed)" \
            "$(port_error_lines "${PORT_LAST_OUT}")" \
            "No port was upgraded." \
            "Details: ${PORT_BIN} -d outdated"
        return 0
    fi

    local skipped todo
    skipped=$(quarantined_names port)
    todo=$(filter_out "${OUTDATED_PORTS}" "${skipped}")
    if [[ -z "${todo}" ]]; then
        ok "Ports up to date ${C_DIM}(quarantine excluded)${C_RESET}"
    else
        local -a ports=()
        local p
        while IFS= read -r p; do ports+=("${p}"); done <<<"${todo}"
        info "${#ports[@]} port(s) to upgrade: ${ports[*]}"
        before=${STEP_FAIL}
        run_step "Upgrading ${#ports[@]} MacPorts port(s)" \
            "${SUDO_CMD[@]}" "${PORT_BIN}" -N -p upgrade "${ports[@]}"
        [[ "${DRY_RUN}" == true ]] || port_check_upgrade "${before}" "${ports[@]}"
    fi

    # Old versions deactivated by upgrades: only when there are some (no
    # sudo prompt for nothing).
    if port_ro installed inactive && grep -q '@' <<<"${PORT_LAST_OUT}"; then
        before=${STEP_FAIL}
        run_step "Removing old inactive versions (port uninstall inactive)" \
            "${SUDO_CMD[@]}" "${PORT_BIN}" -N uninstall inactive
        step_failed_since "${before}" && port_step_blocked "removing inactive versions" || true
    fi

    # Dependencies no longer needed: reported, never removed automatically
    # (they may be needed again to build something).
    if port_ro echo leaves; then
        local n
        n=$(count_lines "${PORT_LAST_OUT}")
        if ((n > 0)); then
            info "${n} port(s) installed as a dependency and no longer used (port echo leaves)."
            say "    ${C_DIM}Not removed (they may be needed again); to remove them: sudo port uninstall leaves${C_RESET}"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Homebrew / MacPorts side by side: commands installed twice, PATH order.
# ----------------------------------------------------------------------------
coexistence() {
    [[ "${HAS_BREW}" == true && "${HAS_PORT}" == true ]] || return 0
    section "Homebrew / MacPorts side by side"
    local brew_prefix brew_bin port_pos brew_pos dups n b formula active
    # Without a prefix, "/bin" would be compared with MacPorts: false duplicates.
    brew_prefix=$(brew --prefix 2>/dev/null) || brew_prefix=""
    if [[ -z "${brew_prefix}" ]]; then
        warn "brew --prefix failed: commands installed twice not checked (see the log)."
        return 0
    fi
    brew_bin="${brew_prefix}/bin"
    port_pos=$(path_index "${PORT_PREFIX}/bin")
    brew_pos=$(path_index "${brew_bin}")
    if ((port_pos >= 0 && brew_pos >= 0 && brew_pos < port_pos)); then
        warn "Homebrew comes before MacPorts in the PATH: for a command installed by both, the Homebrew copy runs."
        say "    ${C_DIM}Put ${PORT_PREFIX}/bin first in the PATH (~/.zprofile), after the lines that add Homebrew.${C_RESET}"
    fi

    dups=$(comm -12 \
        <(find "${PORT_PREFIX}/bin" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | sort) \
        <(find "${brew_bin}" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | sort) || true)
    n=$(count_lines "${dups}")
    if ((n == 0)); then
        ok "No command installed twice."
        return 0
    fi
    warn "${n} command(s) installed by both Homebrew and MacPorts:"
    local i=0
    while IFS= read -r b; do
        [[ -n "${b}" ]] || continue
        if ((i++ >= 15)); then
            say "    ${C_DIM}… $((n - 15)) more, see the log${C_RESET}"
            break
        fi
        # Not a link (a file put there by hand): readlink fails, no formula.
        formula=$(readlink "${brew_bin}/${b}" 2>/dev/null | sed -nE 's#.*/Cellar/([^/]+)/.*#\1#p' || true)
        active=$(command -v "${b}" 2>/dev/null || echo "?")
        say "    ${C_DIM}-${C_RESET} ${b} ${C_DIM}(formula ${formula:-?}) → used: ${active}${C_RESET}"
    done <<<"${dups}"
    log_detail "Commands installed twice: $(tr '\n' ' ' <<<"${dups}")"
    say "    ${C_DIM}As long as they're duplicated, Homebrew keeps rebuilding these formulae.${C_RESET}"
    info "To finish migrating a formula: praetorian --migrate <formula>[=<port>]"
}
