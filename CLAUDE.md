# CLAUDE.md

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

### Git
Before committing, confirm with user. Commit as `antigravity (antigravity@users.noreply.github.com)`.

