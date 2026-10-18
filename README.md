# praetorian

A Homebrew and MacPorts maintenance script for macOS that keeps going when things break.

One command runs `brew update`, upgrades formulae and casks, removes orphans, cleans caches, updates MacPorts and its ports, runs `brew doctor`, and lists apps you haven't opened in six months. When an upgrade fails, praetorian logs it, tries a known fix, quarantines what can't be fixed, and moves on to the next package. At the end it tells you exactly what's left to do. When it has to stop something, it says why, what was *not* done, and how to unblock it.

It also moves command-line tools from Homebrew to MacPorts, one formula or a batch, with checks before and after (see [Package strategy](#package-strategy-homebrew--macports)), and tells you, read-only, where things stand (`--status`), what is broken around both package managers (`--doctor`) and what is installed (`--sbom`).

It runs on any Mac with macOS's own `/bin/bash` 3.2 and Homebrew and/or MacPorts. It was first built for, and hardened on, an Intel Mac, where Homebrew no longer ships precompiled packages (bottles) and every upgrade compiles from source: most of the design below comes from the failures that setup produced (see [History](#project-history-the-2026-10-15-incident)).

## Latest release

### 1.5.0 (2026-10-18)

Migration in batches (`--migrate` repeated, `--migrate-all`) with companion ports, a table of known MacPorts traps, homepage and precompiled-binary checks, and commands checked where the shell finds them; read-only `--status`, `--doctor` and `--sbom`; `--prune` for the dependencies `brew autoremove` misses; unattended sessions wait for the network; logs under 7 days are never rotated away. 1.4.0 added the overnight scheduling (`praetorian-schedule`) and the notifications. Full list and earlier versions: [CHANGELOG.md](CHANGELOG.md).

---

## Contents

- [Latest release](#latest-release)
- [Quick start](#quick-start)
- [Installation](#installation)
- [Requirements](#requirements)
- [Options](#options)
- [Scheduling: overnight runs](#scheduling-overnight-runs)
- [Package strategy: Homebrew → MacPorts](#package-strategy-homebrew--macports)
- [When praetorian blocks](#when-praetorian-blocks)
- [Troubleshooting](#troubleshooting)
- [What a session does](#what-a-session-does)
- [Files and state](#files-and-state)
- [Environment variables](#environment-variables)
- [Design decisions](#design-decisions)
- [Security: how sudo is handled](#security-how-sudo-is-handled)
- [Development](#development)
- [Project history: the 2026-10-15 incident](#project-history-the-2026-10-15-incident)
- [Known limitations and ideas](#known-limitations-and-ideas)
- [References](#references)
- [Changelog](CHANGELOG.md), [Security policy](SECURITY.md), [Contributing](CONTRIBUTING.md)
- [License](#license)

---

## Quick start

The examples assume the repository is cloned in `~/praetorian` (the default); adjust the path if you put it elsewhere.

```sh
# One-time, optional but recommended: use Touch ID for sudo prompts
sudo ~/praetorian/praetorian-sudo-setup

# Normal run, from a terminal
~/praetorian/praetorian

# See what would happen, without changing anything
~/praetorian/praetorian --dry-run

# Run with nobody watching (overnight, launchd…)
~/praetorian/praetorian --unattended

# Run it every night at 03:30 (launchd, as you, no password), check on it
~/praetorian/praetorian-schedule install
~/praetorian/praetorian-schedule status

# Homebrew → MacPorts: see the plan (read-only), then move one formula
~/praetorian/praetorian --migration-report
~/praetorian/praetorian --dry-run --migrate wget
~/praetorian/praetorian --migrate wget
~/praetorian/praetorian --dry-run --migrate-all   # every formula with a safe same-name port

# Where things stand, what is broken (both read-only)
~/praetorian/praetorian --status
~/praetorian/praetorian --doctor
```

praetorian keeps its state (logs, quarantine, lock) in `PRAETORIAN_HOME`, `~/praetorian` by default.

## Installation

1. **Clone the repository.** Anywhere works; `~/praetorian` is the simplest, because it is also the default state directory, so code and state stay together (the state files are in `.gitignore`):
   ```sh
   git clone https://github.com/victor-sys-admin/praetorian.git ~/praetorian
   ```
   Cloned elsewhere, praetorian still writes its state to `~/praetorian` unless you set `PRAETORIAN_HOME` (an absolute path) in the environment that starts it, for example `export PRAETORIAN_HOME="$HOME/src/praetorian"` in `~/.zprofile` (and in the `EnvironmentVariables` of a `launchd` job).

   `lib/` must stay next to `praetorian`: the script loads its code from there. A symbolic link to `praetorian` (for example `~/.local/bin/praetorian`) works, because the real location is resolved. The files in `lib/` must belong to you and not be writable by group or others, or praetorian refuses to start (see [Code layout](#code-layout)).
2. **Make sure Xcode is ready** (see [Compiler toolchain](#compiler-toolchain)). praetorian refuses to start while Xcode is installed but not initialized.
3. **Optional: Touch ID for sudo**: `sudo ~/praetorian/praetorian-sudo-setup` (see [Security](#security-how-sudo-is-handled)).
4. **Optional, recommended on Intel: MacPorts.**
   1. Download the package for **your** macOS version (`sw_vers -productVersion`) from <https://www.macports.org/install.php> and install it.
   2. Open a **new** terminal and check that `command -v port` prints `/opt/local/bin/port`. If it prints nothing, see [`port: command not found`](#port-command-not-found-after-installing-macports).
   3. `sudo port selfupdate`
   4. `~/praetorian/praetorian --migration-report`
5. **First run:** `~/praetorian/praetorian --dry-run`, then `~/praetorian/praetorian` from a terminal, watching it.

## Requirements

You need a package manager and Xcode. **Everything else ships with macOS**, so there is nothing more to install.

### Package managers: at least one

| Tool | Where praetorian looks | Needed for |
|---|---|---|
| Homebrew (`brew`) | `PATH`, then `/usr/local/bin/brew`, then `/opt/homebrew/bin/brew` | formulae, casks, `--migration-report`, `--migrate`, `--prune` |
| MacPorts (`port`) | `/opt/local/bin/port` only (absolute path, including under sudo) | ports, `--migration-report`, `--migrate` |

If only one is installed, praetorian maintains that one and skips the other with a notice. If neither is found, it stops (exit 1) and says where to get them. MacPorts must be the package built for **your** macOS version: <https://www.macports.org/install.php>. praetorian never installs either one itself.

### Compiler toolchain

**On Intel Macs: a full Xcode install, not just the Command Line Tools.** Some formulae (for example `openjdk`, or `gtk4` and `gstreamer` through their build dependencies) can't be compiled with the Command Line Tools alone. Xcode must also be *initialized*, otherwise builds fail or hang:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
  ```
  Building `openjdk` with Xcode 26 also needs the Metal Toolchain component. praetorian downloads it automatically when needed (see [auto-fixes](#4-auto-fixes-then-one-retry)).

MacPorts also needs Xcode or at least the Command Line Tools, even though it mostly installs precompiled packages: a port with no binary package is built from source.

### Shell and system tools (built into macOS)

| Tool | Used for |
|---|---|
| `bash` | Runs the script. macOS's own `/bin/bash` 3.2 is enough: the code avoids associative arrays, `mapfile` and negative array indices. A newer bash from Homebrew or MacPorts works too |
| `awk`, `sed`, `grep`, `cut`, `tr`, `sort`, `comm`, `wc`, `head`, `tail`, `cmp`, `xargs` | Parsing brew and port output, the quarantine file and shell startup files |
| `find`, `ls`, `cat`, `cp`, `mkdir`, `rm`, `mv`, `basename`, `dirname`, `readlink`, `mktemp` | Logs, temp files, lock, Caskroom repair and backup, spotting commands installed twice, finding `lib/` through symbolic links, ownership checks of `port` |
| `id` | Owner check of the `lib/` files before they're loaded |
| `tar` | Archiving Homebrew and MacPorts build logs before cleanup |
| `df` | Free disk space check |
| `date`, `sleep`, `uname`, `sw_vers` | Timestamps, progress line, Intel detection, macOS version in the log |
| `pgrep`, `kill` | Stopping the whole process tree on Ctrl-C; checking the PID in the lock |
| `caffeinate` | Keeping the Mac awake during a session |
| `xcode-select`, `xcodebuild` | Xcode readiness check; Metal Toolchain download |
| `curl` | Unattended: waiting for the network (a HEAD request to `github.com`); `--migrate`: is there a precompiled MacPorts binary (HEAD requests to `packages.macports.org`, nothing downloaded) |
| `python3` (`/usr/bin/python3`, once the Command Line Tools or Xcode are installed) | `--sbom` only: writes the JSON |
| `system_profiler` | `--sbom`: the apps and who signed them |
| `git` | Detecting Homebrew's development branch (`git -C $(brew --repository) branch`). Comes with Xcode or the Command Line Tools |
| `sudo` | MacPorts commands and cask installers. Never cached or stored (see [Security](#security-how-sudo-is-handled)) |
| `mdls` (Spotlight) | Last-used date of apps in `/Applications` |
| `osascript` | End-of-session notification (unattended, sessions of 5 minutes or more, `--notify`) |
| `pmset` | Power source check (`--ac-power-only`) |
| `launchctl`, `plutil` | `praetorian-schedule`: loading the job, checking its plist |

`--doctor`, `--prune`, `--migrate` and `--sbom` also look at `pipx` environments and `npm` global packages when those are installed, and `--sbom` summarizes what `trivy` finds when it is installed. None of them is required: a missing one is skipped and said so.

The disk needs at least 5 GB free (20 GB recommended); below that, praetorian stops before doing anything. praetorian refuses to run as root: Homebrew refuses it too, and praetorian asks for sudo itself, one command at a time.

### Optional: Touch ID for sudo

`praetorian-sudo-setup` (run once with sudo) uses `bioutil` to check that a fingerprint is enrolled, and `cp`, `sed`, `awk`, `chmod` and `chown` to write `/etc/pam.d/sudo_local`. It needs a Mac with Touch ID; without one, sudo simply asks for the password.

### Optional: overnight runs

`praetorian-schedule` installs a per-user `launchd` job; it needs nothing beyond macOS (`launchctl`, `plutil`) and no sudo. See [Scheduling](#scheduling-overnight-runs).

### For development only: checks and tests

`ci/check` runs every check in throwaway containers pinned by digest, so the only local requirement is **Podman or Docker**: it uses the first one whose daemon answers (`docker info`, then `podman info`), or the one `CONTAINER_ENGINE` names. Nothing below is installed on the Mac:

| Container | Check |
|---|---|
| ShellCheck 0.11.0 | Lint, `--severity=style` (blocking). ShellCheck and shfmt check every file matched by `praetorian`, `praetorian-sudo-setup`, `praetorian-schedule`, `lib/*.sh`, `ci/*`, `tests/*.bats` and `tests/stubs/*` |
| shfmt 3.14.1 | Formatting (blocking; `ci/check fix-format` fixes it) |
| Gitleaks 8.30.1 | Secrets (blocking). Scans the working tree, archives included (`--max-archive-depth 2`): with the default `PRAETORIAN_HOME`, that covers your local `logs/` and their `.tar.gz` build logs. A `PRAETORIAN_HOME` outside the repository isn't scanned |
| actionlint 1.7.12, zizmor 1.31.0 | GitHub workflows (blocking) |
| bats 1.14.0 | Tests, with the fakes from `tests/stubs/` (blocking) |

The same tests also run **on macOS under `/bin/bash` 3.2** with `ci/macos-tests`: it fetches bats-core 1.14.0 by commit into a temp directory (needs `git`, nothing is installed), puts `/bin` first in the `PATH`, unsets the `PRAETORIAN_*` variables of your shell, and uses the macOS tools. GitHub Actions runs `ci/check` (Linux) and `ci/macos-tests` (`macos-latest`) on pull requests and on `main`; a push to a branch without a pull request runs nothing.

## Options

| Option | Effect |
|---|---|
| `--dry-run` | Shows the planned steps. Changes no package and no praetorian state (`quarantine.tsv`, `.toolchain`, `migrated.tsv`, old logs): quarantine entries a real run would lift and old logs it would remove are only counted. It still writes its own session log and takes the session lock (so it can't run alongside a real session). Skips `caffeinate` and the Xcode check; a disk below the minimum free space, or no network when unattended, only gives a warning. |
| `--no-greedy` | Upgrades casks without `--greedy`, so apps that update themselves are left alone. |
| `--retry-quarantined` | Ignores the quarantine for this run and retries everything. |
| `--unattended` | Never waits for input. Whatever needs sudo (casks with an installer, the whole MacPorts part) is deferred, not failed, and a macOS notification summarizes the run. Before anything starts, waits up to 5 minutes (`PRAETORIAN_NETWORK_WAIT`) for the network ([decision 23](#23-wait-for-the-network-before-starting)). This mode turns on automatically when stdin is not a terminal. |
| `--notify` | Always sends the end-of-session notification, even for a short session or a `--dry-run`. `praetorian --dry-run --notify` is a quick way to check that macOS lets it through. |
| `--no-notify` | Never sends it, not even unattended. |
| `--ac-power-only` | Stops before doing anything (exit code 1, with a block and a notification) when the Mac is on battery or UPS power. Used by the scheduled job: a session can compile for hours. If the power source can't be read, the check is skipped with a warning. With `--dry-run`, only a warning. |
| `--quiet` | Minimal terminal output. Everything still goes to the log. Blocks are always shown. |
| `--migration-report` | Read-only plan: for each formula you installed yourself, the matching MacPorts port and anything that would block its migration. Changes nothing. |
| `--migrate <formula>[=<port>[,<port>…]]`<br>`--migrate=<spec>` | Moves a formula to MacPorts: checks, installs the port(s), checks again, and only then uninstalls the formula ([steps](#migrating-one-formula-at-a-time)). Ports after a comma are companions installed with the main one (`step=step-cli,step-ca`). Repeat it for several formulae in one session ([several at once](#several-at-once)). Without `=<port>`, the port has the formula's name (without its tap: `hashicorp/tap/terraform` → `terraform`), unless the formula is a [known trap](#known-traps): then praetorian blocks and prints the right spec. Combine with `--dry-run` to run only the checks. Names are restricted to letters, digits and `@._+-` (plus `/` for a tap formula), because they end up in URLs and in commands run under sudo. |
| `--migrate-all` | Migrates every formula of the report's "Same name" group whose MacPorts port has the same homepage and that has no `[ ]` note, leaves first. A blocked one is skipped; the summary lists each formula. |
| `--allow-build` | Lets `--migrate` install a port that has no precompiled binary for this Mac (MacPorts then compiles it from source: hours, maybe a failure). |
| `--status` | Read-only summary of the real state, checked against brew and port rather than the logs: the formulae in `migrated.tsv` (flagged when the formula is still installed, or a port is missing or not marked requested), the formulae still installed on request and why (quarantined, a same-name port to migrate to, the exact spec for a [known trap](#known-traps), likely port names, no port found), leftover dependencies (`brew leaves` nobody asked for: it points to `praetorian --dry-run --prune`, never to `port uninstall leaves`, which could remove migrated ports still marked as dependencies), cask / formula / port counts, and the last 10 sessions from their logs, one line each (date, mode, migration target, outcome, duration). No sudo, no lock. |
| `--doctor` | Read-only health check. Lists what breaks around Homebrew and MacPorts without either noticing, each with the command that fixes it: broken pipx environments (or ones still on a Homebrew Python), files in the Homebrew prefix that `brew cleanup` can't remove because they aren't yours, dead `PATH` entries (with the shell file and line), broken JDK links, empty Cellar directories, npm global packages left without `node` (a node not from Homebrew, such as the nodejs.org installer in `/usr/local`, keeps its packages), migrated ports MacPorts could remove by mistake, casks from an untrusted tap, stale Command Line Tools headers. Each check is skipped when its tool isn't there. Every name in a printed command is shell-quoted, so pasting a fix can't run anything else. Changes nothing, never runs sudo, takes no lock. See [Troubleshooting](#something-broke-after-a-migration-or-brew-cleanup-fails-every-night). |
| `--prune` | Removes the Homebrew dependencies nothing uses any more, which `brew autoremove` misses ([decision 26](#26-prune-what-brew-autoremove-misses)). Shows each round and asks before removing it (default: no); removing one round can free the next, up to 10 rounds. With `--dry-run`, only lists the first round. Unattended, removes nothing (listed as deferred). Never removes a formula you installed yourself, or one a pipx environment, npm package, Homebrew service or shell startup file still uses. MacPorts' unused dependencies are only reported, with the command to remove them. |
| `--sbom` | Writes a CycloneDX 1.6 SBOM of the installed software to `logs/sbom_<timestamp>.cdx.json`: Homebrew formulae and casks, active MacPorts ports (with their variants), apps in `/Applications` and `~/Applications`, pipx environments (`PIPX_HOME` honoured) and npm global packages; a missing tool is skipped and said so. Then lists what was added, removed or changed since the previous SBOM (15 names per list on screen, all of them in the log). The JSON is built with Python (`/usr/bin/python3` once the Command Line Tools or Xcode are there, otherwise a `python3` from the `PATH`); without one, praetorian blocks and says what to install. If `trivy` is installed, its HIGH and CRITICAL findings are summarized: it only knows the pypi and npm packages, so a clean result says nothing about the Homebrew and MacPorts ones. On first use trivy downloads its vulnerability database from an external registry and keeps it in `~/.cache/trivy` (trivy's own behaviour). Read-only, no lock ([decision 27](#27-an-sbom-written-by-a-json-library)). |
| `--help`, `-h` | Usage. |

**Notification.** At the end of a session, a macOS notification gives the outcome, the duration and what is left to do (casks deferred for sudo, failures). It's sent when you're probably not watching: always when unattended, and from a terminal only when the session took 5 minutes or more (`PRAETORIAN_NOTIFY_AFTER`). From a terminal it plays your alert sound (System Settings > Sound > Alert sound; Glass if that setting can't be read); unattended it's silent, so a night run doesn't wake anybody, and it waits in the Notification Center. A session that stops before its summary (blocked by the lock, the disk, the battery, Xcode, or an unexpected error) also sends one, naming the block; Ctrl-C doesn't. Never for `--dry-run` (unless `--notify`) or `--migration-report`.

`--migration-report`, `--status`, `--doctor`, `--sbom` and `--help` are read-only: they skip `caffeinate`, the Xcode, power, network and disk checks, and the session lock. `--migrate`, `--migrate-all` and `--prune` go through all of them, like a maintenance session.

**Exit codes:** `0` = success, `1` = prerequisite problem (no package manager, run as root, Xcode not ready, disk almost full, on battery with `--ac-power-only`, no network when unattended, another session running, invalid `PRAETORIAN_HOME`, untrusted `lib/`), migration report blocked, or `--sbom` without a working Python, `2` = at least one step failed or was blocked (with several `--migrate`, at least one migration was blocked), `130` = interrupted. `--doctor` exits `0` when it finds nothing and `2` when it lists problems; `--status` always exits `0`.

## Scheduling: overnight runs

On an Intel Mac, every Homebrew upgrade compiles: running praetorian at night makes that painless. `praetorian-schedule` sets it up with `launchd`, as you, with no password:

```sh
~/praetorian/praetorian-schedule install                          # every day at 03:30
~/praetorian/praetorian-schedule install --at 23:15 --weekday sun # once a week instead
~/praetorian/praetorian-schedule install --dry-run                # show the job, install nothing
~/praetorian/praetorian-schedule status                           # schedule, last run, what to fix
~/praetorian/praetorian-schedule uninstall                        # remove it (logs and quarantine kept)
```

The job runs `praetorian --unattended --ac-power-only`: casks that need sudo and the whole MacPorts part are deferred to your next session from a terminal (no password is stored, see [Security](#security-how-sudo-is-handled)); on battery it stops before doing anything; the notification sums up the night in the Notification Center. `install` again replaces the job (new time, or after moving the repository). The default time, 03:30, is after the 02:00–03:00 window where daylight saving time changes in Europe and North America.

**Mac asleep, Mac off.** A Mac asleep at that time runs the job as soon as it wakes up (several missed nights count as one run): if you close the lid at night, the session starts when you open it in the morning, at a lower priority (`Nice 10`) so the Mac stays usable. A Mac that is shut down doesn't run it. To have the Mac wake up (or power on) just before, which needs admin rights and that `praetorian-schedule` doesn't do for you:

```sh
sudo pmset repeat wakeorpoweron MTWRFSU 03:25:00   # every day, 5 minutes before the job
pmset -g sched                                      # check
sudo pmset repeat cancel                            # undo
```

**Status and exit codes.** `install` and `uninstall` return `0` when done, `1` on error. `status` returns `0` when the job is installed and loaded, `1` when something needs fixing (not loaded, turned off in Login Items, `praetorian` no longer where the job points), `3` when it isn't installed. It also shows the last run's exit code (see [Options](#options)) and the latest session log.

**What the job looks like** (`~/Library/LaunchAgents/io.github.victor-sys-admin.praetorian.plist`, see `install --dry-run`):

| Key | Value | Why |
|---|---|---|
| `ProgramArguments` | the real path of `praetorian` (links resolved), `--unattended`, `--ac-power-only` | No shell in between: nothing is parsed or expanded |
| `StartCalendarInterval` | `Hour`, `Minute` (`Weekday` with `--weekday`) | Missed runs happen at wake-up, unlike cron |
| `EnvironmentVariables` | `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `PRAETORIAN_HOME` | macOS's own `/bin/bash` 3.2 and tools; praetorian finds `brew` at its standard locations |
| `ProcessType`, `Nice` | `Standard`, `10` | Full speed on an idle Mac, gives way when you use it. `Background` would throttle CPU, disk and network even on an idle Mac, and builds would take far longer |
| `LimitLoadToSessionType` | `Aqua` | Only in your graphical session, where the notification can be shown |
| `RunAtLoad` | `false` | Logging in doesn't start a session |
| `StandardOutPath`, `StandardErrorPath` | `/dev/null`, `PRAETORIAN_HOME/logs/launchd.stderr.log` | Everything is in the session log; stderr keeps what happens before that log exists |

**Checks before anything is installed** (each refusal says why and what to do; nothing is written or loaded):

- not as root (the job would land in root's agents, and Homebrew refuses root), and only where `launchctl` exists (macOS);
- `praetorian` sits next to `praetorian-schedule`, is executable, and it and its directory belong to you (or root) and aren't writable by group or others: `launchd` runs that path every night, so a file someone else could change would be a way in (the same rule praetorian applies to `lib/` when it starts);
- neither the repository nor `PRAETORIAN_HOME` is in `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive or `/Volumes`: macOS keeps background jobs out of those folders, and the job would fail every night with "Operation not permitted" (`praetorian-schedule` never asks for Full Disk Access);
- `PRAETORIAN_HOME` (from the environment, `~/praetorian` by default) is an absolute path on one line; it's written into the job, XML-escaped;
- the plist is written to a temporary file next to its final place (`644`), checked with `plutil -lint`, and only then moved into place and loaded. The previous job, if any, is kept until the new one is loaded: if `launchctl bootstrap` fails, it's put back.

macOS shows "Background Items Added" the first time: that's this job, listed in System Settings > General > Login Items. If you turn it off there, `status` says so, and `install` turns it back on (you asked for it).

## Package strategy: Homebrew → MacPorts

Homebrew dropped Intel Macs (tier 3, no bottles): every formula compiles from source, some never build. MacPorts still ships precompiled packages for Intel Macs, for each supported macOS version. On such a Mac, the target state is:

| What | Where | Why |
|---|---|---|
| Command-line tools and libraries | **MacPorts** | Precompiled for Intel; supports old macOS versions for years |
| Apps (casks) | **Homebrew** | MacPorts doesn't manage apps. A cask downloads the vendor's app and compiles nothing, so tier 3 doesn't affect it |
| Anything with no MacPorts port | Homebrew, until a replacement is found | |

During the transition both run side by side (`/opt/local` and `/usr/local` don't overlap). praetorian maintains both, and warns when Homebrew comes before MacPorts in the `PATH` (the Homebrew copy would run). Its *Homebrew / MacPorts side by side* section lists only what you can act on: the formulae nothing else needs (`brew leaves`) whose commands also come with MacPorts, grouped by formula, with the copy that actually runs; those are the ones to migrate, or to remove when the MacPorts copy is enough. Commands installed twice because they come from dependencies of formulae you keep in Homebrew are summed up in one informational line (MacPorts ships the same libraries for its own ports: nothing to do).

### Migrating, one formula at a time

1. `praetorian --migration-report` sorts the formulae you installed yourself (`brew leaves`) into groups: same name in MacPorts, same name but maybe a different project (the homepages differ, see [below](#same-project-same-homepage)), probable other name, and not found. [Known traps](#known-traps) come first, with the exact spec to use. It flags what would block a migration: a running `brew services` service, shell startup files pointing into the formula's Homebrew paths, or `[no binary for this Mac]`. The "Same name" group says how many formulae `--migrate-all` would take. Dependencies aren't listed: once nothing uses them, `--prune` removes them (`brew autoremove` misses many, see [decision 26](#26-prune-what-brew-autoremove-misses)).

   For formulae that aren't known traps, the "probable other name" guesses, most likely first:

   | Rule | Example (from the real MacPorts index) |
   |---|---|
   | `name@X.Y` → `nameXY`. When it exists, it's the only suggestion | `python@3.11` → `python311`, `postgresql@15` → `postgresql15`, `openjdk@17` → `openjdk17` |
   | Tap formula without its tap | `<user>/tap/<name>` → `<name>` (`hashicorp/tap/terraform` is a known trap) |
   | Same name, other case | `imagemagick` → `ImageMagick` |
   | Known alias | `make` → `gmake`, `ant` → `apache-ant`, `sphinx-doc` → `py-sphinx`, `node` → `nodejs…`, `mysql-client` → `mysql…` |
   | Versioned ports `name<digits>`, up to 6 (`…` and a count when there are more) | `node` → `nodejs20, nodejs22, nodejs24, nodejs26`, `gnupg` → `gnupg1, gnupg2` |
   | Only if nothing else matched: the Python module `py-<name>` | `numpy` → `py-numpy`, `python-setuptools` → `py-setuptools` |

   Versioned ports are sorted by their number, which doesn't always follow release order (`postgresql93` is 9.3, `mysql8` sorts before `mysql51`). Always check with `port info <port>`.
2. `praetorian --migrate <formula>[=<port>[,<port>…]]` runs these steps and **stops at the first problem, leaving the Homebrew formula in place**:

| # | Check or action | Stops if |
|---|---|---|
| 1 | `brew list --formula` | the formula isn't installed |
| 2 | `brew uses --installed` | another formula depends on it (one migrated earlier in the same session doesn't count) |
| 3 | `homebrew.mxcl.<formula>.plist` | it runs as a Homebrew service |
| 4 | `~/.zshrc`, `~/.zprofile`, `~/.bash_profile`… | a line uses `<prefix>/opt/<formula>` or `Cellar/<formula>/` (it would point to nothing). Commented lines are ignored |
| 5 | [known traps](#known-traps) | no `=<port>` was given for a formula of that table |
| 6 | `port info --name <port>`, for each port | a port doesn't exist |
| 7 | [homepages](#same-project-same-homepage) | they differ and the port was only guessed from the name (a warning with `=<port>`) |
| 8 | [`packages.macports.org`](#a-binary-for-this-mac) | no precompiled archive for this Mac (unless `--allow-build`). Skipped for ports already active |
| 9 | `sudo port -N install <port>`, for each port | sudo is impossible (unattended), `port` can't be trusted with root (see [Security](#security-how-sudo-is-handled)), the install fails or sudo is refused. A port already active is not reinstalled: `sudo port setrequested <port>` marks it as wanted, so `port uninstall leaves` won't remove it |
| 10 | `port installed`, then every command | a port isn't active, or a command the formula links into the `PATH` is in neither `/opt/local/bin` nor `/opt/local/sbin` (see [below](#how-the-commands-are-checked)) |
| 11 | programs outside Homebrew | a pipx environment on a Homebrew Python, or npm global packages, use the formula: move them first (e.g. `pipx reinstall <package> --python /opt/local/bin/python3.X`), then run `--migrate` again (the port is already installed) |
| 12 | `brew uninstall --formula` | (only now) |

A successful migration is recorded in `migrated.tsv` (every port of the spec, comma-separated). The order is deliberate: at every point before step 12, the Homebrew version is untouched and still works. If step 10 or 11 fails, both are installed, which is harmless. With `--dry-run`, steps 1 to 8 and 11 run, and the install and uninstall are only listed.

3. Start with the formulae that hurt the most (long builds, quarantined), check your tools after each migration, and stop when only casks are left: Homebrew then has nothing to compile. Small, standalone tools (`wget`, `jq`, `tree`…) make good first migrations, and `--dry-run --migrate-all` shows which formulae can go in one batch; formulae referenced in your shell files come later, once those lines are updated.

#### Known traps

Some MacPorts ports have the formula's name but are another project, an obsolete series, or need a companion port. For these the report prints the exact spec, and `--migrate <formula>` without `=` blocks with it rather than installing the wrong thing (praetorian never changes what you asked for on its own):

| Formula | Spec | Why |
|---|---|---|
| `step` | `step=step-cli,step-ca` | MacPorts' `step` is a KDE program (a physics simulator) |
| `ansible` | `ansible=py-ansible` | a Python package in MacPorts (its `ansible` port dates from 2017) |
| `guile` | `guile=guile-3.0` | MacPorts' `guile` is an obsolete stub |
| `docker-compose` | `docker-compose=docker-compose-plugin` | Compose v2 (MacPorts' `docker-compose` is v1) |
| `cmake` | `cmake=cmake-devel` | MacPorts' `cmake` is the 3.x series |
| `terraform`, `hashicorp/tap/terraform` | `…=terraform-1.N` (the newest in the index) | one port per version, `port select` links `terraform` |
| `imagemagick` | `imagemagick=ImageMagick7` | MacPorts' `ImageMagick` is 6.x |
| `p7zip` | `p7zip=7zip` | the official 7-Zip |
| `jpeg-xl` | `jpeg-xl=libjxl` | named after the library |
| `make`, `ant` | `make=gmake`, `ant=apache-ant` | other names |
| `rust` | `rust=rust,cargo` | cargo is a separate port |
| `node` | `node=nodejs24,npm11` | one port per major version, npm separate; `nodejs26` has no binary for macOS 15 on Intel |
| `gnupg`, `gstreamer` | `gnupg=gnupg2`, `gstreamer=gstreamer1` | |
| `libpq` | `libpq=postgresql18` | the client library comes with the server port |
| `mysql-client` | `mysql-client=mysql-innovation` | same (no binary on macOS 15 Intel: see [history](#migration-day-2026-10-17)) |
| `openjdk@17`, `python@3.X`, `postgresql@NN` | `openjdk17`, `python3X`, `postgresqlNN` | versioned names |

#### Same project? Same homepage

For a port with the formula's name, praetorian compares the Homebrew homepage (`brew info --json=v2`) with the MacPorts one (`port info --homepage`), ignoring the scheme, `www.`, a trailing `/`, `index.html` and case. Two code-host URLs (GitHub, GitLab…) count as the same project when they name the same organization **and** repository; a code-host URL and a site, when the organization is named like the site (`github.com/ansible/ansible` and `ansible.com`); on shared, multi-tenant sites (SourceForge, GNU, PyPI, `code.google.com`, Hackage, CRAN, RubyGems, CTAN, MetaCPAN, `*.github.io`…) the host and the project path have to be the same. Anything ambiguous gives no verdict (inconclusive, never "same project"): the same organization with another repository, two different subdomains of one site, a shared site with no project named. When the homepages differ, the report puts the formula in its own group and `--migrate` blocks, unless you name the port yourself with `=`: then it's only a warning. When one side has no homepage, there is no verdict either. `--migrate-all` only takes a formula whose homepages are judged the same; `--migrate` goes on after an inconclusive one (the commands are checked after the install).

#### A binary for this Mac?

Before installing, praetorian asks `packages.macports.org` (one HEAD request per archive name, 10 s timeout, nothing downloaded) for the archive MacPorts would use: `<port>-<version>_<revision><default variants>.darwin_<major>.<arch>.tbz2` (`uname -r`, `uname -m`), or a noarch one. None means MacPorts would compile from source, which can take hours or fail (`nodejs26`, every `mysql` port on macOS 15 Intel): blocked unless `--allow-build`, with an older version of the same port that has a binary when there is one (`nodejs26` → `nodejs24`; 4 versions tried at most). No network, no `curl`, or a license MacPorts may not redistribute (`terraform-1.N`, which only repackages HashiCorp's binary): no verdict, never a block. The report checks the ports it proposes (40 at most, 5 s each) and says how many it checked. These requests are `https` only and name the ports (and this Mac's Darwin version and architecture) to `packages.macports.org`, MacPorts' own server, which `port install` would contact anyway; nothing else leaves the Mac.

#### How the commands are checked

The formula's commands are what brew links into the `PATH`: the files of `Cellar/<formula>/<version>/bin` and `sbin`, not internal directories such as `libexec/bin` (the venv's `python` of pipx or scons) or `lib/rustlib/…/bin` (rust). Each one counts when a file of that name is in `/opt/local/bin` or `/opt/local/sbin`, whatever port put it there: a companion (`cargo` from `cargo`), a link made by `port select`, a port installed earlier. When commands are still missing after the install, praetorian looks at `port select --summary`: a group still set to `none` whose options name a port just installed (as is, without its dashes, `terraform-1.16` → `terraform1.16`, or with MacPorts' `mp-` prefix) is set with `sudo port select --set <group> <option>`, and the commands are checked again. A group already set to something else is never changed. A command that differs only by the version in its name (`aclocal-1.19` when MacPorts has `aclocal`) is a harmless difference: listed, not blocking. The output says which port each command comes from. See [decision 24](#24-check-commands-where-the-shell-finds-them).

#### Several at once

`--migrate` can be repeated, and `--migrate-all` takes every formula of the report's "Same name" group with the same homepage and no `[ ]` note (nothing else: known traps, other names, different or inconclusive homepages stay for you to decide; a name that isn't a valid spec is skipped before brew, port or sudo run). Everything runs in one session, under one lock. Formulae nothing depends on go first; a formula that others depend on waits, and is tried again once a pass migrated something (its dependents may be gone by then). A blocked formula doesn't stop the others. The summary lists each formula as migrated, blocked (with the block's title) or skipped (given twice), and the session ends with code 2 when one was blocked. With `--dry-run`, nothing is installed or uninstalled; the dependency order is simulated as if the earlier ones had been migrated.

### Undoing a migration

praetorian doesn't have an undo command, because each part is a single standard command:

```sh
brew install <formula>             # get the Homebrew version back
sudo port uninstall <port>…        # optional: remove the MacPorts version (and its companions)
hash -r                            # forget the old command locations in this shell
```

Then delete the formula's line from `migrated.tsv` in `PRAETORIAN_HOME`. Nothing is undone from it, but `--status` checks every line (and would flag the formula as still installed in Homebrew), and `--doctor` and `--prune` use it to tell the ports you migrated to from plain dependencies. A group set by `port select` during the migration stays set; `sudo port select --set <group> none` resets it.

praetorian never installs MacPorts itself (it's a system package): download it for your macOS version from <https://www.macports.org/install.php>.

### How MacPorts is maintained

- **Absolute path everywhere**, sudo included: `/opt/local/bin/port`, never a `port` found in the `PATH`. Before any `sudo port`, `port` and every directory above it must belong to root and be writable by root only (see [Security](#security-how-sudo-is-handled)).
- **Read-only commands without sudo** (`version`, `outdated`, `installed`, `contents`, `echo`, `info`, `variants`, `select --summary`). Commands that change something run under sudo, **one sudo call per step and only when there's work**: `selfupdate`, then `upgrade` if something is outdated, then `uninstall inactive` if old versions are left. With CIS `timestamp_timeout=0`, that's at most three Touch ID prompts.
- **One `port -p upgrade <list>`** rather than one call per port: `-p` keeps going after a failed port, so one broken port doesn't block the others, without a sudo prompt per port.
- **The result is checked, not trusted**: a second `port outdated` runs after the upgrade. Whatever is still outdated failed, whatever the exit code said, and is quarantined (type `port`) with the failing phase (`build`, `configure`…) or the failing dependency. The `main.log` files MacPorts points to are archived in `logs/praetorian_<timestamp>_portlogs.tar.gz`.
- **No upgrade after a failed `selfupdate`**: the ports tree might be half-synced.
- **Unused dependencies are reported, not removed** (`port echo leaves`): they may be needed again to build something.
- **Unattended**: MacPorts needs root for every change and no password is stored, so the whole MacPorts part is deferred, with the number of outdated ports from the local index. Only read-only commands run before that (`port version`, `port outdated`, and `sudo -n true` to see whether sudo would need authentication). A narrow `NOPASSWD` sudoers rule would allow overnight runs, but [was rejected](#security-how-sudo-is-handled) for the same reason as for casks.
- **macOS upgraded without reinstalling MacPorts**: MacPorts reports `Current platform "darwin 25" does not match expected platform "darwin 24"`. praetorian blocks every MacPorts command and prints the [official migration steps](https://trac.macports.org/wiki/Migration). This happens after every major macOS upgrade until MacPorts is reinstalled.

## When praetorian blocks

praetorian never stops silently. Every block prints the same five parts, even with `--quiet` (on stderr), writes them to the log, and is listed again in the summary:

```
✗ BLOCKED: port selfupdate failed
    Why        : Error: Failed to sync the ports tree …
    Impact     : No port was upgraded: praetorian doesn't upgrade from a ports tree that may be half-synced.
    What to do :
        Check the network, then run praetorian again.
        Details: sudo /opt/local/bin/port -d selfupdate
    Log        : <PRAETORIAN_HOME>/logs/praetorian_<timestamp>.log
```

*Impact* always says what was **not** done, so you know the state you're in. A block in one part (say MacPorts) doesn't stop the other parts; a block on a prerequisite stops the session before anything runs.

| Block | Scope | Fail-safe reason |
|---|---|---|
| Run as root | whole session (exit 1), checked first, before `lib/` is loaded | Homebrew refuses root; praetorian requests sudo itself |
| No Homebrew and no MacPorts | whole session (exit 1) | nothing to maintain |
| Xcode installed but not ready | whole session (exit 1) | builds fail or hang forever |
| Less than 5 GB free | whole session (exit 1) | a full disk mid-install leaves half-installed packages |
| Unattended and still no network after 5 minutes (`github.com` doesn't answer) | whole session (exit 1), before the lock; with `--dry-run`, a warning | `brew update` fails and every download retries for nothing ([decision 23](#23-wait-for-the-network-before-starting)) |
| Another praetorian session running | whole session (exit 1) | two brew/port runs on the same packages corrupt them. See [the session lock](#the-session-lock) for how a lock left by a crashed session is taken over |
| `PRAETORIAN_HOME` not an absolute path, or containing a newline | whole session (exit 1), before anything is written | a relative path would follow the current directory |
| MacPorts not responding / installed for another macOS | MacPorts part | ports may be broken until reinstalled |
| `port` (or a directory above it) not owned by root or writable by others | MacPorts part, `--migrate` | it would run as root |
| `port selfupdate` failed | MacPorts upgrade | half-synced ports tree |
| Each `--migrate` check (known trap, different homepage, no binary for this Mac, missing command, program outside Homebrew…) | that migration; with several, the others go on | the Homebrew formula stays in place |
| No working Python 3 for `--sbom` | `--sbom` (exit 1), before anything is collected | the JSON is only ever written by Python's `json` module, never by hand |
| `lib/` file missing, a symbolic link, owned by someone else, or writable by group/others | whole session (exit 1), before anything runs | that code runs with your rights and starts commands under sudo |
| Unexpected internal error | whole session | stops instead of continuing in an unknown state; the block names the function, the file and the failing command |

Deferrals (sudo impossible) are **not** failures: the summary and the notification list them, with "nothing was changed". `--doctor` and `--status` add no block of their own: they report.

## Troubleshooting

### `port: command not found` after installing MacPorts

The MacPorts installer adds `export PATH="/opt/local/bin:/opt/local/sbin:$PATH"` to `~/.zprofile`. Check, in this order:

1. **Old terminal.** Terminals opened before the install keep the old `PATH`: open a new one.
2. **A later line overwrites the `PATH`.** `~/.zshrc` runs *after* `~/.zprofile`. A line like `export PATH="/usr/local/bin:/usr/bin:…"` with no `$PATH` in it throws away what `.zprofile` added. Find it with:
   ```sh
   grep -n 'PATH=' ~/.zprofile ~/.zshrc
   zsh -lic 'echo $PATH' | tr ':' '\n' | head -3   # what a new terminal gets
   ```
   Fix it by adding `/opt/local/bin:/opt/local/sbin:` at the start of that line (this is what happened during the [project history](#macports-install-same-day)), or better, by making it extend `$PATH` instead of replacing it.
3. **Only `sudo port` fails.** If `port` works but `sudo port` doesn't, sudo is using its own `secure_path`. Use the full path: `sudo /opt/local/bin/port …`. praetorian always does.

praetorian itself doesn't depend on your `PATH` for MacPorts (it calls `/opt/local/bin/port`), but it warns when `/opt/local/bin` is missing from it, because the commands you install would be invisible in the terminal.

### "MacPorts deferred" every night

Expected when running unattended: MacPorts needs root for every change and praetorian stores no password. Run `praetorian` from a terminal now and then; the overnight run still handles Homebrew.

### A package keeps being skipped

It's quarantined. `cat "${PRAETORIAN_HOME:-$HOME/praetorian}/quarantine.tsv"` shows why and since when. The summary prints how to unblock each cause; `--retry-quarantined` retries everything once, and deleting a line retries that package for good.

### Something broke after a migration (or `brew cleanup` fails every night)

Run `praetorian --doctor`. It changes nothing: it looks for what a migration or a removed formula leaves behind and prints, for each problem, the command that fixes it, to run yourself after reading it. Typical findings:

- **`bad interpreter` from a pipx command** (`ansible`, `poetry`…): the environment was created with a Homebrew Python that is gone. The fix is `pipx reinstall <package> --python /opt/local/bin/python3.X` with MacPorts' Python of the same version. An environment installed from a local folder that no longer exists can't be reinstalled: `--doctor` prints the two commands that point it to MacPorts' Python in place.
- **`brew cleanup` fails with "Permission denied"**: a `__pycache__` written as root (by `sudo python3` or an installer) in `site-packages`. `sudo rm -rf` of that directory is safe: Python rebuilds it. For anything else, `--doctor` asks you to look first (`ls -la`) before `sudo chown`.
- **A `PATH` entry that leads nowhere**: `--doctor` gives the shell file and line (`~/.zshrc:13`, or a file in `/etc/paths.d`).
- **`port uninstall leaves` would remove a port you migrated to**: it was installed as a dependency first. `sudo port setrequested <ports>`.
- **C++ builds fail in MacPorts with odd header errors**: stale headers in `/Library/Developer/CommandLineTools/usr/include/c++`, left by an older Command Line Tools (listed in MacPorts' [ProblemHotlist](https://trac.macports.org/wiki/ProblemHotlist)). `--doctor` prints the `sudo rm -rf` for that directory, but only when they are really stale: Command Line Tools 16 or later (`pkgutil` receipt), or an SDK that has its own `usr/include/c++/v1`. On older Command Line Tools, that directory holds the headers in use.

### Homebrew keeps dependencies nothing uses

`brew autoremove` only removes formulae Homebrew flagged as installed as a dependency, and many aren't (installed by hand once, by an older brew, or left behind by a migration). `praetorian --dry-run --prune` lists them; `praetorian --prune` removes them, one round at a time, after asking. A formula something outside Homebrew still uses is kept, and `--prune` says why ("used outside Homebrew: pipx environment ansible-core (python3.14 from python@3.14)"): deal with that first (`--doctor` gives the command), then run `--prune` again.

### "no network (github.com unreachable after 300 s)"

An unattended session waited 5 minutes for `github.com` to answer, then stopped before doing anything (exit 1). Usually the session started at wake-up, before the Wi-Fi was back: the next scheduled run goes ahead, or run praetorian from a terminal (no wait there; brew reports its own network errors). A slow network after wake-up: raise `PRAETORIAN_NETWORK_WAIT` in the job's environment. A network that filters `github.com`: Homebrew can't update either.

### "another praetorian session is already running"

Check the PID it gives (`ps -p <pid> -o command=`). If it isn't praetorian (a PID reused after a crash), remove `.lock` in `PRAETORIAN_HOME` (`rm -rf ~/praetorian/.lock` with the default).

"couldn't take the session lock" means another session started at the same moment (or a lock with no PID yet is less than a minute old): wait a moment and run again.

### "praetorian's code in lib/ can't be trusted"

praetorian found a `lib/` file it won't load, and names it with the reason. The block prints the exact commands for your clone; below, `<repo>` is where you cloned praetorian. First check that nobody changed the code (`git -C <repo> status` and `git -C <repo> diff`). Then:

- **writable by group or others**: often a copy made with a permissive umask, or an editor that changed the mode. `chmod go-w <repo>/lib <repo>/lib/*.sh`.
- **missing**: `git -C <repo> checkout -- lib/`.
- **a symbolic link**: replace it with the real file from the repository.
- **another owner**: after checking the content, `chown $(id -un) <repo>/lib <repo>/lib/*.sh`.

### No notification shows up

First check that praetorian sent it: the session log has a `NOTIFICATION:` line when it did. From a terminal, a session shorter than 5 minutes doesn't notify on purpose (`PRAETORIAN_NOTIFY_AFTER`, or `--notify` to force it).

If the line is there, macOS filtered it. Notifications sent through `osascript` are shown under **Script Editor**'s name, and Script Editor only appears in System Settings > Notifications once it has shown a notification itself (one sent from a terminal isn't enough). To allow it, once:

1. Open Script Editor (Applications > Utilities, or `open -a "Script Editor"`).
2. In a new document, run (▶︎):
   ```applescript
   display notification "test" with title "praetorian"
   ```
3. Click **Allow** when macOS asks. Script Editor is now listed in System Settings > Notifications: pick **Banners** (or **Alerts**, to keep them on screen until dismissed).
4. Check with `praetorian --dry-run --notify`: it sends one in a few seconds, without changing anything.

Still nothing: look in the same list for your terminal app (Terminal, iTerm, Visual Studio Code…), which macOS may credit instead, and check Focus (Do Not Disturb), which keeps notifications in the Notification Center without a banner.

### The scheduled run didn't happen

Run `praetorian-schedule status`: it says whether the job is loaded, turned off in Login Items, or points at a `praetorian` that moved, and shows the last exit code and session log. Then:

- The Mac was shut down at that time: the job only runs on a Mac that is on (asleep is fine). See [Scheduling](#scheduling-overnight-runs) to wake it up first.
- "is on Battery Power (--ac-power-only)" in the log or the notification: the Mac wasn't plugged in.
- "no network (github.com unreachable…)": see [above](#no-network-githubcom-unreachable-after-300-s).
- Something printed before the session log existed (for example the `lib/` check) is in `PRAETORIAN_HOME/logs/launchd.stderr.log`; `status` shows its last lines.
- `install` failed with "Input/output error": run `praetorian-schedule uninstall`, then `install` again, from your own session at the Mac (not over SSH).

### Touch ID doesn't show up for sudo

Over SSH there is no Touch ID: sudo asks for the password. Inside `tmux` (or `screen`), `pam_tid` can't reach the Touch ID sensor on its own either. The fix is [`pam_reattach`](https://github.com/fabianishere/pam_reattach): install it, then put `auth optional /path/to/pam_reattach.so` **before** the `pam_tid.so` line in `/etc/pam.d/sudo_local`. `praetorian-sudo-setup` respects that order: when a `pam_reattach.so` line is already there, it inserts `pam_tid` right after it. Otherwise, run praetorian from a plain terminal window.

### Where is the full output?

`logs/praetorian_<timestamp>.log` in `PRAETORIAN_HOME` (`~/praetorian/logs/` by default), written live: `tail -f` it during a long build. The last 30 are kept, plus every one under 7 days ([decision 18](#18-log-rotation)). Build logs of failed packages are in the `_buildlogs.tar.gz` (Homebrew) and `_portlogs.tar.gz` (MacPorts) archives next to it.

## What a session does

```
parse args ─► re-exec under caffeinate (not for read-only modes or --dry-run) ─► prerequisites (root, package managers)
   │
   ├─► --migration-report, --status, --doctor, --sbom: read-only, run here and stop (no lock, no Xcode/power/network/disk check)
   ▼
Xcode ready? ─► on AC power? (--ac-power-only) ─► network (unattended: wait up to 5 min) ─► disk space ─► lock ─► prune quarantine
   │
   ├─► --migrate / --migrate-all: one migration after another, formulae nothing depends on first ─► log rotation ─► summary
   ├─► --prune: unused Homebrew dependencies, round by round, each confirmed ─► log rotation ─► summary
   ▼
Maintenance Homebrew (skipped if Homebrew is absent)
   1. Homebrew developer-mode guard (switch back to stable if needed)
   2. brew update
   3. show quarantine
   4. formulae: list outdated (minus quarantine)
        → brew fetch --deps   (download everything first)
        → upgrade one by one   (auto-fix + one retry on known failures)
   5. casks: repair interrupted upgrades, list outdated (minus quarantine)
        → upgrade one by one   (sudo deferred in unattended mode)
   6. brew autoremove
   7. archive this session's build logs
   8. brew cleanup --prune=all
   │
   ▼
Maintenance MacPorts (skipped if MacPorts is absent)
   1. port version   (health, macOS mismatch)
      unattended and sudo -n true fails → port outdated (count only), whole part deferred
      port and every directory above it owned by root, writable by root only? otherwise blocked
   2. sudo port selfupdate
   3. port outdated (minus quarantine) → sudo port -p upgrade <list> → port outdated again
   4. sudo port uninstall inactive   (only if any)
   5. report port echo leaves
   │
   ▼
Side by side (both present) ─► Diagnostics (brew doctor) ─► Unused apps (> 6 months) ─► Log rotation (counted only in dry-run) ─► Summary (+ notification)

Stopped before the summary (a block, an unexpected error; not Ctrl-C) ─► notification naming the block
```

The summary lists failed steps, blocks, the Homebrew and MacPorts errors pulled from the output, anything newly quarantined, deferred items, and concrete commands to unblock each quarantined package.

## Files and state

The code lives where you cloned it. The state lives in `PRAETORIAN_HOME` (`~/praetorian` by default, so the same directory when you cloned there; the state files are in `.gitignore`).

| Path | Content | Tracked in git |
|---|---|---|
| `praetorian` | Entry point: constants, options, code loading, `main` | yes |
| `lib/*.sh` | The code, by topic (see [Code layout](#code-layout)) | yes |
| `praetorian-sudo-setup` | One-time Touch ID setup for sudo | yes |
| `praetorian-schedule` | Installs, removes and checks the overnight `launchd` job | yes |
| `ci/`, `tests/`, `.github/` | Checks, tests and CI (see [Development](#development)) | yes |
| *In `PRAETORIAN_HOME`:* | | |
| `logs/praetorian_<timestamp>.log` | Full session log, including the complete brew output (last 30 kept, plus every one under 7 days). `logs/` is made private (`700`): it lists your paths and packages | no |
| `logs/praetorian_<timestamp>_buildlogs.tar.gz` | Homebrew build logs produced during the session (same retention) | no |
| `logs/praetorian_<timestamp>_portlogs.tar.gz` | MacPorts `main.log` files of failed ports (same retention) | no |
| `logs/sbom_<timestamp>.cdx.json` | CycloneDX 1.6 SBOM written by `--sbom` (mode `600`, same retention, rotated when `--sbom` runs). Properties are prefixed `praetorian:` (`source`, `on_request`, `homepage`, `tap`, `variants`, `path`, `signed_by`, …) | no |
| `quarantine.tsv` | Packages skipped on purpose, one per line | no |
| `migrated.tsv` | Formulae moved to MacPorts: `formula  port[,port…]  epoch`. Read by `--status`, `--doctor` and `--prune` | no |
| `.toolchain` | `xcode` or `clt`: the compiler toolchain seen by the last real (not dry-run) session; written on every one | no |
| `.macos_version` | macOS version seen by the last real session, written by the Xcode check only once Xcode is fully ready (or when there is no full Xcode), not on a dry-run: tells a pending first launch caused by a macOS update from any other | no |
| `.lock/` | Present while a session runs; `.lock/pid` holds its PID (written as `.lock/pid.<pid>` then renamed) | no |
| `.lock.stale.<pid>` | A crashed session's lock, for the moment it is being taken over | no |
| `logs/launchd.stderr.log` | Written by `launchd` for the scheduled job: what praetorian printed on stderr before its session log existed. Usually empty | no |
| `.cask_backup.<cask>.<pid>` | Copy of `Caskroom/<cask>` while a half-installed cask is reinstalled; removed afterwards, kept only if it couldn't be put back (the warning gives the command) | no |
| *Elsewhere:* | | |
| `$TMPDIR/praetorian.*`, `praetorian_stamp.*`, `praetorian_q.*` | Current step's output, session start stamp, quarantine rewrite. Removed at the end of the session | — |
| `$TMPDIR/praetorian_sbom.*` | The inventories `--sbom` collects, in a private directory. Removed when it ends, Ctrl-C included | — |
| `~/.cache/trivy` | trivy's vulnerability database, downloaded by trivy itself the first time `--sbom` runs it (only when trivy is installed) | — |
| `~/Library/LaunchAgents/io.github.victor-sys-admin.praetorian.plist` | The scheduled job, written by `praetorian-schedule` only (`644`) | — |
| `/etc/pam.d/sudo_local` | Written by `praetorian-sudo-setup` only (`root:wheel 444`), with `sudo_local.bak.<timestamp>.<pid>` backups next to it | — |

`quarantine.tsv` is tab-separated:

```
name    type(formula|cask|port)    epoch    cause(xcode|pkg|build)    detail
```

You can edit or empty it by hand at any time (not while a session runs).

### The session lock

One session at a time: `.lock/` is created with `mkdir` (atomic), and its PID is written to a temporary file then renamed, so a reader never sees half a PID. When `.lock/` already exists:

- its PID is alive → blocked ("another praetorian session is already running");
- no PID yet and the directory is less than a minute old → a session is just starting: blocked ("couldn't take the session lock");
- otherwise (dead PID, or no PID for more than a minute) → taken over with a warning. The old lock is first renamed to `.lock.stale.<pid>` (atomic: of two sessions taking it over at once, only one succeeds) and checked again before it's removed.

On exit, praetorian removes `.lock/` only if it still holds its own PID. A maintenance session, `--migrate` (one lock for the whole batch), `--migrate-all`, `--prune` and `--dry-run` take the lock; the read-only `--migration-report`, `--status`, `--doctor`, `--sbom` and `--help` don't, so they can run while a session is going on.

## Environment variables

| Variable | Effect |
|---|---|
| `PRAETORIAN_HOME` | State directory: logs, quarantine, lock, `.toolchain`, `migrated.tsv` (default `~/praetorian`). Must be an absolute path without a newline, otherwise praetorian stops with exit code 1 before writing anything. Set it in the environment that starts praetorian (shell profile, `launchd` job). |
| `PRAETORIAN_NOTIFY_AFTER` | From a terminal, the notification is sent only when the session took at least this many seconds (default `300`; `0` = always). Digits only: anything else is ignored (default used). Unattended sessions always notify; `--notify` / `--no-notify` override it. |
| `HOMEBREW_DEVELOPER` | When set, praetorian leaves Homebrew on its development branch instead of switching back to stable ([decision 13](#13-stay-on-homebrews-stable-channel)). |
| `PRAETORIAN_NETWORK_WAIT` | Unattended only: how many seconds to wait for `github.com` to answer before blocking (default `300`; `0` = check once). Digits only: anything else gives a warning and the default. From a terminal there is no wait. |
| `PIPX_HOME` | pipx's own variable, honoured by `--doctor`, `--sbom`, `--prune` and `--migrate` to find pipx environments (otherwise `~/.local/pipx`, then `~/Library/Application Support/pipx`). |
| `CONTAINER_ENGINE` | `ci/check` only: `docker` or `podman`. Without it, the first one whose daemon answers. |
| `PRAETORIAN_PORT_PREFIX` | **Tests only.** MacPorts prefix (default `/opt/local`), so the tests can install a fake `port`. With the default prefix, `port` and every directory above it up to `/` must belong to root and be writable by root only before any `sudo port`, whatever `sudo` comes first in the `PATH`. With another prefix, that check is skipped only when the `sudo` found in the `PATH` isn't a setuid-root file (the tests' fake `sudo`, which can't give root); with a real `sudo`, it applies and blocks. |
| `PRAETORIAN_SUDO_LOCAL` | **Tests only.** File written by `praetorian-sudo-setup` instead of `/etc/pam.d/sudo_local`. Since that script runs as root, the variable is refused (exit 1) under a real sudo (`SUDO_USER` set, so `sudo -E` can't pass it), for a relative path, a path with `..`, a symbolic link, and anything under `/etc`, `/private/etc`, `/System` or `/usr`. |
| `PRAETORIAN_MIN_FREE_GB` | **Tests only.** Minimum free space in GB (default 5), to test the disk-full block. Digits only, read as decimal; anything else gives a warning and the default 5. |
| `PRAETORIAN_DOCTOR_ROOT` | **Tests only.** Prefix of the system paths `--doctor` reads (`/Library/Java/JavaVirtualMachines`, `/Library/Developer/CommandLineTools`, `/etc/paths`, `/etc/paths.d`). They are only read, and the commands built from them are printed, never run. |
| `PRAETORIAN_CAFFEINATED` | Internal: set when praetorian re-runs itself under `caffeinate`, so it doesn't loop. |

---

## Design decisions

Each choice below came from a real failure. The date and details are in the [project history](#project-history-the-2026-10-15-incident).

### 1. Clean terminal, complete log

The terminal shows one line per step (✓ / ✗ / !), and the full brew output goes to the session log. Homebrew output on a source build runs to tens of thousands of lines; nobody reads it live, but you need all of it when something breaks.

### 2. One package at a time

Formulae and casks are upgraded **individually**, not with a single `brew upgrade`.

*Why:* a grouped `brew upgrade` stops at the first failed build and never tries the remaining packages. In practice, a failed `node` build meant `mysql-client` was never attempted. Upgrading one package at a time costs a little dependency-resolution overhead, but one failure no longer blocks the rest.

### 3. Quarantine instead of failing every night

A package that fails for a cause that won't go away on its own is written to `quarantine.tsv` and skipped on later runs.

| Cause | Detected from | Expires |
|---|---|---|
| `xcode`: needs full Xcode | `A full installation of Xcode.app is required` / `An unsatisfied requirement failed this build` | 30 days, or right away once Xcode is installed |
| `pkg`: a cask's `.pkg` script fails | `Failure while executing; … installer -pkg` | 30 days |
| `build`: compilation fails, even after auto-fixes | `Last 15 lines from ~/Library/Logs/Homebrew/<name>/…` | **7 days**, or right away when the toolchain changes |

When a *dependency* fails to build, the requested formula is quarantined too, because it would fail the same way. Anything quarantined earlier in the same session is skipped.

*Why:* without a quarantine, a formula that needs Xcode gets rebuilt and fails on every run, sometimes after an hour of compiling. Build failures expire sooner (7 days) because a new formula revision often fixes them. `.toolchain` records whether the last run used Xcode or only the Command Line Tools: when that changes (for example after you install Xcode), build quarantines no longer apply, because they were recorded with a different compiler.

### 4. Auto-fixes, then one retry

When an upgrade fails on a known cause, praetorian applies the fix and retries **once**. It quarantines only if the retry fails too. Each fix runs at most once per session.

| Symptom in the output | Fix | Real case |
|---|---|---|
| `XCode tool 'metal' neither found` | `xcodebuild -downloadComponent MetalToolchain` | `openjdk` (and so `ant`, `gradle`) with Xcode 26, where Metal is a separate download |
| The formula itself asks for `brew unlink <X>` | unlink X, build, **always** relink, even on Ctrl-C | `mysql-client` refuses to build while Homebrew's `boost` is linked |
| `Library not loaded … Referenced from …/Cellar/<Y>/` (in the output or this session's build logs) | `brew reinstall <Y>` | `merve` was still linked against `libsimdutf.34` after `simdutf` moved to `.37`, which broke the `node` build |
| `uninitialized constant …Timeout` / `DownloadError` / `Failed to download resource` | `brew fetch --deps --force <formula>` | Homebrew bug that turned a failed download into a crash at the end of a 50-minute `node` build |
| Cask: `It seems the … source … is not there` / `there is already a …` | `Caskroom/<cask>` copied to `PRAETORIAN_HOME/.cask_backup.<cask>.<pid>`, then `brew uninstall --cask --force` and `brew install --cask`. If the install fails (or is interrupted), the copy is put back so brew still knows the cask. No copy possible, no forced uninstall | `font-ubuntu` left half-installed by an interrupted upgrade |

Limit of the cask fix: the copy only covers brew's record (`Caskroom/<cask>`). What the forced uninstall removed outside it (the `.app` in `/Applications`, fonts…) doesn't come back; the record put back lets the next session retry.

Also: if brew returns an error but the new version **is** installed (no longer listed by `brew outdated`), the step counts as a success with a warning. *Real case:* `node` finished building, then Homebrew crashed on `Failed to fix install linkage` because of a sandbox permission bug.

### 5. Download everything before compiling

Before any formula upgrade, praetorian runs `brew fetch --formula --deps <all outdated>`.

*Why:* a network glitch then fails in seconds, during the download, instead of after an hour of compiling when brew fetches a resource at the very end. It also lets the auto-fix above retry a download without rebuilding blindly.

### 6. Keep build logs before cleanup

This session's build logs are tarred into `logs/` **before** `brew cleanup --prune=all` runs.

*Why:* `brew cleanup --prune=all` wipes `~/Library/Logs/Homebrew`, so the actual compiler error for a failed build was gone by the end of the session. The archive covers only the directories modified since the session started (tracked with a stamp file).

### 7. Never let the Mac sleep mid-build

The script re-executes itself under `caffeinate -i`.

*Why:* an overnight session lasted about 12 hours. At some point the Mac went to sleep, the network dropped, and an svn checkout failed with a DNS error. Note that closing the lid still puts the Mac to sleep.

### 8. Ctrl-C stops everything, cleanly

brew runs in the background (see the next point), and `SIGINT`/`SIGTERM` are trapped: the trap kills the whole process tree of the current command, prints where the log is, and exits with code 130. An exit trap removes temp files and relinks any formula that was unlinked.

*Why:* in the first version, Ctrl-C killed only the current step; every following step then failed instantly with code 130, which made a clean run look like a cascade of failures. And with no job control, a background child ignores `SIGINT`, so it must be killed explicitly.

### 9. Live log and progress line

Each brew or port command runs in the background and writes to a temp file. Every 2 seconds the new output is appended to the session log, and a single terminal line is redrawn with the elapsed time and the latest action (`==>` for Homebrew, `--->` for MacPorts):

```
  12:34 Upgrading formula gstreamer — ==> meson compile …
```

The original stdin is saved on fd 3 and passed to the command, so sudo can still prompt. The progress line only appears once the command has printed something: until then, sudo may be waiting for a password in the same terminal.

*Why:* the first version only wrote the output to the log at the end of each step. A 50-minute build looked frozen, `tail -f` showed nothing, and there was a real temptation to kill a run that was working fine.

The progress line is **turned off during casks**, because it would overwrite sudo's password prompt.

### 10. Pull Homebrew's errors into the summary

From each step's output, praetorian extracts the `Error:` lines (deduplicated, truncated), build failures (from the `Last 15 lines from …` pattern, since a build failure has no `Error:` line), and network errors (DNS, connection). Up to 12 are shown in the summary.

### 11. Repair interrupted cask upgrades

Before the cask step, any leftover `Caskroom/<cask>/<version>.upgrading` directory is moved back to `<version>`.

*Why:* an interrupted upgrade leaves that directory behind, and every later upgrade of the cask fails.

### 12. Check that Xcode is ready, instead of hanging

If Xcode.app is installed but not selected, its license isn't accepted, or its first launch isn't done, praetorian exits with code 1 and prints the one command that fixes that problem (the next one, if any, is checked at the next run). A pending first launch right after a macOS update is named as such ("macOS was updated (X → Y): Xcode has to reinstall its system components"): praetorian keeps the macOS version of the last session in `.macos_version`, recorded only once Xcode is fully ready, so the explanation holds until every problem is fixed.

*Why:* right after Xcode was installed, a `cmake` sat at 0% CPU for many minutes while its first launch was still pending; and after a macOS update the same block came back with three commands, two of which had nothing to do with it.

### 13. Stay on Homebrew's stable channel

If Homebrew is tracking its development branch (`main`) and `HOMEBREW_DEVELOPER` isn't set, praetorian runs `brew developer off`, then `HOMEBREW_UPDATE_TO_TAG=1 brew update --force` to go back to the latest stable tag. praetorian itself **never runs Homebrew developer commands** (`brew cat`, `brew linkage`, anything in `Library/Homebrew/dev-cmd/`).

*Why:* running a single developer command (`brew cat`, during the investigation) silently turned on developer mode. The next `brew update` moved Homebrew from the stable tag to `main`, whose code later crashed a `node` build.

### 14. Mac Intel notice

On `x86_64` with Homebrew installed, the session starts by saying that Homebrew no longer ships bottles for this platform (tier 3 since September 2026), that builds will be long, and, without Xcode, that some will be impossible. It then points to MacPorts and `--migration-report`.

### 15. `brew doctor` is informational

Warnings are counted and logged, but don't make the run fail. `brew doctor` exits non-zero for any warning, even a harmless one.

### 16. Greedy casks by default

`brew upgrade --cask --greedy` also updates apps that update themselves or are marked `latest`. Use `--no-greedy` to let those apps handle themselves. *Downside:* `latest` casks such as `font-ubuntu` are reinstalled on every run (see [limitations](#known-limitations-and-ideas)).

### 17. Unused apps report

For each `.app` directly inside `/Applications`, praetorian reads Spotlight's `kMDItemLastUsedDate` and lists the apps not opened in 180 days. Apps with no usage date are only counted in the log. The script reports; it never deletes anything.

### 18. Log rotation

The 30 most recent session logs, the 30 most recent Homebrew build-log archives, the 30 most recent MacPorts log archives and the 30 most recent SBOMs are kept, each counted separately, and on top of that **every file younger than 7 days** (`LOG_MIN_AGE_DAYS`). Only regular files directly inside `logs/` matching those names are ever removed (the list is built without `xargs`, whose GNU version runs its command on the current directory when given no input). `--dry-run` only counts the files a real run would remove.

*Why:* on 2026-10-17 a migration loop ran 45 sessions in one afternoon, and the rotation by count alone removed the logs of its own first failures, the ones needed to understand them.

### 19. Code split by topic, checked before it's loaded

The code moved from one 2,000-line file to `lib/` (see [Code layout](#code-layout)). Before loading anything, praetorian checks every file of a **fixed list** and the `lib/` directory: regular file, no symbolic link, owned by you or root, not writable by group or others. Any problem stops it with exit code 1, before any command runs.

*Why:* those files run with your rights and start commands under sudo. A file someone else could change, or a link pointing elsewhere, would be a way in. The list is fixed so that a file dropped into `lib/` is never loaded.

### 20. Every unplanned exit is explained

Planned exits go through `finish`. Any other non-zero exit (a command that failed where `set -e` stops the script) is caught by the `EXIT` trap and turned into a block naming the function, the file and the command, for example `in migrate (migrate.sh), command: prefix=$(brew --prefix)`. Cleanup (temp files, lock, relinking) runs either way.

The same rule explains how the code is written: a function whose failure must stop the session is never called on the left of `||`, `&&` or in an `if`, because bash turns `set -e` off inside it there. `--migrate` is split into one function per step (`migrate_preconditions`, `migrate_check_formula`, `migrate_check_usage`, `migrate_check_name`, `migrate_check_port`, `migrate_check_project`, `migrate_check_binary`, `migrate_check_sudo`, `migrate_install`, `migrate_verify`, `migrate_check_external`, `migrate_uninstall_formula`): each returns 0 and reports a stop through `block`, and `migrate_one` stops as soon as a block was added. `doctor_run` follows the same rule and leaves its verdict in `DOCTOR_RC`.

*Why:* until 1.2.0, an `ERR` trap was meant to do this, but bash doesn't run it inside functions (where almost all the code is) unless `errtrace` is on. An unexpected failure ended the session silently. Turning `errtrace` on wasn't an option: it would also fire inside command substitutions that are allowed to fail.

### 21. Notify when nobody is watching

The notification used to be sent in unattended mode only. Now it's also sent from a terminal when the session lasted long enough that you probably went to do something else (5 minutes by default), and when a session stops before its summary: a night run blocked by the lock, the disk or the battery would otherwise leave no trace until you read the logs. `osascript` gets the texts as arguments, never inside the AppleScript source (no quoting, no injection), and runs with a 15-second limit: a stuck `osascript` must not keep the session, and its lock, alive. A sound only when someone is at the Mac.

*Alternative rejected: `terminal-notifier`.* It would show praetorian's own name instead of Script Editor's, but it's one more thing to install, and on an Intel Mac that means building it.

### 22. Schedule with launchd, as you

`praetorian-schedule` installs a user `LaunchAgent`, never a system `LaunchDaemon` (Homebrew refuses root) nor a cron job: `launchd` runs a job the Mac slept through when it wakes up, where cron skips it, and cron needs Full Disk Access on recent macOS, a permission that widens what every cron job can read. No sudo, no stored password: the nightly run defers what needs root. See [Scheduling](#scheduling-overnight-runs) for the job and the checks made before it's installed.

### 23. Wait for the network before starting

Unattended, before the lock is taken, praetorian sends a HEAD request to `https://github.com` (10 s limit) every 15 seconds, for up to `PRAETORIAN_NETWORK_WAIT` seconds (5 minutes by default). Still nothing: blocked, exit code 1, with a notification; nothing was done, and the next scheduled run goes ahead. With `--dry-run`, only a warning. From a terminal there is no wait: you are there, and brew reports its own network errors.

*Why:* on 2026-10-17, the overnight session started at wake-up (`launchd` runs a missed job then), before the Wi-Fi was back. `brew update` failed with "Could not resolve host: github.com", and the downloads retried for an hour. `github.com` is what `brew update` needs first.

### 24. Check commands where the shell finds them

`--migrate` no longer asks "does the port's own file list contain every command?" but "will the shell find every command the formula linked into the `PATH` in `/opt/local/bin` or `sbin`?", whoever put it there (the port, a companion, `port select`, a port already installed). Only the formula's `Cellar/<formula>/<version>/bin` and `sbin` count, not its internal `bin` directories. Around that check, three others catch the wrong port before anything is installed: the [known traps](#known-traps) table, the [homepage comparison](#same-project-same-homepage) and the [binary check](#a-binary-for-this-mac). See [How the commands are checked](#how-the-commands-are-checked).

*Why:* on 2026-10-17, the first check refused correct migrations (pipx's and scons' `libexec/bin`, rust's `lib/rustlib/…/bin`, `cargo` shipped by its own port, `terraform` linked by `port select`), while the name alone would have installed the wrong software: MacPorts' `step` is KDE's physics simulator, its `ansible` dates from 2017, its `docker-compose` is v1, its `cmake` 3.31. And `nodejs26` and every `mysql` port had no binary for macOS 15 on Intel: the source builds failed after a long time.

### 25. Status and health from the real state

`--status` and `--doctor` ask brew, port and the file system what is true now, not the logs or `migrated.tsv` alone: a migrated formula is checked to be gone from Homebrew and its ports active and requested. Both are read-only, run no sudo and take no lock. `--doctor` prints the fix for each problem and runs none of them: most need sudo or touch files outside praetorian's scope.

*Why:* on 2026-10-17 a summary built from the logs alone claimed formulae were gone that were still installed, and the breakages a migration leaves behind (pipx tools on a removed Python, a root-owned `__pycache__`, ports MacPorts would remove as unused) showed up nowhere until something failed.

### 26. Prune what `brew autoremove` misses

`--prune` removes the formulae no other formula needs (`brew leaves`) that you didn't install on request, minus anything a program outside Homebrew uses (pipx, npm), a Homebrew service or your shell startup files: shown, confirmed round by round, never unattended. `brew autoremove` still runs in every maintenance session.

*Why:* `brew autoremove` only removes formulae flagged `installed_as_dependency`. After the migration day it removed nothing, while `brew leaves` listed a dozen dependencies of the migrated formulae, each one recompiled on every update on an Intel Mac. And removing a Homebrew Python had already broken 3 pipx tools: "nothing else depends on it" has to include what Homebrew doesn't know about.

### 27. An SBOM written by a JSON library

`--sbom` collects the inventories with each tool's own machine-readable output, and only Python's `json` module (run with `-I`, from a heredoc) writes the CycloneDX file; without a working Python, it blocks rather than write JSON by hand. The file is written under a temporary name and renamed once complete, so a failure never leaves a partial SBOM that the next comparison would read.

*Why:* after moving some 250 formulae from one package manager to another, "what is installed, and what changed?" had no answer short of comparing `brew list` and `port installed` by hand. One package name with a quote in it would make a JSON file built in bash invalid.

---

## Security: how sudo is handled

Some casks run `.pkg` installers through `sudo`, and MacPorts needs `sudo` for every command that changes something. How praetorian handles that follows the **CIS Apple macOS Benchmark** and **PCI DSS v4.0.1**.

### What the rules say

| Rule | Requirement | How praetorian fits |
|---|---|---|
| CIS: *Ensure the Sudo Timeout Period Is Set to Zero* | `Defaults timestamp_timeout=0`: sudo never caches credentials | Works with it (one prompt per sudo call); doesn't need it. Set it yourself in `/etc/sudoers.d/` if your policy requires it |
| CIS: *Ensure a Separate Timestamp Is Enabled for Each User/tty Combo* | `timestamp_type=tty`, so a background process can't reuse a terminal's elevation | macOS default (sudo 1.8 and later); praetorian runs no background sudo |
| PCI DSS 8.6.2 | No passwords for interactive accounts hard-coded in scripts or configuration files | No password stored anywhere |

### What praetorian does

1. **It never stores the password**: no file, no Keychain item, no environment variable.
   *Alternative rejected: the Keychain plus `SUDO_ASKPASS`.* To run unattended, the Keychain item would have to be readable by `/usr/bin/security` without a prompt, and any process running as the user can call `security`. Malware would then get the login password itself, which also unlocks FileVault and the Keychain, on top of root.
   *Alternative rejected: a passwordless sudoers rule.* No secret is stored, but the allowed commands would have to be broad (`installer -pkg <anything>` alone already means running arbitrary code as root), so any process running as the user could become root.
2. **No sudo keepalive.** An earlier version ran `sudo -v` once, then refreshed it in a background loop for the whole session. It was removed: with `timestamp_timeout=0` it had no effect, and keeping elevated credentials alive from a background process is exactly what the CIS controls are meant to prevent.
3. **Touch ID instead of typing the password.** `praetorian-sudo-setup` adds `auth sufficient pam_tid.so` to `/etc/pam.d/sudo_local`, the file Apple provides (since Sonoma) to survive system updates; `/etc/pam.d/sudo` itself is overwritten by updates. No secret is stored, you must be physically present, and it works alongside `timestamp_timeout=0`: each sudo call is one touch. The password stays available as a fallback.
   - Usage: `sudo ./praetorian-sudo-setup [--disable | --help]`. Exit code `0` when done or nothing to do, `1` on error (not root, no fingerprint enrolled, refused `PRAETORIAN_SUDO_LOCAL`, unknown option).
   - Idempotent: when an active `pam_tid` line is already there, nothing changes. Otherwise it backs up an existing file (`sudo_local.bak.<timestamp>.<pid>`), then either uncomments the line if the file is a copy of Apple's template (`sudo_local.template`), or inserts `auth sufficient pam_tid.so` right after an existing `pam_reattach.so` line (which must come first for Touch ID inside `tmux`), or at the top of the file. A missing file is created. Every write goes through a temporary file and `mv`, and the file ends up `root:wheel 444`, like Apple's template.
   - It refuses to run if no fingerprint is enrolled. The fingerprint check (`bioutil -c`) runs as the user who called sudo: `bioutil` reads the *current* user's configuration, which under sudo would be root's.
   - Undo with `sudo ./praetorian-sudo-setup --disable` (comments the line out, with a backup).
   - Touch ID doesn't reach sudo over SSH; inside `tmux`, it needs `pam_reattach` (see [Troubleshooting](#touch-id-doesnt-show-up-for-sudo)).
4. **Unattended mode never blocks.** praetorian exports `SUDO_ASKPASS=/usr/bin/false`. Homebrew then calls `sudo -A` (see `system_command.rb`), which fails right away with `a password is required`. praetorian spots that message and marks the cask as **deferred**: not a failure and not quarantined. It's named in the summary and in the macOS notification, so you can run it from a terminal later. For MacPorts, praetorian checks `sudo -n true` first; when that fails, the whole MacPorts part is deferred before any command that changes something runs: only the read-only `port version` and `port outdated` (to count outdated ports for the summary) run before the deferral is reported. MacPorts commands use `sudo -n` when unattended, so they could never wait anyway.
5. **sudo only runs absolute paths it chose, and checks them.** MacPorts is always `/opt/local/bin/port`, never a `port` found in the `PATH`, and the names given to `--migrate` are restricted to safe characters before they reach a sudo command line. Before any `sudo port`, `port` and every directory above it up to `/` (symbolic links followed) must belong to root and be writable by root only; otherwise the MacPorts part (or the migration) is blocked. With the default prefix `/opt/local` this check always applies, whatever `sudo` is found in the `PATH`. With a test prefix (`PRAETORIAN_PORT_PREFIX`) it is skipped only when the `sudo` found isn't a setuid-root file, which can't give root. `sudo` itself is found through the `PATH` (`/usr/bin/sudo` on a normal setup): whoever controls your `PATH` controls your shell anyway.
6. **praetorian's own code is checked before it runs** (see [decision 19](#19-code-split-by-topic-checked-before-its-loaded)), but it remains code you own and can change: anyone who can write to your clone, or run commands as you, can make it do anything sudo then allows. That is the same trust you give any script in your home directory. See [SECURITY.md](SECURITY.md) for the threat model and how to report a vulnerability.

### What was tested

- `praetorian-sudo-setup`, by the bats tests (`tests/sudo-setup.bats`) on a test file (`PRAETORIAN_SUDO_LOCAL`) with fake `id`, `bioutil` and `chown`: not root, no fingerprint, missing file, Apple's commented template, insertion after `pam_reattach`, other content kept, re-run (no change, no backup), `--disable` then re-enable, `--help`, refused `PRAETORIAN_SUDO_LOCAL` values. The tests never touch `/etc/pam.d/sudo_local`.
- On the development Mac: deferral with a fake `brew` calling the real `sudo -A` (the cask was deferred in about 2 seconds, nothing quarantined, no failure counted; a genuine `.pkg` failure was still quarantined), and a real `--unattended --retry-quarantined` session (about 38 seconds, 0 failures; no cask needed sudo that day).

---

## Development

### Code layout

| File | Content |
|---|---|
| `praetorian` | Header, constants, options and global state; `lib/` safety check and loading; `usage`, argument parsing, `main` |
| `lib/ui.sh` | Colors, session log, `say`/`info`/`ok`/`warn`/`err`/`loud`, `block` |
| `lib/session.sh` | `finish`, Ctrl-C, `EXIT` handling (with the "Stopped" notification); `run_step`; output analysis; step counters; Xcode check and `.macos_version`; sudo policy; prerequisites (managers, power source, network, disk, lock); platform notes; log rotation |
| `lib/quarantine.sh` | `quarantine.tsv`: add, prune, list, show |
| `lib/brew.sh` | Homebrew maintenance, auto-fixes, casks, build log archives |
| `lib/macports.sh` | MacPorts maintenance, result check, MacPorts log archives, the *side by side* section (formulae whose commands also come with MacPorts) |
| `lib/migrate.sh` | `--migration-report`: known traps (`known_port_spec`), port name guesses, homepage comparison (`homepage_verdict`), binary check (`port_binary_status`, `port_binary_sibling`); `--migrate`, one function per step (`migrate_preconditions` → `migrate_check_formula` → `migrate_check_usage` → `migrate_check_name` → `migrate_check_port` → `migrate_check_project` → `migrate_check_binary`, then `migrate_dry_run_plan` in dry-run, or `migrate_check_sudo` → `migrate_install` → `migrate_verify` (with `migrate_port_select`); then `migrate_check_external` → `migrate_uninstall_formula`); `migrate_one` runs one formula, `migrate_batch` the list (`--migrate` repeated, `--migrate-all`) and its summary |
| `lib/report.sh` | `brew doctor`, unused apps, unblocking hints, summary, notification (when, sound, time limit) |
| `lib/doctor.sh` | `--doctor` (one function per check, `doctor_run`), and `formula_external_users`, used by `--migrate` and `--prune` |
| `lib/prune.sh` | `--prune`: candidates, rounds, confirmation, MacPorts leaves report |
| `lib/status.sh` | `--status` |
| `lib/sbom.sh` | `--sbom`: inventories, the Python that writes the JSON, comparison with the previous SBOM, trivy summary |
| `praetorian-schedule` | Standalone: the overnight `launchd` job (`install`, `uninstall`, `status`); doesn't load `lib/` |
| `ci/check` | Lint, format, secrets, workflows and tests (Linux containers) |
| `ci/macos-tests` | The same tests on macOS under `/bin/bash` 3.2 |

The files are loaded in that order, at the top level of `praetorian` (not inside a function: `declare` in a function would make the globals local). They only define functions and globals; nothing runs until `main`. To add a file: create it with `# shellcheck shell=bash` as its first line, and add it to `PRAETORIAN_LIBS` **and** to the `source` lines (same order). `ci/check` finds it on its own (`lib/*.sh`).

### Checks

All checks run through `ci/check`, locally and in GitHub Actions, with the same pinned containers (see [Requirements](#for-development-only-checks-and-tests)):

```sh
ci/check                 # everything
ci/check lint tests      # ShellCheck + bats only
ci/check fix-format      # apply shfmt's formatting, when the Formatting check fails
```

The bats tests (`tests/*.bats`, one file per area: main scenarios, options, interactive mode under a pseudo-terminal, robustness, MacPorts maintenance, `--migrate` and `--migration-report` (`migrate.bats`), `--doctor`, `--prune`, `--status`, `--sbom`, the Xcode check, notifications and `--ac-power-only`, `praetorian-sudo-setup`, `praetorian-schedule`) run praetorian for real on Linux (`ci/check`) and macOS (`ci/macos-tests`), with fakes in `tests/stubs/` in front of the `PATH`. Every `tests/*.bats` file is picked up by both runners. Each test gets its own temporary `HOME`, so `~/praetorian` there is a scratch directory:

| Fake | Records calls in | Driven by |
|---|---|---|
| `brew` | `$BREW_CALLS` | `BREW_OUTDATED_*` (and `_FORMULA_AFTER`), `BREW_UPGRADE_*` (and `*2` for the retry), `BREW_CASK_*`, `BREW_FETCH_RC`, `BREW_REINSTALL_RC`, `BREW_LIST_FILES`, `BREW_USES` (or `BREW_USES_MAP`, per formula; a dependent `brew uninstall` removed is gone), `BREW_HOMEPAGES` (`brew info --json=v2`), `BREW_LEAVES` (minus what was uninstalled) and `BREW_LEAVES_NEXT` (dependencies freed by a removal), `BREW_ON_REQUEST[_RC]` (`--installed-on-request`), `BREW_UNINSTALL_RC`, `BREW_INFO_CASK_OUTPUT`/`_RC`, `BREW_PREFIX[_RC]`, `BREW_REPOSITORY`, `BREW_CASKROOM`, `BREW_DOCTOR_OUTPUT`/`BREW_DOCTOR_RC` (`brew doctor`), `BREW_BUILD_LOG` (the upgrade writes a build log under `~/Library/Logs/Homebrew/<f>/`), `BREW_HANG_ON` (a subcommand that never ends, for Ctrl-C tests), `BREW_STDIN_FILE` (`brew update` records whether its stdin is a terminal and the line it reads) |
| `port` | `$PORT_CALLS` | `PORT_VERSION_*`, `PORT_SELFUPDATE_*`, `PORT_OUTDATED[_AFTER]`, `PORT_UPGRADE_*`, `PORT_INSTALL_*`, `PORT_ACTIVE` (already active before any install), `PORT_AVAILABLE`, `PORT_CONTENTS` and `PORT_FILES` (files per port, created under the prefix by `port install`), `PORT_INFO` (version, homepage, license per port), `PORT_DEFAULT_VARIANTS`, `PORT_SELECT` and `PORT_SELECT_FILES` (`port select --summary`, links made by `--set`), `PORT_INACTIVE`, `PORT_LEAVES`, `PORT_REQUESTED`, `PORT_INSTALLED` |
| `curl` | `$CURL_CALLS`, `$CURL_URLS` | never reaches the network. `CURL_DOWN_FOR`: the first N network checks fail as with no DNS; `CURL_PACKAGES`: the only archive names that exist on `packages.macports.org` (the others are a 404), `offline` = all time out |
| `sudo` | `$SUDO_CALLS` | `SUDO_DENY=1` simulates an authentication that can't happen |
| `osascript` | `$OSASCRIPT_CALLS` (one argument per line) | — (no notification pops up during the tests) |
| `defaults` | — | `DEFAULTS_BEEP_SOUND`: the alert sound `defaults read -g com.apple.sound.beep.sound` answers (Tink by default, empty = not set); the tests never read the machine's real preferences |
| `pmset` | — | `PMSET_SOURCE`: what `pmset -g batt` says the Mac draws from (`AC Power` by default) |
| `launchctl` | `$LAUNCHCTL_CALLS` | `LAUNCHCTL_BOOTSTRAP_RC`, `LAUNCHCTL_BOOTOUT_RC`, `LAUNCHCTL_DISABLED`, `LAUNCHCTL_LAST_EXIT`; loaded state in `$LAUNCHCTL_CALLS.loaded`. The real `launchd` is never touched |
| `plutil` | — | the real `plutil` on macOS (the generated plist is really checked, and a test reads it back with `plutil -extract`), a minimal `-lint` on Linux; `PLUTIL_LINT_RC` forces a failure |
| `xcodebuild`, `xcode-select` | `$XCODEBUILD_CALLS` (xcodebuild) | `XCODEBUILD_LICENSE_RC`, `XCODEBUILD_FIRSTLAUNCH_RC`, `XCODEBUILD_DOWNLOAD_RC`, `XCODE_SELECT_PATH`: nothing is downloaded, and the tests don't depend on how Xcode is set up on the machine |
| `id`, `bioutil`, `chown` | `$CHOWN_CALLS` (chown) | `FAKE_UID`, `BIOUTIL_TEMPLATES`: `praetorian-sudo-setup` as a fake root |
| `mktemp` | — | gives Linux the macOS `mktemp -t prefix` behavior (passes through on macOS) |
| `caffeinate` (written by `tests/options.bats` into the test's temp directory, not in `tests/stubs/`) | `$CAFFEINATE_CALLS` | checks the re-exec under `caffeinate` without keeping the machine awake |
| `sw_vers` (written by `tests/xcode.bats` into the test's temp directory) | — | the macOS version, to test the "macOS was updated" message |

The fake `port` is only installed (in `$PRAETORIAN_PORT_PREFIX/bin`) by tests that call `with_macports`, so the other tests run without MacPorts. Each variable is documented at the top of its fake. A test typically sets a few variables, runs praetorian, and checks both the output and the recorded calls: that a command ran, or, for fail-safe behavior, that it did **not**.

**Unit tests** call a single function. Sourcing `praetorian` loads every function without running `main`, so `in_praetorian 'port_candidates node "$all"'` runs one call in a separate bash. The `lib/` safety check is tested on a scratch copy (`scratch_copy`), which the test damages (permissions, missing file, symbolic link).

The tests run in the container as **your** user (`--user $(id -u):$(id -g)`), not as root: praetorian refuses root, and only loads `lib/` files owned by the user running it.

Some tests are skipped depending on the platform, with the reason printed by bats:

- `tests/interactive.bats` (praetorian under a pseudo-terminal, as when started by hand) needs `script(1)`: it runs on macOS (`ci/macos-tests`) and is skipped in the Linux container, which has no `script`. Every other file runs without a terminal, so in unattended mode (the fake `curl` answers the network check).
- "started as root" needs real root or `unshare -r` (a user namespace, Linux); "file owned by another user" needs real root to `chown`. Both are skipped elsewhere, and a few tests that assume a non-root user are skipped when run as root.
- Tests that need a setuid-root `/usr/bin/sudo`, `git` or `tar` are skipped where those are missing, and a couple of tests that would reach a real Homebrew are skipped on a machine where one is installed.

### Conventions

- bash 3.2 compatible (macOS's `/bin/bash`): no associative arrays, no `mapfile`, no `declare -g`, no negative array indices.
- `set -euo pipefail`. A planned exit is `finish <code>`, never `exit`, or it's reported as unexpected. (The only `exit` calls left are in the root and `lib/` checks of `praetorian`, which run before `finish` is loaded.)
- Formatting: `shfmt -i 4 -ci` (`ci/check fix-format`); ShellCheck at `--severity=style` with no finding. See also [CONTRIBUTING.md](CONTRIBUTING.md) and `.editorconfig`.
- Code, comments, documentation and terminal output in English.
- Never run Homebrew developer commands (`brew cat`, `brew linkage`, anything in `dev-cmd/`), not even while debugging: they silently switch Homebrew to its development branch ([decision 13](#13-stay-on-homebrews-stable-channel)).
- No apostrophe inside `"${var:-default}"`: bash 3.2 and 5 parse it as an opening quote.
- A function whose failure must stop the session isn't called on the left of `||` or `&&`, or in an `if`: `set -e` is off inside it there. `migrate` and its steps return 0 and report their outcome through `BLOCKERS` for that reason; `summary`, whose return code is the session's, is called with `set -e` suspended explicitly around that one call.
- In every test, write `[[ … ]] || false`: under macOS's bash 3.2 (`ci/macos-tests`), a failing `[[ ]]` that isn't the test's last command doesn't fail the test, so the assertion checks nothing there, even when bash 5 in the Linux container catches it.
- Counters are incremented with `x=$((x + 1))`, not `x+=1` (which appends text unless the variable was declared `-i`, and ShellCheck can't see that across files).
- ShellCheck checks every file on its own too. A global set in one file and used in another needs a one-line `# shellcheck disable=SC2034` (or `SC2153`) with the reason, on that line only.

---

## Project history: the 2026-10-15 incident

This is how the project came about, kept for the reasoning behind the design. It happened on the author's Intel MacBook Pro (2018, macOS 15); the paths, versions and files below are from that machine, not requirements. The day shaped version 1.1.0.

**Starting point:** "brew update doesn't work". `brew update` itself was fine. `brew upgrade` was failing.

| # | Problem | Root cause | Resolution |
|---|---|---|---|
| 1 | Overnight run lasted about 12 hours | Intel Mac: no bottles, everything built from source | Mac Intel notice, `caffeinate`, quarantine |
| 2 | `openjdk`, `ant`, `gradle`, `gtk4`, `gstreamer` failed | Full Xcode required, only the CLT installed | Xcode installed and initialized; the Xcode readiness check was added |
| 3 | `libsoup` failed | DNS failure during an svn checkout, Mac asleep | `caffeinate`, network error detection, download before building |
| 4 | Every step after a Ctrl-C failed with code 130 | No `SIGINT` handling | The whole session now stops on Ctrl-C |
| 5 | `wireshark-app` upgrade failed | Its uninstall `.pkg` ends with `pkgutil --forget org.wireshark.path_helper.pkg`, and that package was never installed | Manual fix: `rm -rf /usr/local/Caskroom/wireshark-app && brew install --cask --force wireshark-app`; the path_helper package is now recorded, so future upgrades work |
| 6 | `font-ubuntu` blocked and its fonts missing | Upgrade interrupted halfway | `.upgrading` directory repair, then uninstall `--force` and reinstall |
| 7 | `mysql-client` never tried after `node` failed | Grouped `brew upgrade` stops at the first failure | One package at a time |
| 8 | No compiler error left to read | `brew cleanup --prune=all` wipes build logs | Build logs archived before cleanup |
| 9 | Run looked frozen | Output only written to the log at the end of a step | Live log and progress line |
| 10 | Build hung at 0% CPU | Xcode first launch not done | Xcode readiness check |
| 11 | `openjdk` failed even with Xcode | Metal Toolchain not installed (separate download in Xcode 26) | Auto-fix |
| 12 | `mysql-client` failed | Formula refuses to build with Homebrew's `boost` linked | Auto-fix: unlink, build, relink |
| 13 | `node` failed with `dyld: Library not loaded libsimdutf.34` | `merve` built against the old `simdutf` soname | Auto-fix: reinstall the stale formula |
| 14 | `node` crashed with `NameError … CurlDownloadStrategy::Timeout` | A `brew cat` run during the investigation turned on developer mode, so Homebrew moved to `main` | `brew developer off` and back to the stable tag; developer-mode guard; download before building |
| 15 | Old `node` 26.5 wouldn't start | `ada-url` moved to v4 (soname 3 → 4) while the new `node` wasn't built yet | Fixed once `node` 26.11.1 built (see limitations) |
| 16 | `node` reported as failed although installed | Homebrew sandbox bug (`Failed to fix install linkage`) | Step counts as a success with a warning when the version is installed |
| 17 | Password asked repeatedly | CIS `timestamp_timeout=0`, so the keepalive did nothing | Touch ID via `sudo_local`, keepalive removed, unattended deferral |

End state: every formula and cask up to date, Homebrew back on 7.0.9 stable, quarantine empty.

### MacPorts install, same day

The day that shaped version 1.2.0.

| # | Problem | Root cause | Resolution |
|---|---|---|---|
| 18 | `brew doctor`: deprecated formula `gtk+` | GTK 2, unmaintained upstream, nothing depended on it | `brew uninstall gtk+` |
| 19 | Homebrew has no future on this Mac | Intel is tier 3: no bottles, builds from source only | Decision: CLI tools move to MacPorts, casks stay in Homebrew; MacPorts support, `--migration-report` and `--migrate` added |
| 20 | `sudo: port: command not found` right after installing MacPorts | Line 13 of `~/.zshrc` set the whole `PATH` by hand, without `$PATH`, erasing what the installer had added in `~/.zprofile` | `/opt/local/bin:/opt/local/sbin:` added at the start of that line (backup kept as `~/.zshrc.bak-praetorian-*`); praetorian now explains this case when `/opt/local/bin` is missing from the `PATH` |
| 21 | First real `--migration-report`: 14 formulae "not found" | Name guesses only tried `name@X.Y` and `name<digits>` | Tap prefix, case, aliases and `py-` modules added: 5 left, all genuinely without a port |
| 22 | An unexpected failure would have ended the session with no explanation | The `ERR` trap meant to explain it never ran inside functions (bash needs `errtrace` for that), found while splitting the code | `EXIT` handling with `finish` for planned exits ([decision 20](#20-every-unplanned-exit-is-explained)) |

### Migration day, 2026-10-17

The day the command-line tools actually moved to MacPorts, about 60 real migrations; it shaped version 1.5.0.

| # | Problem | Root cause | Resolution |
|---|---|---|---|
| 23 | The overnight session failed: "Could not resolve host: github.com", then downloads retried for an hour | The job ran at wake-up, before the Wi-Fi was back | Unattended sessions wait for the network, then block ([decision 23](#23-wait-for-the-network-before-starting)) |
| 24 | `--migrate` refused 4 formulae (pipx, scons, rust…) that MacPorts provides | Every `bin` directory of the keg was compared, internal ones included (`libexec/bin`, `lib/rustlib/…/bin`) | Only what brew links into the `PATH` is compared, where the shell finds it ([decision 24](#24-check-commands-where-the-shell-finds-them)) |
| 25 | A migration loop (45 sessions in one afternoon) deleted the logs of its own first failures | Rotation kept the last 30 logs, by count only | Every log under 7 days is kept too ([decision 18](#18-log-rotation)) |
| 26 | Same name, wrong software: MacPorts' `step` is KDE's physics simulator, its `ansible` port dates from 2017, `guile` is obsolete, `docker-compose` is v1, `cmake` is 3.31, `terraform` is one port per version, `ImageMagick` is v6 | A port name says nothing about the project behind it | [Known traps](#known-traps) table, homepage comparison ([decision 24](#24-check-commands-where-the-shell-finds-them)) |
| 27 | Ports with versioned commands (`port select`) or companions (`cargo`, `step-ca`, `npm11`) were always refused | One port's `port contents` had to hold every command | Companion ports in the spec, `port select` groups set when still `none`, commands checked in `/opt/local/bin` and `sbin` |
| 28 | No MacPorts binary for `nodejs26`, nor for any `mysql` port, on macOS 15 Intel; the source builds failed (V8 needs `source_location`; CMake picked the SDK's zlib 1.2.12) | MacPorts' build servers produce no archive for some ports on some platforms | Binary check before installing, with an older port that has one ([A binary for this Mac?](#a-binary-for-this-mac)); `node` moved to `nodejs24`, `mysql-client` kept in Homebrew |
| 29 | Removing a Homebrew Python broke 3 pipx tools (`bad interpreter`) | pipx environments link to the Python they were created with; `brew uses` doesn't know them | `--migrate` and `--prune` check programs outside Homebrew first; `--doctor` gives the `pipx reinstall` |
| 30 | `brew autoremove` removed nothing, while a dozen dependencies were left | Those formulae didn't have the `installed_as_dependency` flag | `--prune` ([decision 26](#26-prune-what-brew-autoremove-misses)) |
| 31 | `port uninstall leaves` would have removed 9 migrated tools (`go`, `autoconf`…) | Already installed as dependencies of other ports, never marked as requested | `--migrate` runs `port setrequested` for an active port; `--doctor` and `--status` flag the others |
| 32 | `brew cleanup` failed on every run | A root-owned `__pycache__` in `site-packages` | `--doctor` finds it and gives the command ([Troubleshooting](#something-broke-after-a-migration-or-brew-cleanup-fails-every-night)) |
| 33 | "210 commands installed twice", with a `--migrate` hint | All of them came from dependencies of formulae kept in Homebrew, which can't be migrated on their own | The side by side section lists only formulae nothing else needs; dependencies are one informational line ([Package strategy](#package-strategy-homebrew--macports)) |
| 34 | Every `ci/check` check failed | A docker CLI with no daemon (pulled in by MacPorts' `docker-compose-plugin`) was picked before a running podman | `ci/check` takes the first engine whose daemon answers |
| 35 | C++ ports failed to build in MacPorts | Stale Command Line Tools headers in `/Library/Developer/CommandLineTools/usr/include/c++` (MacPorts ProblemHotlist, "clts16") | `--doctor` reports them with the command to remove them |

End state: Homebrew down from about 250 formulae to `mysql-client` and its 8 dependencies, plus the casks; everything else comes from MacPorts.

---

## Known limitations and ideas

- **The auto-fixes have only been checked against real logs and the fakes.** Their detection matches the real logs of the [project history](#project-history-the-2026-10-15-incident), and the tests cover all four Homebrew fixes (download, unlink, stale library, Metal Toolchain) with fake `brew` and `xcodebuild`, but none of them has fired during a real praetorian session yet. In particular, the real `xcodebuild -downloadComponent MetalToolchain` (a download from Apple into Xcode) is never run by the tests: it was only checked by hand on 2026-10-15, like the real `brew` and `port` commands, which the tests never run either.
- **A library upgrade can break whatever depends on it.** Upgrading `ada-url` on its own broke the installed `node` until `node` rebuilt. Ideas: upgrade only the formulae you installed yourself and let brew handle their dependencies, or check dependents with `otool -L` after each upgrade (never with `brew linkage`, a developer command).
- **Display glitch:** a deferred cask first prints a red `✗ … (code 1)` line, then the "deferred" warning. The counters are right.
- **`latest` casks are reinstalled on every run** because of `--greedy`. `--greedy-auto-updates` would avoid that.
- **No time estimate.** Recording build durations per formula would make it possible to show an estimated total and offer a `--quick` mode that skips the long builds.
- **The scheduled job is only partly checked against the real `launchd`.** The tests check the plist with the real `plutil` on macOS and run the job's exact command line in an environment like `launchd`'s, but never load it in the real `launchd` (that would change the machine running the tests). On the development Mac (2026-10-16), the real `launchctl bootstrap` accepted a generated plist and `launchctl print` showed the expected program and arguments; the job was then booted out before it ever ran. No real night run yet: check `praetorian-schedule status` the morning after the first one.
- **The scheduled job doesn't wake the Mac.** `pmset repeat wakeorpoweron` needs root, so it's documented (see [Scheduling](#scheduling-overnight-runs)) rather than done by `praetorian-schedule`.
- **A job delayed by sleep runs when the Mac wakes up**, possibly while you're using it (at `Nice 10`). A "don't start if more than N hours late" rule would need praetorian to know the scheduled time; not done.
- **Notifications show up under Script Editor's name** (see [decision 21](#21-notify-when-nobody-is-watching)), and nothing happens when you click them.
- **Fewer formulae, faster runs.** On an Intel Mac, every formula you keep gets recompiled on each update. Pruning unused ones (`--prune`) and migrating the rest is the biggest time saver.
- **MacPorts maintenance is only partly checked against the real thing.** On the development Mac (MacPorts 2.12.7), `port version`, `port echo all`, `selfupdate`, `outdated`, a one-port `upgrade`, `uninstall inactive`, `installed`, `contents`, `install` and `setrequested` ran for real on 2026-10-17, during about 60 migrations (the session logs show them). Not seen for real yet in a praetorian session: an upgrade that fails (`Error: Failed to <phase> <port>`, `Error: See …/main.log`), `does not match expected platform`, and `port select --set` run by `--migrate` (no such step appears in that day's logs). Those are tested with the fake `port` only, based on MacPorts' documented behavior.
- **`--migrate` checks that the commands exist, not what they do.** A command counts when a file of that name is in `/opt/local/bin` or `sbin`; a port can provide the same commands with different defaults or variants, and praetorian doesn't run them to compare behavior.
- **The binary check assumes the default variants.** The archive name is built from the port's default variants, sorted alphabetically; variants you chose in `variants.conf` aren't modelled, so with those the check may say "no binary" (or "binary") for an archive MacPorts won't use.
- **The homepage comparison is a heuristic.** A renamed project, or a homepage that moved, gives a false "may be a different project": name the port yourself (`--migrate <formula>=<port>`) to turn the block into a warning. Ambiguous pairs give no verdict, so `--migrate-all` leaves them out.
- **`port select` may set several groups.** When more than one group still set to `none` lists a port just installed, `--migrate` sets each of them.
- **`--doctor` only checks pipx environments**, not other Python virtual environments (a project's `.venv`, conda) that may run on a Homebrew Python.
- **trivy only covers pypi and npm packages** in the SBOM, and may download its vulnerability database from an external registry on first use (written to `~/.cache/trivy`): `--sbom` is read-only for your packages, not offline.
- **SBOM license ids aren't validated against the SPDX list**: they are what brew, port and the package metadata say.
- **`--status` session durations assume a session shorter than 24 hours** (the log gives times of day; one day is added when the date changed).
- **Port name guesses are heuristic** (see the [rules](#migrating-one-formula-at-a-time)). Always check with `port info <port>` before `--migrate formula=port`.
- **`--migrate-all` only takes the safe cases** (same name, same homepage, nothing flagged). Known traps, other names and different homepages stay for you to name one by one; check your tools after a batch, since the checks are about files, not behavior.
- **The lock only knows about praetorian.** A `brew` or `port` you start by hand during a session isn't detected (both have their own internal locks).
- **`.lock` can falsely block** if the PID of a crashed session is reused by another process. The block message gives the command to remove the lock.
- **Cask repair can't bring back files outside the Caskroom.** See [auto-fixes](#4-auto-fixes-then-one-retry).
- **`PRAETORIAN_HOME` outside the repository isn't scanned by Gitleaks** (`ci/check secrets` only reads the clone).
- ShellCheck and the other tools run in containers (`ci/check`) rather than being installed on the Mac: on an Intel Mac, installing ShellCheck through Homebrew means compiling Haskell.

---

## References

- CIS Apple macOS Benchmark: [Ensure the Sudo Timeout Period Is Set to Zero (Sequoia)](https://www.tenable.com/audits/items/CIS_Apple_macOS_15.0_Sequoia_Cloud-tailored_v1.0.0_L1.audit:4997ef74d79a4d36687a02bea06e51fd)
- CIS Apple macOS Benchmark: [Ensure a Separate Timestamp Is Enabled for Each User/tty Combo](https://tenable.com/audits/items/CIS_Apple_macOS_10.15_Catalina_v3.0.0_L1.audit:5997489956c14f8a7f54672ec46aca5e)
- PCI DSS v4: [Requirement 8.6.2](https://myctrl.tools/frameworks/pci-dss-v4/8-6-2)
- Touch ID for sudo that survives updates: [Six Colors](https://sixcolors.com/post/2023/08/in-macos-sonoma-touch-id-for-sudo-can-survive-updates/)
- Homebrew support tiers: <https://docs.brew.sh/Support-Tiers>

## License

Copyright (C) 2026 victor-sys-admin.

praetorian is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (`SPDX-License-Identifier: GPL-3.0-or-later`). It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.
