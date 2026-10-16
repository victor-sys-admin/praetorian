# Changelog

All notable changes to praetorian are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version printed by `praetorian --help` and the latest version in the
README (section "Latest release") must match: a test checks it. No git
tag exists yet for these versions.

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
