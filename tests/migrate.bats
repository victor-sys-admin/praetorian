#!/usr/bin/env bats
#
# --migrate, --migrate-all and --migration-report tests (lib/migrate.sh):
# known traps, homepages, companion ports, port select, binaries on
# packages.macports.org, several migrations in one session. Same fakes as
# tests/macports.bats; uname -m and -r are faked too (an Intel Mac on macOS
# 15), so the archive names do not depend on the machine running the tests.
#
# Each @test runs in its own subshell: the exported variables are meant to
# stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    local sys="${BATS_TEST_TMPDIR}/sys"
    mkdir -p "${sys}"
    cat >"${sys}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -m) echo x86_64 ;;
    -r) echo 24.6.0 ;;
    *) # uname -s and the rest: the real one (tests/stubs/mktemp needs it)
        for u in /usr/bin/uname /bin/uname; do [[ ! -x "${u}" ]] || exec "${u}" "$@"; done
        exit 1
        ;;
esac
EOF
    chmod +x "${sys}/uname"
    export PATH="${sys}:${BATS_TEST_DIRNAME}/stubs:${PATH}"
    export BREW_CALLS="${BATS_TEST_TMPDIR}/brew_calls"
    export PORT_CALLS="${BATS_TEST_TMPDIR}/port_calls"
    export SUDO_CALLS="${BATS_TEST_TMPDIR}/sudo_calls"
    export OSASCRIPT_CALLS="${BATS_TEST_TMPDIR}/osascript_calls"
    export CURL_URLS="${BATS_TEST_TMPDIR}/curl_urls"
    : >"${BREW_CALLS}"
    : >"${PORT_CALLS}"
    : >"${SUDO_CALLS}"
    : >"${CURL_URLS}"
    export PRAETORIAN_PORT_PREFIX="${BATS_TEST_TMPDIR}/opt"
    PRAETORIAN="${BATS_TEST_DIRNAME}/../praetorian"
    MIGRATED="${HOME}/praetorian/migrated.tsv"
    # Fake MacPorts installed in every test of this file.
    mkdir -p "${PRAETORIAN_PORT_PREFIX}/bin"
    cp "${BATS_TEST_DIRNAME}/stubs/port" "${PRAETORIAN_PORT_PREFIX}/bin/port"
}

# in_praetorian '<bash code>': runs code with praetorian's functions loaded
# (sourcing doesn't run main).
in_praetorian() {
    bash -c "source '${PRAETORIAN}'; $1"
}

# --- Unit: names, homepages, versioned commands -------------------------------

@test "unit: homepage_verdict" {
    # Both ways round. The real pairs of the 2026-10-17 migration stay
    # "match"; anything that doesn't tell two projects apart is "unknown"
    # (a "match" puts the formula in --migrate-all's list).
    local pairs=(
        "match https://www.gnu.org/software/wget/ http://gnu.org/software/wget"
        "match https://www.cmake.org/ https://cmake.org"
        "match https://legacy.imagemagick.org https://imagemagick.org"
        "match https://www.gnu.org/software/make/ https://www.gnu.org/software/make/make.html"
        "match https://www.ansible.com/ https://github.com/ansible/ansible"
        "match https://github.com/mysql/mysql-server https://dev.mysql.com"
        "match https://www.bbc.co.uk/a http://news.bbc.co.uk/"
        "match https://GitHub.com/Foo/Bar.git https://foo.dev/docs/index.html"
        "match https://github.com/a/x.git https://github.com/a/x"
        "match https://foo.github.io https://github.com/foo/foo"
        "match https://cran.r-project.org/web/packages/foo/index.html https://cran.r-project.org/web/packages/foo/"
        "match https://cli.github.com https://cli.github.com/"
        "mismatch https://smallstep.com https://www.kde.org"
        "mismatch https://www.gnu.org/software/guile/ https://www.gnu.org/software/make/"
        "mismatch https://jpeg.org/jpegxl/index.html https://github.com/libjxl/libjxl"
        "mismatch https://github.com/a/x https://github.com/b/x"
        "mismatch https://github.com/smallstep/cli https://github.com/smallstep/certificates"
        "mismatch https://github.com/google/foo https://github.com/google/bar"
        "mismatch https://code.google.com/p/foo https://code.google.com/p/bar"
        "mismatch https://hackage.haskell.org/package/foo https://hackage.haskell.org/package/bar"
        "mismatch https://cran.r-project.org/web/packages/foo https://cran.r-project.org/web/packages/bar"
        "mismatch https://rubygems.org/gems/foo https://rubygems.org/gems/bar"
        "mismatch https://ctan.org/pkg/foo https://ctan.org/pkg/bar"
        "mismatch https://pypi.org/project/foo https://pypi.org/project/bar"
        "mismatch https://metacpan.org/pod/Foo https://metacpan.org/pod/Bar"
        "mismatch https://cli.github.com https://desktop.github.com"
        "mismatch https://alice.github.io https://bob.github.io"
        "mismatch https://gitlab.gnome.org/GNOME/foo https://gitlab.gnome.org/GNOME/bar"
        "unknown https://github.com/alice/foo https://foo.sourceforge.net"
        "unknown https://github.com/alice/foo https://www.foo.org"
        "unknown https://sourceforge.net/ https://sourceforge.net/"
        "unknown https://hackage.haskell.org/package/ https://hackage.haskell.org/package"
        "unknown https://www.gnu.org/software/ https://gnu.org/software"
        "unknown https://github.com/google https://github.com/google/foo"
        "unknown https://a.example.com https://b.example.com"
        "unknown https://foo.sourceforge.net https://sourceforge.net/projects/foo"
        "unknown https://github.com/x/foo https://pypi.org/project/foo"
        "unknown not-a-url https://foo.org"
    )
    local line want a b
    for line in "${pairs[@]}"; do
        read -r want a b <<<"${line}"
        run in_praetorian "homepage_verdict '${a}' '${b}'"
        [ "${output}" = "${want}" ] || {
            echo "${a} vs ${b}: got ${output}, expected ${want}"
            false
        }
        run in_praetorian "homepage_verdict '${b}' '${a}'"
        [ "${output}" = "${want}" ] || {
            echo "${b} vs ${a}: got ${output}, expected ${want}"
            false
        }
    done
    run in_praetorian "homepage_verdict '' https://x.org"
    [ "${output}" = "unknown" ]
}

@test "unit: known_port_spec" {
    run in_praetorian "known_port_spec step | cut -f1"
    [ "${output}" = "step-cli,step-ca" ]
    run in_praetorian "known_port_spec python@3.13 | cut -f1"
    [ "${output}" = "python313" ]
    run in_praetorian "known_port_spec postgresql@17 | cut -f1"
    [ "${output}" = "postgresql17" ]
    run in_praetorian "known_port_spec node | cut -f1"
    [ "${output}" = "nodejs24,npm11" ]
    # The newest terraform-1.N of the index, numerically.
    run in_praetorian "known_port_spec hashicorp/tap/terraform \$'terraform\nterraform-1.9\nterraform-1.16\nterraform-1.15' | cut -f1"
    [ "${output}" = "terraform-1.16" ]
    run in_praetorian "known_port_spec wget"
    [ "${output}" = "" ]
    # Another tap: its name says nothing about MacPorts.
    run in_praetorian "known_port_spec someone/tap/step"
    [ "${output}" = "" ]
}

@test "unit: is_versioned_alias" {
    touch "${PRAETORIAN_PORT_PREFIX}/bin/aclocal" "${PRAETORIAN_PORT_PREFIX}/bin/python3"
    run in_praetorian "is_versioned_alias aclocal-1.19 && is_versioned_alias python3.12 && echo yes"
    [ "${output}" = "yes" ]
    run in_praetorian "is_versioned_alias foo-2 || is_versioned_alias aclocal || echo no"
    [ "${output}" = "no" ]
}

@test "unit: brew_homepages reads the formula's own homepage only" {
    export BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/ hashicorp/tap/terraform=https://www.terraform.io"
    mkdir -p "${HOME}/praetorian/logs"
    run in_praetorian "brew_homepages wget hashicorp/tap/terraform"
    [ "${output}" = $'wget\thttps://www.gnu.org/software/wget/\nhashicorp/tap/terraform\thttps://www.terraform.io' ]
    # One unknown name: brew refuses them all, asked one by one.
    run in_praetorian "brew_homepages nope wget"
    [ "${output}" = $'wget\thttps://www.gnu.org/software/wget/' ]
}

# --- Known traps and homepages ----------------------------------------------------

@test "--migrate: known trap without =port → blocked with the exact command, nothing installed" {
    export BREW_LIST_FILES="/usr/local/Cellar/step/0.28/bin/step"
    export PORT_AVAILABLE="step step-cli step-ca"
    run "${PRAETORIAN}" --migrate step
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: step has another spec in MacPorts: step=step-cli,step-ca"* ]] || false
    [[ "${output}" == *"KDE"* ]] || false
    [[ "${output}" == *"praetorian --migrate step=step-cli,step-ca"* ]] || false
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: tap terraform without =port → the newest terraform-1.N suggested" {
    export BREW_LIST_FILES="/usr/local/Cellar/terraform/1.13.0/bin/terraform"
    export PORT_AVAILABLE="terraform terraform-1.9 terraform-1.15 terraform-1.16"
    run "${PRAETORIAN}" --migrate hashicorp/tap/terraform
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"praetorian --migrate hashicorp/tap/terraform=terraform-1.16"* ]] || false
}

@test "--migrate: same name, different homepage → blocked unless the port is named" {
    export BREW_LIST_FILES="/usr/local/Cellar/foo/1.0/bin/foo"
    export PORT_AVAILABLE="foo" PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/foo"
    export BREW_HOMEPAGES="foo=https://foo.dev" PORT_INFO="foo=1.0_0,https://www.kde.org,MIT"
    run "${PRAETORIAN}" --migrate foo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: foo may not be the same software as foo"* ]] || false
    [[ "${output}" == *"Homebrew https://foo.dev, MacPorts https://www.kde.org"* ]] || false
    [[ "${output}" == *"praetorian --migrate foo=foo"* ]] || false
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]

    run "${PRAETORIAN}" --migrate foo=foo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"foo may be a different project than foo"* ]] || false
    [[ "${output}" == *"foo migrated to MacPorts (foo)."* ]] || false
}

@test "--migrate: same homepage → said so" {
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/wget"
    export BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/" PORT_INFO="wget=1.25.0_1,https://www.gnu.org/software/wget/,GPL-3+"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Same project: wget and wget have the same homepage"* ]] || false
}

# --- Companion ports, port select, versioned names ----------------------------

@test "--migrate: companion ports installed, commands checked across all of them" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/step/0.28/bin/step\n/usr/local/Cellar/step/0.28/bin/step-ca'
    export PORT_AVAILABLE="step-cli step-ca"
    export PORT_FILES="step-cli=bin/step step-ca=bin/step-ca"
    run "${PRAETORIAN}" --migrate step=step-cli,step-ca
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Migration: step (Homebrew) → step-cli + step-ca (MacPorts)"* ]] || false
    [[ "${output}" == *"from step-cli: step "* ]] || false
    [[ "${output}" == *"from step-ca: step-ca "* ]] || false
    grep -qx -- '-N install step-cli' "${PORT_CALLS}"
    grep -qx -- '-N install step-ca' "${PORT_CALLS}"
    grep -qx 'uninstall --formula step' "${BREW_CALLS}"
    run cut -f1,2 "${MIGRATED}"
    [ "${output}" = $'step\tstep-cli,step-ca' ]
}

@test "--migrate: companion already active → marked as requested, not reinstalled" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/rust/1.90/bin/rustc\n/usr/local/Cellar/rust/1.90/bin/cargo'
    export PORT_AVAILABLE="rust cargo" PORT_ACTIVE="cargo"
    export PORT_FILES="rust=bin/rustc"
    touch "${PRAETORIAN_PORT_PREFIX}/bin/cargo"
    run "${PRAETORIAN}" --migrate rust=rust,cargo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"from rust: rustc "* ]] || false
    # cargo isn't in "port contents rust": from another port.
    [[ "${output}" == *"from port select links or other ports: cargo"* ]] || false
    grep -qx -- '-N install rust' "${PORT_CALLS}"
    grep -qx -- '-N setrequested cargo' "${PORT_CALLS}"
    run grep -qx -- '-N install cargo' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: command missing → port select for a group set to none, then checked again" {
    export BREW_LIST_FILES="/usr/local/Cellar/terraform/1.13.0/bin/terraform"
    export PORT_AVAILABLE="terraform-1.16" PORT_FILES="terraform-1.16=bin/terraform-1.16"
    export PORT_SELECT="terraform=none=terraform1.16 python3=python313=python312,python313"
    export PORT_SELECT_FILES="terraform1.16=bin/terraform"
    run "${PRAETORIAN}" --migrate hashicorp/tap/terraform=terraform-1.16
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Selecting terraform1.16 for terraform (port select)"* ]] || false
    [[ "${output}" == *"hashicorp/tap/terraform migrated to MacPorts (terraform-1.16)."* ]] || false
    grep -qx -- 'select --set terraform terraform1.16' "${PORT_CALLS}"
    grep -q 'select --set terraform terraform1.16' "${SUDO_CALLS}"
    # A group already chosen is never touched.
    run grep -q 'select --set python3' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: group already set to something else → not changed, blocked" {
    export BREW_LIST_FILES="/usr/local/Cellar/guile/3.0.10/bin/guile"
    export PORT_AVAILABLE="guile-3.0" PORT_FILES="guile-3.0=bin/guile-3.0"
    export PORT_SELECT="guile=guile-2.2=guile-2.2,guile-3.0"
    run "${PRAETORIAN}" --migrate guile=guile-3.0
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"doesn't provide every command of guile"* ]] || false
    [[ "${output}" == *"Missing in ${PRAETORIAN_PORT_PREFIX}/bin and sbin: guile "* ]] || false
    run grep -q 'select --set' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: only another version in a command's name → harmless, migrated" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/automake/1.19/bin/aclocal\n/usr/local/Cellar/automake/1.19/bin/aclocal-1.19'
    export PORT_AVAILABLE="automake" PORT_FILES="automake=bin/aclocal,bin/aclocal-1.18"
    run "${PRAETORIAN}" --migrate automake
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Harmless differences (another version in the name, the plain name is there): aclocal-1.19"* ]] || false
    grep -qx 'uninstall --formula automake' "${BREW_CALLS}"
}

# --- Precompiled binaries ---------------------------------------------------------

@test "--migrate: no binary for this Mac → blocked, an older version with one suggested" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/node/26.1/bin/node\n/usr/local/Cellar/node/26.1/bin/npm'
    export PORT_AVAILABLE="nodejs22 nodejs24 nodejs26 npm11"
    export PORT_FILES="nodejs26=bin/node npm11=bin/npm"
    export CURL_PACKAGES="nodejs24-1.0_0.darwin_24.x86_64.tbz2 npm11-1.0_0.any_any.noarch.tbz2"
    run "${PRAETORIAN}" --migrate node=nodejs26,npm11
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: no precompiled MacPorts binary of nodejs26 for this Mac"* ]] || false
    [[ "${output}" == *"(darwin 24) on x86_64"* ]] || false
    [[ "${output}" == *"nodejs24 has a binary: praetorian --migrate node=nodejs24,npm11"* ]] || false
    [[ "${output}" == *"praetorian --allow-build --migrate node=nodejs26,npm11"* ]] || false
    grep -qx 'https://packages.macports.org/nodejs26/nodejs26-1.0_0.darwin_24.x86_64.tbz2' "${CURL_URLS}"
    grep -qx 'https://packages.macports.org/nodejs26/nodejs26-1.0_0.any_any.noarch.tbz2' "${CURL_URLS}"
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]

    run "${PRAETORIAN}" --allow-build --migrate node=nodejs26,npm11
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MacPorts will compile from source (--allow-build)"* ]] || false
    grep -qx -- '-N install nodejs26' "${PORT_CALLS}"
}

@test "--migrate: archive name carries the default variants" {
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/wget"
    export PORT_INFO="wget=1.25.0_1,,GPL-3+" PORT_DEFAULT_VARIANTS="wget=ssl,gnutls"
    export CURL_PACKAGES="wget-1.25.0_1+gnutls+ssl.darwin_24.x86_64.tbz2"
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Precompiled binary of wget available for this Mac"* ]] || false
    [ "$(wc -l <"${CURL_URLS}" | tr -d ' ')" -eq 1 ]
}

@test "--migrate: packages.macports.org unreachable or license without binary → not blocking" {
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" PORT_CONTENTS="${PRAETORIAN_PORT_PREFIX}/bin/wget"
    export CURL_PACKAGES=offline
    run "${PRAETORIAN}" --migrate wget
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"binary not checked (packages.macports.org didn't answer)"* ]] || false
    # One request only: no waiting for every timeout.
    [ "$(wc -l <"${CURL_URLS}" | tr -d ' ')" -eq 1 ]

    : >"${CURL_URLS}"
    export BREW_LIST_FILES="/usr/local/Cellar/terraform/1.13.0/bin/terraform"
    export PORT_AVAILABLE="terraform-1.16" PORT_INFO="terraform-1.16=1.16.6_0,,Commercial"
    export PORT_FILES="terraform-1.16=bin/terraform" CURL_PACKAGES=""
    run "${PRAETORIAN}" --migrate hashicorp/tap/terraform=terraform-1.16
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"its license doesn't let MacPorts distribute one"* ]] || false
    [ ! -s "${CURL_URLS}" ]
}

# --- Dry-run and programs outside Homebrew ------------------------------------------

@test "--migrate --dry-run: plan per port, nothing installed, no sudo" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/rust/1.90/bin/rustc\n/usr/local/Cellar/rust/1.90/bin/cargo'
    export PORT_AVAILABLE="rust cargo" PORT_ACTIVE="cargo"
    run "${PRAETORIAN}" --dry-run --migrate rust=rust,cargo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1. sudo port -N install rust"* ]] || false
    [[ "${output}" == *"2. sudo port -N setrequested cargo   (already installed"* ]] || false
    run grep -qwE 'install|setrequested|select' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    [ ! -s "${SUDO_CALLS}" ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate: program outside Homebrew uses the formula → blocked before the uninstall" {
    export BREW_LIST_FILES="/usr/local/Cellar/python@3.12/3.12.9/bin/python3.12"
    export PORT_AVAILABLE="python312" PORT_FILES="python312=bin/python3.12"
    export PRAETORIAN_CAFFEINATED=1
    # shellcheck disable=SC2016  # $1 is expanded by the inner bash
    run in_praetorian 'formula_external_users() { echo "pipx environment poetry (python3.12 from $1)"; }; main --migrate python@3.12=python312'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BLOCKED: programs outside Homebrew still use python@3.12"* ]] || false
    [[ "${output}" == *"pipx environment poetry (python3.12 from python@3.12)"* ]] || false
    [[ "${output}" == *"pipx reinstall <package> --python ${PRAETORIAN_PORT_PREFIX}/bin/python3.12"* ]] || false
    grep -qx -- '-N install python312' "${PORT_CALLS}"
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    [ ! -e "${MIGRATED}" ]
}

# --- Several migrations in one session --------------------------------------------

@test "batch: a formula others depend on waits for them, then goes" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/libfoo/1.0/bin/foo-config\n/usr/local/Cellar/app/2.0/bin/app'
    export PORT_AVAILABLE="libfoo app" PORT_FILES="libfoo=bin/foo-config app=bin/app"
    export BREW_USES_MAP="libfoo:app"
    run "${PRAETORIAN}" --migrate libfoo --migrate app
    [ "${status}" -eq 0 ]
    [ "$(grep '^uninstall' "${BREW_CALLS}" | tr '\n' ' ')" = "uninstall --formula app uninstall --formula libfoo " ]
    [[ "${output}" == *"Migrations: one line per formula"* ]] || false
    [[ "${output}" == *"app: migrated"* ]] || false
    [[ "${output}" == *"libfoo: migrated"* ]] || false
    [[ "${output}" == *"2 migrated, 0 blocked, 0 skipped."* ]] || false
    [[ "${output}" != *"BLOCKED"* ]] || false
}

@test "batch: a blocked formula doesn't stop the others, code 2, one line each" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/wget/1.25/bin/wget\n/usr/local/Cellar/step/0.28/bin/step'
    export PORT_AVAILABLE="wget step step-cli" PORT_FILES="wget=bin/wget"
    run "${PRAETORIAN}" --migrate step --migrate wget --migrate wget=wget
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"step: blocked: step has another spec in MacPorts: step=step-cli,step-ca"* ]] || false
    [[ "${output}" == *"wget: migrated"* ]] || false
    [[ "${output}" == *"wget=wget: skipped: wget already in the list"* ]] || false
    [[ "${output}" == *"1 migrated, 1 blocked, 1 skipped."* ]] || false
    grep -qx 'uninstall --formula wget' "${BREW_CALLS}"
}

@test "batch --dry-run: dependency order simulated, nothing changed" {
    export BREW_LIST_FILES=$'/usr/local/Cellar/libfoo/1.0/bin/foo-config\n/usr/local/Cellar/app/2.0/bin/app'
    export PORT_AVAILABLE="libfoo app"
    export BREW_USES_MAP="libfoo:app"
    run "${PRAETORIAN}" --dry-run --migrate libfoo --migrate app
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"app: checks passed (dry-run, nothing changed)"* ]] || false
    [[ "${output}" == *"libfoo: checks passed (dry-run, nothing changed)"* ]] || false
    [[ "${output}" == *"2 ready, 0 blocked, 0 skipped (dry-run: nothing was changed)."* ]] || false
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migrate-all: only same name + same homepage + no note" {
    export BREW_LEAVES=$'wget\nstep\nfoo\nbar\nqux'
    export BREW_LIST_FILES=$'/usr/local/Cellar/wget/1.25/bin/wget\n/usr/local/Cellar/qux/1/bin/qux'
    export PORT_AVAILABLE="wget step step-cli step-ca foo bar qux" PORT_FILES="wget=bin/wget qux=bin/qux"
    export BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/ foo=https://foo.dev bar=https://bar.dev qux=https://qux.org"
    export PORT_INFO="wget=1.0_0,https://www.gnu.org/software/wget/,GPL foo=1.0_0,https://www.kde.org,MIT qux=1.0_0,https://qux.org,MIT"
    # qux: referenced in ~/.zshrc, left out.
    export BREW_PREFIX=/usr/local
    # shellcheck disable=SC2016  # $PATH stays literal: it's the file's content
    echo 'export PATH=/usr/local/opt/qux/bin:$PATH' >"${HOME}/.zshrc"
    run "${PRAETORIAN}" --migrate-all
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 formula(e) with the same name and the same homepage in MacPorts, nothing blocking: wget"* ]] || false
    [[ "${output}" == *"wget: migrated"* ]] || false
    [ "$(grep -c '^uninstall' "${BREW_CALLS}")" -eq 1 ]
    grep -qx 'uninstall --formula wget' "${BREW_CALLS}"
}

@test "--migrate-all: inconclusive homepages and invalid names left out" {
    # baz: github.com/alice/baz and baz.org only share the name → not ready.
    # x..y: not a formula name (brew leaves is not trusted) → skipped.
    export BREW_LEAVES=$'wget\nbaz\nx..y'
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget baz x..y" PORT_FILES="wget=bin/wget"
    export BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/ baz=https://github.com/alice/baz x..y=https://x.org"
    export PORT_INFO="wget=1.0_0,https://www.gnu.org/software/wget/,GPL baz=1.0_0,https://www.baz.org,MIT x..y=1.0_0,https://x.org,MIT"
    run "${PRAETORIAN}" --migrate-all
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 formula(e) with the same name and the same homepage in MacPorts, nothing blocking: wget x..y"* ]] || false
    [[ "${output}" == *"wget: migrated"* ]] || false
    [[ "${output}" == *"x..y: skipped: invalid name"* ]] || false
    [[ "${output}" != *"baz: "* ]] || false
    run grep -F 'x..y' "${PORT_CALLS}" "${SUDO_CALLS}"
    [[ "${output}" != *install* ]] || false
    run grep -E 'baz|x\.\.y' "${BREW_CALLS}"
    [[ "${output}" != *uninstall* ]] || false
    [ "$(grep -c '^uninstall' "${BREW_CALLS}")" -eq 1 ]
}

@test "--migrate-all --dry-run: nothing changed" {
    export BREW_LEAVES="wget"
    export BREW_LIST_FILES="/usr/local/Cellar/wget/1.25/bin/wget"
    export PORT_AVAILABLE="wget" BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/"
    export PORT_INFO="wget=1.0_0,https://www.gnu.org/software/wget/,GPL"
    run "${PRAETORIAN}" --dry-run --migrate-all
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"wget: checks passed (dry-run, nothing changed)"* ]] || false
    run grep -qw install "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
    run grep -q '^uninstall' "${BREW_CALLS}"
    [ "${status}" -eq 1 ]
    [ ! -s "${SUDO_CALLS}" ]
}

# --- --migration-report ---------------------------------------------------------------

@test "--migration-report: traps, different homepages and missing binaries shown" {
    export BREW_LEAVES=$'wget\nstep\nfoo\ncurl'
    export PORT_AVAILABLE="wget step step-cli step-ca foo curl"
    export BREW_HOMEPAGES="wget=https://www.gnu.org/software/wget/ foo=https://foo.dev curl=https://curl.se"
    export PORT_INFO="wget=1.0_0,https://www.gnu.org/software/wget/,GPL foo=1.0_0,https://www.kde.org,MIT curl=1.0_0,https://curl.se/,MIT"
    export CURL_PACKAGES="curl-1.0_0.darwin_24.x86_64.tbz2 step-cli-1.0_0.darwin_24.x86_64.tbz2 step-ca-1.0_0.darwin_24.x86_64.tbz2"
    run "${PRAETORIAN}" --migration-report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Same name in MacPorts (2)"* ]] || false
    [[ "${output}" == *"- wget [no binary for this Mac: wget]"* ]] || false
    [[ "${output}" == *"- curl"$'\n'* ]] || false
    [[ "${output}" == *"migrates the 1 of them"* ]] || false
    [[ "${output}" == *"Same name, but maybe a different project (1)"* ]] || false
    [[ "${output}" == *"foo (Homebrew: https://foo.dev — MacPorts: https://www.kde.org)"* ]] || false
    [[ "${output}" == *"step → step-cli,step-ca (praetorian --migrate step=step-cli,step-ca)"* ]] || false
    [[ "${output}" == *"4 port(s) checked, 1 without one."* ]] || false
    # Legend: only the notes shown above (no service, no shell file here).
    [[ "${output}" == *"[no binary for this Mac: …] → MacPorts would compile it"* ]] || false
    [[ "${output}" != *"[brew service running]"* ]] || false
    [[ "${output}" != *"[referenced in ~/.zshrc…]"* ]] || false
    run grep -wE 'install|uninstall|selfupdate|select|setrequested' "${PORT_CALLS}"
    [ "${status}" -eq 1 ]
}

@test "--migration-report: packages.macports.org unreachable → binaries not checked, no note" {
    export BREW_LEAVES=$'wget\ncurl'
    export PORT_AVAILABLE="wget curl" CURL_PACKAGES=offline
    run "${PRAETORIAN}" --migration-report
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"[no binary"* ]] || false
    [[ "${output}" == *"packages.macports.org didn't answer: 1 port(s) not checked"* ]] || false
    [ "$(wc -l <"${CURL_URLS}" | tr -d ' ')" -eq 1 ]
}
