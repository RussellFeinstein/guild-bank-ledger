# GuildBankLedger: Path to v1.0.0

> Created 2026-04-12. Updated 2026-04-12 after sync fix cascade (v0.10.1–v0.11.3).
> Teams/Alts deferred to v1.1.0 by scope decision.

## Context

GuildBankLedger is at **v0.11.3** with M1–M5 complete (425 tests, 14 production files, luacheck clean). An unplanned sync fix cascade consumed versions v0.10.1–v0.11.3 to resolve a perpetual sync loop discovered in live testing. The original Phase 0–3 plan is intact but version-shifted.

**Version path:** ~~v0.10.1–3 (bugs) → v0.11.0 (Export) → v0.12.0 (Snapshots/Alerts) → v1.0.0 (Polish/Release)~~

**Revised:** v0.12.0 (occurrence fix) → v0.12.x (UI bugs) → v0.13.0 (Export) → v0.14.0 (Snapshots/Alerts) → v1.0.0 (Polish/Release)

---

## Sync Fix Cascade (v0.10.1–v0.11.3) — Completed

An in-game sync test revealed a perpetual sync loop. Three fixes peeled back layers of the same root problem: peers scanning the same event at different times produce different timestamps → different record IDs → divergent `dataHash` → infinite re-sync. A fourth version added comprehensive regression coverage.

### v0.10.1 — Luacheck cleanup
- Renamed shadowed upvalue (`total` → `totalBytes`) in SendCommMessage callback
- Inverted empty if-branch in UI.lua

### v0.10.2 — Sync dedup false positives
- Fuzzy ±1 hour dedup incorrectly rejected genuinely new records in consecutive hours
- Added timestamp proximity check (< 3600s strict) to separate same-event re-scans from different events
- Proof: same event across clients always has |diff| ≤ 3599 (WoW API hour granularity); different events always have |diff| == 3600

### v0.11.0 — Fix 1: Deterministic ID normalization
- `IsDuplicate` returns matched `seenTxHashes` key on fuzzy matches
- `HandleSyncData` uses deterministic tiebreaker (lexicographically smaller ID wins) to normalize record IDs in-place
- Hash cache reset after normalization so next HELLO detects convergence
- Compaction guarded during sync receive (`_syncReceiving` flag)
- **Problem found:** When receiver's ID is already smaller, sender never gets feedback → hashes never converge → perpetual loop persists

### v0.11.1 — Fix 2: Sender-wins + timestamp normalization
- Changed from "smaller ID wins" to sender-wins: receiver always adopts sender's ID AND timestamp
- Converges fully in one sync cycle (protocol serializes direction, preventing oscillation)
- Timestamp normalization prevents bucket hash mismatch (without it, same record lands in different 6h buckets)
- **Problem found:** Bucket keys still derived from `tx.timestamp`, not normalized ID → different buckets on each peer → 4 buckets re-syncing 627 records endlessly

### v0.11.2 — Patch: Bucket key from record ID
- `bucketKeyForRecord()` now extracts `timeSlot` from record ID (pattern `|(%d+):%d+$`)
- Falls back to `tx.timestamp / 21600` for legacy records without parseable IDs
- `HandleSyncRequest` uses same `BucketKeyForRecord()` for filtering
- Ensures consistent bucket placement across peers regardless of timestamp differences

### v0.11.3 — Regression tests (20 new, 425 total)
- Bucket key consistency after normalization (3 tests)
- Multi-record normalization in same chunk (2 tests)
- Hash cache invalidation correctness (2 tests)
- Bidirectional convergence + no-oscillation proof (2 tests)
- Occurrence index edge cases (2 tests)
- reconstructSyncRecord pipeline with missing fields (2 tests)
- Mixed outcomes in same bucket (1 test)
- NormalizeRecordId edge cases (5 tests)
- seenTxHashes atomic update (1 test)
- End-to-end two-peer convergence cycle (1 test — the definitive regression test)

---

## Current State (v0.12.0)

**What's shipped and working:**
- Transaction logging with persistent storage and tiered compaction
- Slot-level inventory scanning with periodic re-scan (3–5s)
- Hour-bucket dedup engine (occurrence-based, clock-drift tolerant)
- Item categorization (30+ classes via classID/subclassID)
- Full UI: Transactions, Gold Log, Consumption, Sync tabs
- Accessibility: 4 colorblind palettes, high contrast, keyboard nav, triple encoding
- Guild-wide sync: HELLO/SYNC_REQUEST/SYNC_DATA/ACK with LibDeflate compression, fingerprint-based delta sync, sender-wins convergence, NACK retry, zone protection, FPS-adaptive throttling
- Minimap button, slash commands, AceDB profiles
- 425 tests, luacheck clean

**Outstanding bugs (from original Phase 0):**
- `UI/LedgerView.lua:225` — Pagination controls not rendering in AceGUI ScrollFrame
- `UI/UI.lua:547` — Same pagination issue in Gold Log tab
- Column widths clipping text in some views
- Window resize artifacts when shrinking horizontally
- README.md out of date

**Test gaps:**
- No tests for `UI/LedgerView.lua`, `UI/SyncStatus.lua`, or `UI/UI.lua`

---

## Phase 0a: Sync Dedup Fix (v0.12.0)

Fix the remaining cross-client false positive problem before UI work. This affects sync correctness — UI bugs don't.

### v0.12.0 — Prefix-based occurrence counting + migration
- **Problem:** `AssignOccurrenceIndices` counts per-baseHash (includes timeSlot). Two genuinely different events with the same prefix in adjacent hours both get `:0`. When a second client's timeSlot shifts by +1 hour, the incoming ID exactly matches a different event — bypassing fuzzy match entirely (~50% false positive rate for same-prefix adjacent-hour events).
- **Fix:** Change `AssignOccurrenceIndices` to count per-prefix (via `BuildTxPrefix`, excludes timeSlot). One-time migration (`MigrateOccurrenceScheme`) rebuilds seenTxHashes. SchemaVersion bump 1 → 2.
- **Risk:** High — changes ID generation for all new records. Cross-version peers handled by sender-wins normalization.
- **Full plan:** `~/.claude/plans/fix2-occurrence-counting.md`
- Tests: ~8 new (3 dedup + 5 migration)

---

## Phase 0b: Bug Fix Pass (v0.12.x)

Fix existing UI issues before building new features. These were the original v0.10.1–v0.10.3 items.

### v0.12.1 — Pagination fix
- Fix pagination controls in LedgerView.lua and UI.lua Gold Log
- Solution: Place pagination in a fixed-height SimpleGroup above ScrollFrame (not inside it)
- Page state already exists (`_ledgerCurrentPage`, `_goldLogCurrentPage`)
- Tests: ~4 new (page nav, boundaries, reset on filter change)

### v0.12.2 — Column widths + resize fix
- Widen clipping columns across all views
- Fix Flow layout recalculation on frame shrink
- Tests: ~2 regression tests

### v0.12.3 — UI test coverage
- Add `spec/ui/ledger_view_spec.lua` (pagination, sorting, column rendering)
- Add `spec/ui/sync_status_spec.lua` (peer list, audit trail)
- Tests: ~15 new — creates safety net before new UI tabs

---

## Phase 1: M6 — Export (v0.13.0)

### New files
- `Export.lua` — Format engine (CSV, Discord Markdown, BBCode)
- `UI/ExportFrame.lua` — AceGUI MultiLineEditBox modal with format picker
- `spec/export_spec.lua` — 13 tests

### Modified files
- `Core.lua` — Register Export module
- `UI/UI.lua` — Add Export button to Transactions/Gold Log filter bars
- `GuildBankLedger.toc` — Add new files

### Key implementation notes
- Reuse `ExtractItemName()` pattern from ConsumptionView.lua for item link stripping
- Discord split at 1900 chars (buffer below 2000 limit)
- CSV field quoting for commas/quotes/newlines
- Risk: **Low** — self-contained, no existing code refactored

### Tests (13)
- CSV: basic format, delimiter option, header toggle, field escaping (commas, quotes, newlines), empty dataset
- Discord: table format, 2000-char split, item link stripping, empty dataset
- BBCode: table tags, item link stripping
- Integration: export from filtered view, date format from profile

---

## Phase 2: M8a — Snapshots + Alerts (v0.14.0)

### New files
- `Snapshots.lua` — Capture from Scanner results, LibDeflate compress, diff engine
- `Alerts.lua` — Stock thresholds, chat + sound notifications, 1-hour cooldown
- `spec/snapshots_spec.lua` — 10 tests
- `spec/alerts_spec.lua` — 9 tests

### Modified files
- `Core.lua` — Register modules, hook bank close for auto-snapshot
- `UI/UI.lua` — Add Snapshots tab (list, select-two-to-diff, diff view)
- `GuildBankLedger.toc` — Add new files

### Snapshots implementation
- Capture slot data from Scanner.lua results (reuse existing scan infrastructure)
- Store compressed: `{ timestamp, tabData = { [tabIdx] = { [slotIdx] = { itemID, count } } } }`
- LibDeflate already available (used in Sync.lua)
- Diff engine: compare two snapshots → `{ added = {}, removed = {}, changed = {} }` per tab
- Storage: `guildData.snapshots` (AceDB default at Core.lua:25) — keep last 10, rotate oldest
- Auto-snapshot on bank close + on-demand via `/gbl snapshot`

### Alerts implementation
- Stock thresholds: `guildData.stockAlerts` (AceDB default at Core.lua:40)
- Check after each scan: compare inventory against thresholds
- Chat notification (`self:Print()`) + optional sound (`PlaySound()`)
- Cooldown: don't re-alert same item within 1 hour
- Risk: **Medium** — snapshot storage needs careful bounding

### Tests (19)
- Snapshots (10): capture, compression round-trip, diff (added/removed/changed), empty tabs, rotation, moved items, no-diff same state, tab-specific, timestamp ordering
- Alerts (9): threshold check, below triggers, above silent, cooldown, multiple items, chat notification, sound toggle, CRUD, disabled state

---

## Phase 3: M8b — Polish + Release (v1.0.0)

### Performance
- Memoize `C_Item.GetItemInfoInstant()` in Categories.lua
- Debounce rapid `RefreshUI()` calls (0.1s coalesce)
- Coroutine-sliced compaction in Storage.lua
- Lazy tab initialization (defer content build until first select)

### GBS integration
- Detect via `GetAddOnInfo("GuildBankSorter")`
- Pause tx recording during sort operations
- No-op if GBS not installed

### SavedVariables monitoring
- Startup check warning if >5MB
- `/gbl dbsize` command

### Documentation
- Full README rewrite (all features, commands, installation, CurseForge)
- CHANGELOG entries for all milestones
- ROADMAP mark all milestones complete

### Release
- Verify `.pkgmeta` externals
- Tag v1.0.0

### Tests (~8 new)
- Item cache hit/miss, debounce coalescing, GBS detection, dbsize command

---

## Deferred: Teams + Alts → v1.1.0

**Scope:** Raid team management (max 4), alt linking (manual + guild note auto-detect), team/alt-aggregated consumption

**Why deferred:** Highest-risk milestone — refactors ConsumptionView.lua (363 lines, 48 existing tests), cross-cutting alt aggregation. Not critical for v1.0.0 launch.

**AceDB defaults already scaffolded:** `teams = {}`, `altLinks = {}` at Core.lua:38-39

**Files planned:** `Teams.lua`, `Alts.lua`, `UI/TeamView.lua` + 24 tests

---

## Test Projections

| Phase | New Tests | Running Total |
|-------|-----------|---------------|
| v0.12.0 (current) | — | 433 |
| Phase 0b: Bug fixes + UI tests | ~21 | ~454 |
| Phase 1: Export | ~13 | ~467 |
| Phase 2: Snapshots/Alerts | ~19 | ~486 |
| Phase 3: Polish | ~8 | ~494 |

**Target: ~494 tests at v1.0.0**

---

## Verification

After each phase:
1. `busted --verbose` — all tests pass
2. `luacheck .` — clean
3. In-game smoke test per milestone audit checklist (in `docs/ROADMAP.md`)
4. At v1.0.0: full regression through all audit checklists, CurseForge packager test
