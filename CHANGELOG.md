# Changelog

All notable changes to praetorian are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version printed by `praetorian --help` and the latest version in the
README (section "Latest release") must match, and so must the first
numbered entry of this file: a test checks all three. Changes merged
since that release are listed under "Unreleased", above it, until the
next version takes them. Git tags start at 1.5.0: the earlier versions
have none.

## Unreleased

### Added

- Settings outside the shell startup files that name a formula's
  Homebrew paths are now looked for: a Git credential helper
  (`!/usr/local/bin/gh auth git-credential`), an editor's interpreter, a
  launch agent or daemon, a crontab line. A read-only search of the
  configuration files in your home dotfiles, `~/.config`,
  `~/Library/Application Support`, `~/Library/Preferences`, the launch
  agents and daemons, and your crontab, for `<prefix>/opt/<formula>`,
  `<prefix>/Cellar/<formula>/` and the formula's commands in
  `<prefix>/bin`. Never a block: `--migration-report` notes it on the
  formula's line, `--migrate` warns before the install and lists the
  lines again after the uninstall with the MacPorts path, and `--doctor`
  reports the settings whose Homebrew path is already gone. A binary
  plist is read with `plutil`, and the MacPorts installer's backup copies
  (`.zprofile.macports-saved_…`) are skipped.
- Free disk space is checked again before each formula upgrade, not
  only before the session: the source downloads and every build eat into
  it. Below the minimum (10 GB), the formulae left and the casks are
  skipped, `brew autoremove` and `brew cleanup` still run, and a block
  lists what wasn't upgraded.
- With `HOMEBREW_NO_INSTALL_CLEANUP` set, Homebrew no longer removes an
  upgraded formula's old version: praetorian now runs `brew cleanup
  <formula>` after each upgrade instead of leaving it to the final
  cleanup.
- When a formula and its port have different homepages, the report and
  `--migrate` can ask both project sites whether one forwards to the
  other (a project that moved): on a terminal, they ask you once first
  (the default is no); `--allow-project-site-requests` answers yes in
  advance. One HEAD request per site, over https, following up to 5
  redirects, nothing downloaded. A homepage that forwards to the other
  is the same project, never taken by `--migrate-all`.
- `--limit N` and `--exclude a,b`, with `--migrate-all` only, to take
  part of its list. `--limit` stops after N formulae migrated, counted in
  the order they are actually migrated; blocked ones don't count, nothing
  more of the list runs once N is reached (not even the last try of the
  ones still waiting), and the rest is listed as `skipped: --limit
  reached`. In a dry run, "checks passed" counts. `--exclude` leaves the
  formulae named out of the list (`skipped: excluded`); a name that isn't
  an installed formula blocks the run before anything is migrated, one
  not in the list gets an info line. Formulae given with `--migrate` in
  the same run are left as they are. Both are per run: nothing is
  remembered.

### Fixed

- An unattended session could wait all night on a macOS keychain
  dialog: after a failed build, brew's search for known issues looks
  for a GitHub token in the keychain too. Unattended sessions now set
  `HOMEBREW_NO_GITHUB_API`, which skips that search.
- Any formula failing on "An unsatisfied requirement failed this build"
  was taken for one that needs full Xcode, so the summary said to install
  Xcode for a formula that needs an `arm64` Mac, and on a Mac with Xcode
  it was retried every session. The Xcode advice now needs Homebrew's
  Xcode message as the only requirement, with an Xcode this macOS can
  run; the other cases are quarantined for 30 days as `requirement`. A
  formula with several requirements not met ("Unsatisfied requirements
  failed this build") is quarantined too, instead of retried every
  session.
- A formula whose upgrade failed to build, then got built later in the
  session as another formula's dependency, stayed quarantined for 7
  days and was listed in the failed steps. Once the formula upgrades
  are done, a formula quarantined for a failed build (in this session
  or an earlier one) that is installed and current is lifted, and so
  is a formula held back only by such dependencies.
- `ci/macos-tests --jobs N` ran no test: the script resets the PATH,
  and bats needs GNU parallel for `--jobs`. It now keeps `parallel`,
  and only that, in the PATH.
- `--migrate` blocked an obsolete MacPorts port (`docbook-xsl`, replaced
  by `docbook-xsl-nons`) for lack of a binary that will never exist, and
  the report listed it under "Same name". Both now point to the
  replacement.
- `praetorian-sudo-setup` could say "No fingerprint enrolled" with one
  enrolled: `grep -q` left at the first match and `bioutil`, still
  writing, failed the pipeline (seen as a test that failed now and
  then). The output is now read in full first.
- A formula whose upgrade failed was counted as installed when
  `brew outdated` failed too (no output, like an up-to-date formula).
  It now takes a `brew outdated` that succeeds and no longer lists it.
- `tests/schedule.bats` failed under a umask of 002 (directories
  writable by the group, which `praetorian-schedule` refuses): the
  tests set 022.
- A `PRAETORIAN_HOME` that is a file, can't be written to or can't be
  created ended in "unexpected error in praetorian" with a log that
  didn't exist. It's now a block that says which of those it is, before
  anything is written. One that belongs to another user, or that
  everyone can write to, is refused too.
- Without `HOME`, praetorian stopped on bash's "HOME: unbound variable".
  It now says so in one line.
- Started as `bash praetorian`, a session failed with "praetorian: not
  found" (or ran another praetorian found in the `PATH`) when it started
  itself again under `caffeinate`. It now uses its full path.
- A lock whose PID had been reused by another program after a crash or a
  power cut blocked every later session until `.lock` was removed by
  hand. The lock now counts as held only when that PID is a praetorian.
- Closing the terminal during a session (`SIGHUP`) ended in "unexpected
  error": it now stops like Ctrl-C (step killed, lock released, code
  130).
- `launchd.stderr.log` grew without limit: past 1 MB, a session keeps
  its last 500 lines.
- `praetorian-schedule status` read a `PRAETORIAN_HOME` containing `&`,
  `<` or `>` as written in the plist (`&amp;`), and found no log there.
- `ci/macos-tests tests/<file>.bats` ran the whole suite and that file
  a second time. Given test files, it now runs only those.
- The "no precompiled MacPorts binary" block gave examples from one Mac
  ("every mysql port on this Mac") on every Mac. They're gone from the
  message; the README keeps them, for macOS 15 on Intel.
- Two homepages of one project were compared as different:
  `git-lfs.github.com` (the old form of a GitHub Pages address, read as
  `git-lfs.github.io`: now inconclusive against `git-lfs.com`) and
  `gi.readthedocs.io/en/latest/` (the language and version of a Read the
  Docs path are ignored: now the same as `gi.readthedocs.io`).
- The notes MacPorts gives after installing or upgrading a port ("Some
  of the ports you installed have notes") only reached the log. The
  ports that have some are now named, with the `port notes` command
  that shows them.
- A progress line wider than the terminal (a long label and MacPorts'
  "Attempting to fetch … from https://…" in an 80-column window) wrapped,
  and each redraw left its first screen line behind. It's now cut to the
  terminal's width.
- `--migrate` blocked for a port with no precompiled binary always said
  "binaries often appear a few days after a new version", also for ports
  MacPorts has never published an archive of, for any version or Mac.
  When it blocks, one more HEAD request per port without a binary, on
  the port's directory on `packages.macports.org`, tells them apart: a
  404 means no archive of any version so far, and the block now says so
  ("unless the port is new, a binary is unlikely to come"). A redirect,
  another status or no answer keeps the message as it was; with several
  ports, the advice to wait goes only if all of them answer 404. The
  report doesn't make these requests.
- A tap formula (`user/tap/foo` in `brew outdated`, `foo` in its build
  log) was quarantined twice when its own build failed, once as a
  dependency of itself; failing as another formula's dependency, it was
  built and failed again later in the same session; an entry `foo` didn't
  keep `user/tap/foo` out of the next session; and built later as a
  dependency, its failed step stayed. Failed builds are now quarantined
  under the session's name, and the quarantine, the same-session skip
  and the failed steps compare the short name too.

### Security

- `praetorian-sudo-setup` ran `grep`, `sed`, `awk`, `mv` and `chown` as
  root from the caller's `PATH`, which sudo keeps on macOS. As root, it
  now sets the `PATH` to macOS's own directories.

### Changed

- The minimum free disk space is 10 GB instead of 5, for the large
  builds from source that are now common on Intel Macs. Below it, the
  session is blocked before anything runs, and the formula upgrades stop
  before the next one. A Mac with 5 to 10 GB free, which ran before, is
  now blocked, unattended sessions too. The 20 GB warning is unchanged.
- `ci/check` runs the tests 4 at a time (`bats --jobs 4`; GNU parallel
  is in the bats container), in CI too.
- CI: the two jobs stop after 60 minutes instead of GitHub's 6 hours,
  and Dependabot proposes updates of the actions pinned by commit.
- Each step waited at least 2 seconds, the interval at which its output
  is copied to the log and the progress line redrawn, even when the
  command ended at once (`port select`, `brew link`…). The first second
  is now checked every 0.5 s: short steps end sooner, and so do the
  tests. Longer steps are unchanged.

## 1.5.2 - 2026-11-09

### Fixed

- `--doctor` said a formula "isn't installed", and told you to remove its
  `PATH` entry, when the formula was installed and only its `opt` link
  was missing. It now says so and gives the `brew link` command.
- `--doctor` missed a link in the Homebrew prefix that only its owner can
  read, such as a root-only link an app's installer put in
  `/usr/local/bin`: `brew cleanup` stops on it. It now reports it, with
  the `sudo chmod -h 755` that lets you read it and leaves it the owner's.

## 1.5.1 - 2026-11-08

### Fixed

- macOS's own curl (8.7.1) exits 56, not 22, for a 404 over HTTP/2, so
  the binary check read every 404 as "no answer": the noarch archive
  names were never tried, and `--migration-report` stopped checking
  after the first one. It now reads the HTTP code; a 403 or a 5xx is no
  answer, not a missing archive.
- `--migration-report` explained every kind of `[ ]` note, even those
  that didn't appear (a `[brew service running]` legend with no service
  running): it now explains only the notes listed above it.

## 1.5.0 - 2026-10-18

Shaped by the day the author's Intel Mac moved from Homebrew to MacPorts
(2026-10-17, about 60 real migrations): see "Migration day" in the
README's project history. 1.4.0 was never bumped in the code; this
version carries both.

### Added

- `--migrate <formula>=<port>,<port>…`: companion ports, installed with
  the main one and checked together (`step=step-cli,step-ca`,
  `rust=rust,cargo`, `node=nodejs24,npm11`). `migrated.tsv` records
  every port, comma-separated.
- `--migrate` repeated and `--migrate-all`: several migrations in one
  session (one lock). Formulae nothing depends on go first; one that
  others depend on waits and is tried again once a pass migrated
  something. A blocked formula doesn't stop the others; a summary lists
  each one as migrated, blocked (with the block's title) or skipped, and
  the session ends with code 2 if any was blocked. `--migrate-all` takes
  the formulae of the report's "Same name" group with the same homepage
  and no `[ ]` note, nothing else; a name that isn't a valid spec is
  skipped before brew, port or sudo run. With `--dry-run`, the dependency
  order is simulated and nothing changes.
- Known MacPorts traps, a built-in table (`step` → `step-cli,step-ca`,
  `ansible` → `py-ansible`, `guile` → `guile-3.0`, `docker-compose` →
  `docker-compose-plugin`, `cmake` → `cmake-devel`, `terraform` → the
  newest `terraform-1.N`, `imagemagick` → `ImageMagick7`, `node` →
  `nodejs24,npm11`, `mysql-client` → `mysql-innovation`, and more: see
  the README). The report suggests the exact spec; `--migrate <formula>`
  without `=` blocks with the exact command instead of guessing.
- Homepage comparison (`brew info --json=v2` against `port info
  --homepage`): a same-name port with another homepage "may be a
  different project". In the report, its own group, left out of
  `--migrate-all`; in `--migrate`, a block when the port was only guessed
  from the name, a warning when you named it with `=`. Two code-host URLs
  must name the same organization and repository; shared sites
  (SourceForge, GNU, PyPI, `*.github.io`…) need the same host and project
  path. Anything ambiguous is inconclusive, never "same project", and
  `--migrate-all` leaves it out.
- Precompiled binary check: before installing, a HEAD request (10 s,
  nothing downloaded) to `packages.macports.org` for the archive of this
  Mac. None: blocked unless `--allow-build` (new option), with an older
  version of the same port that has one when there is (`nodejs26` →
  `nodejs24`). No network, no `curl`, or a license MacPorts may not
  redistribute (`terraform-1.N`): no verdict, never a block. The report
  marks `[no binary for this Mac]`.
- `port select`: commands still missing after the install are looked
  for in the `port select` groups set to `none` whose options name a
  port just installed; the group is set and the commands checked again.
  A group already set to something else is never changed.
- Before the uninstall, programs outside Homebrew that use the formula
  (pipx environments on a Homebrew Python, npm global packages) block
  it, with the fix. The MacPorts port stays installed, so you can move
  them and run `--migrate` again.
- Unattended sessions wait for the network: up to
  `PRAETORIAN_NETWORK_WAIT` seconds (default 300) for `github.com` to
  answer before anything starts. Still offline: blocked (exit code 1);
  with `--dry-run`, a warning. From a terminal, no wait.
- `--status`: read-only summary built from what brew and port answer
  now, not from the logs: migrated formulae checked one by one, formulae
  still in Homebrew and why (with the exact spec for a known trap),
  leftover dependencies (pointing to `--dry-run --prune`, never to
  `port uninstall leaves`), counts, and the last 10 sessions from their
  logs. No sudo, no lock.
- `--doctor`: read-only health check, with the command that fixes each
  problem (praetorian runs none of them, and never sudo): broken pipx
  environments or ones on a Homebrew Python, files in the Homebrew
  prefix that don't belong to you, dead `PATH` entries (with the shell
  file and line), broken JDK links, empty Cellar directories, npm global
  packages left without `node` (those of a node not from Homebrew, such
  as the nodejs.org installer in `/usr/local`, are left alone), migrated
  ports MacPorts sees as plain dependencies, casks from an untrusted tap,
  the stale C++ headers of the Command Line Tools (only for CLT 16 and
  later, or when an SDK has its own). Every name in a printed command is
  shell-quoted, so a pasted fix can't run anything else; an unreadable
  directory or file only skips what it hides. Exit code 0 when nothing
  is found, 2 otherwise. No lock taken.
- `--prune`: removes the Homebrew formulae nothing uses any more, which
  `brew autoremove` misses (formulae without the
  `installed_as_dependency` flag), minus anything a program outside
  Homebrew, a Homebrew service or your shell startup files still use.
  Rounds until nothing is left (10 at most), each one shown and confirmed
  (default: no). `--dry-run` lists the first round; unattended, nothing
  is removed. MacPorts' `port echo leaves` is reported, never removed.
- `--sbom`: CycloneDX 1.6 JSON inventory of the installed software
  (Homebrew formulae and casks, active MacPorts ports with their
  variants, apps, pipx environments, npm global packages) in
  `logs/sbom_<timestamp>.cdx.json` (mode `600`), with the components
  added, removed and changed since the previous one. The JSON is written
  by Python's `json` module (`python3 -I`); without a working Python, a
  block says what to install (exit code 1). When `trivy` is installed,
  its HIGH and CRITICAL findings are summarized; a trivy failure never
  fails the run.
- `.macos_version` in `PRAETORIAN_HOME`: the macOS version seen by the
  last real session.
- Tests: `tests/migrate.bats`, `tests/doctor.bats`, `tests/prune.bats`,
  `tests/status.bats`, `tests/sbom.bats` (skipped without `python3`,
  except the "no Python" block), `tests/xcode.bats`; a fake `curl`; the
  fakes `brew` and `port` answer many more commands (see the README).

### Changed

- `--migrate` checks the formula's commands by what is really installed:
  a command counts when `/opt/local/bin` or `sbin` has it, whatever port
  put it there (a companion, a `port select` link, a port installed
  before), instead of only `port contents <port>`. The output says which
  port each one comes from. A command that differs only by the version
  in its name (`aclocal-1.19` when MacPorts has `aclocal`) is listed as a
  harmless difference instead of blocking.
- `--migration-report`: known traps suggest the exact `--migrate` spec;
  a new "Same name, but maybe a different project" group; "Same name"
  says how many `--migrate-all` would take.
- The "Homebrew / MacPorts side by side" section lists only the formulae
  nothing else needs (`brew leaves`) whose commands also come with
  MacPorts, grouped by formula: the ones you can migrate or remove.
  Duplicates from dependencies of formulae kept in Homebrew are one
  informational line.
- Log rotation keeps every log younger than 7 days on top of the last
  30 (session logs, build and port log archives, SBOMs).
- "Xcode isn't ready" lists only the command for the problem found
  (`xcode-select -s`, `-license accept` or `-runFirstLaunch`) instead of
  all three. A first launch pending because macOS was updated since the
  previous session is named as such.
- `ci/check` picks the first container engine whose daemon answers
  (`docker info`, then `podman info`), not the first one installed.
- Tests: every `[[ ]]` assertion that isn't a test's last command ends
  with `|| false`, in every file, so a failure also fails the test under
  macOS's bash 3.2.

### Fixed

- `--migrate` compared every `bin` directory of the keg, internal ones
  included (`libexec/bin` of pipx and scons, `lib/rustlib/…/bin` of
  rust): 4 migrations were refused for commands MacPorts has no reason
  to ship. Only what brew links into the `PATH`
  (`Cellar/<formula>/<version>/bin` and `sbin`) is compared now.
- `--migrate` no longer refuses migrations whose commands come from
  another port or a `port select` link (terraform through
  `terraform-1.16`, `cargo` from the `cargo` port, `step-ca`).
- `--migrate step` no longer installs KDE's `step` instead of
  smallstep's `step-cli`; same for the other known traps.
- `--migrate` marks a port that was already active (installed as a
  dependency) as requested (`port setrequested`): `port uninstall leaves`
  would otherwise remove the tool just migrated to (9 ports were in that
  state: `go`, `autoconf`…).
- A migration loop (45 sessions in one afternoon) no longer rotates away
  the logs of its own first failures.
- An overnight session started at wake-up, before the Wi-Fi was back:
  `brew update` failed and downloads retried for an hour. It now waits
  for the network, then blocks.
- `ci/check` failed every check when a docker CLI with no daemon
  (pulled in by MacPorts' `docker-compose-plugin`) sat next to a running
  podman.

## 1.4.0 - 2026-10-16

### Added

- `praetorian-schedule`: runs praetorian overnight with a per-user
  `launchd` job (`install [--at HH:MM] [--weekday DAY] [--dry-run]`,
  `uninstall`, `status`), as `praetorian --unattended --ac-power-only`,
  with no sudo and no stored password. Refuses to install when
  `praetorian` or its directory could be changed by another user, or when
  the repository or `PRAETORIAN_HOME` is in a folder macOS keeps from
  background jobs (`~/Documents`, `~/Desktop`, `~/Downloads`, iCloud
  Drive, `/Volumes`). The plist is checked with `plutil -lint` before it's
  loaded, and a previous job is put back if loading the new one fails.
  `status` exits 0 (installed and loaded), 1 (something to fix) or 3 (not
  installed).
- `--ac-power-only`: blocks the session (exit code 1) when the Mac is on
  battery or UPS power; skipped with a warning when the power source can't
  be read.
- `--notify` and `--no-notify`: always or never send the end-of-session
  notification. `PRAETORIAN_NOTIFY_AFTER` (seconds, default 300).
- Tests: `tests/notify.bats`, `tests/schedule.bats`; fakes `launchctl`,
  `plutil` (the real one on macOS) and `pmset`.

### Changed

- The end-of-session notification is also sent from a terminal when the
  session took 5 minutes or more, with a sound (none when unattended). It
  now has a subtitle with the outcome and the duration.
- A session that stops before its summary (a block such as the lock, the
  disk, the battery or Xcode, or an unexpected error) now sends a
  "Stopped" notification naming the block. Not after Ctrl-C.
- `osascript` runs with a 15-second limit, so a stuck notification can't
  keep the session and its lock alive.
- `ci/check` also lints and formats `praetorian-schedule`.
- `tests/interactive.bats`: its `[[ ]]` assertions end with `|| false`.
  That file only runs under macOS's bash 3.2, where a failing `[[ ]]` that
  isn't a test's last command didn't fail the test, so those assertions
  checked nothing. They all hold.

## 1.3.0 - 2026-10-15

Behavior changes after an external audit. Most of them make a session
safer when something goes wrong halfway.

### Added

- `PRAETORIAN_HOME`: the state directory (logs, quarantine, lock) can be
  set from the environment. The default stays `~/praetorian`. It must be an
  absolute path on one line, otherwise praetorian stops with exit code 1
  before writing anything.
- Half-installed cask: `Caskroom/<cask>` is copied to
  `PRAETORIAN_HOME/.cask_backup.<cask>.<pid>` before the forced uninstall
  and put back if the reinstall fails (also on Ctrl-C). When the copy
  can't be made, the forced uninstall doesn't run.
- `praetorian-sudo-setup --help`, and documented exit codes (0 done or
  nothing to do, 1 error).
- `SECURITY.md`, `CONTRIBUTING.md`, `.editorconfig`, this changelog.
- Tests: `tests/robustness.bats`, `tests/macports.bats`,
  `tests/sudo-setup.bats`, `tests/options.bats`, `tests/interactive.bats`.

### Changed

- Session lock: the PID is written atomically (temp file then rename). A
  lock with no PID that is less than a minute old is treated as a session
  that is starting (this one stops); an older one is taken over. A stale
  lock is renamed to `.lock.stale.<pid>` before it's removed, so two
  sessions can't both take it over. On exit, praetorian only removes the
  lock it owns.
- MacPorts under sudo: with the default prefix `/opt/local`, `port` and
  every directory above it up to `/` must belong to root and be writable
  by root only, whatever `sudo` comes first in the `PATH`. With another
  prefix (tests), the check is skipped only when that `sudo` isn't a
  setuid-root file.
- `--dry-run` no longer removes old logs: it only counts what a real run
  would remove. It still takes the lock and writes its own log.
- `.toolchain` is written on every real session, even with an empty
  quarantine, so a later toolchain change is detected correctly.
- `praetorian-sudo-setup`: the `pam_tid` line goes right after an existing
  `pam_reattach.so` line (Touch ID inside tmux), otherwise at the top of
  the file. `PRAETORIAN_SUDO_LOCAL` (tests) is refused under a real sudo,
  for relative paths, paths with `..`, symbolic links, and anything under
  `/etc`, `/private/etc`, `/System` or `/usr`.
- `PRAETORIAN_MIN_FREE_GB` (tests): digits only, read as decimal;
  anything else gives a warning and the default 5 GB.
- `--migrate` is split into one function per step (`migrate_*`), each
  reporting through `block`, so `set -e` stays active in every step.
- The summary is no longer called on the left of `||` (which silently
  turned `set -e` off inside it).
- `ci/check` finds the files to lint and format by glob (`praetorian`,
  `praetorian-sudo-setup`, `lib/*.sh`, `ci/*`, `tests/*.bats`,
  `tests/stubs/*`) instead of a fixed list, and Gitleaks also opens
  archives (`--max-archive-depth 2`), such as the build log archives.
- The version history moved from the script header and the README to
  this file.

## 1.2.1 - 2026-10-15

Patch release on top of 1.2.0. Its individual changes weren't recorded
separately at the time; see the git history.

## 1.2.0 - 2026-10-15

### Added

- MacPorts maintenance: `port selfupdate`, port upgrades (checked with a
  second `port outdated`), removal of inactive versions, quarantine of
  ports that fail to upgrade. Homebrew becomes optional: MacPorts alone
  is enough.
- Homebrew → MacPorts migration: `--migration-report` (read-only) and
  `--migrate <formula>[=<port>]` (installs the port, checks it, and only
  then uninstalls the formula).
- Every block is fully explained: why, what was *not* done, how to
  unblock, where the log is.
- Fail-safe checks: session lock, minimum free disk space, nothing
  removed without checking first.

### Changed

- Code split by topic in `lib/`, checked before it's loaded (owner,
  permissions, no symbolic link).
- Every unplanned exit is explained (`EXIT` handling with `finish`).
- Code, comments and terminal output in English.

## 1.1.0 - 2026-10-15

### Added

- Quarantine: a package that fails for a cause that won't go away on its
  own (full Xcode required, broken cask `.pkg` script) is set aside and
  skipped by later sessions. Entries expire after 30 days; Xcode-related
  ones are lifted as soon as Xcode.app is installed. Build failures are
  quarantined 7 days, dependents included.
- The session runs under `caffeinate`: the Mac doesn't sleep during long
  builds.
- brew errors are pulled from the log and summarized on screen.
- Homebrew build logs are archived before `brew cleanup` deletes them;
  half-upgraded casks are repaired.
- Intel Mac detection: Homebrew no longer ships bottles there (tier 3),
  everything compiles from source.

### Changed

- Ctrl-C stops the whole session cleanly (no more cascade of steps
  failing with code 130).
- Formulae and casks are upgraded one at a time: one failure no longer
  blocks the others.
