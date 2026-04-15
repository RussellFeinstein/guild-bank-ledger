**GuildBankLedger**

WoW's guild bank log only keeps 25 entries per tab. In an active guild, that rolls over in minutes. GuildBankLedger saves every transaction before it's gone and syncs the data between guild members running the addon.

**What it does**

- Scans all guild bank tabs when you open the bank
- Records every deposit, withdrawal, move, repair, and gold transaction
- Syncs between guild members automatically — install and go
- Fingerprint-based delta sync with compression, retry logic, and FPS-adaptive throttling
- Categorizes items (flasks, herbs, ore, gems, armor, etc.)
- Deduplicates across multiple scanners so nothing is double-counted
- Compacts old data to keep SavedVariables small

**UI** (`/gbl` or minimap button)

- **Transactions** — Sortable, filterable log of all item movements
- **Gold Log** — Deposits, withdrawals, repairs, tab purchases
- **Consumption** — Guild-wide dashboard: totals, top 10 consumers, top 15 items with 7d/30d/all-time trends
- **Sync** — Online peers with version status, audit trail, GM access control config
- **Changelog** — Embedded version history with paginated display

**Access control** — GM configures a rank threshold. Players below it are restricted to Sync Only or Own Transactions Only mode. Settings sync via HELLO protocol.

**Accessibility**

- Colorblind-safe palettes (4 modes, auto-detected from WoW settings)
- Triple encoding: shape + color + text for all transaction types
- Keyboard navigation
- Font scaling (8-24pt)

**Beta** — In guild testing. Recording and sync are stable. Export, team management, and stock alerts are planned.
