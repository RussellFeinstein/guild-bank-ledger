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
- **Windows/MSYS2:** bare `busted`/`luacheck` require shim scripts in `~/bin/` (see `~/bin/busted`). Fallback: `bash run_tests.sh --verbose` (or `--lint` for luacheck).

## Conventions

- Addon object: `GBL` (local alias for the AceAddon instance)
- Module registration: use AceAddon modules, not standalone globals
- Events: always check interaction type before acting on `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`
- Timestamps: always `GetServerTime()`, never `time()`
- Item IDs: use `C_Item.GetItemInfoInstant()` for classID/subclassID
- Guard `Enum.PlayerInteractionType.GuildBanker` existence for Classic compat
- Saved variables: `GuildBankLedgerDB` (AceDB), data keyed per guild name
- **Sync is guild-wide** — all members participate in HELLO/sync, not just officers. Officer rank only gates UI visibility (settings, admin features). Never add rank checks to the sync protocol.

## Sync subsystem notes

### Protocol / transport

- Sync transport stack is **AceSerializer → LibDeflate → AceComm → ChatThrottleLib → `C_ChatInfo.SendAddonMessage`**. AceComm splits payloads into 255 B wire fragments; a 980 B compressed chunk is ~4 fragments. Whole-chunk loss compounds: at per-fragment drop probability `p`, chunk loss is `1 - (1-p)^n`. Moving from 3 to 4 fragments at p=5% raises chunk loss from 14% to 19%.
- AceComm WHISPER has an empirically ~2000 B reliability ceiling (`WHISPER_SAFE_BYTES` in `Sync.lua`). Staying under it is necessary but not sufficient — fragment *count* is an independent reliability factor.
- `ChatThrottleLib.avail` is the **client-side** bandwidth meter only. It does not model server-side per-recipient addon-message throttling that Blizzard's chat server applies to `SendAddonMessage` independent of CTL. A healthy `CTL.avail` can still coincide with server-dropped messages when chunks are issued <1s apart.
- `C_ChatInfo.SendAddonMessage` via `AceComm:SendCommMessage` does not return a useful delivery status — reliability is observed only via ACK/NACK/timeout at the protocol layer. Do not branch on its return value.
- AceComm's progress callback fires per CTL piece; only `sent == totalBytes` indicates "handed to the wire," and only then should the ACK timer start. This is the v0.23.0 contract codified in `SendNextChunk`.

### Code invariants to preserve

- All sync diagnostics go through `GBL:AddAuditEntry`. Use `chatOnly=true` for high-frequency per-chunk chat spam and plain calls for the audit trail. The trail is capped at 2000 entries — new per-chunk entries must be additive/terse, not verbose.
- `syncState.lastChunkBytes` is the canonical compressed chunk size. Reuse it for fragment-count estimates (`ceil(lastChunkBytes/255)`) rather than re-measuring.
- `HasSyncBandwidth()` uses a **dynamic** threshold `max(CTL_BANDWIDTH_MIN, lastChunkBytes)` — this is the v0.28.2 fix for the burst-stall regression from v0.28.0. Do not regress to a fixed threshold.
- The superset skip in `HandleHello` and again in the bidirectional check after `FinishSending` is load-bearing for convergence but lacks a "tried and failed, back off" state — when sends fail, both sides' bidirectional checks short-circuit on "likely superset" and the protocol re-enters the same failing pattern. Flagged as a candidate amplifier, not fixed in v0.28.4.
- Stale-ACK discard in `HandleAck` (v0.23.0) and `ScheduleReceiveTimeout` rescheduling (v0.25.3) are real defect fixes, not patches — do not remove during refactors.

### Historical patch verdicts

- **Genuine root-cause fixes:** v0.11.x (ID normalization), v0.22.0 (BUSY + pending queue), v0.23.0 (stale-ACK + callback-timed ACK timer), v0.25.0 (epidemic gossip + MANIFEST), v0.25.3 (receive-timer reschedule), v0.27.0 (epoch-0 migration + unified audit), v0.28.2 (dynamic CTL threshold).
- **Regression + partial rollback:** v0.28.0 raised chunk size 25→35 / 3200→5000 and tightened CTL 400→200 / 1.0s→0.25s — introduced burst-stall (Mode A) and increased fragment-loss exposure (Mode B). Only Mode A was fixed in v0.28.2; chunk size was not reverted.
- **Correct in isolation, amplifier in practice:** v0.25.4 superset-skip interacts poorly with failed sends (covers the symmetric pair so neither side retries).
- **Intentionally not a fix:** v0.28.1 and v0.28.4 added diagnostic logging because the root cause was uncertain.

### Chunk sizing — moderate vs. conservative

- **Moderate (shipped, v0.28.6):** `MAX_RECORDS_PER_CHUNK = 10`, `CHUNK_BYTE_BUDGET = 2500`. Compressed chunks land around 450–510 bytes → 2 AceComm wire fragments per chunk. At the observed ~24% per-fragment drop on cross-realm whispers this gives ~42% per-attempt chunk loss and <1% 6-retry failure per chunk. Sync of ~4000 records ≈ 7 minutes at the 1.0s gap floor.
- **Conservative (pinned as a commented block in `Sync.lua`):** `MAX_RECORDS_PER_CHUNK = 5`, `CHUNK_BYTE_BUDGET = 1500`. Compressed chunks ≤ 255 bytes → 1 fragment per chunk. Per-attempt loss equals per-fragment loss (~24%). 6-retry failure per chunk is ~0.02%. Sync time roughly doubles to ~14 minutes.
- **When to flip to conservative:** if a v0.28.6 sync still aborts mid-stream on cross-realm peers (particularly chunk 1 failing all 6 retries from a fresh `Send complete to X — 1/N chunks` line), or `Sync outcomes` reports `p_frag_est > 15%` after multiple attempts. Flip by editing `Sync.lua:12-13` to the values in the commented alternative, bump patch version, ship.
- **What NOT to do:** do not go *above* 10 records / 2500 byte budget without new diagnostic data — the v0.28.4→v0.28.5 evidence shows 4-fragment chunks have unrecoverable per-attempt loss on at least some cross-realm routes.

### Diagnosis discipline

- Do not lower a pacing constant without an independent reliability measurement — "more aggressive" is not the same as "better."
- Per-chunk audit outcomes (attempt count, wire-to-ACK latency, gap since prior chunk, estimated fragments) are the minimum signal needed to discriminate fragment loss from server throttle from callback-timing bugs. Add these before changing behavior.
- `sendChunkIndex` in the "Send complete X/Y chunks" line is the index of the **last attempted** chunk, not the count acknowledged. When writing future diagnostics or UI strings, prefer an explicit "N ok / M aborted" framing.

## Version

Current: 0.28.6 (see `VERSION` file)
