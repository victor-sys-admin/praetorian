# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — Homebrew → MacPorts migration
#
# --migration-report (read-only plan), --migrate (check, install, check,
# and only then uninstall the formula) and --migrate-all (every formula
# the plan finds ready, one session).
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# Homebrew → MacPorts names
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

# The highest terraform-1.N port: from the list of available ports when
# given, otherwise from "port echo" (read-only). terraform-1.16 if none.
latest_terraform_port() {
    local all=$1 best
    if [[ -z "${all}" ]]; then
        port_ro echo 'terraform-1.*' || true
        all=${PORT_LAST_OUT}
    fi
    best=$(awk '$1 ~ /^terraform-1\.[0-9]+$/ { split($1, a, "."); if (a[2] + 0 >= m) { m = a[2] + 0; best = $1 } }
        END { print best }' <<<"${all}")
    printf '%s' "${best:-terraform-1.16}"
}

# Known traps, learned migrating a real Mac (2026-10-17): formulae whose
# MacPorts port under the same name is another project or an obsolete
# series, or that need companion ports. Checked against the MacPorts index
# of that day.
# known_port_spec <formula> ["<available ports>"]: "<port>[,<port>…]<TAB>
# <why>", nothing for a formula not in the table.
known_port_spec() {
    local f=$1 all=${2:-} short v ports="" why=""
    short=${f##*/}
    case "${f}" in
        hashicorp/tap/terraform) ;;
        */*) return 0 ;; # other taps: their name says nothing about MacPorts
    esac
    case "${short}" in
        step)
            ports="step-cli,step-ca"
            why="MacPorts' \"step\" is a KDE program (a physics simulator); smallstep's step command is step-cli, its certificate authority step-ca."
            ;;
        ansible)
            ports="py-ansible"
            why="MacPorts ships Ansible as a Python package: py-ansible."
            ;;
        guile)
            ports="guile-3.0"
            why="MacPorts' \"guile\" is an obsolete stub; the Guile 3 Homebrew installs is guile-3.0 (with port select)."
            ;;
        docker-compose)
            ports="docker-compose-plugin"
            why="Compose v2 as Homebrew ships it is docker-compose-plugin in MacPorts."
            ;;
        cmake)
            ports="cmake-devel"
            why="MacPorts' \"cmake\" is the older 3.x series; Homebrew's cmake 4 is cmake-devel."
            ;;
        terraform)
            ports=$(latest_terraform_port "${all}")
            why="MacPorts ships one port per Terraform version (terraform-1.N), linked as \"terraform\" by port select."
            ;;
        imagemagick)
            ports="ImageMagick7"
            why="MacPorts' \"ImageMagick\" is the legacy 6.x series; ImageMagick 7 is ImageMagick7."
            ;;
        p7zip)
            ports="7zip"
            why="p7zip is no longer maintained; MacPorts ships the official 7-Zip: 7zip."
            ;;
        jpeg-xl)
            ports="libjxl"
            why="MacPorts names JPEG XL after its library: libjxl."
            ;;
        make)
            ports="gmake"
            why="GNU make is gmake in MacPorts (make is the one of macOS)."
            ;;
        ant)
            ports="apache-ant"
            why="Ant is apache-ant in MacPorts."
            ;;
        rust)
            ports="rust,cargo"
            why="MacPorts splits Rust in two: rust (the compiler) and cargo."
            ;;
        node)
            ports="nodejs24,npm11"
            why="MacPorts ships one port per Node.js major version and npm on its own (nodejs26 has no binary for macOS 15 on Intel)."
            ;;
        gnupg)
            ports="gnupg2"
            why="GnuPG 2 is gnupg2 in MacPorts."
            ;;
        gstreamer)
            ports="gstreamer1"
            why="GStreamer 1.x is gstreamer1 in MacPorts."
            ;;
        libpq)
            ports="postgresql18"
            why="MacPorts has no separate libpq: the client library and tools come with postgresql18."
            ;;
        mysql-client)
            ports="mysql-innovation"
            why="The MySQL client comes with a server port in MacPorts: mysql-innovation is the current series."
            ;;
        openjdk@17)
            ports="openjdk17"
            why="MacPorts names each JDK version openjdkNN."
            ;;
        python@3.*)
            v=${short#python@}
            [[ "${v}" =~ ^3\.[0-9]+$ ]] || return 0
            ports="python${v//./}"
            why="MacPorts names each Python version pythonXY (python@3.12 → python312)."
            ;;
        postgresql@*)
            v=${short#postgresql@}
            [[ "${v}" =~ ^[0-9]+$ ]] || return 0
            ports="postgresql${v}"
            why="MacPorts names each PostgreSQL version postgresqlNN."
            ;;
    esac
    [[ -z "${ports}" ]] || printf '%s\t%s\n' "${ports}" "${why}"
    return 0
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
# The known traps (known_port_spec) come first: see migration_classify.
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

# ----------------------------------------------------------------------------
# Same software? Homebrew and MacPorts homepages compared
#
# A port with the formula's name can be another project (MacPorts' "step"
# is a KDE program, smallstep's is step-cli). The homepages tell them
# apart without a table: same site, same GitHub repository, or a
# code-hosting organization named like the other site
# (github.com/ansible/ansible and ansible.com) count as the same project.
# ----------------------------------------------------------------------------
# brew_homepages formula…: "<formula><TAB><homepage>" per formula Homebrew
# knows, from brew info --json=v2 read with awk (no JSON tool needed:
# only the formula-level keys, at the indentation of the first
# "full_name"). One call; when it fails (one unknown name makes brew
# refuse them all), one call per formula.
brew_homepages() {
    local out f
    (($# > 0)) || return 0
    if out=$(brew info --json=v2 "$@" 2>>"${LOG_FILE}"); then
        brew_homepages_parse <<<"${out}"
        return 0
    fi
    for f in "$@"; do
        out=$(brew info --json=v2 "${f}" 2>>"${LOG_FILE}") || continue
        brew_homepages_parse <<<"${out}"
    done
    return 0
}

brew_homepages_parse() {
    awk '
        /^ *"full_name": "/ {
            ind = match($0, /[^ ]/); if (top == 0) top = ind
            if (ind == top) { name = $0; sub(/^ *"full_name": "/, "", name); sub(/".*/, "", name) }
            next
        }
        /^ *"homepage": "/ && name != "" && match($0, /[^ ]/) == top {
            h = $0; sub(/^ *"homepage": "/, "", h); sub(/".*/, "", h)
            print name "\t" h; name = ""
        }'
}

# homepage_verdict <url> <url>: "match", "mismatch", or "unknown" (one of
# them empty or unreadable, or nothing that tells: same organization but
# not the same repository named, two subdomains of one site…). Anything
# ambiguous is "unknown", never "match": a match puts the formula in
# --migrate-all's list. Compared without scheme, "www.", query, trailing
# "/", index.html or .html, ".git", case.
# - Code hosting (github.com…): organization and repository both equal.
# - Shared sites (SourceForge, GNU, PyPI, code.google.com, *.github.io,
#   cli.github.com…): the same host and the same project part of the
#   path; none named (sourceforge.net/ alone) is "unknown".
# - Other sites: the same host, or one of them the bare registrable domain
#   (legacy.imagemagick.org = imagemagick.org); two other subdomains of
#   one domain are "unknown".
# - Code hosting and a site: the organization named like the site
#   (github.com/ansible/ansible and ansible.com); only the repository
#   named like it (github.com/alice/foo and foo.org) is "unknown".
homepage_verdict() {
    [[ -n "$1" && -n "$2" ]] || {
        echo unknown
        return 0
    }
    awk -v a="$1" -v b="$2" '
        function regdom(h, n, l) {
            n = split(h, l, ".")
            if (n < 2) return h
            if (n >= 3 && length(l[n]) == 2 && l[n - 1] ~ /^(co|com|org|net|ac|gov|edu)$/)
                return l[n - 2] "." l[n - 1] "." l[n]
            return l[n - 1] "." l[n]
        }
        # Code hosting: the project is the organization and the repository.
        function codehost(h) { return h ~ /^(github\.com|gitlab\.com|codeberg\.org|bitbucket\.org|git\.sr\.ht|sr\.ht)$/ }
        # Multi-tenant hosts: projects in the path, the host names none.
        function tenant(h) {
            return h ~ /^(code\.google\.com|hackage\.haskell\.org|cran\.r-project\.org|rubygems\.org|ctan\.org|metacpan\.org|pypi\.org|npmjs\.com|crates\.io|launchpad\.net|sourceforge\.net|sf\.net|gnu\.org|nongnu\.org|freedesktop\.org|apache\.org|kde\.org|gnome\.org|macports\.org)$/
        }
        # Shared sites: the project is the host and the path.
        function shared(h, d) {
            return tenant(h) || tenant(d) || d ~ /^(github\.io|gitlab\.io|readthedocs\.io|github\.com|gitlab\.com|codeberg\.org)$/
        }
        # Path parts that hold projects rather than name one.
        function container(x) { return x ~ /^(p|package|packages|software|project|projects|pkg|gems|dist|release|pod|web|wiki|apps)$/ }
        # parse <url> <side>: T[side] ("code", "site" or ""), ORG, REPO,
        # HOST, DOM, SHR, PROJ (project part of the path, "?" when none is
        # named), LABEL (the site name), PNAME (last part of PROJ).
        function parse(u, k, i, h, p, n, s, j, m) {
            u = tolower(u)
            sub(/^[a-z+.-]+:\/\//, "", u); sub(/[?#].*$/, "", u)
            h = u; p = ""
            if ((i = index(u, "/")) > 0) { h = substr(u, 1, i - 1); p = substr(u, i + 1) }
            sub(/:[0-9]+$/, "", h); sub(/^www\./, "", h)
            sub(/(^|\/)index\.(html?|php)$/, "", p); sub(/\.(html?|php)$/, "", p); sub(/\/+$/, "", p)
            T[k] = ""
            if (h == "" || h !~ /\./) return
            n = split(p, s, "/")
            if (codehost(h)) {
                T[k] = "code"; ORG[k] = (n >= 1) ? s[1] : ""; REPO[k] = (n >= 2) ? s[2] : ""
                sub(/\.git$/, "", REPO[k])
                return
            }
            T[k] = "site"; HOST[k] = h; DOM[k] = regdom(h); SHR[k] = shared(h, DOM[k])
            LABEL[k] = substr(DOM[k], 1, index(DOM[k], ".") - 1); PROJ[k] = ""; PNAME[k] = ""
            if (!SHR[k]) return
            # A shared site: the host names the project only on a project
            # subdomain (foo.sourceforge.net, foo.github.io).
            LABEL[k] = (h != DOM[k] && DOM[k] ~ /^(sourceforge\.net|sf\.net|github\.io|gitlab\.io|readthedocs\.io|apache\.org)$/) ? substr(h, 1, index(h, ".") - 1) : ""
            # The path: its first two parts, more while they only hold
            # projects (cran.r-project.org/web/packages/foo).
            m = 0
            for (j = 1; j <= n && j <= 4; j++) {
                PROJ[k] = PROJ[k] (j > 1 ? "/" : "") s[j]
                m = j
                if (j >= 2 && !container(s[j])) break
            }
            if ((m == 0 && tenant(h)) || (m >= 1 && container(s[m]))) PROJ[k] = "?"
            else if (m >= 1) PNAME[k] = s[m]
        }
        # named <side> <name>: the site or its project is called <name>.
        function named(k, x) { return x != "" && (LABEL[k] == x || PNAME[k] == x) }
        # code_site <code side> <site side>
        function code_site(c, w) {
            if (ORG[c] == "") return "unknown"
            if (LABEL[w] != "" && ORG[c] == LABEL[w]) return "match"
            if (named(w, REPO[c]) || named(w, ORG[c])) return "unknown"
            return "mismatch"
        }
        function verdict() {
            parse(a, 1); parse(b, 2)
            if (T[1] == "" || T[2] == "") return "unknown"
            if (T[1] == "code" && T[2] == "code") {
                if (ORG[1] == "" || ORG[2] == "") return "unknown"
                if (ORG[1] != ORG[2]) return "mismatch"
                if (REPO[1] == "" || REPO[2] == "") return "unknown"
                return (REPO[1] == REPO[2]) ? "match" : "mismatch"
            }
            if (T[1] == "code") return code_site(1, 2)
            if (T[2] == "code") return code_site(2, 1)
            if (SHR[1] || SHR[2]) {
                if (HOST[1] != HOST[2]) return (named(1, LABEL[2]) || named(1, PNAME[2])) ? "unknown" : "mismatch"
                if (PROJ[1] == "?" || PROJ[2] == "?") return "unknown"
                return (PROJ[1] == PROJ[2]) ? "match" : "mismatch"
            }
            if (DOM[1] != DOM[2]) return "mismatch"
            if (HOST[1] == HOST[2] || HOST[1] == DOM[1] || HOST[2] == DOM[2]) return "match"
            return "unknown"
        }
        BEGIN { print verdict() }'
}

# ----------------------------------------------------------------------------
# Precompiled binaries on packages.macports.org
#
# MacPorts installs a port from a precompiled archive when the build bots
# made one for this macOS and architecture; otherwise it compiles it from
# source, which is what the move away from Homebrew was meant to avoid
# (2026-10-17: nodejs26 and every mysql port had no binary for macOS 15 on
# Intel). The archive is checked with a HEAD request (nothing downloaded),
# by its exact name: <port>-<version>_<revision><default variants>.
# darwin_<major>.<arch>.tbz2, or a noarch one.
# ----------------------------------------------------------------------------
readonly PORT_PACKAGES_URL="https://packages.macports.org"
BINARY_CHECK_TIMEOUT=10 # seconds per request (the report uses less)

# port_meta <port>: "version<TAB>revision<TAB>homepage<TAB>license" (port
# info --line), non-zero when port doesn't know the port.
port_meta() {
    port_ro info --line --version --revision --homepage --license "$1" || return 1
    awk -F '\t' 'NF >= 4 { line = $0 } END { if (line == "") exit 1; print line }' <<<"${PORT_LAST_OUT}"
}

# Default variants of a port as they appear in its archive name
# ("+gnutls", "+lto+optimizations"), sorted like MacPorts does.
port_default_variants() {
    port_ro variants "$1" || return 0
    sed -nE 's/^\[\+\]([A-Za-z0-9_]+):.*/\1/p' <<<"${PORT_LAST_OUT}" | LC_ALL=C sort -u |
        awk '{ printf "+%s", $0 }'
}

# port_binary_status <port> [quick]: "yes" (an archive for this Mac
# exists), "no" (none: MacPorts would compile it), "restricted" (license
# MacPorts may not redistribute: never an archive, it's built here, often
# by only repackaging the vendor's binary), "offline" (no answer from
# packages.macports.org) or "unknown" (no curl, unexpected platform or
# port data). quick: only the archive for this architecture (one request).
# Only "no" may block: never a guess.
port_binary_status() {
    local p=$1 quick=${2:-} meta version revision license arch major variants suffix url rc
    if [[ ! "${p}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || ! command -v curl >/dev/null 2>&1; then
        echo unknown
        return 0
    fi
    arch=$(uname -m)
    major=$(uname -r)
    major=${major%%.*}
    if [[ "${arch}" != x86_64 && "${arch}" != arm64 ]] || [[ ! "${major}" =~ ^[0-9]+$ ]]; then
        echo unknown
        return 0
    fi
    if ! meta=$(port_meta "${p}"); then
        echo unknown
        return 0
    fi
    version=$(cut -f1 <<<"${meta}")
    revision=$(cut -f2 <<<"${meta}")
    license=$(cut -f4 <<<"${meta}")
    # Only these characters ever reach the URL.
    if [[ ! "${version}" =~ ^[A-Za-z0-9._+-]+$ || ! "${revision}" =~ ^[0-9]+$ ]]; then
        echo unknown
        return 0
    fi
    if grep -qiwE 'commercial|restrictive|nomirror' <<<"${license//Restrictive\/Distributable/}"; then
        echo restricted
        return 0
    fi
    variants=$(port_default_variants "${p}")
    if [[ -n "${variants}" && ! "${variants}" =~ ^(\+[A-Za-z0-9_]+)+$ ]]; then
        echo unknown
        return 0
    fi
    local -a suffixes=("darwin_${major}.${arch}")
    [[ -n "${quick}" ]] || suffixes+=("darwin_${major}.noarch" "darwin_any.noarch" "any_any.noarch")
    for suffix in "${suffixes[@]}"; do
        url="${PORT_PACKAGES_URL}/${p}/${p}-${version}_${revision}${variants}.${suffix}.tbz2"
        rc=0
        curl -fsSI --proto =https --max-time "${BINARY_CHECK_TIMEOUT}" -o /dev/null "${url}" 2>>"${LOG_FILE}" || rc=$?
        log_detail "Binary archive: ${url} (curl rc ${rc})"
        case "${rc}" in
            0)
                echo yes
                return 0
                ;;
            22) ;; # HTTP error (404): not there, next name
            *)
                echo offline
                return 0
                ;;
        esac
    done
    echo no
}

# port_binary_sibling <port>: for a versioned port (nodejs26, python314),
# the closest older version with a binary for this Mac, if any. At most 4
# versions tried, one request each.
port_binary_sibling() {
    local p=$1 base num c n=0
    [[ "${p}" =~ ^(.*[^0-9])([0-9]+)$ ]] || return 0
    base=${BASH_REMATCH[1]}
    num=${BASH_REMATCH[2]}
    port_ro echo "${base}*" || return 0
    while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        ((n++ < 4)) || break
        if [[ "$(port_binary_status "${c}" quick)" == yes ]]; then
            printf '%s' "${c}"
            return 0
        fi
    done < <(awk -v b="${base}" -v n="${num}" 'index($1, b) == 1 {
            v = substr($1, length(b) + 1); if (v ~ /^[0-9]+$/ && v + 0 < n + 0) print v "\t" $1 }' \
        <<<"${PORT_LAST_OUT}" | sort -rn | cut -f2)
    return 0
}

# "macOS 15 (darwin 24) on x86_64", for the messages.
binary_platform() {
    local major
    major=$(uname -r)
    printf 'macOS %s (darwin %s) on %s' "$(sw_vers -productVersion 2>/dev/null || echo '?')" "${major%%.*}" "$(uname -m)"
}

# ----------------------------------------------------------------------------
# Shell startup files and services
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# The plan: --migration-report prints it, --migrate-all runs its ready part
# ----------------------------------------------------------------------------
# Filled by migration_classify (bash 3.2: no namerefs, hence globals).
PLAN_LEAVES=""              # brew leaves
declare -a PLAN_SAME=()     # same name, not a known trap, homepage not different
declare -a PLAN_DIFFER=()   # same name, but the homepages differ
declare -a PLAN_APPROX=()   # known trap or probably another name
declare -a PLAN_NONE=()     # nothing found
declare -a PLAN_READY=()    # what --migrate-all migrates
PLAN_HAS_NOTES=false        # some [ ] note shown
PLAN_BINARY_CHECKED=0       # ports whose binary was looked for
PLAN_BINARY_MISSING=0       # …and had none
PLAN_BINARY_SKIPPED=0       # not checked (limit reached, or offline)
PLAN_BINARY_OFFLINE=false   # packages.macports.org didn't answer
readonly PLAN_BINARY_MAX=40 # ports checked at most by one report

# plan_binary_note <port>…: sets PLAN_BNOTE to " [no binary for this Mac:
# <ports>]" for the ports packages.macports.org has no archive of, empty
# otherwise (a global, not printed: the counters must survive). Bounded:
# PLAN_BINARY_MAX ports per report, none once the site stopped answering.
PLAN_BNOTE=""
plan_binary_note() {
    local q status missing=""
    PLAN_BNOTE=""
    for q in "$@"; do
        if [[ "${PLAN_BINARY_OFFLINE}" == true ]] || ((PLAN_BINARY_CHECKED >= PLAN_BINARY_MAX)); then
            PLAN_BINARY_SKIPPED=$((PLAN_BINARY_SKIPPED + 1))
            continue
        fi
        PLAN_BINARY_CHECKED=$((PLAN_BINARY_CHECKED + 1))
        status=$(port_binary_status "${q}")
        case "${status}" in
            no)
                PLAN_BINARY_MISSING=$((PLAN_BINARY_MISSING + 1))
                missing+="${missing:+ }${q}"
                ;;
            offline) PLAN_BINARY_OFFLINE=true ;;
        esac
    done
    [[ -z "${missing}" ]] || PLAN_BNOTE=" [no binary for this Mac: ${missing}]"
    return 0
}

# migration_classify [binaries]: sorts every formula of brew leaves (see
# the PLAN_* globals). With "binaries", also looks for the precompiled
# archive of each port proposed (the report; --migrate-all leaves that to
# each migration). A problem with MacPorts or Homebrew: explained block.
# Read-only.
migration_classify() {
    local check_binaries=${1:-}
    PLAN_LEAVES="" PLAN_HAS_NOTES=false
    PLAN_SAME=() PLAN_DIFFER=() PLAN_APPROX=() PLAN_NONE=() PLAN_READY=()
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
    [[ "${check_binaries}" != binaries ]] || BINARY_CHECK_TIMEOUT=5

    local prefix f known kports cands notes bnote meta port_hp brew_hp verdict homepages
    PLAN_LEAVES=$(brew leaves 2>>"${LOG_FILE}" || true)
    prefix=$(brew --prefix 2>/dev/null) || prefix=""
    # Homepages of the formulae with a port of the same name, one brew call.
    local -a same_name=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        grep -qxF "${f}" <<<"${all}" && same_name+=("${f}")
    done <<<"${PLAN_LEAVES}"
    homepages=$(brew_homepages "${same_name[@]+"${same_name[@]}"}")

    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        notes=$(migration_notes "${f}" "${prefix}")
        known=$(known_port_spec "${f}" "${all}")
        kports=${known%%$'\t'*}
        if [[ -n "${known}" ]] && grep -qxF "${kports%%,*}" <<<"${all}"; then
            # A known trap: the right spec, never the same-name port.
            bnote=""
            if [[ "${check_binaries}" == binaries ]]; then
                local -a kp=()
                IFS=, read -r -a kp <<<"${kports}"
                plan_binary_note "${kp[@]}"
                bnote=${PLAN_BNOTE}
            fi
            [[ -z "${notes}${bnote}" ]] || PLAN_HAS_NOTES=true
            PLAN_APPROX+=("${f} → ${kports} ${C_DIM}(praetorian --migrate ${f}=${kports})${C_RESET}${notes}${bnote}")
        elif grep -qxF "${f}" <<<"${all}"; then
            brew_hp=$(awk -F '\t' -v f="${f}" '$1 == f { print $2; exit }' <<<"${homepages}")
            port_hp=""
            if meta=$(port_meta "${f}"); then port_hp=$(cut -f3 <<<"${meta}"); fi
            verdict=$(homepage_verdict "${brew_hp}" "${port_hp}")
            if [[ "${verdict}" == mismatch ]]; then
                [[ -z "${notes}" ]] || PLAN_HAS_NOTES=true
                PLAN_DIFFER+=("${f} ${C_DIM}(Homebrew: ${brew_hp} — MacPorts: ${port_hp})${C_RESET}${notes}")
                continue
            fi
            bnote=""
            if [[ "${check_binaries}" == binaries ]]; then
                plan_binary_note "${f}"
                bnote=${PLAN_BNOTE}
            fi
            [[ -z "${notes}${bnote}" ]] || PLAN_HAS_NOTES=true
            if [[ "${verdict}" == match ]]; then
                PLAN_SAME+=("${f}${notes}${bnote}")
                [[ -n "${notes}${bnote}" ]] || PLAN_READY+=("${f}")
            else
                PLAN_SAME+=("${f} ${C_DIM}(homepage not compared)${C_RESET}${notes}${bnote}")
            fi
        else
            cands=$(port_candidates "${f}" "${all}")
            [[ -z "${notes}" ]] || PLAN_HAS_NOTES=true
            if [[ -n "${cands}" ]]; then
                PLAN_APPROX+=("${f} → ${cands}${notes}")
            else
                PLAN_NONE+=("${f}${notes}")
            fi
        fi
    done <<<"${PLAN_LEAVES}"
    return 0
}

# --migration-report: read-only plan, nothing is changed.
migration_report() {
    section "Homebrew → MacPorts migration plan (read-only)"
    if [[ "${HAS_BREW}" != true ]]; then
        ok "Homebrew isn't (or no longer) installed: nothing to migrate."
        return 0
    fi
    local blocks_before=${#BLOCKERS[@]}
    migration_classify binaries
    ((${#BLOCKERS[@]} == blocks_before)) || return 0

    local n_casks item
    info "Formulae you installed yourself (brew leaves): $(count_lines "${PLAN_LEAVES}")."
    say "    ${C_DIM}The others are dependencies: brew autoremove will remove them once nothing uses them.${C_RESET}"
    if ((${#PLAN_SAME[@]} > 0)); then
        say ""
        ok "Same name in MacPorts (${#PLAN_SAME[@]}) — praetorian --migrate <formula>:"
        for item in "${PLAN_SAME[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
        say "    ${C_DIM}praetorian --migrate-all migrates the ${#PLAN_READY[@]} of them with the same homepage and no [ ] note.${C_RESET}"
    fi
    if ((${#PLAN_DIFFER[@]} > 0)); then
        say ""
        warn "Same name, but maybe a different project (${#PLAN_DIFFER[@]}) — the homepages differ: check with \"port info <port>\" before migrating:"
        for item in "${PLAN_DIFFER[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
        say "    ${C_DIM}Same software after all: praetorian --migrate <formula>=<port> (naming the port skips this check).${C_RESET}"
    fi
    if ((${#PLAN_APPROX[@]} > 0)); then
        say ""
        warn "Probably a different name (${#PLAN_APPROX[@]}) — check with \"port info <port>\", then praetorian --migrate <formula>=<port>:"
        for item in "${PLAN_APPROX[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
    fi
    if ((${#PLAN_NONE[@]} > 0)); then
        say ""
        warn "Not found under this name (${#PLAN_NONE[@]}) — search with \"port search --name <word>\", otherwise keep it in Homebrew:"
        for item in "${PLAN_NONE[@]}"; do say "    ${C_DIM}-${C_RESET} ${item}"; done
    fi
    if [[ "${PLAN_HAS_NOTES}" == true ]]; then
        say ""
        info "The [ ] notes will block the migration until they're dealt with:"
        say "    ${C_DIM}[brew service running]      → brew services stop <formula>, then the MacPorts equivalent (sudo port load <port>)${C_RESET}"
        say "    ${C_DIM}[referenced in ~/.zshrc…]   → replace those Homebrew paths with MacPorts ones (${PORT_PREFIX}/…)${C_RESET}"
        say "    ${C_DIM}[no binary for this Mac: …] → MacPorts would compile it (hours, may fail): wait for the binary, or --allow-build${C_RESET}"
    fi
    if ((PLAN_BINARY_CHECKED > 0 || PLAN_BINARY_SKIPPED > 0)); then
        say ""
        info "Precompiled binaries (packages.macports.org, $(binary_platform)): ${PLAN_BINARY_CHECKED} port(s) checked, ${PLAN_BINARY_MISSING} without one."
        if [[ "${PLAN_BINARY_OFFLINE}" == true ]]; then
            say "    ${C_DIM}packages.macports.org didn't answer: ${PLAN_BINARY_SKIPPED} port(s) not checked (--migrate checks again before installing).${C_RESET}"
        elif ((PLAN_BINARY_SKIPPED > 0)); then
            say "    ${C_DIM}${PLAN_BINARY_SKIPPED} more not checked (limit of ${PLAN_BINARY_MAX} per report): --migrate checks each one before installing.${C_RESET}"
        fi
    fi

    n_casks=$(count_lines "$(brew list --cask 2>/dev/null || true)")
    say ""
    info "${n_casks} cask(s) (apps): they STAY in Homebrew."
    say "    ${C_DIM}MacPorts doesn't manage apps, and a cask downloads the vendor's app without compiling anything:${C_RESET}"
    say "    ${C_DIM}tier 3 doesn't affect them.${C_RESET}"

    say ""
    info "Suggested order:"
    say "    1. First the formulae that cause trouble (long builds, quarantined)."
    say "    2. One at a time: ${C_BOLD}praetorian --migrate <formula>[=<port>]${C_RESET} (with --dry-run to see the checks),"
    say "       or every ready one at once: ${C_BOLD}praetorian --migrate-all${C_RESET} (a blocked one is skipped and listed)."
    say "    3. After each migration, check that your tools work (new terminal)."
    say "    4. When only casks are left, Homebrew has nothing to compile: maintenance becomes fast."
}

# ----------------------------------------------------------------------------
# --migrate formula[=port[,port…]]
# ----------------------------------------------------------------------------
# Installs with MacPorts, checks, and only then uninstalls the formula. Any
# failing check stops everything, the Homebrew formula untouched. Always
# returns 0: the outcome is in BLOCKERS and MIGRATE_RESULT (called outside
# a "||" context so set -e stays active).
#
# One function per step (migrate_*). Each one returns 0 and reports a
# stop through block(): migrate stops as soon as BLOCKERS grew. A step
# never returns a status to test: it would have to be called left of "||"
# or in an "if", where bash turns set -e off for the whole function, and
# an unexpected failure (e.g. brew --prefix) would go on unnoticed instead
# of being explained by on_exit.
# The steps share migrate's locals (bash: a function sees the locals of
# its caller): f (formula), p (main port), ports (main port then its
# companions), spec_ports (them, comma-separated), explicit (true when
# the ports were named with "="), short (formula without its tap, as used
# in opt/ paths, service names and MacPorts), brew_files (set by
# migrate_check_formula), brew_bins (set by migrate_check_port).
MIGRATE_RESULT="" # "migrated", "checked" (dry-run), empty: not done
MIGRATE_DONE=""   # formulae migrated (or checked, dry-run) this session

migrate() {
    local f=${MIGRATE_SPEC%%=*} p short spec_ports explicit=false
    local -a ports=()
    short=${f##*/}
    spec_ports=${short}
    if [[ "${MIGRATE_SPEC}" == *=* ]]; then
        explicit=true
        spec_ports=${MIGRATE_SPEC#*=}
    fi
    IFS=, read -r -a ports <<<"${spec_ports}"
    p=${ports[0]}
    MIGRATE_RESULT=""
    section "Migration: ${f} (Homebrew) → ${spec_ports//,/ + } (MacPorts)"
    say "Fail-safe order: check → install with MacPorts → check → only then uninstall with Homebrew."
    say "${C_DIM}If a step fails, praetorian stops and ${f} stays installed with Homebrew.${C_RESET}"

    local brew_files="" brew_bins="" step blocks_before=${#BLOCKERS[@]}
    for step in migrate_preconditions migrate_check_formula migrate_check_usage migrate_check_name \
        migrate_check_port migrate_check_project migrate_check_binary; do
        "${step}"
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
    done
    if [[ "${DRY_RUN}" == true ]]; then
        migrate_dry_run_plan
        migrate_check_external
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
        MIGRATE_RESULT=checked
        return 0
    fi
    for step in migrate_check_sudo migrate_install migrate_verify migrate_check_external migrate_uninstall_formula; do
        "${step}"
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
    done
    MIGRATE_RESULT=migrated
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

# 1. Is the formula installed? 2. No other formula may depend on it (those
# migrated earlier in this session aside: uninstalled, or about to be in a
# dry-run).
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
    dependents=$(filter_out "${dependents}" "${MIGRATE_DONE}")
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

# 5. A known trap (known_port_spec) asked for without "=": the same-name
# port is the wrong one, or companions are missing. Never changed behind
# your back: blocked with the exact command.
migrate_check_name() {
    [[ "${explicit}" != true ]] || return 0
    local known kports
    known=$(known_port_spec "${f}")
    [[ -n "${known}" ]] || return 0
    kports=${known%%$'\t'*}
    block "${f} has another spec in MacPorts: ${f}=${kports}" \
        "${known#*$'\t'}" \
        "Nothing was done: praetorian doesn't change what you asked for on its own." \
        "Check: port info ${kports//,/ }" \
        "then: praetorian --migrate ${f}=${kports}" \
        "(a port that isn't the main one, after a comma, is a companion installed with it)"
}

# 6. Do the ports exist? 7. Commands provided by the formula: they must
# exist on the MacPorts side (checked by migrate_verify).
migrate_check_port() {
    local q
    for q in "${ports[@]}"; do
        if ! port_ro info --name "${q}"; then
            if port_platform_mismatch "${PORT_LAST_OUT}"; then
                block_port_platform "${PORT_LAST_OUT}"
                return 0
            fi
            local glob
            glob="$(port_family "${short%%@*}")*"
            [[ "${q}" == "${p}" ]] || glob="${q%%[0-9]*}*"
            block "no MacPorts port named ${q}" \
                "$(port_error_lines "${PORT_LAST_OUT}")" \
                "Nothing was done." \
                "Find the right name: port search --name --glob '${glob}'" \
                "then: praetorian --migrate ${f}=<port-name>"
            return 0
        fi
        ok "Port ${q} available in MacPorts"
    done

    # Only what brew links into the PATH: <Cellar>/<formula>/<version>/bin
    # or sbin. Not every "bin" directory of the keg: libexec/bin (pipx,
    # scons: the venv's python), lib/rustlib/…/bin (rust) are internal, and
    # MacPorts has no reason to ship them (2026-10-17: 4 migrations refused
    # for that).
    brew_bins=$(awk -v keg="/Cellar/${short}/" '{ i = index($0, keg) }
        i > 0 { n = split(substr($0, i + length(keg)), a, "/")
                if (n == 3 && (a[2] == "bin" || a[2] == "sbin")) print a[3] }' <<<"${brew_files}" | sort -u)
    info "Commands provided by ${f}: $(tr '\n' ' ' <<<"${brew_bins:-none}")"
}

# 8. Same software? The homepages of the formula and of the main port.
# Different: blocked when the port was only guessed from the name, a
# warning when you named it yourself. Unknown on one side, or nothing
# that tells (homepage_verdict): no verdict.
migrate_check_project() {
    local brew_hp port_hp="" meta verdict
    brew_hp=$(brew_homepages "${f}" | awk -F '\t' 'NR == 1 { print $2 }')
    if meta=$(port_meta "${p}"); then port_hp=$(cut -f3 <<<"${meta}"); fi
    verdict=$(homepage_verdict "${brew_hp}" "${port_hp}")
    case "${verdict}" in
        match) ok "Same project: ${f} and ${p} have the same homepage (${port_hp})" ;;
        unknown) info "${C_DIM}Homepages inconclusive (unknown on one side, or not telling the projects apart): port info ${p} shows what it is.${C_RESET}" ;;
        mismatch)
            if [[ "${explicit}" == true ]]; then
                warn "${p} may be a different project than ${f}: the homepages differ (Homebrew: ${brew_hp}, MacPorts: ${port_hp})."
                say "    ${C_DIM}Going on: you named the port yourself. The commands are checked after the install.${C_RESET}"
                return 0
            fi
            block "${p} may not be the same software as ${f}" \
                "Same name, different homepages: Homebrew ${brew_hp}, MacPorts ${port_hp}. Some names belong to unrelated projects in MacPorts (its \"step\" is a KDE program, not smallstep's)." \
                "Nothing was done: no MacPorts install, no uninstall." \
                "Compare: brew info ${f}   and   port info ${p}" \
                "Same software after all: praetorian --migrate ${f}=${p}   (naming the port turns this block into a warning)" \
                "Otherwise find the right port: port search --name --glob '$(port_family "${short%%@*}")*'"
            ;;
    esac
}

# 9. A precompiled binary for this Mac, for every port to install
# (already active ones need nothing). None: blocked unless --allow-build,
# with an older version of the same port that has one, when there is.
# Network trouble: no verdict, never a block.
migrate_check_binary() {
    local q status="" sibling alt r
    local -a nobin=() hints=()
    for q in "${ports[@]}"; do
        port_is_active "${q}" && continue
        # No answer once: the other ports would only wait for their timeout.
        [[ "${status}" == offline ]] || status=$(port_binary_status "${q}")
        case "${status}" in
            yes) ok "Precompiled binary of ${q} available for this Mac (packages.macports.org)" ;;
            restricted)
                info "${q}: no precompiled binary (its license doesn't let MacPorts distribute one): built on this Mac."
                say "    ${C_DIM}Usually quick when the port only repackages the vendor's own binary (terraform-1.N).${C_RESET}"
                ;;
            offline) info "${C_DIM}${q}: binary not checked (packages.macports.org didn't answer): not blocking.${C_RESET}" ;;
            unknown) info "${C_DIM}${q}: binary not checked (no curl, or unexpected platform or port data): not blocking.${C_RESET}" ;;
            *) nobin+=("${q}") ;;
        esac
    done
    ((${#nobin[@]} > 0)) || return 0
    if [[ "${ALLOW_BUILD}" == true ]]; then
        warn "No precompiled binary for this Mac: ${nobin[*]}. MacPorts will compile from source (--allow-build): this may take hours."
        return 0
    fi
    for q in "${nobin[@]}"; do
        sibling=$(port_binary_sibling "${q}")
        [[ -n "${sibling}" ]] || continue
        alt=""
        for r in "${ports[@]}"; do
            [[ "${r}" == "${q}" ]] && r=${sibling}
            alt+="${alt:+,}${r}"
        done
        hints+=("${sibling} has a binary: praetorian --migrate ${f}=${alt}")
    done
    block "no precompiled MacPorts binary of ${nobin[*]} for this Mac" \
        "packages.macports.org has no archive of ${nobin[*]} for $(binary_platform): MacPorts would compile from source, which may take hours or fail (e.g. nodejs26, every mysql port on this Mac)." \
        "Nothing was done: no MacPorts install, no uninstall. ${f} stays in Homebrew." \
        "${hints[@]+"${hints[@]}"}" \
        "Compile anyway: praetorian --allow-build --migrate ${MIGRATE_SPEC}" \
        "Or keep ${f} in Homebrew for now: binaries often appear a few days after a new version."
}

migrate_dry_run_plan() {
    local q n=1
    info "Next steps (not run in dry-run):"
    for q in "${ports[@]}"; do
        if port_is_active "${q}"; then
            say "    $((n++)). sudo port -N setrequested ${q}   (already installed: marked as wanted)"
        else
            say "    $((n++)). sudo port -N install ${q}"
        fi
    done
    say "    $((n++)). check that the port(s) are active and that every command above is in ${PORT_PREFIX}/bin or sbin"
    say "       (missing ones: sudo port select --set <group> <port>, only for a group still set to none)"
    say "    $((n++)). brew uninstall --formula ${f}   (only if the checks pass)"
}

migrate_check_sudo() {
    if ! port_sudo_available; then
        block "MacPorts needs sudo, impossible when unattended" \
            "Installing ${spec_ports//,/ } needs Touch ID or the password, and praetorian stores none." \
            "Nothing was done." \
            "Run it from a terminal: praetorian --migrate ${MIGRATE_SPEC}"
        return 0
    fi
    port_sudo_safe || return 0
}

# 10. MacPorts install of each port (skipped when it's already active).
migrate_install() {
    local q before
    for q in "${ports[@]}"; do
        if port_is_active "${q}"; then
            ok "${q} already installed and active in MacPorts"
            # Installed as a dependency of another port: MacPorts doesn't
            # know you want it, and "port uninstall leaves" (or that other
            # port leaving) would remove the command you just migrated to
            # (2026-10-17: go, autoconf, libtool… 9 ports in that state).
            before=${STEP_FAIL}
            run_step "Marking ${q} as requested in MacPorts" \
                "${SUDO_CMD[@]}" "${PORT_BIN}" -N setrequested "${q}"
            step_failed_since "${before}" &&
                warn "${q} stays marked as a dependency: run sudo port setrequested ${q} yourself."
            continue
        fi
        before=${STEP_FAIL}
        run_step "Installing ${q} with MacPorts" \
            "${SUDO_CMD[@]}" "${PORT_BIN}" -N install "${q}"
        step_failed_since "${before}" || continue
        save_port_logs "${STEP_OUT}"
        if is_sudo_auth_failure "${STEP_OUT}"; then
            block "sudo authentication cancelled or refused" \
                "MacPorts needs sudo to install ${q}." \
                "${f} stays installed with Homebrew, nothing changed." \
                "Run again: praetorian --migrate ${MIGRATE_SPEC}"
            return 0
        fi
        if port_platform_mismatch "${STEP_OUT}"; then
            block_port_platform "${STEP_OUT}"
            return 0
        fi
        block "installing ${q} with MacPorts failed" \
            "$(port_error_lines "${STEP_OUT}")" \
            "${f} stays installed with Homebrew and usable. MacPorts never activates a half-installed port." \
            "Details: port log ${q}  (or the *_portlogs.tar.gz archive in ${LOG_DIR})" \
            "Clean up and retry: sudo port clean ${q} && praetorian --migrate ${MIGRATE_SPEC}" \
            "This Mac is still supported by MacPorts: bugs can be reported at https://trac.macports.org"
        return 0
    done
}

# Commands of the list (one per line) found in neither ${PORT_PREFIX}/bin
# nor sbin, whatever port put them there (a companion, a port select link,
# a port installed earlier).
port_commands_missing() {
    local c
    while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        [[ -e "${PORT_PREFIX}/bin/${c}" || -e "${PORT_PREFIX}/sbin/${c}" ]] || printf '%s\n' "${c}"
    done <<<"$1"
}

# Harmless difference: a versioned name (aclocal-1.19, python3.12, foo-2)
# whose unversioned name is there (aclocal, python3, foo): only the
# version in the name differs between Homebrew and MacPorts.
is_versioned_alias() {
    local c=$1 b
    for b in "$(sed -E 's/-[0-9]+(\.[0-9]+)*$//' <<<"${c}")" \
        "$(sed -E 's/\.[0-9]+$//' <<<"${c}")" \
        "$(sed -E 's/[0-9]+\.[0-9]+$//' <<<"${c}")"; do
        [[ -n "${b}" && "${b}" != "${c}" ]] || continue
        [[ -e "${PORT_PREFIX}/bin/${b}" || -e "${PORT_PREFIX}/sbin/${b}" ]] && return 0
    done
    return 1
}

# Commands still missing after the install: MacPorts often ships
# versioned names only (terraform-1.16, guile-3.0) and links the plain
# name with "port select". A group nobody chose yet (selected: none) whose
# options include a port just installed (as is, without its dashes, or
# with MacPorts' mp- prefix) is set to it. A group already set to
# something else is never changed.
migrate_port_select() {
    port_ro select --summary || return 0
    local group selected options q cand before
    while read -r group selected options; do
        [[ "${selected}" == none && "${group}" =~ ^[A-Za-z0-9._+-]+$ ]] || continue
        for q in "${ports[@]}"; do
            for cand in "${q}" "${q//-/}" "mp-${q}"; do
                [[ " ${options} " == *" ${cand} "* ]] || continue
                before=${STEP_FAIL}
                run_step "Selecting ${cand} for ${group} (port select)" \
                    "${SUDO_CMD[@]}" "${PORT_BIN}" select --set "${group}" "${cand}"
                log_detail "port select: ${group} was none, set to ${cand}"
                step_failed_since "${before}" &&
                    warn "Not selected: run sudo port select --set ${group} ${cand} yourself."
                continue 3
            done
        done
    done < <(awk 'seen && NF >= 3 { print } /^=+/ { seen = 1 }' <<<"${PORT_LAST_OUT}")
}

# 11. Checks after the install: every port active, and every command of
# the formula found on the MacPorts side.
migrate_verify() {
    local q
    for q in "${ports[@]}"; do
        if ! port_is_active "${q}"; then
            block "${q} isn't active in MacPorts after the install" \
                "port installed ${q} doesn't show it as (active)." \
                "${f} was NOT uninstalled from Homebrew." \
                "See: port installed ${q}" \
                "Activate it: sudo port activate ${q}, then run praetorian --migrate ${MIGRATE_SPEC} again"
            return 0
        fi
    done
    local missing c harmless="" absent=""
    missing=$(port_commands_missing "${brew_bins}")
    if [[ -n "${missing}" ]]; then
        migrate_port_select
        missing=$(port_commands_missing "${brew_bins}")
    fi
    while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        if is_versioned_alias "${c}"; then
            harmless+="${harmless:+ }${c}"
        else
            absent+="${absent:+ }${c}"
        fi
    done <<<"${missing}"
    if [[ -n "${absent}" ]]; then
        block "${spec_ports//,/ + } (MacPorts) doesn't provide every command of ${f}" \
            "Missing in ${PORT_PREFIX}/bin and sbin: ${absent} — often a name with a version suffix (python3.12 instead of python3), a port select group, a companion port, or a variant to enable." \
            "BOTH are installed: ${f} (Homebrew) was NOT uninstalled. This is harmless." \
            "Compare: port contents ${p} | grep bin/" \
            "Links by name: port select --summary   (then sudo port select --set <group> <option>)" \
            "Variants: port variants ${p}" \
            "A companion port: praetorian --migrate ${f}=${spec_ports},<port>" \
            "Keep both, or undo on the MacPorts side: sudo port uninstall ${spec_ports//,/ }" \
            "If you don't use those commands: brew uninstall --formula ${f} (do it yourself)"
        return 0
    fi
    migrate_show_sources
    [[ -z "${harmless}" ]] ||
        info "Harmless differences (another version in the name, the plain name is there): ${harmless}"
    ok "${spec_ports//,/ + } active, every command of ${f} found in MacPorts"
}

# Which port provides which command of the formula (port contents); the
# rest comes from port select links or other ports.
migrate_show_sources() {
    local rest q owned mine
    rest=$(comm -23 <(sed '/^$/d' <<<"${brew_bins}") <(port_commands_missing "${brew_bins}" | sort -u) || true)
    [[ -n "${rest}" ]] || return 0
    for q in "${ports[@]}"; do
        port_ro contents "${q}" || true
        owned=$(awk -v pre="${PORT_PREFIX}" '{ sub(/^[[:space:]]+/, "") }
            index($0, pre "/bin/") == 1 || index($0, pre "/sbin/") == 1 { n = split($0, a, "/"); print a[n] }' \
            <<<"${PORT_LAST_OUT}" | sort -u)
        mine=$(comm -12 <(printf '%s\n' "${rest}") <(printf '%s\n' "${owned}") || true)
        [[ -n "${mine}" ]] || continue
        say "    ${C_DIM}from ${q}: $(tr '\n' ' ' <<<"${mine}")${C_RESET}"
        rest=$(comm -23 <(printf '%s\n' "${rest}") <(printf '%s\n' "${mine}") || true)
    done
    [[ -z "${rest}" ]] || say "    ${C_DIM}from port select links or other ports: $(tr '\n' ' ' <<<"${rest}")${C_RESET}"
}

# 12. Programs outside Homebrew that use the formula (pipx environments on
# a Homebrew python, npm global packages…: formula_external_users, in
# lib/doctor.sh): brew uses doesn't know them, and the uninstall would
# break them. Run after the install, so the MacPorts version is there to
# move them to.
migrate_check_external() {
    declare -F formula_external_users >/dev/null || return 0
    local users line py fix
    users=$(formula_external_users "${f}")
    if [[ -z "${users}" ]]; then
        ok "No program outside Homebrew uses ${f}"
        return 0
    fi
    local -a list=()
    while IFS= read -r line; do [[ -z "${line}" ]] || list+=("  ${line}"); done <<<"${users}"
    case "${short}" in
        python@*)
            py="${PORT_PREFIX}/bin/python${short#python@}"
            fix="pipx: pipx reinstall <package> --python ${py}   (or pipx reinstall-all --python ${py})"
            ;;
        node | node@*) fix="npm: reinstall the global packages with MacPorts' npm (${PORT_PREFIX}/bin/npm install -g <package>)" ;;
        *) fix="Point them at the MacPorts version (${PORT_PREFIX}/…), or reinstall them with it" ;;
    esac
    local impact="${spec_ports//,/ + } installed with MacPorts; ${f} was NOT uninstalled from Homebrew (both installed: harmless)."
    [[ "${DRY_RUN}" != true ]] || impact="Nothing was done (dry-run): a real run would install ${spec_ports//,/ + } and stop here, before the uninstall."
    block "programs outside Homebrew still use ${f}" \
        "They were set up with the Homebrew ${f} and would stop working once it's uninstalled (brew uses only knows about formulae)." \
        "${impact}" \
        "Programs involved:" \
        "${list[@]}" \
        "→ ${fix}" \
        "  then run again: praetorian --migrate ${MIGRATE_SPEC}"
}

# 13. Only now: the Homebrew uninstall.
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
    # Every port, comma-separated (read by migrated_port_names).
    printf '%s\t%s\t%s\n' "${f}" "${spec_ports}" "$(date +%s)" >>"${MIGRATED_FILE}"
    ok "${f} migrated to MacPorts (${spec_ports//,/ + })."
    info "Terminals already open: run \"hash -r\" (or open a new one) to use the MacPorts version."
    info "${C_DIM}Homebrew dependencies no longer needed go away at the next brew autoremove (praetorian session).${C_RESET}"
    port_path_check
}

# ----------------------------------------------------------------------------
# Several migrations in one session (--migrate repeated, --migrate-all)
#
# One lock, one session. Formulae nothing depends on go first; one that
# others depend on waits, and is tried again once a pass migrated
# something (its dependents may be gone). A blocked formula doesn't stop
# the others. Each block stays in BLOCKERS: the session ends with code 2.
# ----------------------------------------------------------------------------
declare -a BATCH_SPECS=() BATCH_OUTCOMES=()

# migrate_waits <formula>: true when an installed formula not migrated in
# this session depends on it.
migrate_waits() {
    local dependents
    dependents=$(brew uses --installed "$1" 2>>"${LOG_FILE}" || true)
    [[ -n "$(filter_out "${dependents}" "${MIGRATE_DONE}")" ]]
}

# migrate_one <spec>: one migration, its outcome recorded.
migrate_one() {
    local before=${#BLOCKERS[@]} outcome
    MIGRATE_SPEC=$1
    migrate
    if [[ -n "${MIGRATE_RESULT}" ]]; then
        outcome=${MIGRATE_RESULT}
        MIGRATE_DONE+="${MIGRATE_DONE:+$'\n'}${1%%=*}"
    elif ((${#BLOCKERS[@]} > before)); then
        outcome="blocked: ${BLOCKERS[${#BLOCKERS[@]} - 1]}"
    else
        outcome="not migrated (see above)"
    fi
    BATCH_SPECS+=("$1")
    BATCH_OUTCOMES+=("${outcome}")
}

migrate_batch() {
    local spec f seen=""
    local -a todo=() pending=() ready=() waiting=()
    if [[ "${MIGRATE_ALL}" == true ]]; then
        section "Formulae ready to migrate (--migrate-all)"
        if [[ "${HAS_BREW}" != true ]]; then
            ok "Homebrew isn't (or no longer) installed: nothing to migrate."
            return 0
        fi
        local blocks_before=${#BLOCKERS[@]}
        migration_classify
        ((${#BLOCKERS[@]} == blocks_before)) || return 0
        if ((${#PLAN_READY[@]} == 0)); then
            info "None: no formula has a port with the same name, the same homepage and nothing blocking."
        else
            info "${#PLAN_READY[@]} formula(e) with the same name and the same homepage in MacPorts, nothing blocking: ${PLAN_READY[*]}"
        fi
        say "    ${C_DIM}Left out: the known traps and other names, different homepages, [ ] notes — see praetorian --migration-report.${C_RESET}"
    fi
    # shellcheck disable=SC2153  # MIGRATE_SPECS is set by parse_args (praetorian)
    todo=("${MIGRATE_SPECS[@]+"${MIGRATE_SPECS[@]}"}" "${PLAN_READY[@]+"${PLAN_READY[@]}"}")
    ((${#todo[@]} > 0)) || return 0

    # The same formula twice: only the first one. A name that isn't one
    # (the --migrate ones are checked by parse_args, the --migrate-all
    # ones come from brew leaves) never reaches brew, port or sudo.
    for spec in "${todo[@]}"; do
        f=${spec%%=*}
        if ! valid_migrate_spec "${spec}"; then
            BATCH_SPECS+=("${spec}")
            BATCH_OUTCOMES+=("skipped: invalid name")
            continue
        fi
        if grep -qxF "${f}" <<<"${seen}"; then
            BATCH_SPECS+=("${spec}")
            BATCH_OUTCOMES+=("skipped: ${f} already in the list")
            continue
        fi
        seen+="${seen:+$'\n'}${f}"
        pending+=("${spec}")
    done

    local done_before
    while ((${#pending[@]} > 0)); do
        ready=()
        waiting=()
        for spec in "${pending[@]}"; do
            if ((${#pending[@]} > 1)) && migrate_waits "${spec%%=*}"; then
                waiting+=("${spec}")
            else
                ready+=("${spec}")
            fi
        done
        ((${#ready[@]} > 0)) || break
        done_before=${MIGRATE_DONE}
        for spec in "${ready[@]}"; do migrate_one "${spec}"; done
        pending=("${waiting[@]+"${waiting[@]}"}")
        # Nothing migrated: the dependents of the waiting ones are still
        # there, another pass would change nothing.
        [[ "${MIGRATE_DONE}" != "${done_before}" ]] || break
    done
    # Still waiting: one try each, for the block that explains why.
    for spec in "${pending[@]+"${pending[@]}"}"; do migrate_one "${spec}"; done

    ((${#BATCH_SPECS[@]} > 1)) || [[ "${MIGRATE_ALL}" == true ]] || return 0
    migrate_batch_summary
}

# One line per formula: migrated / blocked (the block's title) / skipped.
migrate_batch_summary() {
    local i spec outcome n_ok=0 n_blocked=0 n_skipped=0
    section "Migrations: one line per formula"
    for ((i = 0; i < ${#BATCH_SPECS[@]}; i++)); do
        spec=${BATCH_SPECS[i]}
        outcome=${BATCH_OUTCOMES[i]}
        case "${outcome}" in
            migrated)
                n_ok=$((n_ok + 1))
                ok "${spec}: migrated"
                ;;
            checked)
                n_ok=$((n_ok + 1))
                ok "${spec}: checks passed (dry-run, nothing changed)"
                ;;
            skipped*)
                n_skipped=$((n_skipped + 1))
                info "${spec}: ${outcome}"
                ;;
            *)
                n_blocked=$((n_blocked + 1))
                err "${spec}: ${outcome}"
                ;;
        esac
    done
    if [[ "${DRY_RUN}" == true ]]; then
        info "${n_ok} ready, ${n_blocked} blocked, ${n_skipped} skipped (dry-run: nothing was changed)."
    else
        info "${n_ok} migrated, ${n_blocked} blocked, ${n_skipped} skipped."
    fi
}
