# claude-code-statusline config. Sourced by statusline.sh on every render.
# Location: ${XDG_CONFIG_HOME:-~/.config}/claude-statusline/config.sh
# (override with CLAUDE_STATUSLINE_CONFIG=/path/to/file).

# Dev servers shown on line 2 as space-separated name:port pairs.
# Empty = line 2 is hidden.
STATUSLINE_DEV_PORTS=""
# STATUSLINE_DEV_PORTS="web:3000 api:8000"

# Only check the ports inside git repos containing at least one of these
# paths (relative to the repo root). Empty = check everywhere.
STATUSLINE_DEV_PORTS_WHEN=""
# STATUSLINE_DEV_PORTS_WHEN="apps/web apps/api"
