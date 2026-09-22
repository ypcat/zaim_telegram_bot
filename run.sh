#!/bin/bash
set -eu
cd "$(dirname "$0")"

# systemd hands over a minimal PATH, so a per-user uv is not on it.
for d in "$HOME/.local/share/mise/shims" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [ -x "$d/uv" ] && PATH="$d:$PATH"
done || true
export PATH

# Keep .venv in step with uv.lock, but do NOT run the bot through `uv run`.
# Doing so leaves uv as the service's main process, and a snap-packaged uv
# re-execs through snap-confine into its own namespace and cgroup. The python
# process then escapes zaim.service's cgroup, which journald uses to attribute
# output to a unit, so nothing it logs ever reaches `journalctl -u zaim`.
if command -v uv >/dev/null; then
    uv sync --locked --quiet || echo "uv sync failed; using existing .venv" >&2
fi

[ -x .venv/bin/python ] || {
    echo "No .venv here. Run: uv sync --locked" >&2
    exit 127
}

exec .venv/bin/python bot.py
