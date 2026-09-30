# Contributing

Bug reports and PRs are welcome. The whole thing is one bash script, so changes are usually small.

## Ground rules

These are what keep the status line usable. A PR that breaks one of them will be sent back.

1. **Never block a render.** Claude Code runs the script on every update. Anything that touches
   the network (`gh`, the usage API, GraphQL) runs in a detached background job and writes to a
   cache under `$TMPDIR/claude`. The render only reads the cache.
2. **`touch` the cache before spawning the refresh.** Otherwise a slow refresh starts a new job
   on every render until the first one finishes.
3. **Hide when empty.** A segment with nothing to say (no PR, zero Codex threads, 0/0 diff)
   prints nothing, not a placeholder.
4. **Linux and macOS.** Anything GNU-only needs a BSD fallback or has to fail quietly. Existing
   examples: `stat -c`/`stat -f`, `date -d`/`date -r`, `stty -F`/`stty -f`, `ss`/`lsof`, `with_timeout`.
5. **Machine-specific values go in the config** (`config.example.sh`), not in the script.

## Testing a change

```bash
bash -n statusline.sh                 # syntax
shellcheck -S warning statusline.sh   # if you have it

# Render with a sample input (any Claude Code statusline JSON works)
echo '{"model":{"display_name":"Opus"},"cwd":"'"$PWD"'"}' | COLUMNS=150 bash statusline.sh
```

To see what Claude Code actually sends, point `statusLine.command` at
`tee /tmp/sl-input.json | bash /path/to/statusline.sh` for one session, then replay the file.

Two gotchas worth knowing before touching layout:

- Claude Code trims leading whitespace from every line. Line 2 starts with U+2800 (blank braille)
  so its padding survives. A normal space or NBSP gets trimmed.
- `wc -L` counts `✍️` as one column but terminals draw it as two, so the alignment math has a `+1`.

## Screenshots

If your change is visible, regenerate the images and include them in the PR:

```bash
./demo/render.sh   # needs git, jq, node, python3, ImageMagick, Chrome/Chromium
```

It builds a throwaway repo and seeds fake caches, so no real repo name or usage number ends up
in `docs/`.

## Commits

Conventional prefixes (`feat:`, `fix:`, `docs:` …), one change per commit. Add a line to
`CHANGELOG.md` under *Unreleased*.
