# GuildBankLedger

Persistent guild bank transaction logging for World of Warcraft. WoW's built-in guild bank log only stores 25 entries per tab, which rolls over in minutes for active guilds. GuildBankLedger captures every transaction before it's lost.

## Features

- **Persistent logging** — Transactions are saved to `SavedVariables` and survive log rollovers
- **Automatic scanning** — Scans all guild bank tabs when you open the bank
- **Slot-level scanning** — Reads all 98 slots per viewable tab
- **Transaction recording** — Reads guild bank transaction logs via `GetGuildBankTransaction`
- **Item categorization** — Classifies items by WoW classID/subclassID (flasks, herbs, ore, gems, weapons, armor, etc.)
- **Deduplication** — Occurrence-based hashing with event count metadata prevents duplicate records across multiple scanners
- **Money tracking** — Records deposits, withdrawals, repairs, tab purchases
- **Per-player statistics** — Tracks deposit/withdrawal counts, money totals, first/last seen timestamps
- **Tiered storage** — Full records (0-30d), daily summaries (30-90d), weekly summaries (90d+)
- **Automatic compaction** — Old data compressed into summaries on bank open
- **UI window** — Tabbed interface with Transactions, Gold Log, Consumption, Sync, Changelog, and About views, opened via `/gbl` or minimap button
- **Transaction list** — Scrolling list with sortable columns: Timestamp, Player, Action, Item, Count, Category, Tab
- **Filter bar** — Search by player/item, filter by date range, category, transaction type, tab, with reset button
- **Consumption view** — Guild-wide overview dashboard with guild totals (items + gold in/out/net), top 10 consumers (flat ranked table with gold breakdown), and top 15 most used items (withdrawal counts with 7d/30d/all trend columns). Click player to jump to filtered Transactions tab
- **Guild-wide sync** — AceComm-based sync: guild members running the addon have their data merged automatically with no duplicates. Fingerprint-based delta sync, LibDeflate compression, chunked transfer (15 records/chunk), retry logic with NACK, FPS-adaptive throttling, zone change protection, peer tracking, audit trail
- **Sync tab** — Enable/disable sync, view online peers with version and directional status (newer/outdated), review sync audit log, GM access control configuration
- **Changelog tab** — Embedded version history with paginated display (10 versions per page), color-coded sections
- **About tab** — Addon info, author credit, copyable Ko-fi and CurseForge links, library credits
- **Version label** — Addon version displayed in the top-right corner; turns orange with "update available" when a peer has a newer version
- **Auto re-scan** — While the bank is open, re-queries all transaction logs every 5 seconds to capture item movements and gold transactions before they roll off the 25-entry-per-tab limit
- **Minimap button** — Left-click to toggle the ledger window
- **Access control** — GM configures a rank threshold for full addon access. Players below the threshold are restricted to Sync Only or Own Transactions Only mode (GM's choice). Settings sync to all guild members via the HELLO protocol
- **Accessibility** — Colorblind-safe palettes (4 modes, auto-detected from WoW settings), high contrast mode, triple encoding (shape + color + text), keyboard navigation (Tab/Shift+Tab), font scaling (8-24pt)

### Planned Features

- Raid team management and per-team reports (v1.1.0)
- Alt linking — manual + guild note parsing (v1.2.0)
- Stock level alerts (v1.3.0)
- Guild Bank Sort addon integration (v1.4.0)
- CSV/Discord/BBCode export (v1.5.0)

## Installation

1. Download from CurseForge (or clone this repo)
2. Copy `GuildBankLedger/` to your `Interface/AddOns/` directory
3. If installing from source, run `bash fetch-libs.sh` to download dependencies, or use CurseForge packager

### Dependencies

- Ace3 (AceAddon, AceDB, AceConsole, AceEvent, AceComm, AceSerializer, AceGUI, AceConfig, AceConfigDialog, AceConfigCmd)
- LibDBIcon-1.0, LibDataBroker-1.1, LibSharedMedia-3.0, LibDeflate

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

## Support

If you find GuildBankLedger useful, consider supporting development:

- [Ko-fi](https://ko-fi.com/RexxyBear)
- [GitHub Sponsors](https://github.com/sponsors/RussellFeinstein)

## License

MIT — see [LICENSE](LICENSE).
