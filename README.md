# zaim_telegram_bot

Telegram bot that logs expenses to [Zaim](https://zaim.net/).

## Setup

```sh
cp config.json.sample config.json   # fill in telegram token + zaim consumer key/secret
./auth.sh                           # one time
```

Zaim tokens expire after about a day, whatever the approval page says. Put
`email` and `password` under `zaim` in `config.json` and the bot renews the
token itself at startup and whenever Zaim answers 401.

Without them, `./auth.sh` does it by hand: it prints a Zaim URL, you approve
and paste the code back. You'd be doing that daily.

## Run

```sh
./run.sh
```

Renews an expired token on its own if `zaim.email`/`zaim.password` are set;
otherwise refuses to start and tells you to run `./auth.sh`.

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
`Environment=LOG_LEVEL=DEBUG` adds per-message detail and the hourly Zaim
keepalive.

## Files

- `oauth_token.json` — current Zaim access token, rewritten on renewal. Gitignored, mode 0600.
- `cats.json` — categories and aliases. First name in each list is the canonical one shown in replies.
- `dump.py` — export all Zaim records to jsonl.
