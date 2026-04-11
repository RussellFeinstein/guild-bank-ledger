# Changelog

All notable changes to GuildBankLedger will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] — 2026-04-11

### Added
- **Fingerprint-based sync** — HELLO now includes a `dataHash` (XOR-aggregated djb2 of all record IDs). When both `dataHash` and `txCount` match between peers, sync is skipped entirely — zero WHISPER traffic for the common "already in sync" case
- **Bucket-filtered sync** — SYNC_REQUEST includes per-day bucket fingerprints. When datasets differ, only records from differing days are sent instead of everything, dramatically reducing transfer size for partial sync and retries after failure
- `Fingerprint.lua` module: `HashString` (djb2), `XOR32` (with pure-Lua fallback for tests), `ComputeDataHash`, `ComputeBucketHashes`, `GetDataHash` (cached)

### Changed
- `FinishReceiving` always checkpoints `lastSyncTimestamp` (previously reset to 0 when still behind, causing full re-sends). Bucket fingerprints handle the "still behind" case more precisely

## [0.7.17] — 2026-04-11

### Changed
- Reverted inter-chunk delay back to 100ms — 1s delay reduced throughput without improving reliability

## [0.7.15] — 2026-04-11

### Changed
- Reduced CHUNK_BYTE_BUDGET from 1400 to 600 — produces ~3 records per chunk (~800 bytes) to improve AceComm WHISPER reliability in cross-realm guilds

## [0.7.14] — 2026-04-11

### Fixed
- Crash syncing records from older/newer addon versions with missing fields: `reconstructSyncRecord` now guarantees `id`, `timestamp`, `scanTime`, `scannedBy` are always non-nil regardless of what the sender provides — computes missing `id` from record fields, recovers `timestamp` from id or falls back to current time, and `MarkSeen` guards against nil hash

## [0.7.13] — 2026-04-10

### Fixed
- Cross-realm sync failures: replaced `Ambiguate` with realm-stripping `baseName()` for peer identity matching in HandleAck and HandleSyncData — Ambiguate is context-dependent (behaves differently per client's realm), causing silent ACK rejection in cross-realm guilds where GUILD and WHISPER channels may format sender names differently

### Added
- Diagnostic audit entries: "RECV" logs raw channel + sender for all incoming messages, "ACK check" logs raw sender vs target before comparison — aids cross-realm debugging

## [0.7.12] — 2026-04-10

### Fixed
- Sync chunks could exceed WHISPER ~2000-byte limit and be silently dropped — PrepareChunks now uses estimated serialized size (1400-byte budget) instead of fixed record count, preventing ACK timeout loops on oversized chunks
- Money transactions now stripped via stripForSync before sync sending — previously sent raw with scanTime/scannedBy fields, wasting payload bytes and leaking mutable references

### Changed
- CHUNK_SIZE (10) replaced with MAX_RECORDS_PER_CHUNK (15) as a hard cap alongside new size-based splitting — typical chunks will be 7–9 records based on estimated byte size

## [0.7.11] — 2026-04-10

### Fixed
- Sync request could stall permanently if sender never responded — `receiving` stayed true with no timeout, blocking all future syncs. Now aborts after 30s with a chat message.

### Added
- Chat print when sync request is declined (sender already busy)
- Chat print per chunk on the send side (record count + byte size)
- Chat print for oversized chunk warnings (red text)
- Chat print for hard timeout (AceComm never finished transmitting)
- Audit trail entry when HELLO decides not to sync (with reason: counts equal, already receiving, or autoSync off)

## [0.7.10] — 2026-04-10

### Added
- Chat output for all sync events: request, chunk progress (new/duped counts), retries, timeouts, completion summary with elapsed time
- ACK receipt logging in audit trail
- Dedup breakdown per chunk (new vs duplicate record counts)
- Sync completion summary: total new, total duped, chunks received, elapsed seconds

## [0.7.9] — 2026-04-10

### Fixed
- Crash when syncing records from older addon versions that lack a `timestamp` field (`attempt to compare nil with number` in UpdatePlayerStats)
- Sync receiver now recovers missing `timestamp` from the id's timeSlot when receiving old-format records

## [0.7.8] — 2026-04-10

### Changed
- Sync chunk size increased from 3 to 10 records per chunk — ~3x faster sync throughput with fewer round-trips
- Sync payloads now strip 6 additional reconstructable fields (category, tabName, destTabName, scanTime, scannedBy, _occurrence) — smaller messages, more records fit per chunk
- Received sync records automatically reconstruct stripped fields (category from classID, occurrence from id, scanTime set to receipt time)

## [0.7.7] — 2026-04-10

### Fixed
- Sync data chunks too large for reliable WHISPER delivery — reduced from 25 to 3 transactions per chunk (~900 bytes vs ~6400 bytes), preventing silent AceComm reassembly failures
- Single dropped chunk no longer kills entire sync — ACK timeouts now retry the same chunk up to 3 times before aborting
- HandleAck timer cancellation still using `.cancelled = true` instead of `:Cancel()` (missed in v0.7.6 timer fix pass)

## [0.7.6] — 2026-04-10

### Fixed
- Sync timers never firing in WoW — `C_Timer.After` returns nil so timeouts could not be tracked or cancelled; switched all sync timers to `C_Timer.NewTicker(..., 1)` which returns a cancellable handle
- Timer cancellation using `.cancelled = true` (only worked in tests, not WoW API); replaced with `:Cancel()` method calls
- Manual "Broadcast Hello" button now bypasses the 60s cooldown

### Added
- Audit trail entry when receiving a HELLO from a peer (e.g. "Received HELLO from Katorri (tx: 556)")
- Diagnostic audit entries for chunk send lifecycle: bytes queued, transmission complete, and ACK wait

## [0.7.5] — 2026-04-10

### Fixed
- Peer discovery failure: new-peer HELLO reply was silently blocked by the 60s cooldown, preventing mutual peer detection until one side independently triggered a broadcast (e.g. closing the guild bank)
- HELLO cooldown consumed even when broadcast fails due to missing guild data at login — subsequent retries blocked for 60s

### Added
- HELLO broadcast on guild bank open for immediate peer discovery
- Debounced new-peer HELLO replies bypass the cooldown; multiple new peers discovered within 2s coalesce into a single reply (prevents HELLO flood in large guilds)

## [0.7.4] — 2026-04-10

### Added
- HELLO response: receiving a HELLO from a new peer now triggers a HELLO back so both sides discover each other (previously required both players to independently trigger a broadcast)
- Version indicator in Sync tab peer list — peers on a different version show "(outdated)" in orange

## [0.7.3] — 2026-04-10

### Fixed
- Sync data rejected by receiver due to name format mismatch between GUILD and WHISPER channels — HELLO arrives with "PlayerName" but SYNC_DATA arrives with "PlayerName-RealmName"; now uses `Ambiguate` on all sender comparisons in HandleSyncData and HandleAck
- Updated sync comments and UI strings from "officers" to "guild members" (sync is guild-wide, officer rank only gates UI)

## [0.7.2] — 2026-04-10

### Fixed
- Column text wrapping to new lines on all tabs — disabled word wrap on all fixed-width Label and InteractiveLabel cells (headers, data rows, summary panel, breakdown rows)

## [0.7.1] — 2026-04-10

### Fixed
- Sync ACK timeout — timer started immediately on message queue instead of after AceComm finished transmitting; large chunks exceeded the 10s timeout before the receiver even got the data
- Self-message filtering broken in retail WoW — realm-qualified sender names (e.g. "Player-Realm") never matched `UnitName("player")` output; now uses `Ambiguate`

### Changed
- Sync chunk size reduced from 200 to 25 transactions per message to fit within AceComm bandwidth constraints
- ACK timeout increased from 10s to 15s to allow for receiver dedup + round-trip
- `itemLink` stripped from sync payload (reconstructable from `itemID`) to reduce message size by ~30%
- Added 120s hard timeout safety net in case AceComm send callback never fires

## [0.7.0] — 2026-04-08

### Added
- Gold summary panel on Gold Log tab with per-type breakdown (deposits, withdrawals, repairs, tab purchases, net) rendered to the right of transaction columns with vertical divider
- Date range filters: added Last Hour, Last 3 Hours, Last 24 Hours to all tabs
- Pagination for Transactions tab (100 rows per page)

### Fixed
- Re-scan no longer resets selected date range and filters — `RefreshUI` now uses per-tab refresh functions that preserve filter state
- Runtime crash: `attempt to register unknown event "GUILD_BANK_LOG_UPDATE"` — corrected to `GUILDBANKLOG_UPDATE` (WoW uses `GUILDBANK` as a single token in event names)

## [0.6.2] — 2026-04-07

### Fixed
- Re-scan not detecting new transactions (withdrawals, deposits) while guild bank remains open — restored event-driven `GUILDBANKLOG_UPDATE` listener so reads happen after server responds, not after an arbitrary delay

## [0.6.1] — 2026-04-07

### Fixed
- Periodic re-scan not functioning in-game due to unreliable `C_Timer.After` return value tracking and event-driven overhead
- Re-scan chain silently breaking on Lua errors (now protected with pcall)

### Changed
- Reduced default re-scan interval from 5s to 3s (effective ~3.5s cycles, within 2-4s target)
- Simplified re-scan to use fixed 0.5s delay instead of event-driven debounce with 2s fallback
- Re-scan state tracked via boolean flag instead of timer handle (works across all WoW versions)

## [0.6.0] — 2026-04-07

### Added
- Periodic re-scan of all transaction logs while guild bank is open (every 5 seconds)
- Catches item and money transactions before they roll off the 25-entry-per-tab WoW API limit
- Auto-starts after initial scan completes, stops on bank close
- "Auto re-scan" toggle in settings row
- Re-scan status shown in `/gbl status` output

## [0.5.0] — 2026-04-07

**Milestone M5: Multi-Officer Sync**

### Added
- Multi-officer transaction sync via AceComm addon channel (prefix `GBLSync`)
- HELLO broadcast on login and bank close — announces version, tx count, and last scan time to guild
- Automatic sync: when a peer's HELLO shows more transactions, requests delta sync with chunked transfer (200 tx/chunk with ACK flow)
- Sync tab in main UI with enable/disable toggle, auto-sync toggle, and Broadcast Hello button
- Peer list showing online officers with version, tx count, and last seen time
- Sync audit trail (last 50 events) displayed in the Sync tab
- Sync progress messages (`GBL_SYNC_STARTED`, `GBL_SYNC_PROGRESS`, `GBL_SYNC_COMPLETE`) for UI updates
- ACK timeout (10s) — aborts stalled transfers, retries on next HELLO
- Receive timeout (30s) — resets stuck receive state if sender goes offline mid-sync
- Major version mismatch detection — warns in audit log and refuses sync across incompatible versions
- HELLO cooldown (60s) prevents broadcast flooding
- Wrong-sender guard — rejects SYNC_DATA from a third party during an active receive session
- 68 new tests (241 total) covering HELLO, sync request/response, chunking, dedup, dispatch, audit trail, and edge cases

### Changed
- Core addon now mixes in `AceComm-3.0` and `AceSerializer-3.0`
- Bank close now broadcasts HELLO to notify peers of fresh scan data
- Delta sync filters by `scanTime` (when record was created) instead of `timestamp` (when event happened) — ensures recently-scanned old transactions are not missed

## [0.4.1] — 2026-04-07

### Fixed
- Gold/money transactions now appear in the Transactions tab (were previously only visible in Consumption)
- Added "Amount" column to ledger view showing formatted gold amounts for money transactions
- Money transaction types (Repair, Tab Purchase, Deposit Summary) now appear in the Type filter dropdown
- Player stats now correctly track repair, buyTab, and depositSummary money types (were silently dropped)
- Money transactions no longer show misleading "0" in Count column or blank Item/Category/Location fields
- Transaction scan now uses debounced GUILDBANKLOG_UPDATE handler (0.5s after last event) so money tab data arrives before reading — previous next-frame read was too fast and missed money log responses
- Money log now queried at `MAX_GUILDBANK_TABS+1` (constant 9), not `GetNumGuildBankTabs()+1` — guilds with <8 tabs were querying the wrong tab index, so money data was never loaded from the server
- WoW API returns `"withdrawal"` for money transactions but code checked for `"withdraw"` — added normalization in CreateMoneyTxRecord so all downstream code matches correctly

### Changed
- Ledger "Action" column widened to 80px to fit "Tab Purchase" label; "Item" narrowed to 180px to accommodate new Amount column

## [0.4.0] — 2026-04-07

**Milestone M4: Consumption Detail + UI Polish**

### Added
- Click-to-expand player rows in consumption tab — click a player to see per-item breakdown with item name, category, withdrawn/deposited counts
- Sortable column headers on consumption tab (Player, Withdrawn, Deposited, Net, Last Active) with [asc]/[desc] indicators
- Category filter dropdown on consumption tab (reuses existing filter pipeline)
- Top Item column showing the #1 most active item name (extracted from item link)
- `ExtractItemName()` utility for extracting display names from WoW item links
- `GetBreakdownForDisplay()` transforms raw breakdown data into sorted display arrays with category labels
- `FormatTopItems()` formats top items as truncated comma-separated names
- 21 new tests (173 total) covering breakdown display, sort state, indicators, category filtering, item name extraction, edge cases

### Changed
- Ledger view column widths tightened to fit 720px usable frame (645px total: 130+90+70+200+40+80+35)
- Consumption tab filter bar now includes date range, category dropdown, and reset button (was date-only)

### Fixed
- Guild bank open no longer stutters — transaction scanning and compaction deferred via `C_Timer.After(0)` so the bank frame renders first

## [0.3.3] — 2026-04-07

### Fixed
- Sort direction indicators showed as boxes (UTF-8 unsupported by WoW font); changed to [asc]/[desc] text

### Added
- Revised roadmap (`docs/ROADMAP.md`) with sync moved to M5 and audit checklists per milestone

## [0.3.2] — 2026-04-07

### Fixed
- UI rows overflowed frame — ledger and consumption views now use AceGUI ScrollFrame for scrollable content
- LibDBIcon-1.0 `.toc` path pointed to nonexistent `lib.xml`; corrected to `LibDBIcon-1.0.lua`
- Interface version updated from 110105 to 120001 (WoW Midnight Season 1)

## [0.3.1] — 2026-04-07

### Fixed
- `fetch-libs.sh` pointed to nonexistent GitHub repos under `BigWigsMods/`; corrected to `WoWUIDev/Ace3`, `lua-wow/LibStub`, `zerosnake0/LibDBIcon-1.0`
- AceConfigDialog-3.0 and AceConfigCmd-3.0 are nested inside AceConfig-3.0 in the Ace3 repo; script now copies them correctly

### Removed
- LibSharedMedia-3.0 from `.toc` load list (no standalone GitHub repo; addon doesn't use it yet)

## [0.3.0] — 2026-04-07

**Milestone M3: UI**

### Added
- Main UI window toggled via `/gbl` or minimap button (left-click)
- Transaction ledger view with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar: text search, date range (7d/30d/all), category, transaction type, reset button
- Per-player consumption summary with net contribution, top items, last active
- Minimap button via LibDataBroker + LibDBIcon
- Accessibility: 4 colorblind-safe palettes auto-detected from WoW CVar, high contrast mode (WCAG AAA)
- Triple encoding for transaction types: shape icon + color + text label (WCAG 1.4.1)
- Keyboard navigation (Tab/Shift+Tab) with visible 2px yellow focus indicator, focus trap (WCAG 2.1.1, 2.4.7)
- Font size scaling (8-24pt) via addon settings
- Frame position clamping to screen bounds
- Library fetch script (`fetch-libs.sh`) for development setup
- 78 new tests (152 total) covering accessibility, filters, consumption, keyboard nav

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.6] — 2026-04-07

### Added
- Keyboard navigation: Tab/Shift+Tab focus traversal with wrap (focus trap per WCAG 2.1.1)
- Focus indicator: 2px yellow border tracked on each focusable widget (WCAG 2.4.7)
- Focus restore on frame reopen
- Frame position clamping to screen bounds
- 9 new keyboard nav and frame clamping tests (152 total)

## [0.2.5] — 2026-04-07

### Added
- Main UI window (`UI/UI.lua`) with tabbed view: Transactions and Consumption
- Scrolling transaction list (`UI/LedgerView.lua`) with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar widgets: search box, date range, category, type dropdowns, reset button
- Consumption table with per-player summaries, net contribution, last active
- Minimap button via LibDataBroker + LibDBIcon (left-click toggles window)
- `.toc` updated with all M3 library and UI file entries
- 4 new integration tests (143 total)

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.4] — 2026-04-07

### Added
- Per-player consumption aggregation (`UI/ConsumptionView.lua`): withdrawal/deposit totals, net contribution, money tracking, top items, last active timestamp
- Sortable consumption summaries by any column (player, withdrawn, deposited, net, last active)
- Per-player item breakdown with withdrawn/deposited per item
- Money formatting utility (`FormatMoney`: copper to "Xg Ys Zc")
- 18 new consumption tests (139 total)

## [0.2.3] — 2026-04-07

### Added
- Transaction filter logic (`UI/FilterBar.lua`) with AND-combined criteria: text search, date range (7d/30d/all), category, transaction type, player, tab
- AceGUI-3.0 mock framework for UI unit testing
- LibDataBroker-1.1 and LibDBIcon-1.0 mocks
- 19 new filter tests (121 total)

## [0.2.2] — 2026-04-06

### Added
- Accessibility module (`UI/Accessibility.lua`) with WCAG 2.1 AA-adapted design
- 4 colorblind-safe palettes: normal, protanopia, deuteranopia, tritanopia (auto-detected from WoW CVar)
- High-contrast palette variants (WCAG AAA 7:1+ contrast)
- Triple encoding for transaction types: shape icon + color + text label (WCAG 1.4.1)
- Font scaling utilities with 8-24pt clamping
- Timestamp formatting from profile settings
- 28 new accessibility tests (102 total)

## [0.2.1] — 2026-04-06

### Added
- Library fetch script (`fetch-libs.sh`) for local development setup — downloads Ace3 and supporting libraries from GitHub
- `.pkgmeta` externals for M3 libraries: AceGUI-3.0, AceConfig-3.0, AceConfigDialog-3.0, AceConfigCmd-3.0, LibDBIcon-1.0, LibDataBroker-1.1, LibSharedMedia-3.0

## [0.2.0] — 2026-04-06

**Milestone M2: Ledger + Dedup + Categories + Storage**

### Added
- Transaction recording from guild bank logs via `GetGuildBankTransaction` API
- Item categorization by WoW classID/subclassID (flasks, herbs, ore, gems, weapons, armor, and 30+ categories)
- Hour-bucket deduplication engine with 3-slot adjacent check for multi-officer drift tolerance
- Money transaction tracking (deposits, withdrawals, repairs, tab purchases)
- Per-player statistics: deposit/withdrawal counts, money totals, first/last seen timestamps
- Tiered storage compaction: full records (0-30d), daily summaries (30-90d), weekly summaries (90d+)
- Automatic compaction on bank open with scan-in-progress guard
- Storage statistics and size estimation
- Data purge command for manual cleanup
- 50 new unit tests (73 total) covering Ledger, Dedup, Categories, and Storage modules

## [0.1.0] — 2026-04-06

**Milestone M1: Scaffold + Scanner**

### Added
- AceAddon bootstrap with OnInitialize/OnEnable/OnDisable lifecycle
- Guild bank open/close detection via `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`
- Slot-level guild bank scanning across all viewable tabs
- Chained tab scanning with configurable delay via `C_Timer.After`
- Slash commands: `/gbl status`, `/gbl scan`, `/gbl help`
- AceDB saved variables with profile support
- Full test infrastructure with WoW API and Ace3 mocks
- 20 unit tests covering Core and Scanner modules
- Project scaffolding: .toc, .pkgmeta, .luacheckrc, .busted, LICENSE (MIT)
