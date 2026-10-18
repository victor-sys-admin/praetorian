# Recording the demo

A short terminal recording (30 to 60 seconds) for the README and for posts.
Every command below is read-only: nothing is installed, removed or locked.

## Before recording

- The recording shows your package names, paths and hostname. Use a
  terminal profile with a neutral prompt (`PS1='$ '`), and check what each
  command prints on your Mac before recording it.
- Use a window of about 100 × 30 characters, a large font, and a dark or
  light theme with good contrast.
- Run each command once beforehand: the first `--migration-report` and
  `--status` read the MacPorts index and are slower.

## Scenario

```sh
clear
praetorian --status                 # what is migrated, what is left and why, the last sessions
praetorian --doctor                 # what is broken around Homebrew and MacPorts, with the fix
praetorian --migration-report       # on a Mac with formulae left: the plan, the traps, the binaries
praetorian --dry-run --migrate-all  # what a batch migration would do, without changing anything
```

On a Mac that still has formulae to migrate, `--migration-report` and
`--dry-run --migrate-all` are the most telling. On one that is already
migrated, `--status` and `--doctor` are.

## Tools

Any of these works; none is needed by praetorian itself.

- **asciinema** (`pipx install asciinema`): `asciinema rec demo.cast`, then
  upload it to asciinema.org or convert it to a GIF with `agg`.
- **macOS screen recording** (Shift-Command-5), then convert the video to a
  GIF with a tool such as `gifski` or `ffmpeg`.

Keep the GIF under about 5 MB so it loads quickly on GitHub and Reddit.
Put it in `docs/` and reference it near the top of the README.

## Social preview

`docs/social-preview.png` (1280 × 640) is the image shown when the
repository link is shared. It is generated from `docs/social-preview.svg`:

```sh
rsvg-convert -w 1280 -h 640 docs/social-preview.svg -o docs/social-preview.png
```

Upload the PNG in the repository's Settings → General → Social preview.
