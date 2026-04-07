# GuildBankLedger

Persistent guild bank transaction logging for World of Warcraft. WoW's built-in guild bank log only stores 25 entries per tab, which rolls over in minutes for active guilds. GuildBankLedger captures every transaction before it's lost.

## Features (v0.2.5)

- **Persistent logging** — Transactions are saved to `SavedVariables` and survive log rollovers
- **Automatic scanning** — Scans all guild bank tabs when you open the bank
- **Slot-level scanning** — Reads all 98 slots per viewable tab
- **Transaction recording** — Reads guild bank transaction logs via `GetGuildBankTransaction`
- **Item categorization** — Classifies items by WoW classID/subclassID (flasks, herbs, ore, gems, weapons, armor, etc.)
- **Deduplication** — Hour-bucket fuzzy matching prevents duplicate records when multiple officers scan
- **Money tracking** — Records deposits, withdrawals, repairs, tab purchases
- **Per-player statistics** — Tracks deposit/withdrawal counts, money totals, first/last seen timestamps
- **Tiered storage** — Full records (0-30d), daily summaries (30-90d), weekly summaries (90d+)
- **Automatic compaction** — Old data compressed into summaries on bank open
- **Slash commands** — `/gbl status`, `/gbl scan`, `/gbl help`

### Planned Features

- Multi-officer sync via AceComm
- Raid team management and per-team reports
- Alt linking (manual + guild note parsing)
- Compressed inventory snapshots with diff
- Stock level alerts
- CSV/Discord/BBCode export
- Guild Bank Sort addon integration
- Accessibility-first UI (colorblind mode, keyboard nav, font scaling)

## Installation

1. Download from CurseForge (or clone this repo)
2. Copy `GuildBankLedger/` to your `Interface/AddOns/` directory
3. If installing from source, install dependencies via `.pkgmeta` externals (or use CurseForge packager)

### Dependencies

- Ace3 (AceAddon, AceDB, AceConsole, AceEvent)

## Usage

| Command | Description |
|---------|-------------|
| `/gbl` | Show help |
| `/gbl status` | Show addon version, guild name, transaction count, last scan time |
| `/gbl scan` | Manually trigger a full guild bank scan |
| `/gbl help` | Show available commands |

Scanning happens automatically when you open the guild bank. Results are saved per-guild in `SavedVariables/GuildBankLedgerDB.lua`.

## Development

### Requirements

- Lua 5.1
- LuaRocks
- busted (test runner)

### Running Tests

```bash
busted --verbose
```

### Linting

```bash
luacheck .
```

## License

MIT — see [LICENSE](LICENSE).
