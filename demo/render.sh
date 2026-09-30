#!/bin/bash
# Regenerate docs/screenshot.png and docs/states.png from fake but realistic
# input, so the images never show a real repo, branch or usage number.
# Needs: git, jq, node, python3, ImageMagick (convert), google-chrome or chromium.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(cd "$(mktemp -d)" && pwd -P)
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$work"' EXIT
chrome=$(command -v google-chrome || command -v chromium || command -v chromium-browser)
now=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# ── Fake repo: dirty branch, pinned toolchain, venv, Codex script ──
repo="$work/acme-web"
branch="feat/checkout-flow"
mkdir -p "$repo/.venv" "$repo/.claude/skills/codex-lens/scripts" "$work/notes"
git -C "$repo" init -q -b "$branch"
echo 3.12 > "$repo/.python-version"
node --version | sed 's/^v//; s/\..*//' > "$repo/.node-version"
printf 'home = /usr/bin\nversion = 3.12.3\n' > "$repo/.venv/pyvenv.cfg"
printf '#!/bin/bash\necho 2\n' > "$repo/.claude/skills/codex-lens/scripts/codex-threads.sh"
echo .venv > "$repo/.gitignore"
git -C "$repo" add -A
git -C "$repo" -c user.name=demo -c user.email=demo@example.com commit -qm init
echo dist >> "$repo/.gitignore"

# ── Dev ports: one listening, one not ──
web_port=47310
api_port=47311
python3 -m http.server "$web_port" --bind 127.0.0.1 >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 30); do
    (ss -ltnH 2>/dev/null || lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null) | grep -q ":$web_port" && break
    sleep 0.1
done
printf 'STATUSLINE_DEV_PORTS="web:%s api:%s"\n' "$web_port" "$api_port" > "$work/config.sh"

# ── Seed caches fresh, so nothing is fetched from gh or the usage API ──
export TMPDIR="$work/tmp"
cache="$TMPDIR/claude"
mkdir -p "$cache" "$work/claude"
pr_cache="$cache/pr-$(printf '%s/%s' "$repo" "$branch" | tr -c 'a-zA-Z0-9' '_').json"
seed_pr() { printf '{"number":128,"statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"%s"}]}' "$1" > "$pr_cache"; }
echo 2 > "$cache/codex-threads-128.txt"
jq -n --arg fable_reset "$(iso $((now + 400000)))" '{
    five_hour: {utilization: 0}, seven_day: {utilization: 0},
    limits: [{kind: "weekly_scoped", percent: 34, resets_at: $fable_reset,
              scope: {model: {display_name: "Fable"}}}],
    extra_usage: {is_enabled: true, utilization: 12, used_credits: 600, monthly_limit: 5000}
}' > "$cache/statusline-usage-cache.json"

# render CWD CONTEXT_TOKENS EFFORT CACHE_WARM CACHE_SECONDS_LEFT
render() {
    jq -n --arg cwd "$1" --argjson tok "$2" --arg effort "$3" --argjson warm "$4" \
        --argjson now "$now" --argjson left "$5" --arg start "$(iso $((now - 4380)))" '{
        model: {display_name: "Opus 5.5"}, cwd: $cwd,
        context_window: {context_window_size: 200000,
            current_usage: {input_tokens: 1200, cache_creation_input_tokens: 3000,
                            cache_read_input_tokens: ($tok - 4200)}},
        effort: {level: $effort}, session: {start_time: $start},
        prompt_cache: {warm: $warm, expires_at: ($now + $left), hit_ratio: 0.94},
        cost: {total_lines_added: 214, total_lines_removed: 37},
        rate_limits: {five_hour: {used_percentage: 38, resets_at: ($now + 8100)},
                      seven_day: {used_percentage: 61, resets_at: ($now + 260000)}}
    }' | COLUMNS=150 CLAUDE_STATUSLINE_CONFIG="$work/config.sh" CLAUDE_CONFIG_DIR="$work/claude" \
        bash "$root/statusline.sh"
}
caption() { printf '\033[38;2;110;112;135m# %s\033[0m\n' "$1"; }

shot() {
    {
        cat <<'EOF'
<!doctype html><meta charset="utf-8"><style>
body { margin: 0; background: #15161e; }
pre { margin: 0; padding: 24px; color: #dcdcdc; white-space: pre;
      font: 15px/1.5 "DejaVu Sans Mono", Menlo, monospace; }
.w2 { display: inline-block; width: 2ch; text-align: center; }
</style><pre>
EOF
        node "$root/demo/ansi2html.mjs" < "$1"
        echo '</pre>'
    } > "$work/shot.html"
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
        --window-size=1500,420 --screenshot="$work/raw.png" "file://$work/shot.html" >/dev/null 2>&1
    convert "$work/raw.png" -trim +repage -bordercolor '#15161e' -border 48 "$2"
    echo "wrote $2"
}

mkdir -p "$root/docs"
export VIRTUAL_ENV="$repo/.venv"

seed_pr SUCCESS
render "$repo" 46000 high true 2820 > "$work/main.ansi"
shot "$work/main.ansi" "$root/docs/screenshot.png"

{
    seed_pr FAILURE
    caption "CI failing, prompt cache cold, context nearly full"
    render "$repo" 186000 max false 0 | sed -n 1p; echo; echo
    seed_pr IN_PROGRESS
    echo 3.13 > "$repo/.python-version"
    caption "CI running, cache about to expire, venv doesn't match .python-version"
    render "$repo" 121000 medium true 170 | sed -n 1p; echo; echo
    caption "outside a git repo, no venv"
    (unset VIRTUAL_ENV; render "$work/notes" 12000 low true 3300 | sed -n 1p)
} > "$work/states.ansi"
shot "$work/states.ansi" "$root/docs/states.png"
