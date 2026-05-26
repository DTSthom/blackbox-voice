# Contributing

This is a personal-scratch project shared in case it's useful. PRs welcome, with the following posture:

- **Bug fixes** — happy to merge clean, targeted patches with a reproducer.
- **New features** — open an issue first to discuss fit; the project deliberately stays small and operator-readable. Adding dependencies or new daemons is unlikely to be merged.
- **Refactors** — generally no, unless they fix a real bug along the way.

The codebase is intentionally small enough to read end-to-end in an hour. If you find yourself adding abstractions, that's probably a sign the change belongs in a fork.

## Style

- Bash with `set -euo pipefail`. Explicit `if ! cmd; then ... ; fi` guards over `set -e` reliance when a function is called via `if`/`||`/`&&` (set -e is suppressed in those contexts — easy to forget).
- Python stdlib only. No SDK clients (the daily summary uses the Claude CLI subprocess, not the `anthropic` package).
- Comments explain *why*, not *what*. The shell + names should make *what* obvious.

## Testing

There's no test suite. Smoke-test by dropping a known-good MP3 into `~/blackbox-incoming/session-test/` on the host and watching `tail -f /data/blackbox/_log`. The Whisper output is deterministic enough that diffing transcript output across two runs catches most regressions.
