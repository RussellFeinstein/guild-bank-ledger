<!-- Source of truth for the CurseForge project page description. After edits, paste contents (excluding this comment) into https://www.curseforge.com/wow/addons/guildbankledger > Manage > Description. -->

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
- **Sort**: Preview the planned moves to reshape the bank against a saved layout, then execute them on a fixed one-second cadence and auto-rerun any remaining moves until the bank matches the layout. Self-heals if the client's frame loop wedges mid-run. Hidden from members without sort access.
- **Layout**: Per-tab template editor (display, overflow, ignore modes) with per-item slot counts and stack sizes. Capture-from-current-tab shortcut. Hidden from members without layout-write access. Sort access is a two-tier policy (Layout Write and Sort-only, by rank threshold or named delegate) that the GM manages and that syncs guild-wide, so a grant reaches the granted officer automatically. The saved layout itself also syncs to officers with sort access, so a granted officer can sort against the GM's layout without rebuilding it.
- **Restock**: Restock the guild bank to your layout targets. Lists every layout item grouped by bank tab with its target, current stock, and how many to buy. With the Auctionator addon installed, searches the Auction House and buys the shortfall, per item or as a sweep (optionally capped by a per-run gold budget), spending real gold through WoW's commodity flow with an up-front affordability check. Hidden from members without sort access. Created by Katorri (Guild Bank Restock).
- **Sync** — Enable/disable sync, online peers with version and directional status (newer/outdated), GM access control configuration. Diagnostic logs persist across reloads (capped, never bank contents) so you can share them with the developer when something misbehaves; nothing is ever sent anywhere automatically. Manage with `/gbl audit`.
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
- Keyboard navigation: partial (Tab/Shift+Tab wiring under audit; complete before v1.0)
- Font scaling (8–24pt)

## Commands

- `/gbl` — Toggle the ledger window
- `/gbl status` — Version, guild, transaction count, last scan
- `/gbl scan` — Manual full scan
- `/gbl restock`: Open the Restock tab
- `/gbl synclog` — Pop up the sync session log
- `/gbl sortlog` — Pop up the sort session log
- `/gbl logs` — Pop up the master log (sync + sort + system, interleaved by timestamp)
- `/gbl audit on|off|status|clear` — Manage persistent log capture for troubleshooting (on by default; nothing is sent anywhere)
- `/gbl help` — Show all commands

**Status**: Beta. Recording and dedup are mature. Sync, sort, and UI are in active guild use with known improvements queued. Accessibility ships with palettes, contrast, triple encoding, and font scaling, but keyboard navigation is partial pending a v1.0 audit pass.

**Before v1.0**: complete accessibility audit and keyboard-nav wiring across all UI widgets, sync rate limiting, performance audit (SavedVariables size, compaction verification, UI debouncing).

**Planned post-1.0**: analytics dashboard, raid team management, alt linking, stock tab (passive inventory view), stock alerts, Guild Bank Sort integration, CSV/Discord/BBCode export.

**Support development**: [Ko-fi](https://ko-fi.com/RexxyBear) · [GitHub Sponsors](https://github.com/sponsors/RussellFeinstein)