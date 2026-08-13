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
- **Full history, kept indefinitely** — Every transaction stays a complete record. `src/Storage.lua` still contains a tiered-storage and compaction layer (full records 0-30d, daily summaries 30-90d, weekly beyond), but it has never once run: its entry point is guarded on `scanInProgress`, and the only caller fires while the scan is still going. It is being retired rather than repaired (issue #62), because compaction is incompatible with sync: a peer that compacted would drop to a 30-day fingerprint, every other peer would read it as far behind and push the records back
- **UI window** — Tabbed interface with Transactions, Gold Log, Consumption, Sort, Layout, Restock, Sync, Changelog, and About views, opened via `/gbl` or minimap button
- **Transaction list** — Scrolling list with sortable columns: Timestamp, Player, Action, Item, Count, Category, Tab
- **Filter bar** — Search by player/item, filter by date range, category, transaction type, tab, with reset button
- **Consumption view** — Guild-wide overview dashboard with guild totals (items + gold in/out/net), top 10 consumers (flat ranked table with gold breakdown), and top 15 most used items (withdrawal counts with 7d/30d/all trend columns). Click player to jump to filtered Transactions tab
- **Guild-wide sync**: AceComm-based sync. Guild members running the addon have their data merged automatically with no duplicates. Cross-version from 0.37.0 on: a `MIN_SYNC_VERSION` floor replaced the exact-version gate, so a guild spread across several releases keeps converging instead of splitting into islands. Fingerprint-based delta sync, LibDeflate compression, chunked transfer (each chunk is budgeted as a whole message, event counts and header included, so it fits a single wire fragment), retry logic with NACK, FPS-adaptive throttling, zone change protection, peer tracking, validation and repair of records damaged in transit, per-channel session logs (sync, sort, system) with severity levels, surfaced via `/gbl synclog`, `/gbl sortlog`, and `/gbl logs`
- **Sync tab**: Enable/disable sync, view online peers with version and status (newer, older but still syncing, or below the sync floor), GM access control configuration. Sync diagnostics surface on demand via `/gbl synclog` or the master log via `/gbl logs`. Diagnostic logs also persist to SavedVariables across reloads (capped and rotated, 10 sessions, never bank contents), so members can hand over troubleshooting data instead of copying chat; manage with `/gbl audit`. Nothing is ever sent anywhere automatically; sharing a capture stays a manual, deliberate step
- **Changelog tab** — Embedded version history with paginated display (10 versions per page), color-coded sections
- **About tab** — Addon info, author credit, copyable Ko-fi and CurseForge links, library credits
- **Version label** — Addon version displayed in the top-right corner; turns orange with "update available" when a peer has a newer version
- **Auto re-scan** — While the bank is open, re-queries all transaction logs every 5 seconds to capture item movements and gold transactions before they roll off the 25-entry-per-tab limit
- **Minimap button** — Left-click to toggle the ledger window
- **Mute ambient NPC chatter**: Optional client-side filter that suppresses `Silvermoon Citizen` say/yell/emote in chat and hides the matching world speech bubbles. Off by default. Toggle on the personal-preferences row at the top of the ledger window.
- **Access control** — GM configures a rank threshold for full addon access. Players below the threshold are restricted to Sync Only or Own Transactions Only mode (GM's choice). Settings sync to all guild members via the HELLO protocol
- **Sort access**: A separate GM-managed, two-tier policy (Layout Write and Sort-only, by rank threshold or named delegate) gates the Sort and Layout tabs. Members without access do not see them. The policy syncs guild-wide via the HELLO protocol, so a grant reaches the granted member without a reload. The saved bank layout itself syncs to members with sort access (advertise-and-pull: HELLO carries only a version cursor, and a member who can sort fetches the full template only when it changes), so a granted officer can sort against the GM's layout without rebuilding it
- **Restock**: Restock the guild bank to your layout targets. The Restock tab lists every layout item grouped by bank tab with its target, current stock, and how many to buy. With the Auctionator addon installed it searches the Auction House and buys the shortfall, per item or as a sweep (optionally capped by a per-run gold budget). Gated by sort access, like the Sort tab. Buying spends real gold through WoW's commodity purchase flow, with an up-front affordability check
- **Accessibility**: Colorblind-safe palettes (4 modes, auto-detected from WoW settings), high contrast mode, triple encoding (shape + color + text), keyboard-navigation primitives (partial; Tab/Shift+Tab wiring under audit), font scaling (8-24pt)

### Before v1.0

These items block the v1.0 release:

- Accessibility audit and keyboard-nav completion: wire `RegisterFocusable` into every AceGUI widget, hook Tab/Shift+Tab via a key handler, verify focus indicators on every tab, screen-reader audit, palette validation against WCAG AAA contrast targets
- Sync rate limiting (per-peer bandwidth budgeting)
- Performance audit (SavedVariables size, UI debouncing). Compaction verification came off this list when compaction itself was retired (#62)
- Community feedback iteration

### Planned (Post-1.0)

- Analytics dashboard: headline stats, activity timeline, category breakdown, gold flow, engagement distribution, item velocity. Consumption tab refocuses to per-player view as "Players" (v1.1.0)
- Raid team management and per-team reports (v1.2.0)
- Alt linking: manual and guild note parsing (v1.3.0)
- Stock tab: passive view of current bank inventory, per-item quantities and categories (v1.4.0)
- Stock alerts: toggleable minimum-level notifications with chat + sound (v1.5.0)
- Guild Bank Sort addon integration (v1.6.0)
- CSV/Discord/BBCode export (v1.7.0)

## Installation

1. Download from CurseForge (or clone this repo)
2. Copy `GuildBankLedger/` to your `Interface/AddOns/` directory
3. If installing from source, run `bash fetch-libs.sh` to download dependencies, or use CurseForge packager

### Dependencies

- Ace3 (AceAddon, AceDB, AceConsole, AceEvent, AceComm, AceSerializer, AceGUI, AceConfig, AceConfigDialog, AceConfigCmd)
- LibDBIcon-1.0, LibDataBroker-1.1, LibSharedMedia-3.0, LibDeflate

Auctionator is an optional dependency. With it installed, the Restock tab can search the Auction House and buy shortfalls. Restock still shows targets and stock without it; only the search and buy steps need it.

## Usage

| Command | Description |
|---------|-------------|
| `/gbl` | Toggle the ledger window |
| `/gbl show` | Toggle the ledger window |
| `/gbl status` | Show addon version, guild name, transaction count, last scan time |
| `/gbl scan` | Manually trigger a full guild bank scan |
| `/gbl restock` | Open the Restock tab |
| `/gbl synclog` | Show the sync-channel session log in a copy-pastable pop-up |
| `/gbl sortlog` | Show the sort-channel session log in a copy-pastable pop-up |
| `/gbl logs` | Show the master log: sync + sort + system, merged in timestamp order |
| `/gbl logs dump [N]` | Dump the last N master entries to chat (default 50) |
| `/gbl logs clear sync\|sort\|system\|all` | Truncate a channel |
| `/gbl logs debug sync\|sort\|system on\|off` | Toggle per-channel DEBUG-to-chat mirroring |
| `/gbl audit on\|off\|status\|clear` | Manage persistent log capture (on by default; off is the kill switch; clear wipes the whole account's captures) |
| `/gbl help` | Show available commands |

Scanning happens automatically when you open the guild bank. Results are saved per-guild in `SavedVariables/GuildBankLedgerDB.lua`.

## Restock

The Restock tab shows every item in your guild bank layout, grouped by tab, with its target count (from the layout), current stock, and how many are short. Open it with `/gbl restock` or the Restock tab. Like the Sort tab, it is visible only to members with sort access.

To buy the shortfall from the Auction House, install [Auctionator](https://www.curseforge.com/wow/addons/auctionator). Then:

1. Open the Auction House and Auctionator's Shopping tab.
2. Open the guild bank at least once in the session so Restock knows the current stock.
3. On the Restock tab, click Search to price every item the bank is short on.
4. Buy items individually with each row's Buy button, or click Buy all to sweep the whole list.

Restock spends real gold through WoW's commodity purchase flow. It refuses any purchase you cannot afford, and you can set a per-run gold budget to cap a Buy all sweep. Without Auctionator the tab still shows targets and shortfalls; only the search and buy steps need it.

The Restock feature was created by Katorri, based on the Guild Bank Restock addon.

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

### Git hooks

A `pre-push` hook in `scripts/hooks/` mirrors the CI `Verify DEV_BUILD is nil` step so a forgotten dev flip fails locally in under a second instead of after a CI round-trip. Activate it once per clone:

```bash
git config core.hooksPath scripts/hooks
```

Override for an intentional WIP push: `git push --no-verify`.

## Contributing

Bug reports, feature requests, and pull requests are all welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide: quick-start setup, commit / versioning conventions, test expectations, and the PR review process.

## Support

If you find GuildBankLedger useful, consider supporting development:

- [Ko-fi](https://ko-fi.com/rexxybear)
- [GitHub Sponsors](https://github.com/sponsors/RussellFeinstein)

## License

MIT — see [LICENSE](LICENSE).
