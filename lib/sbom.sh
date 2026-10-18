# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 victor-sys-admin
#
# praetorian — SBOM (--sbom)
#
# CycloneDX 1.6 inventory of the installed software, written in the logs
# directory, with the changes since the previous one.
#
# Sourced by ../praetorian after its safety check (see check_libs); not
# meant to be run on its own.

# ----------------------------------------------------------------------------
# --sbom
#
# Sources, each optional (a missing tool is skipped and said so):
#   - Homebrew formulae and casks   brew info --json=v2 --installed
#   - MacPorts active ports          port -q installed active
#   - apps in /Applications and ~/Applications (not the helpers nested in
#     another app)                   system_profiler SPApplicationsDataType
#   - pipx environments              <PIPX_HOME>/venvs/*/pipx_metadata.json
#   - npm global packages            npm ls -g --json --depth=0
#
# The JSON is built by Python's json module only, never by hand in bash:
# one name with a quote or a backslash would make a hand-written file
# invalid. Python runs isolated (-I: no user site-packages, no PYTHON*
# variables, the script's directory not on sys.path), its script comes
# from a heredoc, the inventories are files in a private temporary
# directory removed on every exit.
#
# Read-only: no sudo, nothing installed or removed. Output: mode 600 in
# the logs directory (700), the last LOG_RETENTION SBOMs kept.
# ----------------------------------------------------------------------------
readonly SBOM_NAMES=15 # names shown on screen per list (all in the log)
SBOM_TMP=""            # private temporary directory (removed on exit)
SBOM_PART=""           # SBOM being written, renamed once complete

# Removes SBOM_TMP, and a half-written SBOM.
sbom_cleanup() {
    [[ -z "${SBOM_TMP}" ]] || rm -rf "${SBOM_TMP}"
    [[ -z "${SBOM_PART}" ]] || rm -f "${SBOM_PART}"
    SBOM_TMP=""
    SBOM_PART=""
}

# sbom_fail <message>: says why no SBOM was written, cleans up, puts the
# session's exit handler back. Code 2, as for a failed step.
sbom_fail() {
    warn "$1"
    sbom_cleanup
    trap on_exit EXIT
    return 2
}

# sbom_python_works <python>: Python 3.6 or later that runs.
sbom_python_works() {
    "$1" -I -c 'import json, sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1
}

# The Python to use: macOS's /usr/bin/python3 first (root-owned), then a
# python3 from the PATH. /usr/bin/python3 is only a stub until the
# Command Line Tools or Xcode are installed: run then, it opens their
# install dialog. It's only tried when xcode-select points to an existing
# developer directory.
sbom_python() {
    local dev py
    dev=$(xcode-select -p 2>/dev/null || true)
    if [[ -x /usr/bin/python3 && -n "${dev}" && -d "${dev}" ]] && sbom_python_works /usr/bin/python3; then
        echo /usr/bin/python3
        return 0
    fi
    py=$(command -v python3 2>/dev/null || true)
    [[ -n "${py}" ]] || return 1
    # The same stub found through the PATH (macOS only: elsewhere it's a
    # real Python).
    [[ "${py}" != /usr/bin/python3 || "$(uname -s)" != Darwin ]] || return 1
    sbom_python_works "${py}" || return 1
    echo "${py}"
}

# pipx's home: PIPX_HOME, otherwise the first that exists of ~/.local/pipx
# and, for pipx 1.3 and later on macOS, ~/Library/Application Support/pipx.
sbom_pipx_home() {
    local d
    if [[ -n "${PIPX_HOME:-}" ]]; then
        echo "${PIPX_HOME}"
        return 0
    fi
    for d in "${HOME}/.local/pipx" "${HOME}/Library/Application Support/pipx"; do
        if [[ -d "${d}/venvs" ]]; then
            echo "${d}"
            return 0
        fi
    done
}

# Collects the inventories in SBOM_TMP (one file per source; a missing
# file = source skipped). Sets SBOM_PIPX, a local of sbom_run: pipx's
# home, empty when there is no pipx environment.
sbom_collect() {
    local dir=${SBOM_TMP}
    if [[ "${HAS_BREW}" == true ]]; then
        if ! brew info --json=v2 --installed >"${dir}/brew.json" 2>>"${LOG_FILE}"; then
            warn "brew info --json=v2 --installed failed (see the log): Homebrew left out of the SBOM."
            rm -f "${dir}/brew.json"
        fi
    else
        info "Homebrew not found: left out of the SBOM."
    fi
    if [[ "${HAS_PORT}" == true ]]; then
        if ! "${PORT_BIN}" -q installed active >"${dir}/port.txt" 2>>"${LOG_FILE}"; then
            warn "port installed active failed (see the log): MacPorts left out of the SBOM."
            rm -f "${dir}/port.txt"
        fi
    else
        info "MacPorts not found: left out of the SBOM."
    fi
    if command -v system_profiler >/dev/null 2>&1; then
        if ! system_profiler -json -detailLevel mini SPApplicationsDataType >"${dir}/apps.json" 2>>"${LOG_FILE}"; then
            warn "system_profiler failed (see the log): apps left out of the SBOM."
            rm -f "${dir}/apps.json"
        fi
    else
        info "system_profiler not found: apps left out of the SBOM."
    fi
    if command -v npm >/dev/null 2>&1; then
        # Non-zero for a mere "extraneous" or "invalid" package, with the
        # JSON still printed: the output counts, not the code.
        npm ls -g --json --depth=0 >"${dir}/npm.json" 2>>"${LOG_FILE}" || true
        [[ -s "${dir}/npm.json" ]] || {
            warn "npm ls -g printed nothing (see the log): npm packages left out of the SBOM."
            rm -f "${dir}/npm.json"
        }
    else
        info "npm not found: npm global packages left out of the SBOM."
    fi
    SBOM_PIPX=$(sbom_pipx_home)
    if [[ -z "${SBOM_PIPX}" || ! -d "${SBOM_PIPX}/venvs" ]]; then
        info "No pipx environment found: pipx left out of the SBOM."
        SBOM_PIPX=""
    fi
    return 0
}

sbom_run() {
    section "SBOM (CycloneDX 1.6, read-only)"
    local py
    if ! py=$(sbom_python); then
        block "no Python 3 to write the SBOM" \
            "The SBOM is JSON, built with Python's json module: praetorian never writes JSON by hand in bash (one name with a quote in it would make the file invalid). /usr/bin/python3 needs the Command Line Tools or Xcode, and no other python3 in the PATH works." \
            "No SBOM written. Nothing was changed." \
            "Install the Command Line Tools:  xcode-select --install" \
            "or a Python from MacPorts:       sudo port install python313 && sudo port select --set python3 python313" \
            "then run praetorian --sbom again."
        return 1
    fi
    log_detail "SBOM: python ${py}"

    local out="${LOG_DIR}/sbom_${RUN_TS}.cdx.json" prev
    # The previous SBOM, before this one is written (names sort by date).
    prev=$(find "${LOG_DIR}" -maxdepth 1 -name 'sbom_*.cdx.json' -type f 2>/dev/null | sort | tail -n 1)

    # main runs this mode without errexit: every step that matters is
    # checked here.
    if ! SBOM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/praetorian_sbom.XXXXXX") || [[ ! -d "${SBOM_TMP}" ]]; then
        SBOM_TMP=""
        warn "No temporary directory (mktemp -d failed in ${TMPDIR:-/tmp}): no SBOM written."
        return 2
    fi
    # Written under a name the rotation and the next diff never pick up,
    # renamed only once complete: a failure never leaves a partial
    # sbom_*.cdx.json.
    SBOM_PART="${LOG_DIR}/.sbom_${RUN_TS}.partial.$$"
    # Removed on any exit (Ctrl-C included, which goes through finish).
    # on_exit first: it reads the exit code, the failing command and
    # where it failed, which any command run before it would overwrite.
    trap 'on_exit; sbom_cleanup' EXIT
    local SBOM_PIPX=""
    info "Collecting the inventory…"
    sbom_collect

    local rc=0
    "${py}" -I - "${SBOM_TMP}" "${SBOM_PART}" "${prev}" "$(sw_vers -productVersion 2>/dev/null || echo unknown)" \
        "$(uname -m)" "${PRAETORIAN_VERSION}" "${HOME}" "${SBOM_PIPX}" \
        2>>"${LOG_FILE}" <<'PY' || rc=$?
import glob
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from urllib.parse import quote

tmp, out, prev, os_version, arch, tool_version, home, pipx_home = sys.argv[1:9]
components = []
seen = set()


def load(name):
    path = os.path.join(tmp, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def license_entry(lic):
    if not lic:
        return None
    if re.search(r"\s(OR|AND|WITH)\s|[()]", lic, re.IGNORECASE):
        return [{"expression": lic}]
    if re.fullmatch(r"[A-Za-z0-9.+-]+", lic) and not lic.startswith("LicenseRef"):
        return [{"license": {"id": lic}}]
    return [{"license": {"name": lic}}]


def add(source, name, version, purl=None, ctype="application", desc=None, lic=None, props=None):
    if not name:
        return
    version = str(version) if version else "unknown"
    key = (source, name, version)
    if key in seen:
        return
    seen.add(key)
    c = {"type": ctype, "bom-ref": f"{source}:{name}@{version}", "name": name, "version": version}
    if desc:
        c["description"] = desc
    entry = license_entry(lic)
    if entry:
        c["licenses"] = entry
    if purl:
        c["purl"] = purl
    p = [{"name": "praetorian:source", "value": source}]
    for k, v in (props or {}).items():
        if v is not None and v != "":
            p.append({"name": f"praetorian:{k}", "value": str(v).lower() if isinstance(v, bool) else str(v)})
    c["properties"] = p
    components.append(c)


def enc(s):
    return quote(str(s), safe="")


brew = load("brew.json")
if brew:
    for f in brew.get("formulae", []):
        for inst in f.get("installed", []):
            add("homebrew-formula", f["full_name"], inst.get("version"),
                purl=f"pkg:brew/{enc(f['full_name'])}@{enc(inst.get('version'))}",
                desc=f.get("desc"), lic=f.get("license"),
                props={"on_request": bool(inst.get("installed_on_request")), "homepage": f.get("homepage"),
                       "tap": f.get("tap")})
    for c in brew.get("casks", []):
        ver = c.get("installed") or c.get("version")
        add("homebrew-cask", c["token"], ver,
            purl=f"pkg:brew/cask/{enc(c.get('full_token') or c['token'])}@{enc(ver)}",
            desc=c.get("desc"), props={"homepage": c.get("homepage"), "tap": c.get("tap")})

port_file = os.path.join(tmp, "port.txt")
if os.path.exists(port_file):
    with open(port_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*(\S+) @(\S+?)((?:\+\S+)*) \(active\)", line)
            if m:
                name, ver, variants = m.groups()
                add("macports", name, ver, purl=f"pkg:macports/{enc(name)}@{enc(ver)}",
                    props={"variants": variants.lstrip("+").replace("+", ",")})

apps = load("apps.json")
if apps:
    roots = ("/Applications/", os.path.join(home, "Applications") + "/")
    for a in apps.get("SPApplicationsDataType", []):
        path = a.get("path") or ""
        # Helpers nested inside another app are part of it.
        if not path.startswith(roots) or ".app/" in path:
            continue
        signer = (a.get("signed_by") or [None])[0]
        add("application", a.get("_name"), a.get("version"),
            props={"path": path, "obtained_from": a.get("obtained_from"), "signed_by": signer,
                   "arch": a.get("arch_kind")})

if pipx_home:
    for meta in sorted(glob.glob(os.path.join(glob.escape(pipx_home), "venvs", "*", "pipx_metadata.json"))):
        try:
            with open(meta, encoding="utf-8") as f:
                md = json.load(f)
        except (OSError, ValueError) as e:
            print(f"pipx: {meta} unreadable: {e}", file=sys.stderr)
            continue
        main = md.get("main_package") or {}
        pkgs = [(main, "application")] + [(p, "library") for p in (md.get("injected_packages") or {}).values()]
        for p, ctype in pkgs:
            name, ver = p.get("package"), p.get("package_version")
            if not name:
                continue
            norm = re.sub(r"[-_.]+", "-", name).lower()
            add("pipx", name, ver, ctype=ctype, purl=f"pkg:pypi/{enc(norm)}@{enc(ver)}",
                props={"venv": os.path.basename(os.path.dirname(meta)), "python": md.get("python_version")})

npm = load("npm.json")
if npm:
    for name, d in (npm.get("dependencies") or {}).items():
        ver = (d or {}).get("version")
        ns, _, base = name.rpartition("/")
        purl = f"pkg:npm/{enc(ns)}/{enc(base)}@{enc(ver)}" if ns else f"pkg:npm/{enc(name)}@{enc(ver)}"
        add("npm-global", name, ver, ctype="library", purl=purl)

components.sort(key=lambda c: (c["properties"][0]["value"], c["name"].lower(), c["version"]))
bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.6",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "tools": {"components": [{"type": "application", "name": "praetorian", "version": tool_version}]},
        "component": {"type": "operating-system", "name": "macOS", "version": os_version, "bom-ref": "macos",
                      "properties": [{"name": "praetorian:arch", "value": arch}]},
    },
    "components": components,
}
# Mode 600 from the start: never readable by others, not even briefly.
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(bom, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(out, 0o600)

counts = {}
for c in components:
    s = c["properties"][0]["value"]
    counts[s] = counts.get(s, 0) + 1
with open(os.path.join(tmp, "counts.tsv"), "w", encoding="utf-8") as f:
    for s in ("homebrew-formula", "homebrew-cask", "macports", "application", "pipx", "npm-global"):
        f.write(f"{s}\t{counts.get(s, 0)}\n")
    f.write(f"total\t{len(components)}\n")


def versions(comps):
    v = {}
    for c in comps:
        props = {p.get("name"): p.get("value") for p in c.get("properties") or []}
        key = (props.get("praetorian:source", "?"), c.get("name", "?"))
        v.setdefault(key, set()).add(str(c.get("version", "")))
    return v


status = "none"
diff = []
if prev:
    try:
        with open(prev, encoding="utf-8") as f:
            old = versions(json.load(f).get("components") or [])
        status = "ok"
    # Any malformed content ({"components": 5}, an item that isn't an
    # object…) only skips the comparison: it must never fail every later
    # --sbom run.
    except (OSError, ValueError, AttributeError, TypeError) as e:
        print(f"previous SBOM {prev} unreadable: {e}", file=sys.stderr)
        status = "unreadable"
if status == "ok":
    new = versions(components)
    for key in sorted(set(old) | set(new), key=lambda k: (k[1].lower(), k[0])):
        src, name = key
        if key not in old:
            diff.append(("added", f"{name} {', '.join(sorted(new[key]))} ({src})"))
        elif key not in new:
            diff.append(("removed", f"{name} {', '.join(sorted(old[key]))} ({src})"))
        elif old[key] != new[key]:
            diff.append(("changed", f"{name} {', '.join(sorted(old[key]))} → {', '.join(sorted(new[key]))} ({src})"))
with open(os.path.join(tmp, "diff.tsv"), "w", encoding="utf-8") as f:
    f.write(f"status\t{status}\n")
    for kind, text in diff:
        f.write(f"{kind}\t{text}\n")
PY
    if ((rc != 0)) || [[ ! -s "${SBOM_PART}" ]]; then
        sbom_fail "The SBOM couldn't be written (Python error, see the log)."
        return 2
    fi
    if [[ -e "${out}" ]]; then
        sbom_fail "${out} already exists (another --sbom in the same second?): not overwritten, run it again."
        return 2
    fi
    if ! mv "${SBOM_PART}" "${out}"; then
        sbom_fail "The SBOM couldn't be moved to ${out} (see the log)."
        return 2
    fi
    SBOM_PART=""
    sbom_report "${out}" "${prev}"
    sbom_trivy "${py}" "${out}"
    sbom_cleanup
    trap on_exit EXIT
    rotate_pattern 'sbom_*.cdx.json'
    return 0
}

# What the SBOM holds, and what changed since the previous one.
sbom_report() {
    local out=$1 prev=$2 counts total status kind
    counts=${SBOM_TMP}/counts.tsv
    total=$(awk -F'\t' '$1 == "total" {print $2}' "${counts}")
    ok "SBOM written: ${out} (${total} components)"
    say "    ${C_DIM}$(awk -F'\t' '
        $1 == "homebrew-formula" { s = s "Homebrew formulae " $2 }
        $1 == "homebrew-cask"    { s = s ", casks " $2 }
        $1 == "macports"         { s = s ", MacPorts " $2 }
        $1 == "application"      { s = s ", apps " $2 }
        $1 == "pipx"             { s = s ", pipx " $2 }
        $1 == "npm-global"       { s = s ", npm " $2 }
        END { print s }' "${counts}")${C_RESET}"
    log_detail "SBOM: $(tr '\t\n' '= ' <"${counts}")"

    status=$(awk -F'\t' '$1 == "status" {print $2}' "${SBOM_TMP}/diff.tsv")
    case "${status}" in
        none)
            info "First SBOM in ${LOG_DIR}: nothing to compare with."
            return 0
            ;;
        unreadable)
            warn "Previous SBOM unreadable (${prev}): no comparison."
            return 0
            ;;
    esac
    local na nr nc
    na=$(grep -c '^added' "${SBOM_TMP}/diff.tsv" || true)
    nr=$(grep -c '^removed' "${SBOM_TMP}/diff.tsv" || true)
    nc=$(grep -c '^changed' "${SBOM_TMP}/diff.tsv" || true)
    if ((na + nr + nc == 0)); then
        ok "No change since the previous SBOM (${prev##*/})."
        return 0
    fi
    info "Since the previous SBOM (${prev##*/}): ${na} added, ${nr} removed, ${nc} version(s) changed."
    for kind in added removed changed; do
        sbom_diff_list "${kind}"
    done
}

# sbom_diff_list <added|removed|changed>: up to SBOM_NAMES on screen,
# every one in the log.
sbom_diff_list() {
    local kind=$1 lines n line i=0
    lines=$(awk -F'\t' -v k="${kind}" '$1 == k {print $2}' "${SBOM_TMP}/diff.tsv")
    n=$(count_lines "${lines}")
    ((n > 0)) || return 0
    say "    ${C_BOLD}${kind} (${n}):${C_RESET}"
    while IFS= read -r line; do
        log_detail "SBOM ${kind}: ${line}"
        ((i++ < SBOM_NAMES)) && say "      ${C_DIM}-${C_RESET} ${line}"
    done <<<"${lines}"
    ((n <= SBOM_NAMES)) || say "      ${C_DIM}… $((n - SBOM_NAMES)) more, see the log${C_RESET}"
}

# Known vulnerabilities (HIGH, CRITICAL) with trivy, when it's installed.
# trivy only matches the pypi and npm purls: the brew and macports ones
# aren't in its database, so a clean result says nothing about them.
# Whatever trivy does, the SBOM stays written and the run succeeds.
sbom_trivy() {
    local py=$1 out=$2 report="${SBOM_TMP}/trivy.json" summary
    command -v trivy >/dev/null 2>&1 || return 0
    info "trivy found: looking for HIGH / CRITICAL vulnerabilities (may first download its database)…"
    if ! trivy sbom --quiet --severity HIGH,CRITICAL --format json --output "${report}" "${out}" >>"${LOG_FILE}" 2>&1 ||
        [[ ! -s "${report}" ]]; then
        warn "trivy failed (see the log): no vulnerability check. The SBOM is written all the same."
        return 0
    fi
    # Into a file, not $( ): bash 3.2 misparses a heredoc inside $( ).
    summary=${SBOM_TMP}/trivy.txt
    local rc=0
    "${py}" -I - "${report}" >"${summary}" 2>>"${LOG_FILE}" <<'PY' || rc=$?
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
vulns = []
for r in data.get("Results") or []:
    for v in r.get("Vulnerabilities") or []:
        fixed = v.get("FixedVersion")
        vulns.append(f"{v.get('Severity', '?')}\t{v.get('PkgName', '?')} {v.get('InstalledVersion', '')}: "
                     f"{v.get('VulnerabilityID', '?')}" + (f" (fixed in {fixed})" if fixed else ""))
crit = sum(1 for v in vulns if v.startswith("CRITICAL"))
print(f"count\t{len(vulns)}\t{crit}")
for v in sorted(vulns):
    print(v)
PY
    if ((rc != 0)); then
        warn "trivy's report couldn't be read (see the log)."
        return 0
    fi
    local n crit line i=0
    IFS=$'\t' read -r _ n crit <"${summary}"
    if [[ "${n}" == 0 ]]; then
        ok "trivy: no HIGH / CRITICAL vulnerability ${C_DIM}(only pypi and npm packages are covered)${C_RESET}"
        return 0
    fi
    warn "trivy: ${n} HIGH / CRITICAL vulnerability(ies), ${crit} critical ${C_DIM}(only pypi and npm packages are covered)${C_RESET}:"
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        log_detail "TRIVY: ${line}"
        ((i++ < SBOM_NAMES)) && say "      ${C_DIM}-${C_RESET} ${line/$'\t'/ }"
    done < <(tail -n +2 "${summary}")
    ((n <= SBOM_NAMES)) || say "      ${C_DIM}… $((n - SBOM_NAMES)) more, see the log${C_RESET}"
    say "    ${C_DIM}Full report: trivy sbom --severity HIGH,CRITICAL ${out}${C_RESET}"
}
