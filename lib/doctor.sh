# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — health check (--doctor)
#
# Read-only checks for what breaks around Homebrew and MacPorts without
# either of them noticing (pipx environments, files brew can't clean, dead
# PATH entries…), each with the command that fixes it. Every one of them
# bit on 2026-10-17, during the move of the command-line tools to
# MacPorts. Nothing here changes anything: no sudo, no brew or port
# command that writes, the fixes are only printed.
#
# Also formula_external_users, used before a formula is uninstalled
# (--migrate, --prune).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# Root of the system paths read by the doctor (/Library/Java…,
# /Library/Developer…, /etc/paths). PRAETORIAN_DOCTOR_ROOT is for tests
# only: these paths are only read, and the commands built from them are
# printed, never run.
readonly DOCTOR_ROOT="${PRAETORIAN_DOCTOR_ROOT:-}"

DOCTOR_PROBLEMS=0     # problems found by this run
DOCTOR_RC=0           # exit code for main: 0 nothing found, 2 problems
DOCTOR_BREW_PREFIX="" # brew --prefix, cached (see doctor_brew_prefix)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# Quoted for a shell (paths with spaces: "Application Support"), so a
# printed command can be pasted as is.
shq() { printf '%q' "$1"; }

# shq_all <word>…: each word through shq, separated by spaces (a list of
# names in a printed command: package names come from files anyone can
# write, a venv called "x; rm -rf ~" must stay one harmless argument).
shq_all() {
    local w out=""
    for w in "$@"; do
        out+="${out:+ }$(shq "${w}")"
    done
    printf '%s' "${out}"
}

# doctor_problem <count> "<what is wrong>" ["<fix line>" …]: counts and
# prints a problem with the commands that fix it.
doctor_problem() {
    local n=$1 line
    shift
    DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + n))
    warn "$1"
    shift
    for line in "$@"; do
        say "      ${line}"
    done
}

# Homebrew prefix, empty without Homebrew (or when brew --prefix fails).
doctor_brew_prefix() {
    if [[ -z "${DOCTOR_BREW_PREFIX}" ]] && command -v brew >/dev/null 2>&1; then
        DOCTOR_BREW_PREFIX=$(brew --prefix 2>/dev/null) || DOCTOR_BREW_PREFIX=""
    fi
    printf '%s' "${DOCTOR_BREW_PREFIX}"
}

# Removes "." and ".." from an absolute path, as text (the path may no
# longer exist: a link into a removed formula).
path_clean() {
    local part
    local -a parts=() kept=()
    IFS=/ read -r -a parts <<<"$1"
    for part in "${parts[@]+"${parts[@]}"}"; do
        case "${part}" in
            "" | .) ;;
            ..) ((${#kept[@]} == 0)) || kept=("${kept[@]:0:${#kept[@]}-1}") ;;
            *) kept+=("${part}") ;;
        esac
    done
    ((${#kept[@]} > 0)) || {
        echo /
        return 0
    }
    printf '/%s' "${kept[@]}"
    echo
}

# link_hops <path>: every target a chain of symbolic links goes through,
# one absolute path per line (8 hops at most, a loop stops there).
link_hops() {
    local cur=$1 target i
    for ((i = 0; i < 8; i++)); do
        [[ -L "${cur}" ]] || break
        target=$(readlink "${cur}" 2>/dev/null) || break
        [[ "${target}" == /* ]] || target="$(dirname "${cur}")/${target}"
        cur=$(path_clean "${target}")
        printf '%s\n' "${cur}"
    done
}

# The lines of the shell startup files (and /etc/paths, /etc/paths.d)
# that mention a text, as "~/.zshrc:13", one per line. Comments skipped.
# For Homebrew paths, shell_rc_refs (lib/migrate.sh) is used instead.
rc_lines_with() {
    local text=$1 rc f
    for rc in "${SHELL_RC_FILES[@]}"; do
        [[ -f "${HOME}/${rc}" ]] || continue
        awk -v t="${text}" -v name="~/${rc}" '
            /^[[:space:]]*#/ { next }
            index($0, t) > 0 { print name ":" FNR }' "${HOME}/${rc}" 2>/dev/null || true
    done
    for f in "${DOCTOR_ROOT}/etc/paths" "${DOCTOR_ROOT}"/etc/paths.d/*; do
        [[ -f "${f}" ]] || continue
        awk -v t="${text}" -v name="${f}" 'index($0, t) > 0 { print name ":" FNR }' "${f}" 2>/dev/null || true
    done
}

# Ports recorded by --migrate (second column of migrated.tsv, several
# ports separated by commas), one per line.
migrated_port_names() {
    [[ -f "${MIGRATED_FILE}" ]] || return 0
    awk -F'\t' 'NF >= 2 { n = split($2, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' \
        "${MIGRATED_FILE}" 2>/dev/null | sort -u || true
}

# ----------------------------------------------------------------------------
# pipx environments and the Python they run on
#
# A pipx environment is a venv: bin/python3.X is a link to the Python it
# was created with, and pyvenv.cfg names that Python again (home,
# executable). When that Python was a Homebrew formula, uninstalling the
# formula leaves the link pointing to nothing: every command of the
# environment fails with "bad interpreter" (2026-10-17: ansible-core,
# poetry… after python@3.14 went to MacPorts).
# ----------------------------------------------------------------------------
# Where pipx keeps its environments: PIPX_HOME, ~/.local/pipx (the
# default of older pipx versions, still used when it exists), then
# ~/Library/Application Support/pipx. Empty when there is none.
pipx_home() {
    local d
    for d in "${PIPX_HOME:-}" "${HOME}/.local/pipx" "${HOME}/Library/Application Support/pipx"; do
        if [[ -n "${d}" && -d "${d}/venvs" ]]; then
            printf '%s' "${d}"
            return 0
        fi
    done
}

# What pipx installed the environment from (main package only, not the
# injected ones): a name on PyPI, a URL, or a local path.
pipx_source() {
    [[ -f "$1/pipx_metadata.json" ]] || return 0
    awk '/"main_package"/ { m = 1 }
        m && /"package_or_url"/ {
            sub(/.*"package_or_url"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' \
        "$1/pipx_metadata.json" 2>/dev/null || true
}

# brew_python_of <path> <prefix> <minor>: the Homebrew Python formula a
# path belongs to (python@3.14), nothing if none.
brew_python_of() {
    local s=$1 prefix=$2 minor=$3 r
    [[ -n "${prefix}" ]] || return 0
    case "${s}" in
        "${prefix}"/opt/* | "${prefix}"/Cellar/*)
            r=${s#"${prefix}"/*/}
            r=${r%%/*}
            case "${r}" in
                python@*) echo "${r}" ;;
                python | python3) [[ -z "${minor}" ]] || echo "python@${minor}" ;;
            esac
            ;;
        "${prefix}"/Frameworks/Python.framework/Versions/*)
            r=${s#"${prefix}"/Frameworks/Python.framework/Versions/}
            r=${r%%/*}
            [[ "${r}" == [0-9]* ]] && echo "python@${r}"
            ;;
    esac
    return 0
}

# venv_inspect <venv> <brew prefix>: sets
#   VENV_MINOR    its Python version (3.13), from pyvenv.cfg
#   VENV_BROKEN   true when bin/python leads to nothing
#   VENV_TARGET   where bin/python finally points (end of its links)
#   VENV_FORMULA  the Homebrew Python it depends on (link, home or
#                 executable in pyvenv.cfg), empty if none
VENV_MINOR="" VENV_BROKEN=false VENV_TARGET="" VENV_FORMULA=""
venv_inspect() {
    local v=$1 prefix=$2 cfg="$1/pyvenv.cfg" py="" c hops home exe s f
    VENV_MINOR="" VENV_BROKEN=false VENV_TARGET="" VENV_FORMULA=""
    if [[ -f "${cfg}" ]]; then
        # "|| true": an unreadable pyvenv.cfg must not stop the run
        # (pipefail, set -e in the caller).
        VENV_MINOR=$(sed -nE 's/^version(_info)?[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+).*/\2/p' "${cfg}" 2>/dev/null | head -n 1 || true)
        home=$(sed -nE 's/^home[[:space:]]*=[[:space:]]*//p' "${cfg}" 2>/dev/null | head -n 1 || true)
        exe=$(sed -nE 's/^executable[[:space:]]*=[[:space:]]*//p' "${cfg}" 2>/dev/null | head -n 1 || true)
    fi
    for c in ${VENV_MINOR:+"${v}/bin/python${VENV_MINOR}"} "${v}/bin/python3" "${v}/bin/python"; do
        if [[ -L "${c}" || -e "${c}" ]]; then
            py=${c}
            break
        fi
    done
    if [[ -z "${py}" ]]; then
        VENV_BROKEN=true
        VENV_TARGET="no bin/python"
        hops=""
    else
        [[ -e "${py}" ]] || VENV_BROKEN=true
        hops=$(link_hops "${py}")
        VENV_TARGET=$(sed -n '$p' <<<"${hops}")
        [[ -n "${VENV_TARGET}" ]] || VENV_TARGET=${py}
    fi
    while IFS= read -r s; do
        [[ -n "${s}" ]] || continue
        f=$(brew_python_of "${s}" "${prefix}" "${VENV_MINOR}")
        if [[ -n "${f}" ]]; then
            VENV_FORMULA=${f}
            return 0
        fi
        # <prefix>/bin/python3.X: Homebrew's link, when a Homebrew Python
        # of that version is (or was) there. python.org's installer links
        # /usr/local/bin too, so only when the link is gone or Homebrew
        # has that version.
        if [[ -n "${prefix}" && -n "${VENV_MINOR}" ]] &&
            [[ "${s}" == "${prefix}/bin" || "${s}" == "${prefix}/bin/"* ]] &&
            [[ "${VENV_BROKEN}" == true || -e "${prefix}/opt/python@${VENV_MINOR}" ]]; then
            VENV_FORMULA="python@${VENV_MINOR}"
            return 0
        fi
    done <<<"$(printf '%s\n' "${hops}" "${home:-}" "${exe:-}")"
    return 0
}

# Fix lines for a pipx environment that has to move to another Python:
# pipx reinstall, or, when it was installed from a local folder that is
# gone (pipx reinstall needs the source), the repair in place.
pipx_fix_lines() {
    local v=$1 name=${1##*/} minor=$VENV_MINOR src py
    py="${PORT_PREFIX}/bin/python${minor:-3.X}"
    if [[ -z "${minor}" ]]; then
        echo "pipx reinstall $(shq "${name}") --python <a Python outside Homebrew, e.g. ${PORT_PREFIX}/bin/python3.X>"
        return 0
    fi
    [[ -x "${py}" ]] || echo "sudo port install python${minor//./}   (MacPorts' Python ${minor}, not installed yet)"
    src=$(pipx_source "${v}")
    case "${src}" in
        /* | ./* | ../* | "~"* | file:*)
            local path=${src#file://}
            if [[ ! -e "${path}" ]]; then
                echo "Installed from a local folder that no longer exists (${src}): pipx reinstall can't rebuild it."
                echo "Repair it in place, on a Python of the same version (${minor}):"
                echo "  ln -sfn $(shq "${py}") $(shq "${v}/bin/python${minor}")"
                echo "  sed -i '' -e 's#^home = .*#home = $(dirname "${py}")#' -e 's#^executable = .*#executable = ${py}#' $(shq "${v}/pyvenv.cfg")"
                return 0
            fi
            ;;
    esac
    echo "pipx reinstall $(shq "${name}") --python $(shq "${py}")"
}

# a. broken environments, b. environments on a Homebrew Python.
doctor_pipx() {
    local prefix=$1 home v name line n=0 before=${DOCTOR_PROBLEMS}
    home=$(pipx_home)
    if [[ -z "${home}" ]]; then
        info "pipx: no environment (${PIPX_HOME:-~/.local/pipx}): skipped."
        return 0
    fi
    for v in "${home}"/venvs/*; do
        [[ -d "${v}" ]] || continue
        n=$((n + 1))
        name=${v##*/}
        venv_inspect "${v}" "${prefix}"
        local -a fix=()
        if [[ "${VENV_BROKEN}" == true ]]; then
            while IFS= read -r line; do fix+=("${line}"); done < <(pipx_fix_lines "${v}")
            doctor_problem 1 "pipx environment ${name} is broken: its Python (${VENV_TARGET}) no longer exists, its commands fail." "${fix[@]}"
        elif [[ -n "${VENV_FORMULA}" ]]; then
            while IFS= read -r line; do fix+=("${line}"); done < <(pipx_fix_lines "${v}")
            if [[ -e "${prefix}/opt/${VENV_FORMULA}" ]]; then
                doctor_problem 1 "pipx environment ${name} runs on Homebrew's ${VENV_FORMULA}: it breaks as soon as that formula is uninstalled." "${fix[@]}"
            else
                doctor_problem 1 "pipx environment ${name}: its pyvenv.cfg still names Homebrew's ${VENV_FORMULA}, which is no longer installed." "${fix[@]}"
            fi
        fi
    done
    # The shared libraries (pip for every environment): pipx rebuilds them
    # by itself when their Python is gone, nothing to do.
    if [[ -d "${home}/shared" ]]; then
        venv_inspect "${home}/shared" "${prefix}"
        [[ "${VENV_BROKEN}" != true ]] ||
            info "${C_DIM}pipx shared libraries: their Python (${VENV_TARGET}) is gone; pipx rebuilds them by itself at its next install or upgrade.${C_RESET}"
    fi
    ((DOCTOR_PROBLEMS > before)) || ok "pipx: ${n} environment(s), all on a working Python outside Homebrew."
}

# ----------------------------------------------------------------------------
# c. Files in the Homebrew prefix that don't belong to you: brew cleanup
#    fails on them every run ("Permission denied @ apply2files"), mostly
#    __pycache__ directories written by "sudo python3" or a pkg installer
#    into site-packages. Only where brew manages and cleans: Cellar, opt,
#    lib/python3*/site-packages, and brew's links in bin, sbin, share,
#    etc. Files other vendors put in the prefix (/usr/local/bin/firebase,
#    /usr/local/lib/*.so of an SDK, /usr/local/podman) are theirs.
# ----------------------------------------------------------------------------
# doctor_not_yours <uid> <roots…> -- <link dirs…>: the paths that don't
# belong to <uid>, NUL-separated (a file name may hold a newline): the
# top-most one under each root (-prune), and brew's links (into the
# Cellar) in the link directories. A whole __pycache__ directory rather
# than each file in it. find fails on an unreadable directory: what it
# could read is kept, the run goes on.
doctor_not_yours() {
    local uid=$1 p target
    local -a roots=() links=()
    shift
    while (($# > 0)) && [[ "$1" != -- ]]; do
        roots+=("$1")
        shift
    done
    (($# == 0)) || shift
    links=("$@")
    {
        if ((${#roots[@]} > 0)); then
            find "${roots[@]}" ! -user "${uid}" -prune -print0 2>/dev/null || true
        fi
        if ((${#links[@]} > 0)); then
            find "${links[@]}" -type l ! -user "${uid}" -print0 2>/dev/null || true
        fi | while IFS= read -r -d '' p; do
            target=$(readlink "${p}" 2>/dev/null || true)
            [[ "${target}" != *Cellar/* ]] || printf '%s\0' "${p}"
        done
    } | while IFS= read -r -d '' p; do
        [[ "${p}" != */__pycache__/* ]] || p="${p%/__pycache__/*}/__pycache__"
        printf '%s\0' "${p}"
    done
    return 0
}

doctor_brew_ownership() {
    local prefix=$1 uid user p n i=0
    uid=$(id -u)
    user=$(id -un 2>/dev/null || echo "${uid}")
    local -a roots=() links=() found=()
    for p in "${prefix}/Cellar" "${prefix}/opt" "${prefix}"/lib/python3*/site-packages; do
        [[ -d "${p}" ]] && roots+=("${p}")
    done
    for p in bin sbin share etc; do
        [[ -d "${prefix}/${p}" ]] && links+=("${prefix}/${p}")
    done
    while IFS= read -r -d '' p; do
        found+=("${p}")
    done < <(doctor_not_yours "${uid}" "${roots[@]+"${roots[@]}"}" -- "${links[@]+"${links[@]}"}" | LC_ALL=C sort -zu)
    n=${#found[@]}
    if ((n == 0)); then
        ok "Homebrew prefix: everything brew manages belongs to you."
        return 0
    fi
    local -a fix=()
    for p in "${found[@]}"; do
        if ((i++ >= 10)); then
            fix+=("… $((n - 10)) more, see the log")
            break
        fi
        if [[ "${p}" == */__pycache__ ]]; then
            fix+=("sudo rm -rf $(shq "${p}")   (Python bytecode cache, rebuilt when needed)")
        else
            fix+=("ls -la $(shq "${p}")   then, if it's Homebrew's:   sudo chown -R $(shq "${user}") $(shq "${p}")")
        fi
    done
    log_detail "Not yours in ${prefix}: $(shq_all "${found[@]}")"
    doctor_problem "${n}" "${n} path(s) in ${prefix} don't belong to you: brew cleanup (and upgrades) fail on them." "${fix[@]}"
}

# ----------------------------------------------------------------------------
# d. PATH entries that lead nowhere: a removed JDK (/opt/openjdk@17/bin),
#    or <prefix>/opt/<formula>/bin of a formula that was uninstalled or
#    migrated. Harmless for the shell, but they hide the real problem
#    when a command is "not found", and they come back in every terminal.
# ----------------------------------------------------------------------------
doctor_path() {
    local prefix=$1 dir seen=":" f port where before=${DOCTOR_PROBLEMS}
    local -a dirs=()
    IFS=: read -r -a dirs <<<"${PATH}"
    for dir in "${dirs[@]+"${dirs[@]}"}"; do
        dir=${dir%/}
        [[ -n "${dir}" && "${seen}" != *":${dir}:"* ]] || continue
        seen+="${dir}:"
        # macOS's own entries (/etc/paths.d/10-cryptex): they only exist
        # while a cryptex is mounted.
        case "${dir}" in /var/run/com.apple.* | /System/*) continue ;; esac
        if [[ -n "${prefix}" && "${dir}" == "${prefix}/opt/"* && ! -e "${dir}" ]]; then
            f=${dir#"${prefix}/opt/"}
            f=${f%%/*}
            where=$(shell_rc_refs "${f}" "${prefix}" 2>/dev/null | cut -d: -f1,2 | sort -u | tr '\n' ' ' || true)
            # The formula, or a tap formula ending in /<formula>: compared
            # as text (python@3.12, libxml++ aren't regular expressions).
            port=$(awk -F'\t' -v f="${f}" '
                $1 == f || (length($1) > length(f) && substr($1, length($1) - length(f)) == "/" f) { print $2; exit }' \
                "${MIGRATED_FILE}" 2>/dev/null || true)
            local -a fix=()
            if [[ -n "${where}" ]]; then
                fix+=("Remove it from: ${where% }")
            else
                fix+=("Not in your shell startup files: look in the files they source.")
            fi
            [[ -z "${port}" ]] || fix+=("${f} was migrated to MacPorts (${port}): its commands are in ${PORT_PREFIX}/bin.")
            doctor_problem 1 "PATH: ${dir} belongs to the formula ${f}, which isn't installed." "${fix[@]}"
        elif [[ ! -d "${dir}" ]]; then
            where=$(rc_lines_with "${dir}" | sort -u | tr '\n' ' ' || true)
            if [[ -n "${where}" ]]; then
                doctor_problem 1 "PATH: ${dir} $([[ -e "${dir}" ]] && echo "isn't a directory" || echo "doesn't exist")." \
                    "Remove it from: ${where% }"
            else
                doctor_problem 1 "PATH: ${dir} $([[ -e "${dir}" ]] && echo "isn't a directory" || echo "doesn't exist")." \
                    "Not in your shell startup files nor /etc/paths.d: look in the files they source."
            fi
        fi
    done
    ((DOCTOR_PROBLEMS > before)) || ok "PATH: every entry exists."
}

# ----------------------------------------------------------------------------
# e. Java: a JDK link in /Library/Java/JavaVirtualMachines to a JDK that
#    was uninstalled. /usr/libexec/java_home then lists a JDK that doesn't
#    exist, and java can pick it and fail.
# ----------------------------------------------------------------------------
doctor_jvm() {
    local dir="${DOCTOR_ROOT}/Library/Java/JavaVirtualMachines" l before=${DOCTOR_PROBLEMS}
    if [[ ! -d "${dir}" ]]; then
        info "Java: no ${dir}: skipped."
        return 0
    fi
    for l in "${dir}"/*; do
        [[ -L "${l}" && ! -e "${l}" ]] || continue
        doctor_problem 1 "Java: ${l} points to $(readlink "${l}" 2>/dev/null || echo "?"), which no longer exists." \
            "sudo rm $(shq "${l}")"
    done
    ((DOCTOR_PROBLEMS > before)) || ok "Java: no broken JDK link."
}

# ----------------------------------------------------------------------------
# f. Empty directories in the Cellar: a failed install (Cellar/openvpn on
#    2026-10-17) leaves one, and brew list shows a formula that isn't
#    there.
# ----------------------------------------------------------------------------
doctor_cellar_empty() {
    local prefix=$1 d before=${DOCTOR_PROBLEMS}
    [[ -d "${prefix}/Cellar" ]] || return 0
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        doctor_problem 1 "Cellar: ${d} is empty (left by a failed install): brew lists ${d##*/} as installed." \
            "rmdir $(shq "${d}")"
    done < <(find "${prefix}/Cellar" -mindepth 1 -maxdepth 1 -type d -empty 2>/dev/null | sort)
    ((DOCTOR_PROBLEMS > before)) || ok "Cellar: no empty formula directory."
}

# ----------------------------------------------------------------------------
# g. npm global packages left behind by the node formula: they stay in
#    <prefix>/lib/node_modules with their links in <prefix>/bin, and fail
#    with "env: node: No such file or directory".
# ----------------------------------------------------------------------------
# npm global packages in <prefix>/lib/node_modules (@scope/name for
# scoped ones), one per line.
npm_global_packages() {
    local dir="$1/lib/node_modules" p s
    [[ -d "${dir}" ]] || return 0
    for p in "${dir}"/*; do
        [[ -d "${p}" ]] || continue
        if [[ "${p##*/}" == @* ]]; then
            # An empty @scope: the glob stays as is, not a directory.
            for s in "${p}"/*; do
                if [[ -d "${s}" ]]; then
                    printf '%s\n' "${p##*/}/${s##*/}"
                fi
            done
        else
            printf '%s\n' "${p##*/}"
        fi
    done
    return 0
}

# Is a node formula (node, node@22…) installed?
brew_has_node() {
    local d
    for d in "$1"/Cellar/node "$1"/Cellar/node@*; do
        [[ -d "${d}" ]] && return 0
    done
    return 1
}

# The node in <prefix>/bin when it isn't Homebrew's: a nodejs.org
# installer puts node, npm and npx in /usr/local/bin and its global
# packages in /usr/local/lib/node_modules, Homebrew's prefix on Intel.
# Those packages are that node's, not leftovers of a formula. Prints its
# path (empty: none, or Homebrew's link, working or not).
non_brew_node() {
    local prefix=$1 node="$1/bin/node" hop
    [[ -e "${node}" ]] || return 0
    while IFS= read -r hop; do
        case "${hop}" in "${prefix}"/Cellar/* | "${prefix}"/opt/*) return 0 ;; esac
    done < <(link_hops "${node}")
    printf '%s' "${node}"
}

doctor_npm() {
    local prefix=$1 pkgs l target node
    pkgs=$(npm_global_packages "${prefix}")
    if [[ -z "${pkgs}" ]]; then
        ok "npm: no global package in ${prefix}/lib/node_modules."
        return 0
    fi
    if brew_has_node "${prefix}"; then
        ok "npm: the global packages in ${prefix}/lib/node_modules have their node formula."
        return 0
    fi
    node=$(non_brew_node "${prefix}")
    if [[ -n "${node}" ]]; then
        ok "npm: the global packages in ${prefix}/lib/node_modules belong to ${node} (not Homebrew's node): left alone."
        return 0
    fi
    # Their commands start with "#!/usr/bin/env node": another node in
    # the PATH (MacPorts') runs them. Not removed then: only reported.
    node=$(command -v node 2>/dev/null || true)
    if [[ -n "${node}" ]] && "${node}" --version >/dev/null 2>&1; then
        info "npm: $(count_lines "${pkgs}") global package(s) in ${prefix}/lib/node_modules without a node formula; their commands run on ${node}: left alone."
        return 0
    fi
    local -a fix=() rm_pkgs=() rm_links=() names=()
    while IFS= read -r l; do
        rm_pkgs+=("${prefix}/lib/node_modules/${l}")
        [[ "${l}" == npm || "${l}" == corepack ]] || names+=("${l}")
    done <<<"${pkgs}"
    # Only the links into node_modules: their node is gone with the
    # formula (node itself, if still there, is a dead link into the Cellar).
    while IFS= read -r -d '' l; do
        target=$(readlink "${l}" 2>/dev/null || true)
        if [[ "${target}" == *lib/node_modules/* ]]; then
            rm_links+=("${l}")
        fi
    done < <(find "${prefix}/bin" -mindepth 1 -maxdepth 1 -type l -print0 2>/dev/null || true)
    fix+=("Packages: $(tr '\n' ' ' <<<"${pkgs}")")
    fix+=("rm -rf $(shq_all "${rm_pkgs[@]}")")
    ((${#rm_links[@]} == 0)) || fix+=("rm $(shq_all "${rm_links[@]}")")
    ((${#names[@]} == 0)) || fix+=("To keep using them: install node with MacPorts (port search --name nodejs), then npm install -g $(shq_all "${names[@]}")")
    doctor_problem 1 "npm: $(count_lines "${pkgs}") global package(s) in ${prefix}/lib/node_modules, but no node formula: their commands can't run." "${fix[@]}"
}

# ----------------------------------------------------------------------------
# h. Migrated ports that MacPorts doesn't know you want: installed as a
#    dependency before the migration, they are "leaves" for MacPorts, and
#    "sudo port uninstall leaves" would remove the commands you migrated
#    to (2026-10-17: go, autoconf, libtool… 9 ports).
# ----------------------------------------------------------------------------
doctor_port_requested() {
    local migrated requested installed p
    migrated=$(migrated_port_names)
    if [[ -z "${migrated}" ]]; then
        ok "MacPorts: no migrated port to check (${MIGRATED_FILE##*/} empty or absent)."
        return 0
    fi
    if ! port_ro -q echo requested; then
        warn "MacPorts: port echo requested failed: migrated ports not checked (see the log)."
        return 0
    fi
    requested=$(awk 'NF { print $1 }' <<<"${PORT_LAST_OUT}" | sort -u)
    if ! port_ro -q echo installed; then
        warn "MacPorts: port echo installed failed: migrated ports not checked (see the log)."
        return 0
    fi
    installed=$(awk 'NF { print $1 }' <<<"${PORT_LAST_OUT}" | sort -u)
    local -a unrequested=() missing=()
    while IFS= read -r p; do
        if ! grep -qxF "${p}" <<<"${installed}"; then
            missing+=("${p}")
        elif ! grep -qxF "${p}" <<<"${requested}"; then
            unrequested+=("${p}")
        fi
    done <<<"${migrated}"
    if ((${#unrequested[@]} > 0)); then
        doctor_problem "${#unrequested[@]}" "MacPorts: ${#unrequested[@]} migrated port(s) marked as a dependency only: \"sudo port uninstall leaves\" would remove them." \
            "sudo port setrequested $(shq_all "${unrequested[@]}")"
    fi
    if ((${#missing[@]} > 0)); then
        doctor_problem "${#missing[@]}" "MacPorts: ${#missing[@]} port(s) recorded as migrated aren't installed any more: their commands are gone." \
            "sudo port install $(shq_all "${missing[@]}")   (or remove their line from ${MIGRATED_FILE} if you dropped them)"
    fi
    ((${#unrequested[@]} + ${#missing[@]} > 0)) ||
        ok "MacPorts: the $(count_lines "${migrated}") migrated port(s) are installed and marked as requested."
}

# ----------------------------------------------------------------------------
# i. Casks from a third-party tap Homebrew no longer trusts: it refuses to
#    load them ("Refusing to load cask … from untrusted tap"), so they are
#    never upgraded, and can't be uninstalled until trusted. The tap of
#    each cask is in its install receipt; only casks from a third-party
#    tap are asked about (one brew info each).
# ----------------------------------------------------------------------------
doctor_untrusted_casks() {
    local caskroom d tap token out unknown=0 before=${DOCTOR_PROBLEMS}
    local -a third=()
    caskroom=$(brew --caskroom 2>/dev/null) || caskroom=""
    if [[ -z "${caskroom}" || ! -d "${caskroom}" ]]; then
        ok "Casks: none installed."
        return 0
    fi
    for d in "${caskroom}"/*; do
        [[ -d "${d}" ]] || continue
        tap=$(sed -nE 's/.*"tap"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${d}/.metadata/INSTALL_RECEIPT.json" 2>/dev/null | head -n 1 || true)
        if [[ -z "${tap}" ]]; then
            unknown=$((unknown + 1))
        elif [[ "${tap}" != homebrew/* ]]; then
            third+=("${tap}/${d##*/}")
        fi
    done
    for token in "${third[@]+"${third[@]}"}"; do
        out=$(brew info --cask "${token}" 2>&1 || true)
        log_detail "brew info --cask ${token}: $(head -n 3 <<<"${out}" | tr '\n' ' ')"
        if grep -qi 'untrusted tap' <<<"${out}"; then
            tap=${token%/*}
            doctor_problem 1 "Cask ${token##*/}: Homebrew refuses to load it (untrusted tap ${tap}): never upgraded, can't be uninstalled." \
                "To keep it:    brew trust --cask $(shq "${token}")" \
                "To remove it:  brew trust --cask $(shq "${token}") && brew uninstall --cask $(shq "${token}") && brew untap $(shq "${tap}")"
        fi
    done
    ((unknown == 0)) || log_detail "Casks without an install receipt (tap unknown, not checked): ${unknown}"
    ((DOCTOR_PROBLEMS > before)) ||
        ok "Casks: ${#third[@]} from a third-party tap, none refused by Homebrew$( ((unknown == 0)) || echo " (${unknown} too old to tell, not checked)")."
}

# ----------------------------------------------------------------------------
# j. Command Line Tools: an update over an older version can leave its
#    libc++ headers in CommandLineTools/usr/include/c++, which then break
#    C++ builds (MacPorts ProblemHotlist, "clts16"). Stale only once the
#    headers moved into the SDK: Command Line Tools 16 or later, or an SDK
#    that has its own usr/include/c++/v1. Before that, they are the
#    headers in use.
# ----------------------------------------------------------------------------
# Major version of the installed Command Line Tools (16), empty if
# unknown. The receipt is read on DOCTOR_ROOT's volume (tests: a fake
# root, no receipt there).
clt_major_version() {
    local v
    command -v pkgutil >/dev/null 2>&1 || return 0
    v=$(pkgutil --volume "${DOCTOR_ROOT:-/}" --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null |
        awk '$1 == "version:" { print $2; exit }' || true)
    v=${v%%.*}
    [[ "${v}" =~ ^[0-9]+$ ]] && printf '%s' "${v}"
    return 0
}

doctor_clt_headers() {
    local clt="${DOCTOR_ROOT}/Library/Developer/CommandLineTools" dir major sdk why=""
    dir="${clt}/usr/include/c++"
    if [[ ! -d "${dir}" ]]; then
        ok "Command Line Tools: no stale C++ headers."
        return 0
    fi
    major=$(clt_major_version)
    if [[ -n "${major}" ]] && ((major >= 16)); then
        why="Command Line Tools ${major} keep them in the SDK"
    else
        for sdk in "${clt}"/SDKs/*.sdk; do
            if [[ -d "${sdk}/usr/include/c++/v1" ]]; then
                why="the SDK has its own (${sdk##*/})"
                break
            fi
        done
    fi
    if [[ -n "${why}" ]]; then
        doctor_problem 1 "Command Line Tools: stale C++ headers in ${dir} (${why}) break C++ builds (https://trac.macports.org/wiki/ProblemHotlist)." \
            "sudo rm -rf $(shq "${dir}")"
    else
        ok "Command Line Tools: C++ headers in ${dir} are the ones in use (no newer ones in the SDK)."
    fi
}

# ----------------------------------------------------------------------------
# --doctor
# ----------------------------------------------------------------------------
# Always returns 0 (see main): the verdict is in DOCTOR_RC.
doctor_run() {
    section "Health check (read-only)"
    say "${C_DIM}Nothing is changed: each problem comes with the command that fixes it.${C_RESET}"
    local prefix=""
    [[ "${HAS_BREW}" != true ]] || prefix=$(doctor_brew_prefix)

    doctor_pipx "${prefix}"
    if [[ -n "${prefix}" ]]; then
        doctor_brew_ownership "${prefix}"
    elif [[ "${HAS_BREW}" == true ]]; then
        warn "brew --prefix failed: Homebrew checks skipped (see the log)."
    else
        info "Homebrew not found: Homebrew checks skipped."
    fi
    doctor_path "${prefix}"
    doctor_jvm
    if [[ -n "${prefix}" ]]; then
        doctor_cellar_empty "${prefix}"
        doctor_npm "${prefix}"
        doctor_untrusted_casks
    fi
    if [[ "${HAS_PORT}" == true ]]; then
        doctor_port_requested
    else
        info "MacPorts not found: MacPorts checks skipped."
    fi
    doctor_clt_headers

    say ""
    if ((DOCTOR_PROBLEMS == 0)); then
        ok "No problem found."
    else
        warn "${DOCTOR_PROBLEMS} problem(s) found. praetorian changed nothing: the commands above fix them."
    fi
    # shellcheck disable=SC2034  # read by main (../praetorian)
    DOCTOR_RC=$((DOCTOR_PROBLEMS == 0 ? 0 : 2))
    say "Log: ${C_DIM}${LOG_FILE}${C_RESET}"
    return 0
}

# ----------------------------------------------------------------------------
# formula_external_users <formula>: programs outside Homebrew that use the
# formula, one per line ("pipx environment ansible-core (python3.14 from
# python@3.14)"). Empty: none found. Used before a formula is uninstalled
# (--migrate, --prune): brew uses only knows about other formulae.
#   - python@X.Y: pipx environments whose Python is that formula;
#   - node, node@*: npm global packages in <prefix>/lib/node_modules
#     (npm and corepack aside: they come with node), unless the node in
#     <prefix>/bin isn't Homebrew's (non_brew_node): they are its own.
# Fast (files only, no brew call but a cached brew --prefix), and never
# fails its caller: always returns 0.
# ----------------------------------------------------------------------------
formula_external_users() {
    local f=${1##*/} prefix home v p
    prefix=$(doctor_brew_prefix)
    case "${f}" in
        python@*)
            home=$(pipx_home)
            [[ -n "${home}" ]] || return 0
            for v in "${home}"/venvs/*; do
                [[ -d "${v}" ]] || continue
                venv_inspect "${v}" "${prefix}"
                [[ "${VENV_FORMULA}" == "${f}" ]] &&
                    echo "pipx environment ${v##*/} (python${VENV_MINOR} from ${f})"
            done
            ;;
        node | node@*)
            [[ -n "${prefix}" ]] || return 0
            # A nodejs.org node in the prefix: the packages are its own.
            [[ -z "$(non_brew_node "${prefix}")" ]] || return 0
            while IFS= read -r p; do
                [[ -n "${p}" && "${p}" != npm && "${p}" != corepack ]] &&
                    echo "npm global package ${p} (in ${prefix}/lib/node_modules, runs on ${f})"
            done < <(npm_global_packages "${prefix}")
            ;;
    esac
    return 0
}
