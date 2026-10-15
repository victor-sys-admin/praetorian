# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — Homebrew maintenance
#
# Formulae one at a time with automatic fixes and one retry, casks with
# sudo deferral and repair of interrupted upgrades, build log archives.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Automatic fixes: when an upgrade fails for a known cause, apply the fix
# and retry ONCE before quarantining. Real cases (Intel Mac, source
# builds):
#   - openjdk: "XCode tool 'metal' neither found" → the Metal Toolchain is
#     an Xcode 26 component downloaded separately;
#   - mysql-client: "brew unlink boost" requested by the formula itself
#     → unlink for the build, then link back;
#   - node: "Library not loaded ... Referenced from .../Cellar/merve/"
#     → a dependency built against an old version of a library (soname
#     changed): reinstall it.
#   - node: "NameError: uninitialized constant CurlDownloadStrategy::Timeout"
#     → brew bug hiding a failed download: download again.
#   - cask font-ubuntu: files already gone / already there after an
#     interrupted upgrade → forced uninstall + install.
# ----------------------------------------------------------------------------
FIXES_DONE=""  # fixes already applied (once per session)
AUTO_RELINK="" # formula temporarily unlinked, to link back

# Broken libraries: installed formulae referencing a dylib that's gone,
# according to the output and this session's build logs.
broken_linkage_formulas() {
    local brew_logs="${HOME}/Library/Logs/Homebrew"
    {
        printf '%s\n' "$1"
        [[ -n "${SESSION_STAMP}" && -d "${brew_logs}" ]] &&
            find "${brew_logs}" -type f -name '*.log' -newer "${SESSION_STAMP}" -exec cat {} + 2>/dev/null
    } | sed -nE 's#.*Referenced from: <[^>]*> [^ ]*/Cellar/([^/]+)/.*#\1#p' |
        sort -u
}

# auto_fix "<output>" "<formula>": applies a known fix; true if something
# was fixed and a new attempt makes sense.
auto_fix() {
    local out=$1 f=$2 name fixed=1

    # Download failed during the install (network, or the brew bug
    # "NameError: uninitialized constant ...::Timeout" hiding a download
    # error): download again before retrying.
    if grep -qE "uninitialized constant [A-Za-z:]*Timeout|DownloadError|Failed to download resource" <<<"${out}" &&
        [[ " ${FIXES_DONE} " != *" fetch:${f} "* ]]; then
        FIXES_DONE+=" fetch:${f}"
        local before=${STEP_FAIL}
        run_step "New download for ${f}" \
            brew fetch --formula --deps --force "${f}"
        step_failed_since "${before}" || fixed=0
    fi

    if grep -q "XCode tool 'metal' neither found" <<<"${out}" &&
        [[ " ${FIXES_DONE} " != *" metal "* ]]; then
        FIXES_DONE+=" metal"
        local before=${STEP_FAIL}
        run_step "Installing the Metal Toolchain (Xcode)" \
            xcodebuild -downloadComponent MetalToolchain
        step_failed_since "${before}" || fixed=0
    fi

    name=$(grep -oE "brew unlink [A-Za-z0-9@._+-]+" <<<"${out}" | head -n 1 | awk '{print $3}')
    if [[ -n "${name}" && " ${FIXES_DONE} " != *" unlink:${name} "* ]] &&
        brew list --formula "${name}" >/dev/null 2>&1; then
        FIXES_DONE+=" unlink:${name}"
        info "${f} needs ${name} unlinked: unlinked for the duration of the build."
        brew unlink "${name}" >>"${LOG_FILE}" 2>&1 && AUTO_RELINK=${name} && fixed=0
    fi

    while IFS= read -r name; do
        [[ -z "${name}" || "${name}" == "${f}" || " ${FIXES_DONE} " == *" reinstall:${name} "* ]] && continue
        FIXES_DONE+=" reinstall:${name}"
        local before=${STEP_FAIL}
        run_step "Rebuilding ${name} (linked against an outdated library)" \
            brew reinstall --formula "${name}"
        step_failed_since "${before}" || fixed=0
    done < <(broken_linkage_formulas "${out}")

    return "${fixed}"
}

relink_if_needed() {
    [[ -n "${AUTO_RELINK}" ]] || return 0
    if brew link "${AUTO_RELINK}" >>"${LOG_FILE}" 2>&1; then
        log_detail "Linked back: ${AUTO_RELINK}"
    else
        warn "Couldn't link ${AUTO_RELINK} back: run \"brew link ${AUTO_RELINK}\"."
    fi
    AUTO_RELINK=""
}

upgrade_formula() {
    local f=$1
    local label="Upgrading formula ${f}" before upgrade_failed=false build_fails name
    local -a fails=()
    before=${STEP_FAIL}
    run_step "${label}" brew upgrade --formula "${f}"
    step_failed_since "${before}" && upgrade_failed=true
    # Taken now: the auto-fix steps below overwrite LAST_BUILD_FAILS.
    build_fails=${LAST_BUILD_FAILS}

    if [[ "${upgrade_failed}" == true && "${DRY_RUN}" != true ]] &&
        auto_fix "${STEP_OUT}" "${f}"; then
        # The upgrade's own failure, not an auto-fix step's.
        forget_failure "${label}"
        label="Upgrading formula ${f} (2nd try after fix)"
        before=${STEP_FAIL}
        run_step "${label}" brew upgrade --formula "${f}"
        upgrade_failed=false
        step_failed_since "${before}" && upgrade_failed=true
        build_fails=${LAST_BUILD_FAILS}
        relink_if_needed
    fi
    [[ "${upgrade_failed}" == true ]] || return 0

    # brew returned an error but the new version is installed (e.g.
    # "Failed to fix install linkage": brew bug at the very end of the
    # install, after the build) → success with a warning.
    if [[ "${DRY_RUN}" != true ]] &&
        ! brew outdated --formula --quiet "${f}" 2>/dev/null | grep -qxF "${f}"; then
        forget_failure "${label}"
        STEP_OK=$((STEP_OK + 1))
        warn "${f} is installed despite a brew error at the end of the install (see the log)."
        return 0
    fi

    # Build still failing: quarantine the failing formula, and the
    # requested one too when it's one of its dependencies that broke.
    if [[ -n "${build_fails}" ]]; then
        # read -a: split on spaces without glob expansion of the names.
        read -r -a fails <<<"${build_fails}"
        for name in "${fails[@]}"; do
            quarantine_add "${name}" formula build "build failed"
        done
        [[ " ${build_fails} " == *" ${f} "* ]] ||
            quarantine_add "${f}" formula build "dependency ${build_fails} fails to build"
    fi
}

# upgrade_cask name [flags…]
upgrade_cask() {
    local c=$1 before=${STEP_FAIL}
    shift
    run_step "Upgrading cask ${c}" brew upgrade --cask "$@" "${c}"

    # sudo refused for lack of authentication (unattended mode, or Touch
    # ID / password cancelled): neither a failure nor a quarantine, deferred.
    if step_failed_since "${before}" && is_sudo_auth_failure "${STEP_OUT}"; then
        forget_last_failure
        DEFERRED+=("cask ${c}")
        warn "Cask ${c} deferred: its installer needs sudo and nobody could authenticate."
        say "    ${C_DIM}Nothing was changed for this cask; run praetorian again from a terminal.${C_RESET}"
        return 0
    fi

    # Half-installed cask: brew can neither uninstall it (files missing)
    # nor install it (files already there). Start from scratch.
    if step_failed_since "${before}" && [[ "${DRY_RUN}" != true ]] &&
        grep -qE "It seems (the .* source .* is not there|there is already)" <<<"${STEP_OUT}"; then
        reinstall_cask "${c}"
    fi
}

# ----------------------------------------------------------------------------
# Reinstalling a half-installed cask, with a way back.
#
# The forced uninstall removes brew's record of the cask (Caskroom/<cask>:
# installed version, cask file, staged files): if the install then fails,
# brew no longer knows the app at all. So Caskroom/<cask> is copied first
# (a copy, not a move: brew uninstall needs it to find what to remove)
# and put back if the install fails. No copy, no forced uninstall.
# Limit: what the uninstall removed outside the Caskroom (the .app in
# /Applications, fonts…) isn't in the copy; the record put back lets the
# next session retry the upgrade.
# ----------------------------------------------------------------------------
CASK_BACKUP=""      # copy of Caskroom/<cask> while a reinstall runs
CASK_BACKUP_DEST="" # Caskroom/<cask> it was copied from

# Puts the copy back in place of Caskroom/<cask>. True if it worked.
restore_cask_backup() {
    [[ -n "${CASK_BACKUP}" && -d "${CASK_BACKUP}" ]] || return 1
    rm -rf "${CASK_BACKUP_DEST}" 2>>"${LOG_FILE}" || return 1
    mv "${CASK_BACKUP}" "${CASK_BACKUP_DEST}" 2>>"${LOG_FILE}" || return 1
    log_detail "CASK restored: ${CASK_BACKUP} -> ${CASK_BACKUP_DEST}"
    CASK_BACKUP=""
    return 0
}

# reinstall_cask name: replaces the failed upgrade counted by run_step.
reinstall_cask() {
    local c=$1 caskroom before
    local label="Reinstalling cask ${c} (inconsistent install)"
    caskroom=$(brew --caskroom 2>/dev/null || true)
    CASK_BACKUP_DEST="${caskroom}/${c}"
    CASK_BACKUP="${PRAETORIAN_HOME}/.cask_backup.${c}.$$"
    rm -rf "${CASK_BACKUP}"
    if [[ -z "${caskroom}" || ! -d "${CASK_BACKUP_DEST}" ]] ||
        ! cp -pR "${CASK_BACKUP_DEST}" "${CASK_BACKUP}" 2>>"${LOG_FILE}"; then
        rm -rf "${CASK_BACKUP}"
        CASK_BACKUP=""
        # The upgrade failure stays counted: nothing was repaired.
        warn "Cask ${c} is half-installed, but its Caskroom entry (${CASK_BACKUP_DEST}) couldn't be saved: not reinstalled."
        say "    ${C_DIM}A forced uninstall without a copy could lose the app. By hand: brew uninstall --cask --force ${c} && brew install --cask ${c}${C_RESET}"
        return 0
    fi
    log_detail "CASK saved: ${CASK_BACKUP_DEST} -> ${CASK_BACKUP}"
    forget_last_failure
    brew uninstall --cask --force "${c}" >>"${LOG_FILE}" 2>&1 || true
    before=${STEP_FAIL}
    run_step "${label}" brew install --cask "${c}"
    if ! step_failed_since "${before}"; then
        rm -rf "${CASK_BACKUP}"
        CASK_BACKUP=""
        return 0
    fi
    # Install failed: the failure stays counted, brew's record goes back.
    if restore_cask_backup; then
        warn "Cask ${c}: reinstall failed, its previous Caskroom entry was put back (brew still lists it as installed)."
        say "    ${C_DIM}Files the uninstall removed outside the Caskroom (the app itself) may be missing: run praetorian again, or brew install --cask --force ${c}${C_RESET}"
    else
        warn "Cask ${c}: reinstall failed and its Caskroom entry couldn't be put back. Copy kept: ${CASK_BACKUP}"
        say "    ${C_DIM}Put it back by hand: rm -rf ${CASK_BACKUP_DEST} && mv ${CASK_BACKUP} ${CASK_BACKUP_DEST}${C_RESET}"
        CASK_BACKUP=""
    fi
}

# ----------------------------------------------------------------------------
# Casks whose upgrade was interrupted (Ctrl-C, power cut): brew leaves a
# <version>.upgrading directory and then refuses any upgrade ("It seems
# there is already a Font at ..."). Moving the directory back lets the
# next upgrade start cleanly.
# ----------------------------------------------------------------------------
repair_interrupted_casks() {
    local caskroom d base cask
    caskroom=$(brew --caskroom 2>/dev/null) || return 0
    [[ -n "${caskroom}" ]] || return 0
    [[ -d "${caskroom}" ]] || return 0
    while IFS= read -r -d '' d; do
        base=${d%.upgrading}
        cask=$(basename "$(dirname "${d}")")
        if [[ -e "${base}" ]]; then
            warn "Cask ${cask}: leftover from an interrupted upgrade (${d}), check it by hand."
        elif mv "${d}" "${base}" 2>>"${LOG_FILE}"; then
            info "Cask ${cask}: interrupted upgrade repaired."
            log_detail "CASK repaired: ${d} -> ${base}"
        else
            warn "Cask ${cask}: couldn't move ${d} back to ${base}, check it by hand."
        fi
    done < <(find "${caskroom}" -mindepth 2 -maxdepth 2 -type d -name '*.upgrading' -print0 2>/dev/null)
}

# ----------------------------------------------------------------------------
# Saving the brew build logs produced during the session.
# ----------------------------------------------------------------------------
save_build_logs() {
    local brew_logs="${HOME}/Library/Logs/Homebrew"
    [[ "${DRY_RUN}" == true || -z "${SESSION_STAMP}" || ! -d "${brew_logs}" ]] && return 0
    local -a dirs=()
    local d
    while IFS= read -r -d '' d; do
        dirs+=("$(basename "${d}")")
    done < <(find "${brew_logs}" -mindepth 1 -maxdepth 1 -type d -newer "${SESSION_STAMP}" -print0 2>/dev/null)
    ((${#dirs[@]} > 0)) || return 0
    local archive="${LOG_DIR}/praetorian_${RUN_TS}_buildlogs.tar.gz"
    if tar -czf "${archive}" -C "${brew_logs}" "${dirs[@]}" 2>>"${LOG_FILE}"; then
        log_detail "Build logs saved: ${archive} (${dirs[*]})"
    else
        warn "Couldn't archive this session's brew build logs (brew cleanup will delete them): ${brew_logs}"
    fi
}

# ----------------------------------------------------------------------------
# Homebrew maintenance steps
# ----------------------------------------------------------------------------
maintenance_brew() {
    section "Homebrew maintenance"

    # Homebrew developer mode: silently turned on by any "dev" command
    # (brew cat, brew linkage, …). brew update then follows the unreleased
    # main branch and its bugs (e.g. NameError ...::Timeout at the end of
    # the node build). praetorian never runs a dev command; if the mode is
    # on without HOMEBREW_DEVELOPER, go back to the stable release.
    local -a update_env=()
    if [[ -z "${HOMEBREW_DEVELOPER:-}" ]] &&
        [[ "$(git -C "$(brew --repository)" branch --show-current 2>/dev/null)" == "main" ]]; then
        warn "Homebrew is following its development branch (developer mode on)."
        if [[ "${DRY_RUN}" != true ]]; then
            brew developer off >>"${LOG_FILE}" 2>&1 || true
            update_env=(env HOMEBREW_UPDATE_TO_TAG=1)
            info "Developer mode turned off, going back to the latest stable release."
        fi
    fi

    if ((${#update_env[@]} > 0)); then
        run_step "Updating the index (brew update, back to stable)" \
            "${update_env[@]}" brew update --force
    else
        run_step "Updating the index (brew update)" \
            brew update
    fi

    show_quarantine

    # --- Formulae: quarantined ones are excluded. -------------------------
    local outdated skipped todo
    outdated=$(brew outdated --formula --quiet 2>>"${LOG_FILE}" || true)
    skipped=$(quarantined_names formula)
    todo=$(filter_out "${outdated}" "${skipped}")
    if [[ -z "${todo}" ]]; then
        ok "Formulae up to date ${C_DIM}(quarantine excluded)${C_RESET}"
    else
        local -a formulas=()
        local f
        while IFS= read -r f; do formulas+=("${f}"); done <<<"${todo}"
        # Download everything first: a network drop fails here in seconds,
        # instead of crashing brew after an hour of compiling (resource
        # downloaded at the end of the install).
        run_step "Downloading sources (${#formulas[@]} formula(e) + dependencies)" \
            brew fetch --formula --deps "${formulas[@]}"
        # One at a time: a grouped brew upgrade stops at the first failed
        # build and doesn't even try the remaining formulae.
        for f in "${formulas[@]}"; do
            # Already quarantined during this session (dependency of an
            # earlier formula that failed to build): skip.
            if [[ " ${SESSION_QUARANTINED} " == *" ${f} "* ]]; then
                info "Formula ${f} skipped ${C_DIM}(failed earlier in the session)${C_RESET}"
                continue
            fi
            upgrade_formula "${f}"
        done
    fi

    # --- Casks: one at a time, so a broken cask doesn't block the others.
    [[ "${DRY_RUN}" == true ]] || repair_interrupted_casks
    local -a cask_flags=()
    [[ "${GREEDY}" == true ]] && cask_flags=(--greedy)
    outdated=$(brew outdated --cask "${cask_flags[@]+"${cask_flags[@]}"}" --quiet 2>>"${LOG_FILE}" || true)
    skipped=$(quarantined_names cask)
    todo=$(filter_out "${outdated}" "${skipped}")
    if [[ -z "${todo}" ]]; then
        ok "Apps (casks) up to date ${C_DIM}(quarantine excluded)${C_RESET}"
    else
        sudo_notes
        # No progress line during casks: it would overwrite sudo's
        # password prompt in the terminal.
        SHOW_PROGRESS=false
        local -a casks=()
        local c
        while IFS= read -r c; do casks+=("${c}"); done <<<"${todo}"
        for c in "${casks[@]}"; do
            upgrade_cask "${c}" "${cask_flags[@]+"${cask_flags[@]}"}"
        done
        # shellcheck disable=SC2034  # read by run_step (session.sh)
        SHOW_PROGRESS=true
    fi

    run_step "Removing orphaned dependencies (brew autoremove)" \
        brew autoremove

    # brew cleanup --prune=all deletes ~/Library/Logs/Homebrew: keep this
    # session's build logs first.
    save_build_logs

    run_step "Cleaning caches and dead links (brew cleanup)" \
        brew cleanup --prune=all
}
