# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — Homebrew → MacPorts migration
#
# --migration-report (read-only plan) and --migrate (check, install,
# check, and only then uninstall the formula).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Homebrew → MacPorts migration
# ----------------------------------------------------------------------------
# A few formulae named differently in MacPorts (checked against the real
# MacPorts index on 2026-10-15).
port_family() {
    case "$1" in
        node) echo nodejs ;;
        mysql-client) echo mysql ;;
        make) echo gmake ;;
        ant) echo apache-ant ;;
        sphinx-doc) echo py-sphinx ;;
        *) echo "$1" ;;
    esac
}

# Likely MacPorts names for a formula missing under its exact name, most
# likely first:
#   - "name@X.Y" → "nameXY" (python@3.11 → python311): when it exists,
#     it's the answer and nothing else is suggested;
#   - a tap formula without its tap (hashicorp/tap/terraform → terraform);
#   - the same name in another case (imagemagick → ImageMagick);
#   - a known alias (make → gmake);
#   - versioned ports "name<digits>" (node → nodejs22), up to 6;
#   - only when nothing else matched: the Python module (numpy → py-numpy),
#     so gnupg suggests gnupg2 rather than py-gnupg.
# port_candidates formula "<available ports>"
port_candidates() {
    local f=$1 all=$2 name base ver c out="" n
    name=${f##*/}
    base=${name%%@*}
    if [[ "${name}" == *@* ]]; then
        ver=${name#*@}
        c="${base}${ver//./}"
        if grep -qxF "${c}" <<<"${all}"; then
            printf '%s' "${c}"
            return 0
        fi
    fi
    for c in "${name}" "$(grep -ixF "${base}" <<<"${all}" | head -n 1 || true)" \
        "$(port_family "${base}")"; do
        [[ -n "${c}" && "${c}" != "${f}" ]] || continue
        grep -qxF "${c}" <<<"${all}" || continue
        [[ ", ${out}, " == *", ${c}, "* ]] || out+="${out:+, }${c}"
    done
    base=$(port_family "${base}")
    c=$(awk -v p="${base}" 'index($0, p) == 1 && substr($0, length(p) + 1) ~ /^[0-9]+$/ {
            print substr($0, length(p) + 1) "\t" $0 }' <<<"${all}" | sort -n | cut -f2)
    n=$(count_lines "${c}")
    if ((n > 0)); then
        c=$(tail -n 6 <<<"${c}" | tr '\n' ' ')
        c=${c% }
        ((n > 6)) && c="… ${c}"
        out+="${out:+, }${c// /, }"
        ((n > 6)) && out+=" (${n} versions: port echo '${base}*')"
    fi
    c="py-${name#python-}"
    if [[ -z "${out}" ]] && grep -qxF "${c}" <<<"${all}"; then out=${c}; fi
    printf '%s' "${out}"
}

# Lines of the shell startup files that point into the formula (e.g.
# export PATH=/usr/local/opt/mysql-client/bin:$PATH): they would point to
# nothing once the formula is uninstalled.
shell_rc_refs() {
    local f=$1 prefix=$2 rc
    for rc in "${SHELL_RC_FILES[@]}"; do
        [[ -f "${HOME}/${rc}" ]] || continue
        awk -v a="${prefix}/opt/${f}" -v b="${prefix}/Cellar/${f}/" -v name="~/${rc}" '
            /^[[:space:]]*#/ { next }
            {
                s = $0
                while ((i = index(s, a)) > 0) {
                    c = substr(s, i + length(a), 1)
                    if (c !~ /[A-Za-z0-9@._+-]/) { print name ":" FNR ": " $0; next }
                    s = substr(s, i + length(a))
                }
                if (index($0, b) > 0) print name ":" FNR ": " $0
            }' "${HOME}/${rc}"
    done
}

# The formula's Homebrew service (brew services), if any.
brew_service_plist() {
    local p
    for p in "${HOME}/Library/LaunchAgents/homebrew.mxcl.$1.plist" "/Library/LaunchDaemons/homebrew.mxcl.$1.plist"; do
        if [[ -e "${p}" ]]; then
            echo "${p}"
            return 0
        fi
    done
    return 1
}

# Blocking notes for a formula (migration report).
migration_notes() {
    local f=${1##*/} prefix=$2 notes="" refs
    brew_service_plist "${f}" >/dev/null && notes+=" [brew service running]"
    # Without the prefix, "/opt/<f>" and "/Cellar/<f>/" would be searched:
    # false notes.
    [[ -n "${prefix}" ]] || {
        printf '%s' "${notes}"
        return 0
    }
    refs=$(shell_rc_refs "${f}" "${prefix}")
    [[ -n "${refs}" ]] && notes+=" [referenced in $(cut -d: -f1 <<<"${refs}" | sort -u | tr '\n' ' ' | sed 's/ $//')]"
    printf '%s' "${notes}"
}

# --migration-report: read-only plan, nothing is changed.
migration_report() {
    section "Homebrew → MacPorts migration plan (read-only)"
    if [[ "${HAS_BREW}" != true ]]; then
        ok "Homebrew isn't (or no longer) installed: nothing to migrate."
        return 0
    fi
    if [[ "${HAS_PORT}" != true ]]; then
        block "MacPorts isn't installed" \
            "The plan compares your Homebrew formulae with the available MacPorts ports: it needs MacPorts and its index." \
            "No plan produced. Nothing was changed." \
            "${MACPORTS_INSTALL_HINT[@]}"
        return 0
    fi
    port_health || return 0
    if ! port_ro echo all; then
        block "couldn't read the MacPorts index" \
            "$(port_error_lines "${PORT_LAST_OUT}")" \
            "No plan produced. Nothing was changed." \
            "sudo port selfupdate, then run praetorian --migration-report again."
        return 0
    fi
    local all
    all=$(awk 'NF {print $1}' <<<"${PORT_LAST_OUT}" | sort -u)
    if [[ -z "${all}" ]]; then
        block "the MacPorts index is empty" \
            "port echo all returns no port: the index has probably never been synced." \
            "No plan produced. Nothing was changed." \
            "sudo port selfupdate, then run praetorian --migration-report again."
        return 0
    fi

    local leaves prefix f cands notes n_casks has_notes=false
    leaves=$(brew leaves 2>>"${LOG_FILE}" || true)
    prefix=$(brew --prefix 2>/dev/null) || prefix=""
    local -a same=() approx=() none=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        notes=$(migration_notes "${f}" "${prefix}")
        [[ -z "${notes}" ]] || has_notes=true
        if grep -qxF "${f}" <<<"${all}"; then
            same+=("${f}${notes}")
        else
            cands=$(port_candidates "${f}" "${all}")
            if [[ -n "${cands}" ]]; then
                approx+=("${f} → ${cands}${notes}")
            else
                none+=("${f}${notes}")
            fi
        fi
    done <<<"${leaves}"

    info "Formulae you installed yourself (brew leaves): $(count_lines "${leaves}")."
    say "    ${C_DIM}The others are dependencies: brew autoremove will remove them once nothing uses them.${C_RESET}"
    local item
    if ((${#same[@]} > 0)); then
        say ""
        ok "Same name in MacPorts (${#same[@]}) — praetorian --migrate <formula>:"
        for item in "${same[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
    fi
    if ((${#approx[@]} > 0)); then
        say ""
        warn "Probably a different name (${#approx[@]}) — check with \"port info <port>\", then praetorian --migrate <formula>=<port>:"
        for item in "${approx[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
    fi
    if ((${#none[@]} > 0)); then
        say ""
        warn "Not found under this name (${#none[@]}) — search with \"port search --name <word>\", otherwise keep it in Homebrew:"
        for item in "${none[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
    fi
    if [[ "${has_notes}" == true ]]; then
        say ""
        info "The [ ] notes will block the migration until they're dealt with:"
        say "    ${C_DIM}[brew service running]      → brew services stop <formula>, then the MacPorts equivalent (sudo port load <port>)${C_RESET}"
        say "    ${C_DIM}[referenced in ~/.zshrc…]   → replace those Homebrew paths with MacPorts ones (${PORT_PREFIX}/…)${C_RESET}"
    fi

    n_casks=$(count_lines "$(brew list --cask 2>/dev/null || true)")
    say ""
    info "${n_casks} cask(s) (apps): they STAY in Homebrew."
    say "    ${C_DIM}MacPorts doesn't manage apps, and a cask downloads the vendor's app without compiling anything:${C_RESET}"
    say "    ${C_DIM}tier 3 doesn't affect them.${C_RESET}"

    say ""
    info "Suggested order:"
    say "    1. First the formulae that cause trouble (long builds, quarantined)."
    say "    2. One at a time: ${C_BOLD}praetorian --migrate <formula>[=<port>]${C_RESET} (with --dry-run to see the checks)."
    say "    3. After each migration, check that your tools work (new terminal)."
    say "    4. When only casks are left, Homebrew has nothing to compile: maintenance becomes fast."
}

# --migrate formula[=port]: installs with MacPorts, checks, and only then
# uninstalls the formula. Any failing check stops everything, the Homebrew
# formula untouched. Always returns 0: the outcome is in BLOCKERS (called
# outside a "||" context so set -e stays active).
#
# One function per step (migrate_*). Each one returns 0 and reports a
# stop through block(): migrate stops as soon as BLOCKERS grew. A step
# never returns a status to test: it would have to be called left of "||"
# or in an "if", where bash turns set -e off for the whole function, and
# an unexpected failure (e.g. brew --prefix) would go on unnoticed instead
# of being explained by on_exit.
# The steps share migrate's locals (bash: a function sees the locals of
# its caller): f (formula), p (port), short (formula without its tap,
# as used in opt/ paths, service names and MacPorts), brew_files (set by
# migrate_check_formula), brew_bins (set by migrate_check_port).
migrate() {
    local f=${MIGRATE_SPEC%%=*} p=${MIGRATE_SPEC#*=} short
    short=${f##*/}
    [[ "${MIGRATE_SPEC}" == *=* ]] || p=${short}
    section "Migration: ${f} (Homebrew) → ${p} (MacPorts)"
    say "Fail-safe order: check → install with MacPorts → check → only then uninstall with Homebrew."
    say "${C_DIM}If a step fails, praetorian stops and ${f} stays installed with Homebrew.${C_RESET}"

    local brew_files="" brew_bins="" step blocks_before=${#BLOCKERS[@]}
    for step in migrate_preconditions migrate_check_formula migrate_check_usage migrate_check_port; do
        "${step}"
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
    done
    if [[ "${DRY_RUN}" == true ]]; then
        migrate_dry_run_plan
        return 0
    fi
    for step in migrate_check_sudo migrate_install migrate_verify migrate_uninstall_formula; do
        "${step}"
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
    done
}

# Homebrew and a working MacPorts.
migrate_preconditions() {
    if [[ "${HAS_BREW}" != true ]]; then
        block "Homebrew not found" "There is no ${f} formula to migrate without Homebrew." "Nothing was done."
        return 0
    fi
    if [[ "${HAS_PORT}" != true ]]; then
        block "MacPorts isn't installed" \
            "${p} can't be installed without MacPorts." \
            "Nothing was done: ${f} stays in Homebrew." \
            "${MACPORTS_INSTALL_HINT[@]}"
        return 0
    fi
    port_health || return 0
}

# 1. Is the formula installed? 2. No other formula may depend on it.
migrate_check_formula() {
    if ! brew_files=$(brew list --formula "${f}" 2>>"${LOG_FILE}"); then
        block "${f} isn't an installed Homebrew formula" \
            "brew list --formula ${f} doesn't find it (exact name? it may be a cask, which stays in Homebrew)." \
            "Nothing was done." \
            "Formulae that can be migrated: praetorian --migration-report"
        return 0
    fi
    ok "Formula ${f} installed with Homebrew"

    local dependents
    dependents=$(brew uses --installed "${f}" 2>>"${LOG_FILE}" || true)
    if [[ -n "${dependents}" ]]; then
        block "other Homebrew formulae depend on ${f}" \
            "Dependents: $(tr '\n' ' ' <<<"${dependents}")— uninstalling ${f} would break them (brew would refuse anyway)." \
            "Nothing was done: no MacPorts install, no uninstall." \
            "Migrate the dependents first (praetorian --migrate <formula>), then ${f};" \
            "or keep ${f} in Homebrew."
        return 0
    fi
    ok "No other formula depends on ${f}"
}

# 3. Homebrew service: it starts the Homebrew binary. 4. The formula's
# Homebrew paths in the shell startup files.
migrate_check_usage() {
    local plist
    if plist=$(brew_service_plist "${short}"); then
        block "${f} runs as a Homebrew service" \
            "${plist} starts the Homebrew binary: the service wouldn't start any more after the uninstall." \
            "Nothing was done." \
            "Stop the service: brew services stop ${short}" \
            "After the migration, the MacPorts equivalent (if the port provides one): sudo port load ${p}" \
            "then run again: praetorian --migrate ${MIGRATE_SPEC}"
        return 0
    fi

    local prefix refs line
    prefix=$(brew --prefix)
    refs=$(shell_rc_refs "${short}" "${prefix}")
    if [[ -n "${refs}" ]]; then
        local -a fix=()
        while IFS= read -r line; do fix+=("  ${line}"); done <<<"${refs}"
        block "your shell uses Homebrew paths of ${f}" \
            "These lines point into ${prefix}/opt/${short} or ${prefix}/Cellar/${short}: after the uninstall they would point to nothing (command not found, or another version picked up elsewhere in the PATH)." \
            "Nothing was done." \
            "Lines involved:" \
            "${fix[@]}" \
            "→ remove them or replace them with the MacPorts equivalent (${PORT_PREFIX}/…), open a new terminal," \
            "  then run again: praetorian --migrate ${MIGRATE_SPEC}"
        return 0
    fi
    ok "No service or shell startup file depends on the Homebrew paths of ${f}"
}

# 5. Does the port exist? 6. Commands provided by the formula: they must
# exist on the MacPorts side (checked by migrate_verify).
migrate_check_port() {
    if ! port_ro info --name "${p}"; then
        if port_platform_mismatch "${PORT_LAST_OUT}"; then
            block_port_platform "${PORT_LAST_OUT}"
            return 0
        fi
        block "no MacPorts port named ${p}" \
            "$(port_error_lines "${PORT_LAST_OUT}")" \
            "Nothing was done." \
            "Find the right name: port search --name --glob '$(port_family "${short%%@*}")*'" \
            "then: praetorian --migrate ${f}=<port-name>"
        return 0
    fi
    ok "Port ${p} available in MacPorts"

    brew_bins=$(awk -F/ '$(NF-1) == "bin" || $(NF-1) == "sbin" {print $NF}' <<<"${brew_files}" | sort -u)
    info "Commands provided by ${f}: $(tr '\n' ' ' <<<"${brew_bins:-none}")"
}

migrate_dry_run_plan() {
    info "Next steps (not run in dry-run):"
    say "    1. sudo port -N install ${p}"
    say "    2. check that ${p} is active and provides the commands above"
    say "    3. brew uninstall --formula ${f}   (only if 2 passes)"
}

migrate_check_sudo() {
    if ! port_sudo_available; then
        block "MacPorts needs sudo, impossible when unattended" \
            "Installing ${p} needs Touch ID or the password, and praetorian stores none." \
            "Nothing was done." \
            "Run it from a terminal: praetorian --migrate ${MIGRATE_SPEC}"
        return 0
    fi
    port_sudo_safe || return 0
}

# 7. MacPorts install (skipped when the port is already active).
migrate_install() {
    if port_is_active "${p}"; then
        ok "${p} already installed and active in MacPorts"
        return 0
    fi
    local before=${STEP_FAIL}
    run_step "Installing ${p} with MacPorts" \
        "${SUDO_CMD[@]}" "${PORT_BIN}" -N install "${p}"
    step_failed_since "${before}" || return 0
    save_port_logs "${STEP_OUT}"
    if is_sudo_auth_failure "${STEP_OUT}"; then
        block "sudo authentication cancelled or refused" \
            "MacPorts needs sudo to install ${p}." \
            "${f} stays installed with Homebrew, nothing changed." \
            "Run again: praetorian --migrate ${MIGRATE_SPEC}"
        return 0
    fi
    if port_platform_mismatch "${STEP_OUT}"; then
        block_port_platform "${STEP_OUT}"
        return 0
    fi
    block "installing ${p} with MacPorts failed" \
        "$(port_error_lines "${STEP_OUT}")" \
        "${f} stays installed with Homebrew and usable. MacPorts never activates a half-installed port." \
        "Details: port log ${p}  (or the *_portlogs.tar.gz archive in ${LOG_DIR})" \
        "Clean up and retry: sudo port clean ${p} && praetorian --migrate ${MIGRATE_SPEC}" \
        "This Mac is still supported by MacPorts: bugs can be reported at https://trac.macports.org"
}

# 8. Checks after the install: active, and every command of the formula.
migrate_verify() {
    if ! port_is_active "${p}"; then
        block "${p} isn't active in MacPorts after the install" \
            "port installed ${p} doesn't show it as (active)." \
            "${f} was NOT uninstalled from Homebrew." \
            "See: port installed ${p}" \
            "Activate it: sudo port activate ${p}, then run praetorian --migrate ${MIGRATE_SPEC} again"
        return 0
    fi
    local port_bins missing
    port_ro contents "${p}" || true
    port_bins=$(awk -v pre="${PORT_PREFIX}" '{ sub(/^[[:space:]]+/, "") }
        index($0, pre "/bin/") == 1 || index($0, pre "/sbin/") == 1 { n = split($0, a, "/"); print a[n] }' \
        <<<"${PORT_LAST_OUT}" | sort -u)
    missing=$(comm -23 <(sed '/^$/d' <<<"${brew_bins}") <(sed '/^$/d' <<<"${port_bins}") || true)
    if [[ -n "${missing}" ]]; then
        block "${p} (MacPorts) doesn't provide every command of ${f}" \
            "Missing on the MacPorts side: $(tr '\n' ' ' <<<"${missing}")— often a name with a version suffix (python3.12 instead of python3), or a variant to enable." \
            "BOTH are installed: ${f} (Homebrew) was NOT uninstalled. This is harmless." \
            "Compare: port contents ${p} | grep bin/" \
            "Variants: port variants ${p}" \
            "Keep both, or undo on the MacPorts side: sudo port uninstall ${p}" \
            "If you don't use those commands: brew uninstall --formula ${f} (do it yourself)"
        return 0
    fi
    ok "${p} is active and provides every command of ${f}"
}

# 9. Only now: the Homebrew uninstall.
migrate_uninstall_formula() {
    local before=${STEP_FAIL}
    run_step "Uninstalling ${f} (Homebrew)" brew uninstall --formula "${f}"
    if step_failed_since "${before}"; then
        block "uninstalling ${f} from Homebrew failed" \
            "$(port_error_lines "${STEP_OUT}")" \
            "${f} is installed twice (Homebrew and MacPorts): harmless, but Homebrew will keep rebuilding it." \
            "See the log, then: brew uninstall --formula ${f}"
        return 0
    fi
    printf '%s\t%s\t%s\n' "${f}" "${p}" "$(date +%s)" >>"${MIGRATED_FILE}"
    ok "${f} migrated to MacPorts (${p})."
    info "Terminals already open: run \"hash -r\" (or open a new one) to use the MacPorts version."
    info "${C_DIM}Homebrew dependencies no longer needed go away at the next brew autoremove (praetorian session).${C_RESET}"
    port_path_check
}
