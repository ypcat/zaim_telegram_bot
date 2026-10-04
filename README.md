# zaim_telegram_bot

Telegram bot that logs expenses to a local account book. It started as a
front end for [Zaim](https://zaim.net/); since Zaim's API blocked it in
October 2026 the book lives in SQLite (`zaim.db`), behind the same calls and
response shapes as the Zaim API (`zaim_db.py`). Single user, no login.

## Setup

```sh
cp config.json.sample config.json   # fill in the telegram token
./import_zaim.py 20261004_zaim.jsonl  # Zaim export into zaim.db
```

`./import_zaim.py` with no argument imports the newest `*_zaim.jsonl` here.
It is idempotent: entries already in the book (same Zaim id) are skipped,
including ones cancelled since, so rerunning it or importing overlapping
dumps is harmless, with the bot running or not.

## Run

```sh
./run.sh
```

## Usage

| send | does |
|---|---|
| `午餐 摩斯 120` | log a payment |
| `20260521 晚餐 鼎泰豐 850` | log with a date |
| `薪水 公司 60000` | log income |
| `/cancel_123` | undo (id comes back in the reply) |
| `/help` | usage |
| `/cats` | list categories, aliases joined by `=` |
| `/alias 買菜=食物` | add an alias (idempotent) |
| `/unalias 買菜 咖啡` | remove aliases (never the last name) |
| `/month` | this month's total |

Commands are published to Telegram on startup, so they appear in the client's `/` menu.

## systemd

```ini
[Unit]
Description=zaim
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=peilun
WorkingDirectory=/home/peilun/git/zaim_telegram_bot
ExecStart=/home/peilun/git/zaim_telegram_bot/.venv/bin/python bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Deploy:

```sh
git pull && uv sync --locked && sudo systemctl restart zaim
journalctl -u zaim -n 20
```

`systemctl status zaim` should show `Main PID: ... (python)` with a few tasks
and tens of MB. `Main PID: ... (uv)` with `Tasks: 0` means the bot is running
inside a snap-packaged uv's confinement: its output never reaches the journal,
and it has left the unit's cgroup. Never run the bot through `uv run` under
systemd.

Quiet is normal: three lines at startup, then one per action.
`Environment=LOG_LEVEL=DEBUG` adds per-message detail.

## Files

- `zaim.db` — the account book (SQLite, table `money` with Zaim's columns). Gitignored; back it up.
- `cats.json` — categories and aliases. First name in each list is the canonical one shown in replies.
