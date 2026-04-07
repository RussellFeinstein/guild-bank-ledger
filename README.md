# GuildBankLedger

Persistent guild bank transaction logging for World of Warcraft. WoW's built-in guild bank log only stores 25 entries per tab, which rolls over in minutes for active guilds. GuildBankLedger captures every transaction before it's lost.

## Features (v0.5.0)

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
- **UI window** — Tabbed interface with Transactions, Gold Log, Consumption, and Sync views, opened via `/gbl` or minimap button
- **Transaction list** — Scrolling list with sortable columns: Timestamp, Player, Action, Item, Count, Category, Tab
- **Filter bar** — Search by player/item, filter by date range, category, transaction type, tab, with reset button
- **Consumption view** — Per-player withdrawal/deposit totals with click-to-expand per-item breakdown, sortable headers, category filter, top items with names
- **Multi-officer sync** — AceComm-based sync: officers scanning the bank independently have their data merged automatically with no duplicates. HELLO broadcast, chunked delta transfer (200 tx/chunk), ACK flow, peer tracking, audit trail
- **Sync tab** — Enable/disable sync, view online peers with version and tx count, review sync audit log
- **Minimap button** — Left-click to toggle the ledger window
- **Accessibility** — Colorblind-safe palettes (auto-detected from WoW settings), high contrast mode, triple encoding (shape + color + text), keyboard navigation (Tab/Shift+Tab), font scaling (8-24pt)

### Planned Features

- Raid team management and per-team reports
- Alt linking (manual + guild note parsing)
- Compressed inventory snapshots with diff
- Stock level alerts
- CSV/Discord/BBCode export
- Guild Bank Sort addon integration

## Installation

1. Download from CurseForge (or clone this repo)
2. Copy `GuildBankLedger/` to your `Interface/AddOns/` directory
3. If installing from source, run `bash fetch-libs.sh` to download dependencies, or use CurseForge packager

### Dependencies

- Ace3 (AceAddon, AceDB, AceConsole, AceEvent, AceComm, AceSerializer, AceGUI, AceConfig, AceConfigDialog, AceConfigCmd)
- LibDBIcon-1.0, LibDataBroker-1.1, LibSharedMedia-3.0

## Usage

| Command | Description |
|---------|-------------|
| `/gbl` | Toggle the ledger window |
| `/gbl show` | Toggle the ledger window |
| `/gbl status` | Show addon version, guild name, transaction count, last scan time |
| `/gbl scan` | Manually trigger a full guild bank scan |
| `/gbl help` | Show available commands |

Scanning happens automatically when you open the guild bank. Results are saved per-guild in `SavedVariables/GuildBankLedgerDB.lua`.

## Development

### Requirements

- Lua 5.1
- LuaRocks
- busted (test runner)

### Setup (from source)

```bash
bash fetch-libs.sh    # download Ace3 and supporting libraries
```

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
