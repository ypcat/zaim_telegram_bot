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
ExecStart=/home/peilun/git/zaim_telegram_bot/run.sh
Restart=always
RestartSec=5
SyslogIdentifier=zaim
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

`Restart=always` matters: without it a crash or a dropped network leaves the
bot down until you notice.

Logs go to stderr, which systemd sends to the journal by default:

```sh
journalctl -u zaim -f         # follow
journalctl -u zaim -n 50      # last 50
```

Quiet is normal. Three lines at startup, then one per action. Set
`Environment=LOG_LEVEL=DEBUG` in the unit for per-message detail.

`git pull` does not reload a running service:

```sh
git pull && uv sync --locked && sudo systemctl restart zaim
```

`run.sh` execs `.venv/bin/python` directly rather than going through
`uv run`. With `uv run`, uv stays the service's main process, and a
snap-packaged uv re-execs through snap-confine into its own namespace and
cgroup. Python then escapes `zaim.service`'s cgroup, which is what journald
uses to attribute output to a unit, so nothing it logs reaches
`journalctl -u zaim`. The symptom is a unit that reports `active (running)`
with `Tasks: 0` and a few KB of memory.

If nothing appears at all, bisect it:

```sh
systemctl show zaim -p ExecMainPID --value          # then: ps -o lstart= -p <pid>
sudo systemctl stop zaim && ./run.sh                # foreground
```

Startup lines in the foreground but not in the journal means the unit is the
problem, not the bot: add the two Standard* lines above and
`systemctl daemon-reload`.

## Files

- `oauth_token.json` — current Zaim access token, rewritten on renewal. Gitignored, mode 0600.
- `cats.json` — categories and aliases. First name in each list is the canonical one shown in replies.
- `dump.py` — export all Zaim records to jsonl.
