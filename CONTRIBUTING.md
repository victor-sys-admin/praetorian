# Contributing

Thanks for helping. praetorian is small on purpose: bash, the tools macOS
ships, and nothing to install. Please keep it that way.

## Before you open a pull request

1. Run the checks. Everything goes through pinned containers, so the only
   requirement is Podman or Docker (`CONTAINER_ENGINE` picks one):

   ```sh
   ci/check                 # lint, format, secrets, workflows, tests
   ci/check lint tests      # a subset
   ci/check fix-format      # apply shfmt's formatting
   ```

   `ci/check` finds the files to check by glob (`praetorian`,
   `praetorian-sudo-setup`, `praetorian-schedule`, `lib/*.sh`, `ci/*`,
   `tests/*.bats`, `tests/stubs/*`): a new file there is checked without
   editing it. A new script at the top of the repository has to be added
   to that list in `ci/check`.

2. On a Mac, also run the tests under macOS's own `/bin/bash` 3.2 and BSD
   tools (fetches bats-core at a pinned commit into a temp directory,
   installs nothing):

   ```sh
   ci/macos-tests
   ```

3. Add or update tests in `tests/*.bats` for any behavior change. The
   fakes in `tests/stubs/` replace `brew`, `port`, `sudo` and friends:
   the tests never run the real ones. A new `.bats` file is picked up by
   both runners automatically.

4. Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
   When releasing, bump `PRAETORIAN_VERSION` in `praetorian` and the
   "Latest release" heading of the README together: a test checks that
   they match.

GitHub Actions runs `ci/check` and `ci/macos-tests` on every push and pull
request.

## Conventions

The full list is in the README, section
[Conventions](README.md#conventions). The essentials:

- bash 3.2 compatible: no associative arrays, no `mapfile`, no
  `declare -g`, no negative array indices.
- `set -euo pipefail`; a planned exit is `finish <code>`, never `exit`.
- A function whose failure must stop the session is never called on the
  left of `||` or `&&`, or in an `if`: bash turns `set -e` off inside it.
- `shfmt -i 4 -ci`, and ShellCheck at `--severity=style` with no finding
  (a `disable` only on the line that needs it, with the reason).
- Code, comments, documentation and terminal output in English.
- Every block explains why, what was *not* done, and how to unblock it
  (`block` in `lib/ui.sh`).

## Don't run Homebrew developer commands

Never run `brew cat`, `brew linkage` or any other command from Homebrew's
`dev-cmd/`, in praetorian or while investigating a problem: one such
command silently turns on developer mode, and the next `brew update`
moves Homebrew to its unreleased `main` branch (see decision 13 in the
README). Use `brew info`, `brew list`, `brew deps` instead.

Don't run the real `praetorian`, `brew`, `port` or `sudo` from the tests
either: use the fakes.

## Security issues

Not in a public issue or pull request: see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contribution is licensed under the
GPL-3.0-or-later, like the rest of the project (see [LICENSE](LICENSE)).
