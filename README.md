# praetorian

A Homebrew and MacPorts maintenance script for macOS that keeps going when things break.

One command runs `brew update`, upgrades formulae and casks, removes orphans, cleans caches, updates MacPorts and its ports, runs `brew doctor`, and lists apps you haven't opened in six months. When an upgrade fails, praetorian logs it, tries a known fix, quarantines what can't be fixed, and moves on to the next package. At the end it tells you exactly what's left to do. When it has to stop something, it says why, what was *not* done, and how to unblock it.

It also moves command-line tools from Homebrew to MacPorts, one formula at a time, with checks before and after (see [Package strategy](#package-strategy-homebrew--macports)).

It was built for, and hardened on, an **Intel MacBook Pro (2018) running macOS 15**. On that machine Homebrew no longer ships precompiled packages (bottles), so every upgrade compiles from source. Most of the design below comes from the failures that setup produced.

> Code, comments and terminal output are in English since version 1.2.0.

---

## Contents

- [Quick start](#quick-start)
- [Installation](#installation)
- [Requirements](#requirements)
- [Options](#options)
- [Package strategy: Homebrew → MacPorts](#package-strategy-homebrew--macports)
- [When praetorian blocks](#when-praetorian-blocks)
- [Troubleshooting](#troubleshooting)
- [What a session does](#what-a-session-does)
- [Files and state](#files-and-state)
- [Environment variables](#environment-variables)
- [Design decisions](#design-decisions)
- [Security: how sudo is handled](#security-how-sudo-is-handled)
- [Development](#development)
- [History: the 2026-10-15 incident](#history-the-2026-10-15-incident)
- [Known limitations and ideas](#known-limitations-and-ideas)
- [References](#references)
- [License](#license)

---

## Quick start

```sh
# One-time, optional but recommended: use Touch ID for sudo prompts
sudo ~/praetorian/praetorian-sudo-setup

# Normal run, from a terminal
~/praetorian/praetorian

# See what would happen, without changing anything
~/praetorian/praetorian --dry-run

# Run with nobody watching (overnight, launchd…)
~/praetorian/praetorian --unattended

# Homebrew → MacPorts: see the plan (read-only), then move one formula
~/praetorian/praetorian --migration-report
~/praetorian/praetorian --dry-run --migrate wget
~/praetorian/praetorian --migrate wget
```

The script expects to live in `~/praetorian/` (see `PRAETORIAN_HOME`).

## Installation

1. **Put the repository in `~/praetorian`.** The script stores its logs, quarantine and lock next to itself there (`PRAETORIAN_HOME` is fixed to `~/praetorian`):
   ```sh
   git clone <repository-url> ~/praetorian
   chmod +x ~/praetorian/praetorian ~/praetorian/praetorian-sudo-setup
   ```
   `lib/` must stay next to `praetorian`: the script loads its code from there. A symbolic link to `praetorian` (for example `~/.local/bin/praetorian`) works, because the real location is resolved. The files in `lib/` must belong to you and not be writable by group or others, or praetorian refuses to start (see [Code layout](#code-layout)).
2. **Make sure Xcode is ready** (see [Compiler toolchain](#compiler-toolchain)). praetorian refuses to start while Xcode is installed but not initialized.
3. **Optional: Touch ID for sudo**: `sudo ~/praetorian/praetorian-sudo-setup`.
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
| Homebrew (`brew`) | `PATH`, then `/usr/local/bin/brew`, then `/opt/homebrew/bin/brew` | formulae, casks, `--migration-report`, `--migrate` |
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
| `find`, `ls`, `cat`, `mkdir`, `rm`, `mv`, `basename`, `dirname`, `readlink`, `mktemp` | Logs, temp files, lock, Caskroom repair, spotting commands installed twice, finding `lib/` through symbolic links |
| `id` | Owner check of the `lib/` files before they're loaded |
| `tar` | Archiving Homebrew and MacPorts build logs before cleanup |
| `df` | Free disk space check |
| `date`, `sleep`, `uname`, `sw_vers` | Timestamps, progress line, Intel detection, macOS version in the log |
| `pgrep`, `kill` | Stopping the whole process tree on Ctrl-C; checking the PID in the lock |
| `caffeinate` | Keeping the Mac awake during a session |
| `xcode-select`, `xcodebuild` | Xcode readiness check; Metal Toolchain download |
| `git` | Detecting Homebrew's development branch (`git -C $(brew --repository) branch`). Comes with Xcode or the Command Line Tools |
| `sudo` | MacPorts commands and cask installers. Never cached or stored (see [Security](#security-how-sudo-is-handled)) |
| `mdls` (Spotlight) | Last-used date of apps in `/Applications` |
| `osascript` | End-of-session notification in unattended mode |

The disk needs at least 5 GB free (20 GB recommended); below that, praetorian stops before doing anything. praetorian refuses to run as root: Homebrew refuses it too, and praetorian asks for sudo itself, one command at a time.

### Optional: Touch ID for sudo

`praetorian-sudo-setup` (run once with sudo) uses `bioutil` to check that a fingerprint is enrolled, and `cp`, `sed`, `chmod` and `chown` to write `/etc/pam.d/sudo_local`. It needs a Mac with Touch ID; without one, sudo simply asks for the password.

### For development only: checks and tests

`ci/check` runs every check in throwaway containers pinned by digest, so the only local requirement is **Podman or Docker** (`CONTAINER_ENGINE` picks one). Nothing below is installed on the Mac:

| Container | Check |
|---|---|
| ShellCheck 0.11.0 | Lint (blocking) |
| shfmt 3.14.1 | Formatting (blocking; `ci/check fix-format` fixes it). Scripts, tests and fakes |
| Gitleaks 8.30.1 | Secrets (blocking) |
| actionlint 1.7.12, zizmor 1.31.0 | GitHub workflows (blocking) |
| bats 1.14.0 | Tests, with the fakes from `tests/stubs/` (blocking) |

The same tests also run **on macOS under `/bin/bash` 3.2** with `ci/macos-tests`: it fetches bats-core 1.14.0 by commit into a temp directory (needs `git`, nothing is installed), puts `/bin` first in the `PATH` and uses the macOS tools. GitHub Actions runs `ci/check` (Linux) and `ci/macos-tests` (`macos-latest`) on every push.

## Options

| Option | Effect |
|---|---|
| `--dry-run` | Shows the planned steps. Changes no package and no praetorian state (`quarantine.tsv`, `.toolchain`, `migrated.tsv`): quarantine entries a real run would lift are only counted. It still writes its own session log and takes the session lock. Skips `caffeinate` and the Xcode check. |
| `--no-greedy` | Upgrades casks without `--greedy`, so apps that update themselves are left alone. |
| `--retry-quarantined` | Ignores the quarantine for this run and retries everything. |
| `--unattended` | Never waits for input. Whatever needs sudo (casks with an installer, the whole MacPorts part) is deferred, not failed, and a macOS notification summarizes the run. This mode turns on automatically when stdin is not a terminal. |
| `--quiet` | Minimal terminal output. Everything still goes to the log. Blocks are always shown. |
| `--migration-report` | Read-only plan: for each formula you installed yourself, the matching MacPorts port and anything that would block its migration. Changes nothing. |
| `--migrate <formula>[=<port>]`<br>`--migrate=<formula>[=<port>]` | Moves **one** formula to MacPorts: checks, installs the port, checks again, and only then uninstalls the formula. Example: `--migrate python@3.12=python312`. Without `=<port>`, the port has the formula's name (without its tap: `hashicorp/tap/terraform` → `terraform`). Combine with `--dry-run` to run only the checks. Names are restricted to letters, digits and `@._+-` (plus `/` for a tap formula), because they end up in commands run under sudo. |
| `--help`, `-h` | Usage. |

**Exit codes:** `0` = success, `1` = prerequisite problem (no package manager, run as root, Xcode not ready, disk almost full, another session running) or migration report blocked, `2` = at least one step failed or was blocked, `130` = interrupted.

## Package strategy: Homebrew → MacPorts

Homebrew dropped Intel Macs (tier 3, no bottles): every formula compiles from source, some never build. MacPorts still ships precompiled packages for this Mac's macOS version. The target state:

| What | Where | Why |
|---|---|---|
| Command-line tools and libraries | **MacPorts** | Precompiled for this Mac; supports old macOS versions for years |
| Apps (casks) | **Homebrew** | MacPorts doesn't manage apps. A cask downloads the vendor's app and compiles nothing, so tier 3 doesn't affect it |
| Anything with no MacPorts port | Homebrew, until a replacement is found | |

During the transition both run side by side (`/opt/local` and `/usr/local` don't overlap). praetorian maintains both, and its *Homebrew / MacPorts side by side* section lists commands installed twice (with the formula they come from and the copy that actually runs) and warns when Homebrew comes before MacPorts in the `PATH` (the Homebrew copy would run).

### Migrating, one formula at a time

1. `praetorian --migration-report` sorts the formulae you installed yourself (`brew leaves`) into three groups: same name in MacPorts, probable other name, and not found. It flags what would block a migration: a running `brew services` service, or shell startup files pointing into the formula's Homebrew paths. Dependencies aren't listed: `brew autoremove` removes them once nothing uses them.

   The "probable other name" guesses, most likely first:

   | Rule | Example (from the real MacPorts index) |
   |---|---|
   | `name@X.Y` → `nameXY`. When it exists, it's the only suggestion | `python@3.11` → `python311`, `postgresql@15` → `postgresql15`, `openjdk@17` → `openjdk17` |
   | Tap formula without its tap | `hashicorp/tap/terraform` → `terraform` |
   | Same name, other case | `imagemagick` → `ImageMagick` |
   | Known alias | `make` → `gmake`, `ant` → `apache-ant`, `sphinx-doc` → `py-sphinx`, `node` → `nodejs…`, `mysql-client` → `mysql…` |
   | Versioned ports `name<digits>`, up to 6 (`…` and a count when there are more) | `node` → `nodejs20, nodejs22, nodejs24, nodejs26`, `gnupg` → `gnupg1, gnupg2` |
   | Only if nothing else matched: the Python module `py-<name>` | `numpy` → `py-numpy`, `python-setuptools` → `py-setuptools` |

   Versioned ports are sorted by their number, which doesn't always follow release order (`postgresql93` is 9.3, `mysql8` sorts before `mysql51`). Always check with `port info <port>`.
2. `praetorian --migrate <formula>[=<port>]` runs these steps and **stops at the first problem, leaving the Homebrew formula in place**:

| # | Check or action | Stops if |
|---|---|---|
| 1 | `brew list --formula` | the formula isn't installed |
| 2 | `brew uses --installed` | another formula depends on it |
| 3 | `homebrew.mxcl.<formula>.plist` | it runs as a Homebrew service |
| 4 | `~/.zshrc`, `~/.zprofile`, `~/.bash_profile`… | a line uses `<prefix>/opt/<formula>` or `Cellar/<formula>/` (it would point to nothing). Commented lines are ignored |
| 5 | `port info --name <port>` | the port doesn't exist |
| 6 | `sudo port -N install <port>` | the install fails or sudo is refused |
| 7 | `port installed` + `port contents` | the port isn't active, or doesn't provide **every** command the formula had in `bin/` and `sbin/` |
| 8 | `brew uninstall --formula` | (only now) |

A successful migration is recorded in `migrated.tsv`. The order is deliberate: at every point before step 8, the Homebrew version is untouched and still works. If step 7 fails, both are installed, which is harmless.

3. Start with the formulae that hurt the most (long builds, quarantined), check your tools after each migration, and stop when only casks are left: Homebrew then has nothing to compile. Small, standalone tools (`wget`, `jq`, `tree`…) make good first migrations; formulae referenced in your shell files (here `mysql-client`, `openjdk`, `libpcap`) come later, once those lines are updated.

### Undoing a migration

praetorian doesn't have an undo command, because each part is a single standard command:

```sh
brew install <formula>             # get the Homebrew version back
sudo port uninstall <port>         # optional: remove the MacPorts version
hash -r                            # forget the old command locations in this shell
```

Then delete the formula's line from `~/praetorian/migrated.tsv` (it's only a record; nothing reads it back).

praetorian never installs MacPorts itself (it's a system package): download it for your macOS version from <https://www.macports.org/install.php>.

### How MacPorts is maintained

- **Absolute path everywhere**, sudo included: `/opt/local/bin/port`, never a `port` found in the `PATH`.
- **Read-only commands without sudo** (`version`, `outdated`, `installed`, `contents`, `echo`, `info`). Commands that change something run under sudo, **one sudo call per step and only when there's work**: `selfupdate`, then `upgrade` if something is outdated, then `uninstall inactive` if old versions are left. With CIS `timestamp_timeout=0`, that's at most three Touch ID prompts.
- **One `port -p upgrade <list>`** rather than one call per port: `-p` keeps going after a failed port, so one broken port doesn't block the others, without a sudo prompt per port.
- **The result is checked, not trusted**: a second `port outdated` runs after the upgrade. Whatever is still outdated failed, whatever the exit code said, and is quarantined (type `port`) with the failing phase (`build`, `configure`…) or the failing dependency. The `main.log` files MacPorts points to are archived in `logs/praetorian_<timestamp>_portlogs.tar.gz`.
- **No upgrade after a failed `selfupdate`**: the ports tree might be half-synced.
- **Unused dependencies are reported, not removed** (`port echo leaves`): they may be needed again to build something.
- **Unattended**: MacPorts needs root for every change and no password is stored, so the whole MacPorts part is deferred, with the number of outdated ports from the local index. A narrow `NOPASSWD` sudoers rule would allow overnight runs, but [was rejected](#security-how-sudo-is-handled) for the same reason as for casks.
- **macOS upgraded without reinstalling MacPorts**: MacPorts reports `Current platform "darwin 25" does not match expected platform "darwin 24"`. praetorian blocks every MacPorts command and prints the [official migration steps](https://trac.macports.org/wiki/Migration). This will happen if this Mac moves to macOS 26.

## When praetorian blocks

praetorian never stops silently. Every block prints the same five parts, even with `--quiet` (on stderr), writes them to the log, and is listed again in the summary:

```
✗ BLOCKED: port selfupdate failed
    Why        : Error: Failed to sync the ports tree …
    Impact     : No port was upgraded: praetorian doesn't upgrade from a ports tree that may be half-synced.
    What to do :
        Check the network, then run praetorian again.
        Details: sudo /opt/local/bin/port -d selfupdate
    Log        : ~/praetorian/logs/praetorian_<timestamp>.log
```

*Impact* always says what was **not** done, so you know the state you're in. A block in one part (say MacPorts) doesn't stop the other parts; a block on a prerequisite stops the session before anything runs.

| Block | Scope | Fail-safe reason |
|---|---|---|
| Run as root | whole session (exit 1) | Homebrew refuses root; praetorian requests sudo itself |
| No Homebrew and no MacPorts | whole session (exit 1) | nothing to maintain |
| Xcode installed but not ready | whole session (exit 1) | builds fail or hang forever |
| Less than 5 GB free | whole session (exit 1) | a full disk mid-install leaves half-installed packages |
| Another praetorian session running | whole session (exit 1) | two brew/port runs on the same packages corrupt them. A lock left by a crashed session (dead PID) is taken over with a warning |
| MacPorts not responding / installed for another macOS | MacPorts part | ports may be broken until reinstalled |
| `port selfupdate` failed | MacPorts upgrade | half-synced ports tree |
| Each `--migrate` check | that migration | the Homebrew formula stays in place |
| `lib/` file missing, a symbolic link, owned by someone else, or writable by group/others | whole session (exit 1), before anything runs | that code runs with your rights and starts commands under sudo |
| Unexpected internal error | whole session | stops instead of continuing in an unknown state; the block names the function, the file and the failing command |

Deferrals (sudo impossible) are **not** failures: the summary and the notification list them, with "nothing was changed".

## Troubleshooting

### `port: command not found` after installing MacPorts

The MacPorts installer adds `export PATH="/opt/local/bin:/opt/local/sbin:$PATH"` to `~/.zprofile`. Check, in this order:

1. **Old terminal.** Terminals opened before the install keep the old `PATH`: open a new one.
2. **A later line overwrites the `PATH`.** `~/.zshrc` runs *after* `~/.zprofile`. A line like `export PATH="/usr/local/bin:/usr/bin:…"` with no `$PATH` in it throws away what `.zprofile` added. Find it with:
   ```sh
   grep -n 'PATH=' ~/.zprofile ~/.zshrc
   zsh -lic 'echo $PATH' | tr ':' '\n' | head -3   # what a new terminal gets
   ```
   Fix it by adding `/opt/local/bin:/opt/local/sbin:` at the start of that line (this is what happened on 2026-10-15, see [history](#macports-install-same-day)), or better, by making it extend `$PATH` instead of replacing it.
3. **Only `sudo port` fails.** If `port` works but `sudo port` doesn't, sudo is using its own `secure_path`. Use the full path: `sudo /opt/local/bin/port …`. praetorian always does.

praetorian itself doesn't depend on your `PATH` for MacPorts (it calls `/opt/local/bin/port`), but it warns when `/opt/local/bin` is missing from it, because the commands you install would be invisible in the terminal.

### "MacPorts deferred" every night

Expected when running unattended: MacPorts needs root for every change and praetorian stores no password. Run `~/praetorian/praetorian` from a terminal now and then; the overnight run still handles Homebrew.

### A package keeps being skipped

It's quarantined. `cat ~/praetorian/quarantine.tsv` shows why and since when. The summary prints how to unblock each cause; `--retry-quarantined` retries everything once, and deleting a line retries that package for good.

### "another praetorian session is already running"

Check the PID it gives (`ps -p <pid> -o command=`). If it isn't praetorian (a PID reused after a crash), `rm -rf ~/praetorian/.lock`.

### "praetorian's code in lib/ can't be trusted"

praetorian found a `lib/` file it won't load, and names it with the reason. First check that nobody changed the code (`git -C ~/praetorian status` and `git diff`). Then:

- **writable by group or others**: often a copy made with a permissive umask, or an editor that changed the mode. `chmod go-w ~/praetorian/lib ~/praetorian/lib/*.sh`.
- **missing**: `git -C ~/praetorian checkout -- lib/`.
- **a symbolic link**: replace it with the real file from the repository.
- **another owner**: after checking the content, `chown $(id -un) ~/praetorian/lib ~/praetorian/lib/*.sh`.

### Touch ID doesn't show up for sudo

Touch ID doesn't reach sudo inside `tmux`, `screen` or over SSH: sudo asks for the password instead. Run praetorian from a plain terminal window.

### Where is the full output?

`~/praetorian/logs/praetorian_<timestamp>.log`, written live: `tail -f` it during a long build. Build logs of failed packages are in the `_buildlogs.tar.gz` (Homebrew) and `_portlogs.tar.gz` (MacPorts) archives next to it.

## What a session does

```
parse args ─► re-exec under caffeinate ─► prerequisites ─► Xcode ready? ─► disk space ─► lock ─► prune quarantine
   │
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
Maintenance MacPorts (skipped if MacPorts is absent; deferred when unattended)
   1. port version   (health, macOS mismatch)
   2. sudo port selfupdate
   3. port outdated (minus quarantine) → sudo port -p upgrade <list> → port outdated again
   4. sudo port uninstall inactive   (only if any)
   5. report port echo leaves
   │
   ▼
Side by side (both present) ─► Diagnostics (brew doctor) ─► Unused apps (> 6 months) ─► Log rotation ─► Summary (+ notification)
```

The summary lists failed steps, blocks, the Homebrew and MacPorts errors pulled from the output, anything newly quarantined, deferred items, and concrete commands to unblock each quarantined package.

## Files and state

| Path | Content | Tracked in git |
|---|---|---|
| `praetorian` | Entry point: constants, options, code loading, `main` | yes |
| `lib/*.sh` | The code, by topic (see [Code layout](#code-layout)) | yes |
| `praetorian-sudo-setup` | One-time Touch ID setup for sudo | yes |
| `logs/praetorian_<timestamp>.log` | Full session log, including the complete brew output (last 30 kept). `logs/` is made private (`700`): it lists your paths and packages | no |
| `logs/praetorian_<timestamp>_buildlogs.tar.gz` | Homebrew build logs produced during the session (last 30 kept) | no |
| `logs/praetorian_<timestamp>_portlogs.tar.gz` | MacPorts `main.log` files of failed ports (last 30 kept) | no |
| `quarantine.tsv` | Packages skipped on purpose, one per line | no |
| `migrated.tsv` | Formulae moved to MacPorts: `formula  port  epoch` | no |
| `.toolchain` | `xcode` or `clt`: the compiler toolchain seen on the previous run | no |
| `.lock/` | Present while a session runs (holds its PID) | no |

`quarantine.tsv` is tab-separated:

```
name    type(formula|cask|port)    epoch    cause(xcode|pkg|build)    detail
```

You can edit or empty it by hand at any time.

## Environment variables

| Variable | Effect |
|---|---|
| `HOMEBREW_DEVELOPER` | When set, praetorian leaves Homebrew on its development branch instead of switching back to stable ([decision 13](#13-stay-on-homebrews-stable-channel)). |
| `CONTAINER_ENGINE` | `ci/check` only: `docker` or `podman`, when both are installed. |
| `PRAETORIAN_PORT_PREFIX` | **Tests only.** MacPorts prefix (default `/opt/local`), so the tests can install a fake `port`. It can't be abused to run something as root: before the system's `sudo` (`/usr/bin/sudo`) runs `port`, praetorian checks that the binary, its directory and the prefix belong to root and are writable by root only, and blocks otherwise. |
| `PRAETORIAN_SUDO_LOCAL` | **Tests only.** File written by `praetorian-sudo-setup` instead of `/etc/pam.d/sudo_local`. Harmless: that script runs as root anyway. |
| `PRAETORIAN_MIN_FREE_GB` | **Tests only.** Minimum free space in GB (default 5), to test the disk-full block. |
| `PRAETORIAN_CAFFEINATED` | Internal: set when praetorian re-runs itself under `caffeinate`, so it doesn't loop. |

---

## Design decisions

Each choice below came from a real failure. The date and details are in the [history](#history-the-2026-10-15-incident).

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
| Cask: `It seems the … source … is not there` / `there is already a …` | `brew uninstall --cask --force` then `brew install --cask` | `font-ubuntu` left half-installed by an interrupted upgrade |

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

If Xcode.app is installed but not selected, its license isn't accepted, or its first launch isn't done, praetorian exits with code 1 and prints the three commands to run.

*Why:* right after Xcode was installed, a `cmake` sat at 0% CPU for many minutes while its first launch was still pending.

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

The 30 most recent session logs, the 30 most recent Homebrew build-log archives and the 30 most recent MacPorts log archives are kept, each counted separately.

### 19. Code split by topic, checked before it's loaded

The code moved from one 2,000-line file to `lib/` (see [Code layout](#code-layout)). Before loading anything, praetorian checks every file of a **fixed list** and the `lib/` directory: regular file, no symbolic link, owned by you or root, not writable by group or others. Any problem stops it with exit code 1, before any command runs.

*Why:* those files run with your rights and start commands under sudo. A file someone else could change, or a link pointing elsewhere, would be a way in. The list is fixed so that a file dropped into `lib/` is never loaded.

### 20. Every unplanned exit is explained

Planned exits go through `finish`. Any other non-zero exit (a command that failed where `set -e` stops the script) is caught by the `EXIT` trap and turned into a block naming the function, the file and the command, for example `in migrate (migrate.sh), command: prefix=$(brew --prefix)`. Cleanup (temp files, lock, relinking) runs either way.

*Why:* until 1.2.0, an `ERR` trap was meant to do this, but bash doesn't run it inside functions (where almost all the code is) unless `errtrace` is on. An unexpected failure ended the session silently. Turning `errtrace` on wasn't an option: it would also fire inside command substitutions that are allowed to fail.

---

## Security: how sudo is handled

Some casks run `.pkg` installers through `sudo`, and MacPorts needs `sudo` for every command that changes something. How praetorian handles that follows the **CIS Apple macOS Benchmark** and **PCI DSS v4.0.1**.

### What the rules say

| Rule | Requirement | On this Mac |
|---|---|---|
| CIS: *Ensure the Sudo Timeout Period Is Set to Zero* | `Defaults timestamp_timeout=0`: sudo never caches credentials | Already applied (`/etc/sudoers.d/10_cissudoconfiguration`) |
| CIS: *Ensure a Separate Timestamp Is Enabled for Each User/tty Combo* | `timestamp_type=tty`, so a background process can't reuse a terminal's elevation | Default since sudo 1.8 / macOS 10.12; sudo here is 1.9.13 |
| PCI DSS 8.6.2 | No passwords for interactive accounts hard-coded in scripts or configuration files | No password stored anywhere |

### What praetorian does

1. **It never stores the password**: no file, no Keychain item, no environment variable.
   *Alternative rejected: the Keychain plus `SUDO_ASKPASS`.* To run unattended, the Keychain item would have to be readable by `/usr/bin/security` without a prompt, and any process running as the user can call `security`. Malware would then get the login password itself, which also unlocks FileVault and the Keychain, on top of root.
   *Alternative rejected: a passwordless sudoers rule.* No secret is stored, but the allowed commands would have to be broad (`installer -pkg <anything>` alone already means running arbitrary code as root), so any process running as the user could become root.
2. **No sudo keepalive.** An earlier version ran `sudo -v` once, then refreshed it in a background loop for the whole session. It was removed: with `timestamp_timeout=0` it had no effect, and keeping elevated credentials alive from a background process is exactly what the CIS controls are meant to prevent.
3. **Touch ID instead of typing the password.** `praetorian-sudo-setup` adds `auth sufficient pam_tid.so` to `/etc/pam.d/sudo_local`, the file Apple provides (since Sonoma) to survive system updates; `/etc/pam.d/sudo` itself is overwritten by updates. No secret is stored, you must be physically present, and it works alongside `timestamp_timeout=0`: each sudo call is one touch. The password stays available as a fallback.
   - Idempotent. It backs up an existing file (`sudo_local.bak.<timestamp>.<pid>`), uncomments the line if it was copied from Apple's template, sets `root:wheel 444` on the file, and refuses to run if no fingerprint is enrolled. The fingerprint check (`bioutil -c`) runs as the user who called sudo: `bioutil` reads the *current* user's configuration, which under sudo would be root's.
   - Undo with `sudo ./praetorian-sudo-setup --disable`.
   - Touch ID doesn't reach sudo inside `tmux` or over SSH; the password prompt shows up instead.
4. **Unattended mode never blocks.** praetorian exports `SUDO_ASKPASS=/usr/bin/false`. Homebrew then calls `sudo -A` (see `system_command.rb`), which fails right away with `a password is required`. praetorian spots that message and marks the cask as **deferred**: not a failure and not quarantined. It's named in the summary and in the macOS notification, so you can run it from a terminal later. For MacPorts, praetorian checks `sudo -n true` first; when that fails, the whole MacPorts part is deferred before any command runs, and its commands use `sudo -n` so they could never wait anyway.
5. **sudo only runs absolute paths it chose, and checks them.** MacPorts is always `/opt/local/bin/port`, never a `port` found in the `PATH`, and the names given to `--migrate` are restricted to safe characters before they reach a sudo command line. Before the system's sudo runs `port`, the binary, `/opt/local/bin` and `/opt/local` must belong to root and be writable by root only. `sudo` itself is found through the `PATH` (`/usr/bin/sudo` on a normal setup): whoever controls your `PATH` controls your shell anyway.

### What was tested

- `praetorian-sudo-setup`, by the bats tests on a test file (`PRAETORIAN_SUDO_LOCAL`) with fake `id`, `bioutil` and `chown`: not root, no fingerprint, missing file, Apple's commented template, other content kept, re-run (no change, no backup), `--disable` then re-enable. It hasn't yet been run for real on `/etc/pam.d/sudo_local`, because that needs root.
- Deferral, with a fake `brew` calling the real `sudo -A`: the cask was deferred in about 2 seconds, with nothing quarantined and no failure counted. A genuine `.pkg` failure with no sudo problem was still quarantined.
- A real `--unattended --retry-quarantined` session: about 38 seconds, 0 failures. No cask needed sudo that day, so deferral has only been checked with the fake `brew`.

---

## Development

### Code layout

| File | Content |
|---|---|
| `praetorian` | Header, constants, options and global state; `lib/` safety check and loading; `usage`, argument parsing, `main` |
| `lib/ui.sh` | Colors, session log, `say`/`info`/`ok`/`warn`/`err`/`loud`, `block` |
| `lib/session.sh` | `finish`, Ctrl-C, `EXIT` handling; `run_step`; output analysis; step counters; Xcode check; sudo policy; prerequisites (managers, disk, lock); platform notes; log rotation |
| `lib/quarantine.sh` | `quarantine.tsv`: add, prune, list, show |
| `lib/brew.sh` | Homebrew maintenance, auto-fixes, casks, build log archives |
| `lib/macports.sh` | MacPorts maintenance, result check, MacPorts log archives, commands installed twice |
| `lib/migrate.sh` | `--migration-report`, `--migrate`, port name guesses |
| `lib/report.sh` | `brew doctor`, unused apps, unblocking hints, summary, notification |
| `ci/check` | Lint, format, secrets, workflows and tests (Linux containers) |
| `ci/macos-tests` | The same tests on macOS under `/bin/bash` 3.2 |

The files are loaded in that order, at the top level of `praetorian` (not inside a function: `declare` in a function would make the globals local). They only define functions and globals; nothing runs until `main`. To add a file: create it with `# shellcheck shell=bash` as its first line, add it to `PRAETORIAN_LIBS` **and** to the `source` lines (same order), and to `SCRIPTS` in `ci/check`.

### Checks

All checks run through `ci/check`, locally and in GitHub Actions, with the same pinned containers (see [Requirements](#for-development-only-checks-and-tests)):

```sh
ci/check                 # everything
ci/check lint tests      # ShellCheck + bats only
ci/check fix-format      # apply shfmt's formatting, when the Formatting check fails
```

The bats tests (`tests/praetorian.bats`) run praetorian for real on Linux (`ci/check`) and macOS (`ci/macos-tests`), with fakes in `tests/stubs/` in front of the `PATH`:

| Fake | Records calls in | Driven by |
|---|---|---|
| `brew` | `$BREW_CALLS` | `BREW_OUTDATED_*` (and `_FORMULA_AFTER`), `BREW_UPGRADE_*` (and `*2` for the retry), `BREW_CASK_*`, `BREW_FETCH_RC`, `BREW_REINSTALL_RC`, `BREW_LIST_FILES`, `BREW_USES`, `BREW_LEAVES`, `BREW_PREFIX[_RC]`, `BREW_REPOSITORY`, `BREW_CASKROOM` |
| `port` | `$PORT_CALLS` | `PORT_VERSION_*`, `PORT_SELFUPDATE_RC`, `PORT_OUTDATED[_AFTER]`, `PORT_UPGRADE_*`, `PORT_INSTALL_RC`, `PORT_AVAILABLE`, `PORT_CONTENTS`, `PORT_INACTIVE`, `PORT_LEAVES` |
| `sudo` | `$SUDO_CALLS` | `SUDO_DENY=1` simulates an authentication that can't happen |
| `osascript` | `$OSASCRIPT_CALLS` | — (no notification pops up during the tests) |
| `xcodebuild`, `xcode-select` | `$XCODEBUILD_CALLS` (xcodebuild) | `XCODEBUILD_LICENSE_RC`, `XCODEBUILD_FIRSTLAUNCH_RC`, `XCODEBUILD_DOWNLOAD_RC`, `XCODE_SELECT_PATH`: nothing is downloaded, and the tests don't depend on how Xcode is set up on the machine |
| `id`, `bioutil`, `chown` | `$CHOWN_CALLS` (chown) | `FAKE_UID`, `BIOUTIL_TEMPLATES`: `praetorian-sudo-setup` as a fake root |
| `mktemp` | — | gives Linux the macOS `mktemp -t prefix` behavior (passes through on macOS) |

The fake `port` is only installed (in `$PRAETORIAN_PORT_PREFIX/bin`) by tests that call `with_macports`, so the other tests run without MacPorts. Each variable is documented at the top of its fake. A test typically sets a few variables, runs praetorian, and checks both the output and the recorded calls: that a command ran, or, for fail-safe behavior, that it did **not**.

**Unit tests** call a single function. Sourcing `praetorian` loads every function without running `main`, so `in_praetorian 'port_candidates node "$all"'` runs one call in a separate bash. The `lib/` safety check is tested on a scratch copy (`scratch_copy`), which the test damages (permissions, missing file, symbolic link).

The tests run in the container as **your** user (`--user $(id -u):$(id -g)`), not as root: praetorian refuses root, and only loads `lib/` files owned by the user running it.

### Conventions

- bash 3.2 compatible (macOS's `/bin/bash`): no associative arrays, no `mapfile`, no `declare -g`, no negative array indices.
- `set -euo pipefail`. A planned exit is `finish <code>`, never `exit`, or it's reported as unexpected. (The only `exit` left is in the `lib/` check, which runs before anything is loaded.)
- No apostrophe inside `"${var:-default}"`: bash 3.2 and 5 parse it as an opening quote.
- A function whose failure must stop the session isn't called on the left of `||` or `&&`: `set -e` is off inside it there. `migrate` returns 0 and reports its outcome through `BLOCKERS` for that reason.
- Counters are incremented with `x=$((x + 1))`, not `x+=1` (which appends text unless the variable was declared `-i`, and ShellCheck can't see that across files).
- ShellCheck checks every file on its own too. A global set in one file and used in another needs a one-line `# shellcheck disable=SC2034` (or `SC2153`) with the reason, on that line only.

---

## History: the 2026-10-15 incident

The day that shaped version 1.1.0.

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

---

## Known limitations and ideas

- **The auto-fixes have only been checked against real logs and the fakes.** Their detection matches the actual 2026-10-15 logs, and the tests cover all four Homebrew fixes (download, unlink, stale library, Metal Toolchain) with fake `brew` and `xcodebuild`, but none of them has fired during a real praetorian session yet. In particular, the real `xcodebuild -downloadComponent MetalToolchain` (a download from Apple into Xcode) is never run by the tests: it was only checked by hand on 2026-10-15, like the real `brew` and `port` commands, which the tests never run either.
- **A library upgrade can break whatever depends on it.** Upgrading `ada-url` on its own broke the installed `node` until `node` rebuilt. Ideas: upgrade only the formulae you installed yourself and let brew handle their dependencies, or check dependents with `otool -L` after each upgrade (never with `brew linkage`, a developer command).
- **Display glitch:** a deferred cask first prints a red `✗ … (code 1)` line, then the "deferred" warning. The counters are right.
- **`latest` casks are reinstalled on every run** because of `--greedy`. `--greedy-auto-updates` would avoid that.
- **No time estimate.** Recording build durations per formula would make it possible to show an estimated total and offer a `--quick` mode that skips the long builds.
- **No scheduler yet.** A `launchd` agent running `--unattended` overnight would make the long builds painless; the mode and the notification are ready for it.
- **Fewer formulae, faster runs.** On an Intel Mac, every formula you keep gets recompiled on each update. Pruning unused ones is the biggest time saver.
- **MacPorts maintenance is only partly checked against the real thing.** MacPorts 2.12.7 is installed on the target Mac, and `port version` and `port echo all` (used by `--migration-report`) have run for real. The rest (`port outdated` lines with `<`, `Error: Failed to <phase> <port>`, `Error: See …/main.log`, `does not match expected platform`, `port contents`) is tested with the fake `port` only, based on MacPorts' documented behavior. Watch the first real maintenance session and the first `--migrate`, and adjust the patterns if needed.
- **`--migrate` compares command names only.** A port can provide the same commands with different defaults or variants; praetorian doesn't run them to compare behavior.
- **Port name guesses are heuristic** (see the [rules](#migrating-one-formula-at-a-time)). Always check with `port info <port>` before `--migrate formula=port`.
- **No `--migrate` for several formulae at once**, on purpose: each migration should be checked before the next. A shell loop works if you really want one.
- **The lock only knows about praetorian.** A `brew` or `port` you start by hand during a session isn't detected (both have their own internal locks).
- **`.lock` can falsely block** if the PID of a crashed session is reused by another process. The block message gives the command to remove the lock.
- `shellcheck` runs in CI (`ci/check`) rather than locally: installing it through Homebrew means compiling Haskell.

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
