# **GuildBankLedger** *- Beta*

WoW's guild bank log only keeps 25 entries per tab. In an active guild, that rolls over in minutes. GuildBankLedger saves every transaction before it's gone and syncs the data across your entire guild automatically.

## Core

- Scans all guild bank tabs automatically when you open the bank and periodically while it remains open
- Records every deposit, withdrawal, move, repair, and gold transaction
- Categorizes items (flasks, herbs, ore, gems, weapons, armor, and 30+ categories)
- Deduplicates across multiple scanners so nothing is double-counted
- Automatically compacts old data to keep SavedVariables small (full records → daily summaries after 30d → weekly after 90d)

## Guild-Wide Sync

Every guild member running the addon automatically logs and shares data. No setup required by participating guild members.

- Data spreads exponentially across the guild through epidemic gossip
- Concurrent send and receive for maximum throughput
- Smart peer selection prioritizes the most out-of-date peers first
- Delta sync only transfers what's actually different
- Compressed transfers, retry on failure, FPS-adaptive throttling

## UI (`/gbl` or minimap button)

- **Transactions** — Scrollable, sortable, filterable log of every item movement. Filter by player, item, date range, category, type, or tab. Paginated (100 per page).
- **Gold Log** — Deposits, withdrawals, repairs, tab purchases with a summary breakdown panel.
- **Consumption** — Guild-wide overview dashboard: total items and gold in/out/net, top 10 consumers with gold breakdown (click a name to jump to their transactions), top 15 most-used items with 7d/30d/all-time trend columns.
- **Sync** — Enable/disable sync, online peers with version and directional status (newer/outdated), sync audit trail, GM access control configuration.
- **Changelog** — Embedded version history, paginated (10 versions per page).
- **About** — Addon info, author credit, support links.

## Access Control

The GM sets a rank threshold. Players below it are restricted to one of two modes (GM's choice):

- **Sync Only** — restricted users see only the Sync tab (still contribute data)
- **Own Transactions Only** — restricted users see all tabs but only their own data

Settings sync to all guild members automatically.

## Accessibility

- 4 colorblind-safe palettes (auto-detected from WoW settings)
- High contrast mode (WCAG AAA)
- Triple encoding: shape + color + text for all transaction types
- Full keyboard navigation (Tab/Shift+Tab)
- Font scaling (8–24pt)

## Commands

- `/gbl` — Toggle the ledger window
- `/gbl status` — Version, guild, transaction count, last scan
- `/gbl scan` — Manual full scan
- `/gbl help` — Show all commands

**Status** — Beta. Recording, sync, and UI are stable and in active guild use. Planned: export (CSV/Discord/BBCode), raid team management, alt linking, stock alerts.

**Support development** — [Ko-fi](https://ko-fi.com/RexxyBear) · [GitHub Sponsors](https://github.com/sponsors/RussellFeinstein)