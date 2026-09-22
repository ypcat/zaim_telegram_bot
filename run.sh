#!/bin/bash
set -eu
cd "$(dirname "$0")"

# systemd hands over a minimal PATH, so a per-user uv (mise, the standalone
# installer, cargo) is not on it. Look in the usual places before giving up.
for d in "$HOME/.local/share/mise/shims" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [ -x "$d/uv" ] && PATH="$d:$PATH"
done
export PATH

command -v uv >/dev/null || {
    echo "uv not found on PATH=$PATH" >&2
    echo "Set Environment=PATH=... in the systemd unit, or install uv system-wide." >&2
    exit 127
}

exec uv run --locked python bot.py
