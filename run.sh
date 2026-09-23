#!/bin/bash
set -eu
cd "$(dirname "$0")"

# systemd hands over a minimal PATH, so a per-user uv is not on it.
for d in "$HOME/.local/share/mise/shims" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [ -x "$d/uv" ] && PATH="$d:$PATH"
done || true
export PATH

# Keep .venv in step with uv.lock, but do NOT run the bot through `uv run`.
# A snap-packaged uv runs python inside the snap's confinement: under systemd
# its output never reached the journal and it left the unit's cgroup
# (status showed Main PID uv, Tasks: 0). Exec'ing the venv's python from this
# unconfined shell avoids both.
if command -v uv >/dev/null; then
    uv sync --locked --quiet || echo "uv sync failed; using existing .venv" >&2
fi

[ -x .venv/bin/python ] || {
    echo "No .venv here. Run: uv sync --locked" >&2
    exit 127
}

exec .venv/bin/python bot.py
