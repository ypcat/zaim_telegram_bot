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
| `/cat` | list categories |
| `/month` | this month's total |

## Files

- `oauth_token.json` — Zaim access token. Gitignored. **Copy it when redeploying**, or re-run `./auth.sh` on the new host.
- `dump.py` — export all Zaim records to jsonl.
