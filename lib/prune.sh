# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — leftover dependencies (--prune)
#
# Removes the Homebrew dependencies nothing uses any more, which brew
# autoremove misses: it only removes formulae flagged
# installed_as_dependency, and many aren't (installed by hand once, by an
# older brew, or left by a migration). 2026-10-17: after the move to
# MacPorts, brew autoremove found nothing while brew leaves listed a
# dozen dependencies of the migrated formulae.
#
# A candidate is a formula no other formula nor installed cask needs
# (brew leaves: a cask's "depends_on formula:" counts too) that you
# didn't install yourself (not in brew list --installed-on-request), and
# that nothing outside Homebrew uses (formula_external_users, lib/
# doctor.sh), runs as a service or is named in your shell startup files.
# Removing one round frees the next: rounds until nothing is left, at
# most PRUNE_MAX_ROUNDS. Every round is shown and confirmed (default:
# no); never when unattended; --dry-run only lists the first round.
#
# MacPorts' own leftovers (port echo leaves) are reported, never removed
# (sudo, and MacPorts may need them again to build something).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

readonly PRUNE_MAX_ROUNDS=10

PRUNE_CANDIDATES="" # this round's formulae to remove, one per line
PRUNE_FAILED=false  # brew couldn't list them: nothing is removed
PRUNE_KEPT_SHOWN="" # formulae already reported as kept (shown once)

# prune_confirm "<question>": asks on the terminal (fd 3, the original
# stdin: see main). Only "y" or "yes" is a yes; anything else, an empty
# answer or no terminal at all, is a no.
prune_confirm() {
    local answer=""
    printf '%s [y/N] ' "$1" >&2
    if ! read -r answer <&3 2>/dev/null; then
        printf '\n' >&2
        answer=""
    fi
    log_detail "CONFIRM: $1 → ${answer:-<no answer>}"
    case "${answer}" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# prune_kept <formula> <why>: reported once per session.
prune_kept() {
    [[ " ${PRUNE_KEPT_SHOWN} " != *" $1 "* ]] || return 0
    PRUNE_KEPT_SHOWN+=" $1"
    info "Kept: $1 ${C_DIM}— $2${C_RESET}"
}

# Fills PRUNE_CANDIDATES. Sets PRUNE_FAILED (with a warning) when brew
# can't say what you installed yourself: without that list, every leaf
# would look removable. Always returns 0 (called outside any "||", so
# set -e stays active inside).
prune_candidates() {
    local leaves on_request f short users refs prefix
    PRUNE_CANDIDATES=""
    PRUNE_FAILED=false
    if ! leaves=$(brew leaves 2>>"${LOG_FILE}"); then
        warn "brew leaves failed (see the log): nothing removed."
        PRUNE_FAILED=true
        return 0
    fi
    if ! on_request=$(brew list --formula --installed-on-request 2>>"${LOG_FILE}"); then
        warn "brew list --installed-on-request failed (see the log): can't tell what you installed yourself, nothing removed."
        PRUNE_FAILED=true
        return 0
    fi
    # Tap formulae as short names, like brew leaves' ones are compared.
    on_request=$(awk -F/ '{ print $NF }' <<<"${on_request}")
    prefix=$(doctor_brew_prefix)
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        short=${f##*/}
        grep -qxF "${short}" <<<"${on_request}" && continue
        users=$(formula_external_users "${f}")
        if [[ -n "${users}" ]]; then
            prune_kept "${f}" "used outside Homebrew: $(tr '\n' ';' <<<"${users}" | sed 's/;$//; s/;/; /g')"
            continue
        fi
        if brew_service_plist "${short}" >/dev/null; then
            prune_kept "${f}" "runs as a Homebrew service (brew services stop ${short} first)"
            continue
        fi
        refs=""
        [[ -z "${prefix}" ]] || refs=$(shell_rc_refs "${short}" "${prefix}" 2>/dev/null | cut -d: -f1,2 | sort -u | tr '\n' ' ' || true)
        if [[ -n "${refs}" ]]; then
            prune_kept "${f}" "named in ${refs% }"
            continue
        fi
        PRUNE_CANDIDATES+="${PRUNE_CANDIDATES:+$'\n'}${f}"
    done <<<"${leaves}"
    return 0
}

prune_brew() {
    local round=0 previous="" n before f
    local -a names=()
    while ((round < PRUNE_MAX_ROUNDS)); do
        round=$((round + 1))
        prune_candidates
        [[ "${PRUNE_FAILED}" != true ]] || return 0
        if [[ -z "${PRUNE_CANDIDATES}" ]]; then
            if ((round == 1)); then
                ok "No unused Homebrew dependency: nothing to prune."
            else
                ok "Nothing left to prune after $((round - 1)) round(s)."
            fi
            return 0
        fi
        # brew said it removed them, yet they are still there: stop rather
        # than ask the same question again.
        if [[ "${PRUNE_CANDIDATES}" == "${previous}" ]]; then
            warn "The same formulae are still installed after their removal (see the log): stopped."
            return 0
        fi
        names=()
        while IFS= read -r f; do names+=("${f}"); done <<<"${PRUNE_CANDIDATES}"
        n=${#names[@]}
        say ""
        info "Round ${round}: ${n} formula(e) nothing uses (no formula depends on them, not installed on request):"
        say "    ${names[*]}"

        if [[ "${DRY_RUN}" == true ]]; then
            info "Dry-run: nothing removed. Removing them can free other dependencies: more rounds may follow."
            return 0
        fi
        if [[ "${UNATTENDED}" == true ]]; then
            DEFERRED+=("--prune: ${n} unused Homebrew formula(e) (${names[*]}), waiting for your confirmation — not sudo")
            warn "Unattended: nothing removed, --prune asks before removing anything."
            return 0
        fi
        # --quiet hides the list above: never ask about names not shown.
        [[ "${QUIET}" != true ]] || loud "Round ${round}, unused formulae: ${names[*]}"
        if ! prune_confirm "Uninstall these ${n} formula(e)?"; then
            info "Nothing removed."
            return 0
        fi
        before=${STEP_FAIL}
        run_step "Uninstalling ${n} unused formula(e) (round ${round})" \
            brew uninstall --formula "${names[@]}"
        if step_failed_since "${before}"; then
            warn "brew uninstall failed (see the log): stopped, no further round."
            return 0
        fi
        previous=${PRUNE_CANDIDATES}
    done
    warn "Stopped after ${PRUNE_MAX_ROUNDS} rounds: run praetorian --prune again to go on."
}

# MacPorts: report only. "sudo port uninstall leaves" would also take
# the migrated ports MacPorts sees as dependencies: the safe command
# names the ports.
prune_macports_report() {
    local leaves migrated p
    if ! port_ro -q echo leaves; then
        warn "MacPorts: port echo leaves failed (see the log): not checked."
        return 0
    fi
    leaves=$(awk 'NF { print $1 }' <<<"${PORT_LAST_OUT}" | sort -u)
    migrated=$(migrated_port_names)
    local -a unused=() wanted=()
    while IFS= read -r p; do
        [[ -n "${p}" ]] || continue
        if grep -qxF "${p}" <<<"${migrated}"; then
            wanted+=("${p}")
        else
            unused+=("${p}")
        fi
    done <<<"${leaves}"
    say ""
    if ((${#unused[@]} == 0)); then
        ok "MacPorts: no unused dependency."
    else
        info "MacPorts: ${#unused[@]} port(s) installed as a dependency and no longer used (not removed by praetorian):"
        say "    ${unused[*]}"
        say "    ${C_DIM}To remove exactly these: sudo port uninstall $(shq_all "${unused[@]}")${C_RESET}"
        say "    ${C_DIM}(that frees others in turn: port echo leaves again afterwards)${C_RESET}"
    fi
    if ((${#wanted[@]} > 0)); then
        warn "MacPorts: ${#wanted[@]} port(s) you migrated to are marked as dependencies: \"sudo port uninstall leaves\" would remove them."
        say "    sudo port setrequested $(shq_all "${wanted[@]}")"
    fi
}

prune_run() {
    section "Unused dependencies (--prune)"
    if [[ "${HAS_BREW}" == true ]]; then
        prune_brew
    else
        info "Homebrew not found: nothing to prune on the Homebrew side."
    fi
    [[ "${HAS_PORT}" != true ]] || prune_macports_report
    return 0
}
