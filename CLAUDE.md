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
- **BankLayout.lua** — Per-guild saved bank layout templates (display/overflow/ignore tab modes with per-item slot counts and stack sizes); validation (exactly one overflow, no duplicate items across display tabs, ≤98 slots); capture-from-snapshot; stock reserves storage
- **SortPlanner.lua** — Pure-function move planner: given a bank snapshot + layout, produces deterministic ordered op list (split/move) to reshape bank. Assign-then-schedule algorithm: Phase 1 builds demands (slotOrder-pinned + items.slots extensions that right-extend then left-extend to keep each item's group contiguous), assigns each demand to the best source (same-tab direct → overflow → cross-tab; largest-count first within each tier; keep-slot harvest protection), and routes leftover supply to overflow using the same right/left extension so the stock tab stays grouped by item. Phase 2 schedules moves via a greedy feasibility loop and breaks swap cycles with a pivot slot (same-tab empty preferred, overflow fallback). Phase 3 sweeps stragglers using the same adjacency rule. Reports deficits, unplaced items (with reason code), and the overflow tab.
- **SortExecutor.lua** — Executes a plan one op at a time with throttling (0.3s gap), pre-step verification, cursor-leak safety, replan-on-foreign-activity (cap 5), bank-close abort, and `GUILDBANKBAGSLOTS_CHANGED`-driven confirmation with timeout fallback.
- **UI/Accessibility.lua** — Colorblind-safe palettes, font scaling, keyboard nav, triple encoding
- **UI/FilterBar.lua** — Transaction filter logic and AceGUI filter widgets
- **UI/ConsumptionView.lua** — Consumption aggregation: guild totals, per-player summaries, guild-wide item usage with time buckets
- **UI/LedgerView.lua** — Virtual-scrolling transaction list with sortable columns
- **UI/SyncStatus.lua** — Sync tab: enable toggle, peer list, audit trail
- **UI/ChangelogView.lua** — Changelog tab: embedded version history and in-game renderer
- **UI/AboutView.lua** — About tab: addon info, Ko-fi donation link, CurseForge link, credits
- **UI/LayoutEditor.lua** — Layout tab: per-tab mode picker (display/overflow/ignore), item-template rows with slots/perSlot, Capture-from-current-tab button, Add-item input, Sort Access sub-section (rank threshold + delegate list). Writes gated by `HasSortAccess()`; Sort Access writes gated by `IsGuildMaster()`.
- **UI/SortView.lua** — Sort tab: preview the planned moves, execute (HasSortAccess-gated), cancel, scan-bank shortcut. Shows move list, deficits, and unplaced items with human-readable item names.
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
- **`chunkOutcomes[idx]` outcome vocabulary (v0.28.7):** `"pending"`, `"ok"`, `"aborted"` (ackTimeout), `"combatAbort"`, `"zoneAbort"`, `"busyAbort"`, `"sendFailed"` (target offline). Abort-tagging paths are all guarded by `outcome == "pending"` so a later ACK that sets `"ok"` wins correctly. **`retryReasons`** is a per-chunk array of `"ackTimeout"` / `"nack"` tags; only these two count toward the wire-loss `chunkFail` metric. Combat/zone/busy/offline aborts are bucketed separately — mixing them into a single "aborted" count loses the ability to tell a noisy test session from a reliability issue.

### Historical patch verdicts

- **Genuine root-cause fixes:** v0.11.x (ID normalization), v0.22.0 (BUSY + pending queue), v0.23.0 (stale-ACK + callback-timed ACK timer), v0.25.0 (epidemic gossip + MANIFEST), v0.25.3 (receive-timer reschedule), v0.27.0 (epoch-0 migration + unified audit), v0.28.2 (dynamic CTL threshold).
- **Regression + partial rollback:** v0.28.0 raised chunk size 25→35 / 3200→5000 and tightened CTL 400→200 / 1.0s→0.25s — introduced burst-stall (Mode A) and increased fragment-loss exposure (Mode B). Only Mode A was fixed in v0.28.2; chunk size was not reverted.
- **Correct in isolation, amplifier in practice:** v0.25.4 superset-skip interacts poorly with failed sends (covers the symmetric pair so neither side retries).
- **Intentionally not a fix:** v0.28.1 and v0.28.4 added diagnostic logging because the root cause was uncertain.

### Chunk sizing — observed reality

- **Compression ratio is 23–26%, not ~18%.** v0.28.6 assumed a ~18% compressed:raw ratio and predicted 2-fragment chunks at a 2500-byte budget. Real cross-realm data showed chunks compressing to 659–737 bytes → 3 fragments, which pushed per-attempt chunk loss to ~45%. The ratio has been stable at 23–26% across chunk sizes in v0.28.5 and v0.28.6 captures.
- **Per-fragment drop is ~18%, not ~24%.** Back-solved from v0.28.6's `p_frag_est=44.9%` with 3-fragment chunks: `1-(1-0.18)^3 ≈ 0.45`. Consistent with multiple capture sessions.
- **Shipped (v0.28.7):** `MAX_RECORDS_PER_CHUNK = 4`, `CHUNK_BYTE_BUDGET = 900`. Byte budget is the binding constraint at ~287 raw bytes/record → ~3 records per chunk → ~860 raw → ~220 compressed → 1 fragment. Per-attempt loss = per-fragment loss ≈ 18%. 6-retry failure per chunk ≈ 0.003%. Sync of ~3300 records ≈ 18 min at the 1.0s gap floor; subsequent syncs are much shorter after bucket-delta convergence.
- **When to flip further down:** if a v0.28.7 sync still aborts mid-stream, the fix is **not** smaller chunks (1 fragment is the floor) — instead raise `INTER_CHUNK_GAP_FLOOR` from 1.0s to 1.5s or 2.0s (server-side throttle is the remaining lever). Read the `Compression for <peer>` audit line first: if `max > ~40%` there's wide compression-ratio tail and further byte-budget reduction might help in edge cases.
- **What NOT to do:** do not raise `CHUNK_BYTE_BUDGET` above ~900 without new data — the v0.28.5→v0.28.6→v0.28.7 arc shows 2-fragment chunks are still unreliable on some cross-realm routes.

### Diagnosis discipline

- Do not lower a pacing constant without an independent reliability measurement — "more aggressive" is not the same as "better."
- Per-chunk audit outcomes (attempt count, wire-to-ACK latency, gap since prior chunk, estimated fragments) are the minimum signal needed to discriminate fragment loss from server throttle from callback-timing bugs. Add these before changing behavior.
- `sendChunkIndex` in the "Send complete X/Y chunks" line is the index of the **last attempted** chunk, not the count acknowledged. When writing future diagnostics or UI strings, prefer an explicit "N ok / M aborted" framing.
- **v0.28.7 FinishSending output is three per-peer lines:** `Sync outcomes for <peer>` (histogram + split abort causes), `Retry causes for <peer>` (ackTimeout / nack / chunkFail / p_frag with observed `n=` frags/chunk), `Compression for <peer>` (min/med/max compression percentage). `p_frag` is back-solved using observed average fragment count rather than `lastChunkBytes`, so A/B data across chunk-size changes is directly comparable. **Do not conflate `chunkFail` (raw retry rate) with `p_frag` (per-fragment loss)** — they are equal only at n=1 fragments.
- **Outcome vocabulary is load-bearing.** Any new abort/failure path should add a named outcome value, not reuse `"aborted"` — the split between wire-loss and environmental aborts is what makes the histogram interpretable.
- **v0.28.8 FinishReceiving emits a `Redundancy from <peer>` line** with total dupe rate + item-vs-money split (e.g. `78% duped (1023/1314 received) — items: 65% (412/635), money: 90% (611/679)`). Per-chunk audit also has a running `X% dup` annotation. This is the receiver-side complement to v0.28.7's three sender-side per-peer lines. Use it to decide whether bucket-granularity redundancy justifies designing a manifest-exchange protocol change. Decision rule: `<30%` = bucket filter is doing most of the work, skip; `30–70%` = worth doing but not urgent; `>70%` = prioritize manifest exchange. Item-vs-money split tells you whether items, money, or both are the redundancy source — money-heavy redundancy may be addressable by smaller money-only buckets instead of full manifest. Suppression: line omitted on empty syncs; segments omitted when the corresponding record type is absent. **Do not conflate redundancy % with sender-side `chunkFail`** — redundancy measures dedup waste at the application layer, not wire-loss retries.

## Version

Current: 0.29.20 (see `VERSION` file)
