#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Config ──────────────────────────────────────────────
# Optional per-machine settings (dev ports etc.); see config.example.sh.
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
config_file="${CLAUDE_STATUSLINE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config.sh}"
# shellcheck source=/dev/null
[ -f "$config_file" ] && . "$config_file"

cache_dir="${TMPDIR:-/tmp}"
cache_dir="${cache_dir%/}/claude"
mkdir -p "$cache_dir"

# timeout(1) is GNU coreutils; macOS lacks it unless coreutils is installed.
with_timeout() {
    local secs=$1; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"
    fi
}

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Prefer the live session value from stdin (reflects mid-session /effort changes);
# fall back to settings.json effortLevel. Absent on models without effort support.
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -z "$effort" ]; then
    settings_path="$claude_dir/settings.json"
    if [ -f "$settings_path" ]; then
        effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
    fi
fi
[ -z "$effort" ] && effort="default"

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Effort ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

# ── PR number + CI status for current branch (cached, non-blocking) ──
# gh hits the network, so never call it synchronously on a render. One call
# fetches number + statusCheckRollup; cache the raw JSON with a short TTL
# (CI flips faster than the PR number). Empty cache file == "no PR".
pr_number=""
pr_ci=""
if [ -n "$git_branch" ] && command -v gh >/dev/null 2>&1; then
    pr_cache_key=$(printf '%s/%s' "$cwd" "$git_branch" | tr -c 'a-zA-Z0-9' '_')
    pr_cache="$cache_dir/pr-${pr_cache_key}.json"
    pr_cache_max_age=120
    refresh_pr=true
    pr_json=""
    if [ -f "$pr_cache" ]; then
        pr_mtime=$(stat -c %Y "$pr_cache" 2>/dev/null || stat -f %m "$pr_cache" 2>/dev/null)
        now=$(date +%s)
        [ $(( now - pr_mtime )) -lt "$pr_cache_max_age" ] && refresh_pr=false
        pr_json=$(cat "$pr_cache" 2>/dev/null)
    fi
    if $refresh_pr; then
        (
            out=$(cd "$cwd" && with_timeout 6 gh pr view "$git_branch" \
                --json number,statusCheckRollup 2>/dev/null)
            printf '%s' "$out" > "$pr_cache.tmp" && mv "$pr_cache.tmp" "$pr_cache"
        ) >/dev/null 2>&1 &
        disown 2>/dev/null
    fi
    if [ -n "$pr_json" ] && echo "$pr_json" | jq -e . >/dev/null 2>&1; then
        pr_number=$(echo "$pr_json" | jq -r '.number // empty')
        # Normalize mixed check shapes (CheckRun/.status+.conclusion vs
        # StatusContext/.state) to one verdict; fail > pending > pass.
        pr_ci=$(echo "$pr_json" | jq -r '
            [ .statusCheckRollup[]? | (.conclusion // .state // .status // "") | ascii_upcase ] as $s
            | if   ($s|length)==0 then ""
              elif ($s|map(select(.=="FAILURE" or .=="ERROR" or .=="CANCELLED" or .=="TIMED_OUT"))|length)>0 then "fail"
              elif ($s|map(select(.=="IN_PROGRESS" or .=="QUEUED" or .=="PENDING" or .=="EXPECTED" or .=="WAITING"))|length)>0 then "pending"
              elif ($s|map(select(.=="SUCCESS" or .=="NEUTRAL" or .=="SKIPPED"))|length)==($s|length) then "pass"
              else "pending" end')
    fi
fi

# ── Dev servers (STATUSLINE_DEV_PORTS, e.g. "web:3000 api:8000") ──
# Local + fast (ss, or lsof on macOS). STATUSLINE_DEV_PORTS_WHEN lists repo
# paths that gate the check so it stays silent in unrelated repos.
dev_servers=""
git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
show_ports=false
if [ -n "$STATUSLINE_DEV_PORTS" ]; then
    if [ -z "$STATUSLINE_DEV_PORTS_WHEN" ]; then
        show_ports=true
    elif [ -n "$git_root" ]; then
        for when_path in $STATUSLINE_DEV_PORTS_WHEN; do
            [ -e "$git_root/$when_path" ] && { show_ports=true; break; }
        done
    fi
fi
if $show_ports; then
    listening=""
    if command -v ss >/dev/null 2>&1; then
        listening=$(ss -ltnH 2>/dev/null)
    elif command -v lsof >/dev/null 2>&1; then
        listening=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null)
    fi
    for entry in $STATUSLINE_DEV_PORTS; do
        port_name="${entry%%:*}"
        port_num="${entry##*:}"
        if echo "$listening" | grep -qE ":${port_num}([^0-9]|$)"; then
            dev_servers+="${sep}${green}◉ ${port_name}${reset}"
        else
            dev_servers+="${sep}${dim}○ ${port_name}${reset}"
        fi
    done
fi

# ── Unresolved Codex threads on the PR (cached, background-refreshed) ──
# The thread walk is paginated GraphQL and takes 1-5s depending on PR size, so it
# can never run on the render path. Touch the cache before spawning: a slow
# refresh would otherwise start a fresh job on every render while it runs.
codex_threads=""
if [ -n "$pr_number" ] && [ -n "$git_root" ]; then
    codex_script="$git_root/.claude/skills/codex-lens/scripts/codex-threads.sh"
    if [ -f "$codex_script" ]; then
        codex_cache="$cache_dir/codex-threads-${pr_number}.txt"
        codex_max_age=180
        refresh_codex=true
        if [ -f "$codex_cache" ]; then
            codex_mtime=$(stat -c %Y "$codex_cache" 2>/dev/null || stat -f %m "$codex_cache" 2>/dev/null)
            now=$(date +%s)
            [ -n "$codex_mtime" ] && [ $(( now - codex_mtime )) -lt "$codex_max_age" ] && refresh_codex=false
            codex_threads=$(head -1 "$codex_cache" 2>/dev/null)
        fi
        if $refresh_codex; then
            touch "$codex_cache"
            (
                out=$(cd "$git_root" && with_timeout 30 bash "$codex_script" "$pr_number" --count 2>/dev/null | head -1)
                # Only a bare number is a result; anything else means the call failed
                # and the previous count should stay on screen.
                case "$out" in
                    ''|*[!0-9]*) : ;;
                    *) printf '%s' "$out" > "$codex_cache.tmp" && mv "$codex_cache.tmp" "$codex_cache" ;;
                esac
            ) >/dev/null 2>&1 &
            disown 2>/dev/null
        fi
    fi
fi

# ── Toolchain: active venv Python + Node ──
# Read the venv version from pyvenv.cfg (no interpreter spawn). Red when it
# disagrees with the repo's .python-version / .node-version pin.
pin_root="${git_root:-$cwd}"
py_label=""
py_version=""
if [ -n "$VIRTUAL_ENV" ] && [ -f "$VIRTUAL_ENV/pyvenv.cfg" ]; then
    py_version=$(sed -nE 's/^version(_info)?[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' "$VIRTUAL_ENV/pyvenv.cfg" | head -1)
    py_label="${VIRTUAL_ENV#"$pin_root"/}"
    # Outside the repo: just <parent>/<venv>, never the full path.
    [ "$py_label" = "$VIRTUAL_ENV" ] && py_label="$(basename "$(dirname "$VIRTUAL_ENV")")/$(basename "$VIRTUAL_ENV")"
elif command -v python3 >/dev/null 2>&1; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    py_label="no venv"
fi
node_version=""
command -v node >/dev/null 2>&1 && node_version=$(node --version 2>/dev/null | sed 's/^v//')

# Prefix match: a "3.12" pin accepts 3.12.3; "24.15.0" must match exactly.
version_color() {
    local actual=$1 pin_file=$2 pin
    [ -f "$pin_file" ] || { printf "$green"; return; }
    pin=$(head -1 "$pin_file" | tr -d '[:space:]v')
    case "$actual" in
        "$pin"|"$pin".*) printf "$green" ;;
        *) printf "$red" ;;
    esac
}

line_tools=""
if [ -n "$py_version" ]; then
    py_color=$(version_color "$py_version" "$pin_root/.python-version")
    line_tools+="🐍 ${py_color}${py_version}${reset} ${dim}(${py_label})${reset}"
fi
if [ -n "$node_version" ]; then
    node_color=$(version_color "$node_version" "$pin_root/.node-version")
    [ -n "$line_tools" ] && line_tools+="${sep}"
    line_tools+="⬢ ${node_color}node ${node_version}${reset}"
fi

# ── Prompt cache + session diff (prepended to the right-side segment) ──
# Cache: remaining TTL before the next request pays a full re-cache write.
cache_seg=""
# `// empty` would also swallow `false`; test for presence explicitly.
cache_warm=$(echo "$input" | jq -r 'if .prompt_cache.warm == null then empty else (.prompt_cache.warm | tostring) end')
if [ -n "$cache_warm" ]; then
    cache_expires=$(echo "$input" | jq -r '.prompt_cache.expires_at // 0')
    cache_hit=$(echo "$input" | jq -r '.prompt_cache.hit_ratio // 0' | awk '{printf "%.0f", $1*100}')
    cache_left=$(( ${cache_expires%.*} - $(date +%s) ))
    if [ "$cache_warm" = "true" ] && [ "$cache_left" -gt 0 ]; then
        if [ "$cache_left" -lt 300 ]; then cache_color="$red"
        elif [ "$cache_left" -lt 900 ]; then cache_color="$yellow"
        else cache_color="$green"
        fi
        cache_seg="${dim}◷ cache${reset} ${white}${cache_hit}%${reset} ${cache_color}$(( (cache_left + 59) / 60 ))m${reset}"
    else
        cache_seg="${red}❄ cache cold${reset}"
    fi
fi

lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
diff_seg=""
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    diff_seg="${green}+${lines_added}${reset} ${red}−${lines_removed}${reset}"
fi

for seg in "$diff_seg" "$cache_seg"; do
    [ -z "$seg" ] && continue
    if [ -n "$line_tools" ]; then line_tools="${seg}${sep}${line_tools}"; else line_tools="$seg"; fi
done

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
    if [ -n "$pr_number" ]; then
        line1+=" ${yellow}#${pr_number}${reset}"
        case "$pr_ci" in
            pass)    line1+="${green}✓${reset}" ;;
            fail)    line1+="${red}✗${reset}" ;;
            pending) line1+="${yellow}⏳${reset}" ;;
        esac
        # Unresolved Codex threads. Silent at zero: the point is to replace
        # asking "any new comments?", not to add a permanent badge.
        if [ -n "$codex_threads" ] && [ "$codex_threads" -gt 0 ] 2>/dev/null; then
            line1+=" ${orange}💬${codex_threads}${reset}"
        fi
    fi
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    max)    line1+="${red}⬤ ${effort}${reset}" ;;
    xhigh)  line1+="${orange}● ${effort}${reset}" ;;
    high)   line1+="${magenta}◕ ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""

stdin_five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$stdin_five_pct" ]; then
    has_stdin_rates=true
    five_hour_pct=$(printf "%.0f" "$stdin_five_pct")
    five_hour_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | awk '{printf "%.0f", $1}')
    seven_day_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
fi

# ── Usage payload (cached) ─────────────────────────────
# Sole source for extra-usage credits and the scoped per-model weekly caps,
# neither of which stdin carries. Fetched synchronously only when stdin has no
# rate limits at all; otherwise refreshed in the background so a render never
# waits on the network.
cache_file="$cache_dir/statusline-usage-cache.json"
cache_max_age=60

usage_data=""
extra_enabled="false"

fetch_usage_cache() {
    local token="" blob="" creds_file response
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        token="$CLAUDE_CODE_OAUTH_TOKEN"
    elif command -v security >/dev/null 2>&1; then
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        creds_file="$claude_dir/.credentials.json"
        [ -f "$creds_file" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    fi
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        if command -v secret-tool >/dev/null 2>&1; then
            blob=$(with_timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
            [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        fi
    fi
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        return 1
    fi

    response=$(curl -s --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.34" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
        printf '%s' "$response" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"
        return 0
    fi
    return 1
}

cache_stale=true
if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    [ -n "$cache_mtime" ] && [ $(( now - cache_mtime )) -lt "$cache_max_age" ] && cache_stale=false
fi

if $cache_stale; then
    if $has_stdin_rates; then
        # Touch first: a slow refresh would otherwise spawn a fresh job per render.
        touch "$cache_file"
        ( fetch_usage_cache ) >/dev/null 2>&1 &
        disown 2>/dev/null
    else
        fetch_usage_cache
    fi
fi

usage_data=$(cat "$cache_file" 2>/dev/null)
if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')

    if ! $has_stdin_rates; then
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_hour_reset_epoch=$(iso_to_epoch "$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')")
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_day_reset_epoch=$(iso_to_epoch "$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')")
    fi
else
    usage_data=""
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

# ── Per-model weekly limits (e.g. Fable) ────────────────
# Scoped weekly caps have no named top-level key in the usage payload; they
# arrive in .limits[] as kind=weekly_scoped, labelled by model display name.
if [ -n "$usage_data" ]; then
    while IFS=$'\t' read -r scoped_name scoped_pct scoped_reset_iso; do
        [ -z "$scoped_name" ] && continue
        scoped_label=$(echo "$scoped_name" | tr '[:upper:]' '[:lower:]')
        scoped_pct=$(printf "%.0f" "$scoped_pct" 2>/dev/null)
        scoped_bar=$(build_bar "$scoped_pct" "$bar_width")
        scoped_pct_color=$(color_for_pct "$scoped_pct")
        scoped_reset=""
        if [ -n "$scoped_reset_iso" ]; then
            scoped_reset=$(format_epoch_time "$(iso_to_epoch "$scoped_reset_iso")" "datetime")
        fi

        [ -n "$rate_lines" ] && rate_lines+="\n"
        rate_lines+="${white}$(printf '%-7s' "$scoped_label")${reset} ${scoped_bar} ${scoped_pct_color}$(printf '%3d' "$scoped_pct")%${reset}"
        [ -n "$scoped_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${scoped_reset}${reset}"
    done < <(echo "$usage_data" | jq -r '
        .limits[]?
        | select(.kind == "weekly_scoped")
        | select(.scope.model.display_name != null)
        | [.scope.model.display_name, (.percent // 0), (.resets_at // "")]
        | @tsv' 2>/dev/null)
fi

if [ "$extra_enabled" = "true" ] && [ -n "$usage_data" ]; then
    extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
    extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
# Right-align the toolchain on line 1. stdout is a pipe, so read the width
# from the tty of the nearest ancestor that has one (the claude process).
term_width=0
[ "${COLUMNS:-0}" -gt 0 ] 2>/dev/null && term_width=$COLUMNS
if [ "$term_width" -eq 0 ]; then
    walk_pid=$PPID
    for _ in 1 2 3 4; do
        walk_tty=$(ps -o tty= -p "$walk_pid" 2>/dev/null | tr -d ' ')
        if [ -n "$walk_tty" ] && [ "$walk_tty" != "?" ]; then
            # GNU stty takes -F, BSD/macOS takes -f.
            term_width=$(stty -F "/dev/$walk_tty" size 2>/dev/null || stty -f "/dev/$walk_tty" size 2>/dev/null)
            term_width=$(echo "$term_width" | awk '{print $2}')
            break
        fi
        walk_pid=$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ')
        [ -z "$walk_pid" ] || [ "$walk_pid" -le 1 ] && break
    done
fi
[ -z "$term_width" ] && term_width=0
# BSD wc has no -L; without it we cannot measure, so fall back to separators.
printf 'x' | wc -L >/dev/null 2>&1 || term_width=0

visible_width() {
    printf "%b" "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -L
}

# Margin covers Claude Code's own left padding and emoji that wc -L
# under-counts (✍️ renders 2 wide, counts 1).
right_margin=6
if [ -n "$line_tools" ]; then
    pad=0
    if [ "$term_width" -gt 0 ]; then
        pad=$(( term_width - $(visible_width "$line1") - $(visible_width "$line_tools") - right_margin ))
    fi
    if [ "$pad" -ge 2 ]; then
        line1+="$(printf '%*s' "$pad" '')${line_tools}"
    else
        line1+="${sep}${line_tools}"
    fi
fi

# Dev servers sit on their own line under the toolchain. +1: line 1's
# ✍️ renders one column wider than wc -L counts.
line2=""
if [ -n "$dev_servers" ]; then
    # Start under line 1's ⬢ node icon; right-align when there is no node segment.
    anchor_w=$(visible_width "$dev_servers")
    [ -n "$node_version" ] && anchor_w=$(visible_width "${sep}⬢ node ${node_version}")
    pad2=$(( $(visible_width "$line1") + 1 - anchor_w ))
    # Claude Code trims leading whitespace per line; a leading U+2800 (blank braille,
    # not whitespace to JS trim()) keeps the padding.
    if [ "$pad2" -ge 2 ]; then line2="⠀$(printf '%*s' "$(( pad2 - 1 ))" '')${dev_servers}"; else line2="$dev_servers"; fi
fi

printf "%b" "$line1"
[ -n "$line2" ] && printf "\n%b" "$line2"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0

