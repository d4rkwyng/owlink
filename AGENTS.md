# Agent rules (Owlink)

Read this before you edit, test, or push. [CLAUDE.md](CLAUDE.md) only points here.

## Push gate

A push is refused unless `Scripts/verify.sh` has stamped this exact HEAD on a clean tree. Run that script after you commit, and before you push or claim done. A Claude Code Stop hook (`.claude/settings.json`, `.githooks/claude-stop.sh`) also blocks "done" without a stamp.

Install the git hook in a worktree only (this does not change other worktrees or global git config):

    git config extensions.worktreeConfig true
    git config --worktree core.hooksPath .githooks

Emergency override (logs itself): `VERIFY_PUSH_OVERRIDE=<reason> git push ...`

## Review

Two review rounds, then stop and ask Derek. A must-fix finding needs evidence: a failing test, a repro command, or a cited code path.

## Tests

- Full local pass: `Scripts/verify.sh` (build, `Scripts/test.sh`, and a Swift 6.1 build when that toolchain is usable).
- Suite only: `Scripts/test.sh`.
- Any change to saving, encoding, BOM, reload, revert, or Follow File needs a byte-for-byte open/save/reload round-trip test, plus fault-injection tests that an interrupted or rejected write does not lose or invent bytes.

## Toolchain

Never run `xcode-select`. Honor `DEVELOPER_DIR` if it is set.

## Data you must not touch

Never read, write, or delete the real `~/Library/Application Support/Cedric`. Tests use their own temporary defaults.

## Language

US English in the UI, docs, comments, and commit messages.
