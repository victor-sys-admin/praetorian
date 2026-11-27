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
    # Only when brew outdated answered (code 0) and no longer lists it:
    # a brew outdated that fails prints nothing either, and an upgrade
    # that failed would be counted as done.
    local still_outdated outdated_rc=0
    still_outdated=$(brew outdated --formula --quiet "${f}" 2>>"${LOG_FILE}") || outdated_rc=$?
    if [[ "${DRY_RUN}" != true ]] && ((outdated_rc == 0)) &&
        ! grep -qxF "${f}" <<<"${still_outdated}"; then
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

# formula_current name: installed and not outdated. Given a name, brew
# outdated exits 1 when the formula is outdated, and on any error, which
# counts as not current. brew resolves the name itself (a tap formula, or
# one installed under an alias, is listed under another name).
formula_current() {
    brew outdated --formula --quiet "$1" </dev/null >/dev/null 2>>"${LOG_FILE}" &&
        brew list --formula --versions "$1" </dev/null >/dev/null 2>&1
}

# lift_built_later: a formula quarantined for a failed build can get
# built after all, most often as the dependency of a formula upgraded
# later (brew upgrade builds the outdated dependencies first). Once it is
# installed and current, its entry goes, and so does the entry of a
# formula held back only by such dependencies ("dependency … fails to
# build"); that formula is then upgraded at the next session. Entries
# from earlier sessions are lifted the same way (a formula built by hand).
lift_built_later() {
    [[ "${DRY_RUN}" != true && -s "${QUARANTINE_FILE}" ]] || return 0
    local entries name detail deps d all tmp q
    local -a lifted=() kept=() dep_list=()
    entries=$(awk -F'\t' '$2 == "formula" && $4 == "build" {print $1 "\t" $5}' "${QUARANTINE_FILE}")
    [[ -n "${entries}" ]] || return 0

    while IFS=$'\t' read -r name detail; do
        if [[ "${detail}" == "dependency "*" fails to build" ]]; then
            deps=${detail#dependency }
            deps=${deps% fails to build}
            all=true
            # read -a: split on spaces without glob expansion of the names.
            read -r -a dep_list <<<"${deps}"
            for d in "${dep_list[@]}"; do
                formula_current "${d}" || all=false
            done
            [[ "${all}" == true ]] || continue
            warn "${name}: ${deps} got built after all, quarantine lifted (${name} is upgraded at the next session)."
        elif formula_current "${name}"; then
            forget_failure "Upgrading formula ${name}"
            forget_failure "Upgrading formula ${name} (2nd try after fix)"
            warn "${name} failed to build, then got built after all (as a dependency of another formula, or by hand): quarantine lifted."
        else
            continue
        fi
        lifted+=("${name}")
        log_detail "QUARANTINE - ${name} (formula): built after all"
    done <<<"${entries}"
    ((${#lifted[@]} > 0)) || return 0

    tmp=$(mktemp -t praetorian_q)
    awk -F'\t' 'NR == FNR {l[$0] = 1; next} !($2 == "formula" && $4 == "build" && ($1 in l))' \
        <(printf '%s\n' "${lifted[@]}") "${QUARANTINE_FILE}" >"${tmp}"
    mv "${tmp}" "${QUARANTINE_FILE}"
    for name in "${lifted[@]}"; do
        kept=()
        for q in "${NEWLY_QUARANTINED[@]+"${NEWLY_QUARANTINED[@]}"}"; do
            [[ "${q}" == "${name} (formula) — "* ]] || kept+=("${q}")
        done
        NEWLY_QUARANTINED=("${kept[@]+"${kept[@]}"}")
    done
}

# skip_pinned "<outdated>": takes out of the caller's todo (maintenance_
# brew) the formulae pinned with brew pin, and those depending on an
# outdated pinned one. brew upgrade refuses both, with code 1 and no
# build log ("Not upgrading 1 pinned package", "You must brew unpin …"),
# so nothing is quarantined and every session failed the same way; their
# new versions were downloaded too. brew list --pinned prints short names
# and brew outdated a tap formula's full one (user/tap/foo): compared on
# the short name (a core and a tap formula of one name can't both be
# installed, they share Cellar/<name>). A pinned dependency that is only
# a build dependency isn't seen (brew uses without --include-build).
skip_pinned() {
    local pinned held held_short map="" p d f short left=""
    pinned=$(brew list --formula --pinned 2>>"${LOG_FILE}" || true)
    [[ -n "${pinned}" && -n "${todo}" ]] || return 0
    # Outdated and pinned, under brew outdated's name.
    held=$(awk 'NR == FNR {p[$0] = 1; next} {s = $0; sub(/.*\//, "", s)} s in p' \
        <(printf '%s\n' "${pinned}") <(printf '%s\n' "$1"))
    [[ -n "${held}" ]] || return 0
    held_short=$(awk '{sub(/.*\//, ""); print}' <<<"${held}")
    # "<dependent> <pinned>", short names.
    while IFS= read -r p; do
        while IFS= read -r d; do
            if [[ -n "${d}" ]]; then map+="${d##*/} ${p}"$'\n'; fi
        done < <(brew uses --installed --recursive --formula "${p}" 2>>"${LOG_FILE}" || true)
    done <<<"${held_short}"

    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        short=${f##*/}
        if grep -qxF "${short}" <<<"${held_short}"; then
            info "Formula ${f} skipped ${C_DIM}(pinned: brew unpin ${short} to upgrade it)${C_RESET}"
            continue
        fi
        p=$(awk -v d="${short}" '$1 == d {print $2; exit}' <<<"${map}")
        if [[ -n "${p}" ]]; then
            info "Formula ${f} skipped ${C_DIM}(needs the newer ${p}, which is pinned: brew unpin ${p} to upgrade both)${C_RESET}"
            continue
        fi
        left+="${left:+$'\n'}${f}"
    done <<<"${todo}"
    todo=${left}
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

# brew_cleanup_formula <formula>: removes the formula's old versions and
# old downloads right after its upgrade, when Homebrew won't:
# HOMEBREW_NO_INSTALL_CLEANUP turns off the "brew cleanup <formula>" brew
# upgrade runs by itself. Otherwise they stay until the final brew
# cleanup, while every next build needs space. Not a step: a failure
# here is only logged (the final cleanup runs anyway).
brew_cleanup_formula() {
    [[ -n "${HOMEBREW_NO_INSTALL_CLEANUP:-}" && "${DRY_RUN}" != true ]] || return 0
    log_detail "CMD: brew cleanup $1"
    brew cleanup "$1" >>"${LOG_FILE}" 2>&1 ||
        log_detail "brew cleanup $1 failed (the final brew cleanup --prune=all runs anyway)"
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

    # --- Formulae: quarantined and pinned ones are excluded. --------------
    local outdated skipped todo disk_low=false
    outdated=$(brew outdated --formula --quiet 2>>"${LOG_FILE}" || true)
    skipped=$(quarantined_names formula)
    todo=$(filter_out "${outdated}" "${skipped}")
    skip_pinned "${outdated}"
    if [[ -z "${todo}" ]]; then
        ok "Formulae up to date ${C_DIM}(quarantine and pins excluded)${C_RESET}"
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
        local -a not_done=()
        for f in "${formulas[@]}"; do
            # Disk below the minimum: every formula left is not upgraded.
            if [[ "${disk_low}" == true ]]; then
                not_done+=("${f}")
                continue
            fi
            # Already quarantined during this session (dependency of an
            # earlier formula that failed to build): skip.
            if [[ " ${SESSION_QUARANTINED} " == *" ${f} "* ]]; then
                info "Formula ${f} skipped ${C_DIM}(failed earlier in the session)${C_RESET}"
                continue
            fi
            # Free space again before each build: the downloads above and
            # every build's temporary files eat into what the first check
            # saw. Below the minimum, stop here rather than fill the disk
            # in the middle of an install.
            if ! disk_space_ok; then
                disk_low=true
                not_done+=("${f}")
                continue
            fi
            upgrade_formula "${f}"
            brew_cleanup_formula "${f}"
        done
        if [[ "${disk_low}" == true ]]; then
            block "disk space ran low during the formula upgrades (${DISK_FREE_GB} GB free, minimum ${DISK_MIN_GB} GB)" \
                "The source downloads and each build's temporary files ate into the space checked at the start. A disk filling up in the middle of an install leaves a half-installed package." \
                "Not upgraded: ${not_done[*]}. The casks were skipped too. brew autoremove and brew cleanup still ran, to give space back." \
                "Free some space, for example:" \
                "  sudo port reclaim            (MacPorts: inactive versions, sources)" \
                "  empty the Trash and ~/Library/Caches" \
                "then run praetorian again: the formulae left are upgraded then."
        fi
    fi
    lift_built_later

    # --- Casks: skipped when the disk ran low above, their downloads need
    # space too.
    if [[ "${disk_low}" == true ]]; then
        info "Apps (casks) skipped: not enough disk space (see the block above)."
    else
        maintenance_casks
    fi

    run_step "Removing orphaned dependencies (brew autoremove)" \
        brew autoremove

    # brew cleanup --prune=all deletes ~/Library/Logs/Homebrew: keep this
    # session's build logs first.
    save_build_logs

    run_step "Cleaning caches and dead links (brew cleanup)" \
        brew cleanup --prune=all
}

# Casks (apps), one at a time: a broken one doesn't block the others.
maintenance_casks() {
    local outdated skipped todo
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
}
