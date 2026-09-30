# Changelog

## Unreleased

## 0.1.0 - 2026-09-30

First standalone release, extracted from a personal `~/.claude/statusline2.sh`.

- Line 1: model, context %, dir + branch, PR number + CI, unresolved Codex threads, session time,
  effort; right-aligned prompt cache, diff, Python venv and Node version.
- Line 2: dev server ports, configured in `~/.config/claude-statusline/config.sh`.
- Usage block: 5-hour, weekly, per-model weekly caps, extra-usage credits.
- `install.sh` that respects `CLAUDE_CONFIG_DIR` and backs up `settings.json`.
- macOS fallbacks: `lsof`, `stty -f`, `gtimeout`, Keychain token.
- `demo/render.sh` to regenerate the README screenshots from fake data.
