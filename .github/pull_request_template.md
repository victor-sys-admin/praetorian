## What and why

<!-- What changes, and the real problem it solves (a log line, a failing case). -->

## Checks

- [ ] `ci/check` passes (lint, format, secrets, workflows, tests)
- [ ] `ci/macos-tests` passes (macOS, `/bin/bash` 3.2)
- [ ] Tests added or updated for the change; every `[[ … ]]` assertion ends with `|| false`
- [ ] README and the CHANGELOG's top entry updated when behaviour changes
- [ ] One commit per file, `ACTION --> path {description}` (see CONTRIBUTING.md)
- [ ] No log, state file, path or secret of your own machine in the diff
