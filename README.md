# zaim_telegram_bot

Telegram bot that logs expenses to [Zaim](https://zaim.net/).

## Setup

```sh
cp config.json.sample config.json   # fill in telegram token + zaim consumer key/secret
./auth.sh                           # one time
```

`auth.sh` prints a Zaim URL. Open it, approve, paste the code back.

**Tick `家計簿へのアクセスを永続的に許可する` on that page** — without it the token dies in 24h.
If the box isn't shown, enable `Permanently accessible to your account book` for the app at https://dev.zaim.net/ first.

## Run

```sh
./run.sh
```

Refuses to start if the token is dead, and tells you to run `./auth.sh`.

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

If nothing at all appears, the service is not running this code. Check with
`systemctl show zaim -p ExecMainPID -p FragmentPath` and `git -C <dir> log --oneline -1`.

## Files

- `oauth_token.json` — Zaim access token. Gitignored. **Copy it when redeploying**, or re-run `./auth.sh` on the new host.
- `cats.json` — categories and aliases. First name in each list is the canonical one shown in replies.
- `dump.py` — export all Zaim records to jsonl.
