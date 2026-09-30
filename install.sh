#!/bin/bash
# Install statusline.sh into the Claude Code config dir and point settings.json at it.
# Usage: ./install.sh            (respects CLAUDE_CONFIG_DIR, defaults to ~/.claude)
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")" && pwd)
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
target="$claude_dir/statusline.sh"
settings="$claude_dir/settings.json"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline"

missing=()
for cmd in bash jq git curl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required commands: ${missing[*]}" >&2
    exit 1
fi
for cmd in gh ss lsof; do
    command -v "$cmd" >/dev/null 2>&1 || echo "note: '$cmd' not found (optional)"
done

mkdir -p "$claude_dir" "$config_dir"
install -m 0755 "$repo_dir/statusline.sh" "$target"
echo "installed  $target"

if [ ! -f "$config_dir/config.sh" ]; then
    cp "$repo_dir/config.example.sh" "$config_dir/config.sh"
    echo "created    $config_dir/config.sh"
else
    echo "kept       $config_dir/config.sh"
fi

[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak-statusline"
tmp=$(mktemp)
jq --arg cmd "bash $target" '.statusLine = {type: "command", command: $cmd}' "$settings" > "$tmp"
mv "$tmp" "$settings"
echo "updated    $settings (backup: $settings.bak-statusline)"
echo "Restart Claude Code (or start a new session) to see it."
