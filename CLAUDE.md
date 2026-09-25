# CLAUDE.md

This repo holds two bots. **`bot.py` (Python, Zaim backend) is the one in
production.** `account_bot.exs` (Elixir, Google Sheets) is the 2.0 rewrite and
is not deployed. Work on whichever the task names; when unsure, it is `bot.py`.

## Production: bot.py (Zaim)

- Python 3.14, python-telegram-bot 22 (async), managed with `uv`. The whole
  operational surface is `./run.sh` (service) and `./auth.sh` (fix the Zaim
  login). Do not add flags or scripts the user would have to remember.
- `zaim_api.py` is a vendored Zaim OAuth 1.0a client. Its `Api` class is
  deliberately wire-identical to the dead `zaim` 0.2.3 package.
- Categories and aliases live in `cats.json`; first name in each list is
  canonical. `/alias` and `/unalias` edit it at runtime.
- **Zaim tokens expire after about a day** despite the "permanent access"
  checkbox. The bot renews them itself with `zaim.email`/`zaim.password` from
  `config.json`, at startup, on any 401, and via an hourly keepalive. Do not
  suggest removing the password. If that fails, `./auth.sh` retries the
  password, falls back to a browser login, and the running bot reloads the
  token from disk on its next 401.
- Runs on host `titan` under systemd at `~/git/zaim_telegram_bot`, not on the
  dev box. uv there is a snap: never run the bot through `uv run` under
  systemd, exec `.venv/bin/python` (see README). Deploy is
  `git pull && uv sync --locked && sudo systemctl restart zaim`.
- Never log a URL: the Telegram bot token is in the API path. httpx/httpcore
  are capped at WARNING and the `telegram` logger at INFO for this reason.

## Project: Account Bot 2.0

Telegram bot for personal/shared bookkeeping, backed by Google Sheets.

### Tech Stack
- **Language**: Elixir
- **Format**: Single self-contained `.exs` script using `Mix.install/2`
- **Backend**: Google Sheets API (OAuth 2.0)
- **Bot API**: Telegram Bot API (polling)

### Key Design Decisions
- Abandoned Zaim API in favor of Google Sheets as the data backend.
- Each user's "account" is a Google Spreadsheet in their own Drive.
- Multiple Telegram users can share the same spreadsheet (via `/invite` in a group).
- Supports both private chat and group chat.
- Bilingual UI — responds in the user's language.
- Input supports both freeform text parsing (legacy syntax) and interactive inline keyboard flow.
- Sheet default name `AccountBot`, user can rename.
- Full legacy category seeding from v1.
- Multiple accounts per user supported.
- Per-user timezone, default to server local TZ.

### Spec
See [spec_v2.md](./spec_v2.md) for the full 2.0 specification.

### Running
```bash
# Bot mode
elixir account_bot.exs

# Import Zaim dump
elixir account_bot.exs --import 20260529_zaim.jsonl --sheet-id SPREADSHEET_ID --chat-id CHAT_ID
```

### Config
The bot reads `config.json` for Telegram token and Google OAuth credentials.
See spec §11 for Google Cloud OAuth setup guide.

## Git
Before committing, confirm with user. Commit as `claude <noreply@anthropic.com>`:

```sh
git -c user.name=claude -c user.email=noreply@anthropic.com commit ...
```

Small changes go straight to master; substantial ones (upgrades, auth or
behaviour changes) get a branch and a PR with the reasoning.

