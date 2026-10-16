# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately**, through GitHub's private
vulnerability reporting for this repository:
<https://github.com/victor-sys-admin/praetorian/security/advisories/new>
(Security tab → "Report a vulnerability").

Don't open a public issue or pull request for a security problem. Include
the praetorian version (`praetorian --help`), the macOS version, and the
steps or the environment needed to reproduce it. Session logs can contain
your paths and package list: share only the relevant lines.

This is a personal project maintained on a best-effort basis: there is no
guaranteed response time, but reports are read and fixes are credited in
[CHANGELOG.md](CHANGELOG.md) unless you'd rather stay anonymous.

## Supported versions

Only the latest release (see [CHANGELOG.md](CHANGELOG.md)) gets fixes.

## Scope

In scope:

- `praetorian` and `lib/*.sh`: anything that lets someone other than you
  run a command as you or as root through praetorian, write outside
  `PRAETORIAN_HOME`, or make praetorian load code it shouldn't.
- `praetorian-sudo-setup`: anything that writes outside
  `/etc/pam.d/sudo_local` (and its backups), or weakens sudo beyond adding
  `pam_tid`.
- `praetorian-schedule`: anything that writes outside
  `~/Library/LaunchAgents/io.github.victor-sys-admin.praetorian.plist`
  (and its temporary file) and `PRAETORIAN_HOME/logs`, or a job that runs
  something other than `praetorian`, or as someone else than you.
- `ci/` and `.github/workflows/`: a way to get secrets or write access from
  the CI.

Out of scope:

- Vulnerabilities in Homebrew, MacPorts, the packages they install, sudo,
  PAM or macOS itself: report them to those projects.
- Attacks that need write access to your clone, your shell startup files
  or your `PATH`, or the ability to run commands as you: at that point the
  attacker already controls every command you type.
- The `PRAETORIAN_*` test variables doing what they're documented to do
  in the tests.

## Threat model, in short

- **praetorian is code you own.** It runs with your rights and starts
  commands under sudo. Before loading `lib/`, it checks a fixed list of
  files: regular files (no symbolic link), owned by you or root, not
  writable by group or others. That protects against another local user or
  a careless `chmod`, not against you (or malware running as you) editing
  the code.
- **sudo and Touch ID.** praetorian never stores a password (no file,
  Keychain item or variable) and keeps no sudo credentials alive in the
  background. Each command that needs root asks for Touch ID or the
  password; unattended, those commands are deferred instead.
  `praetorian-sudo-setup` only adds `auth sufficient pam_tid.so` to
  `/etc/pam.d/sudo_local`, which keeps physical presence as the factor.
- **The scheduled job** (`praetorian-schedule`) is a per-user LaunchAgent:
  it runs as you, never as root, with no password. Before installing it,
  `praetorian-schedule` refuses a `praetorian` (or its directory) that
  another user could change, since `launchd` runs that path every night.
- **What runs as root.** Only MacPorts commands (at the absolute path
  `/opt/local/bin/port`, after checking that it and every directory above
  it belong to root and are writable by root only) and the installers
  Homebrew runs for some casks. Package names passed to `--migrate` are
  restricted to safe characters.
- **Nothing is stored beyond local state.** praetorian sends nothing
  anywhere (the end-of-session notification is a local macOS one). Its state (`PRAETORIAN_HOME`: logs, quarantine, lock) stays on
  the Mac; `logs/` is `700` because it holds the full brew and port output.

The README section
[Security: how sudo is handled](README.md#security-how-sudo-is-handled)
explains each choice and the alternatives that were rejected.
