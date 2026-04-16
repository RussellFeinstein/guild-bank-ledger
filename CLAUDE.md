# GuildBankLedger — Project Instructions

## Overview

WoW addon that persistently logs guild bank transactions. Lua 5.1 + Ace3 stack. Tests via busted.

## Architecture

- **Core.lua** — AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
- **Scanner.lua** — Guild bank slot scanning (inventory snapshots)
- **Categories.lua** — Item classification via WoW classID/subclassID
- **Dedup.lua** — Deduplication engine (occurrence-based hashing, fuzzy matching, event count metadata, count-based cleanup)
- **Ledger.lua** — Transaction recording from GetGuildBankTransaction API
- **Storage.lua** — Tiered storage, compaction (30d daily, 90d weekly), pruning
- **Fingerprint.lua** — Dataset fingerprinting (djb2 hash, XOR aggregation, 6-hour bucket hashes)
- **ItemCache.lua** — Lazy async item info cache (GetItemInfo + GET_ITEM_INFO_RECEIVED for synced records)
- **Sync.lua** — Guild-wide sync via AceComm (HELLO/SYNC_REQUEST/SYNC_DATA/ACK/BUSY/MANIFEST protocol, epidemic gossip propagation, concurrent send+receive, smart peer selection, hash-gated HELLO reply suppression, fingerprint-based delta sync, pending peers queue, NACK backoff, combat/zone guards, bidirectional sync, jitter)
- **UI/Accessibility.lua** — Colorblind-safe palettes, font scaling, keyboard nav, triple encoding
- **UI/FilterBar.lua** — Transaction filter logic and AceGUI filter widgets
- **UI/ConsumptionView.lua** — Consumption aggregation: guild totals, per-player summaries, guild-wide item usage with time buckets
- **UI/LedgerView.lua** — Virtual-scrolling transaction list with sortable columns
- **UI/SyncStatus.lua** — Sync tab: enable toggle, peer list, audit trail
- **UI/ChangelogView.lua** — Changelog tab: embedded version history and in-game renderer
- **UI/AboutView.lua** — About tab: addon info, Ko-fi donation link, CurseForge link, credits
- **UI/UI.lua** — Main AceGUI frame, tab switching, minimap button
- **spec/** — busted tests with WoW API and Ace3 mocks

## Critical WoW API Facts

- `GUILDBANKFRAME_OPENED/CLOSED` **removed in 10.0.2** — use `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` with `Enum.PlayerInteractionType.GuildBanker`
- `GetGuildBankTransaction(tab, i)` returns **relative** time offsets — compute absolute via `GetServerTime() - offset`
- Must call `QueryGuildBankLog(tab)` before reading transactions; `QueryGuildBankTab(tab)` before reading slots
- Use `GetServerTime()` — never `time()` or `os.time()`
- Use numeric `classID`/`subclassID` via `C_Item.GetItemInfoInstant()` — never localized strings
- `MAX_GUILDBANK_SLOTS_PER_TAB = 98`
- `MAX_GUILDBANK_TABS = 8` (constant — max purchasable tabs)
- Money log tab index: `MAX_GUILDBANK_TABS + 1` (always 9, NOT `GetNumGuildBankTabs() + 1`)
- `GetGuildBankMoneyTransaction` returns type `"withdrawal"` (not `"withdraw"`) — normalize at record creation

## Testing

```bash
busted --verbose           # run all tests
busted spec/core_spec.lua  # run specific file
luacheck .                 # lint production code
```

- All mocks are in `spec/mock_wow.lua` and `spec/mock_ace.lua`
- Test helper: `spec/helpers.lua`
- Pattern: `*_spec.lua`

## Conventions

- Addon object: `GBL` (local alias for the AceAddon instance)
- Module registration: use AceAddon modules, not standalone globals
- Events: always check interaction type before acting on `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`
- Timestamps: always `GetServerTime()`, never `time()`
- Item IDs: use `C_Item.GetItemInfoInstant()` for classID/subclassID
- Guard `Enum.PlayerInteractionType.GuildBanker` existence for Classic compat
- Saved variables: `GuildBankLedgerDB` (AceDB), data keyed per guild name
- **Sync is guild-wide** — all members participate in HELLO/sync, not just officers. Officer rank only gates UI visibility (settings, admin features). Never add rank checks to the sync protocol.

## Version

Current: 0.25.0 (see `VERSION` file)
