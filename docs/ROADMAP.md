# GuildBankLedger — Revised Roadmap

> Reordered 2026-04-07 based on officer priorities. Sync is the core value
> proposition — multiple officers scanning independently, data combined
> automatically so nothing is lost.

## Completed

- **M1 (v0.1.0)** — Scaffold + Scanner
- **M2 (v0.2.0)** — Ledger + Dedup + Categories + Storage
- **M3 (v0.3.0)** — UI (frame, ledger view, filters, consumption, minimap, accessibility)
- **Patches (v0.3.1–v0.3.3)** — Lib URL fixes, scroll overflow, interface version, sort indicators
- **M4 (v0.4.0)** — Consumption detail (click-to-expand breakdown, sortable headers, category filter, top item names, ledger column fix)
- **Patches (v0.4.1)** — Gold transaction recording fixes, Gold Log tab
- **M5 (v0.5.0)** — Multi-officer sync via AceComm (HELLO/SYNC_REQUEST/SYNC_DATA/ACK protocol, peer tracking, audit trail, Sync tab)

**Current state:** 405 tests, 14 production files, luacheck clean. (v0.11.0 — sync hash convergence via deterministic ID normalization)

---

## ~~M4: Consumption Detail + UI Polish (v0.4.0)~~ COMPLETE

**Goal:** Make the consumption tab actually useful for officers. Wire the
existing `GetPlayerItemBreakdown()` to the UI, add category grouping, and
fix the ledger view column layout.

**Why now:** The consumption tab exists but shows only raw numbers. Officers
need to see *what* players are taking, not just *how many*. This is 1-2
commits of wiring existing logic — not a new system.

### Deliverables

**Consumption tab improvements:**
- Click player row to expand per-item breakdown (uses existing `GetPlayerItemBreakdown()`)
- Show item links in breakdown (clickable for tooltip)
- Show category next to each item
- Top 3 items column shows actual item names, not just counts
- Add "Category" filter to consumption tab (reuse FilterBar logic)
- Sortable column headers (reuse `SortConsumptionSummary()`)

**Ledger view fixes:**
- Fix column widths to fit default frame size (720px usable)
- Sort arrow indicators (currently [asc]/[desc] text — keep as-is or use WoW-safe characters)

**Files modified:**
- `UI/UI.lua` — `RenderConsumptionTable()` rewritten to use click-to-expand
- `UI/ConsumptionView.lua` — Add rendering functions for breakdown rows
- `UI/LedgerView.lua` — Adjust column widths

**Tests:**
- `spec/ui/consumption_spec.lua` — Add tests for breakdown rendering data
- Verify existing 152 tests still pass

### Audit Checklist (v0.4.0)
- [ ] `/gbl` → Consumption tab → click a player → item breakdown expands
- [ ] Breakdown shows item name, category, withdrawn count, deposited count
- [ ] Click player again → breakdown collapses
- [ ] Sorting works on all columns
- [ ] Category filter works on consumption tab
- [ ] Ledger view columns don't overflow frame at default 800px width
- [ ] All tests pass (`busted --verbose`)
- [ ] Luacheck clean

---

## ~~M5: Sync (v0.5.0)~~ COMPLETE

**Goal:** Multi-officer transaction sync via AceComm. Two officers scan the
bank at different times → their data merges automatically with no
duplicates. This is the reason this addon exists.

**Why now:** The dedup engine (M2) already solves the hard problem — merging
transactions from different officers with hour-level timestamp drift. Sync
is the transport layer: serialize, send, receive, dedup.

### Architecture

**Protocol:** AceComm addon channel, prefix `"GBLSync"`

**Message types:**
| Type | Direction | Purpose |
|------|-----------|---------|
| `HELLO` | Broadcast | "I'm online, here's my version + tx count + last scan time" |
| `SYNC_REQUEST` | Targeted | "Send me transactions newer than timestamp X" |
| `SYNC_RESPONSE` | Targeted | Chunked transaction data (200 tx per message) |
| `ACK` | Targeted | "Got your chunk, send next" / "Done" |
| `FULL_SYNC` | Targeted | "Send me everything" (first-time setup) |

**Flow:**
1. On login / bank close: broadcast `HELLO` with version, guild, tx count, last scan time
2. Receiving officer compares tx counts — if remote has more, send `SYNC_REQUEST`
3. Sender serializes + compresses transactions via AceSerializer + LibDeflate
4. Receiver deserializes, runs each tx through `IsDuplicate()` (M2 dedup engine)
5. New transactions stored via `StoreTx()` (M2 ledger)
6. Sync status updated in `db.global.guilds[guild].syncState`

**Conflict resolution:** Already handled by dedup — same tx from two officers
produces the same hash, second copy is dropped. For true conflicts (same
player, same item, same count, same hour), most recent `scanTime` wins.

### Files to Create

| File | Purpose |
|------|---------|
| `Sync.lua` | AceComm message handling, serialization, chunked send/receive, peer tracking |
| `UI/SyncStatus.lua` | Sync tab in main frame: enable toggle, peer list, last sync time, audit trail |

### Files Modified

| File | Changes |
|------|---------|
| `Core.lua` | Register AceComm, call `InitSync()` on enable, broadcast HELLO on bank close |
| `GuildBankLedger.toc` | Add `Libs\AceComm-3.0`, `Libs\AceSerializer-3.0`, `Sync.lua`, `UI\SyncStatus.lua` |
| `.pkgmeta` | Add AceComm-3.0, AceSerializer-3.0 externals (already listed) |
| `fetch-libs.sh` | Add AceComm-3.0, AceSerializer-3.0 to Ace3 subfolder list |
| `UI/UI.lua` | Add "Sync" tab to TabGroup |

### Key Functions

```lua
-- Sync.lua
GBL:InitSync()                          -- Register AceComm, start HELLO timer
GBL:BroadcastHello()                    -- Send version + tx count to guild channel
GBL:HandleHello(sender, data)           -- Compare counts, request sync if behind
GBL:RequestSync(target, sinceTimestamp) -- Ask for new transactions
GBL:HandleSyncRequest(sender, data)     -- Serialize + chunk + send response
GBL:HandleSyncResponse(sender, data)    -- Deserialize, dedup, store new tx
GBL:SendChunked(target, transactions)   -- Split into 200-tx messages with ACK flow
GBL:GetSyncStatus()                     -- Return peer list, last sync, version
GBL:GetAuditTrail()                     -- Return log of sync events
```

### Libraries Needed

- `AceComm-3.0` — addon-to-addon communication (already in Ace3 repo)
- `AceSerializer-3.0` — table serialization (already in Ace3 repo)
- `LibDeflate` — compression (needs new fetch — check GitHub availability)
- `ChatThrottleLib` — rate limiting (bundled with AceComm or standalone)

### Edge Cases

1. **Version mismatch** — Officers on different addon versions. Compare version in HELLO, warn if major differs, refuse sync if incompatible schema.
2. **Large initial sync** — First officer to install has 0 tx, other has 5000. Chunk at 200 tx/msg with 0.5s delay. Show progress bar in sync tab.
3. **Officer demoted mid-sync** — Validate guild rank on each received message. Drop messages from non-officers.
4. **Sync loop** — Only broadcast locally-scanned data (flag `scannedBy` field). Never re-broadcast received data.
5. **SavedVariables bloat** — `GetStorageStats()` already exists. Warn in sync tab if approaching 5MB.
6. **Addon channel throttle** — ChatThrottleLib handles WoW's rate limits. AceComm uses it internally.
7. **Player offline mid-sync** — ACK timeout (10s). Abort and retry on next HELLO.
8. **Multiple guilds** — Sync is per-guild namespace. HELLO includes guild name. Ignore messages from other guilds.

### Tests (spec/sync_spec.lua — 16 tests)

1. HELLO message serializes version + tx count + last scan time
2. HELLO message deserializes correctly
3. HandleHello triggers SYNC_REQUEST when remote has more tx
4. HandleHello does nothing when counts are equal
5. SYNC_REQUEST includes correct sinceTimestamp
6. HandleSyncRequest serializes transactions newer than requested time
7. HandleSyncResponse runs each tx through IsDuplicate
8. HandleSyncResponse stores non-duplicate tx via StoreTx
9. Duplicate tx in sync response is dropped (dedup works)
10. Conflict resolution: most recent scanTime wins
11. Version mismatch warning (different major version)
12. Non-officer message rejected
13. Peer list updated on HELLO receive
14. Audit trail records sync events
15. Chunked send splits at 200 tx boundary
16. Empty sync (no new tx) completes cleanly

### Accessibility

- Sync status tab: text labels ("Connected", "Syncing...", "Error") alongside color
- Peer list: keyboard-navigable
- Audit trail: structured text, not color-coded
- "Force Full Sync" button: confirm dialog, keyboard-accessible

### Audit Checklist (v0.5.0)
- [ ] Two characters in same guild, both with addon installed
- [ ] Character A scans bank → transactions recorded
- [ ] Character B logs in → receives HELLO from A (or vice versa)
- [ ] Character B opens bank → scans → broadcasts HELLO
- [ ] Character A receives sync → new transactions merged without duplicates
- [ ] `/gbl` → Sync tab shows peer list with last sync time
- [ ] Audit trail shows sync events
- [ ] Verify dedup: same transaction from both characters = 1 record, not 2
- [ ] Version mismatch: one character on different version → warning shown
- [ ] All tests pass (`busted --verbose`)
- [ ] Luacheck clean

---

## M6: Export (v0.6.0)

**Goal:** Get data out of the addon. CSV for spreadsheets, Markdown tables
for Discord, BBCode for forums. Officers need to share reports with the
guild.

**Why now:** With sync working, officers have complete data. Now they need
to share it outside the game.

### Files to Create

| File | Purpose |
|------|---------|
| `Export.lua` | Format transactions/consumption as CSV, Discord Markdown, BBCode |
| `UI/ExportFrame.lua` | Modal with format picker, data picker, EditBox for copy-paste |

### Key Functions

```lua
GBL:ExportTransactionsCSV(filters)      -- Filtered tx as CSV string
GBL:ExportConsumptionCSV(dateRange)     -- Player summaries as CSV
GBL:ExportForDiscord(filters)           -- Markdown table, split at 2000 chars
GBL:ExportForForums(filters)            -- BBCode table
GBL:ShowExportFrame(dataType, format)   -- Open modal with output
```

### Edge Cases

1. Item links in CSV → strip color codes, output `[ItemName] (ID:12345)`
2. Commas in item names → proper CSV quoting
3. Discord 2000-char limit → split with `(1/3)` headers
4. Empty result set → "No data to export" message
5. Very large export (>10k rows) → row limit option with warning
6. EditBox character limit → truncate with count and warning

### Tests (spec/export_spec.lua — 13 tests)

1. CSV header row correct
2. CSV data row formatting
3. CSV delimiter configurable
4. CSV field escaping (commas, quotes)
5. Color code stripping from item links
6. Discord Markdown table format
7. Discord 2000-char split produces correct part headers
8. BBCode table format
9. Consumption CSV includes all summary columns
10. Empty data returns message, not empty string
11. Filter applied before export
12. Row count matches filter count
13. Large export truncation with warning

### Accessibility

- EditBox keyboard-focusable
- "Ctrl+A then Ctrl+C" instruction always visible as text
- Format dropdown keyboard-navigable
- Export output is plain text (no color-dependent formatting)

### Audit Checklist (v0.6.0)
- [ ] `/gbl` → Export button visible on Transactions and Consumption tabs
- [ ] Export transactions as CSV → paste into spreadsheet → columns align
- [ ] Export for Discord → paste in Discord → table renders correctly
- [ ] Export for Discord with >2000 chars → splits into multiple parts
- [ ] Export consumption summary → player totals correct
- [ ] Empty filter result → "No data to export" message
- [ ] All tests pass
- [ ] Luacheck clean

---

## M7: Teams + Alts (v0.7.0)

**Goal:** Group players into raid teams (up to 4), link alts to mains,
view consumption aggregated by team and by main character.

**Why now:** With sync and export working, officers have complete, shareable
data. Now they need to organize it by team structure.

### Files to Create

| File | Purpose |
|------|---------|
| `Teams.lua` | Team CRUD, player assignment, per-team consumption |
| `Alts.lua` | Alt-main linking (manual + guild note auto-detect), aggregated consumption |
| `UI/TeamView.lua` | Team management tab: team list, member list, alt suggestions |

### Key Functions

```lua
-- Teams.lua
GBL:CreateTeam(name, color)             -- Max 4 teams
GBL:DeleteTeam(id)                      -- Unassigns all members
GBL:AssignPlayerToTeam(name, id)
GBL:GetPlayerTeam(name)                 -- Checks alts too
GBL:GetTeamConsumption(id, dateRange)   -- Aggregate for team members
GBL:GetUnassignedPlayers()

-- Alts.lua
GBL:LinkAlt(main, alt)                  -- Prevents circular links
GBL:UnlinkAlt(main, alt)
GBL:GetMain(name)                       -- Returns main or self
GBL:GetAlts(main)                       -- Returns alt list
GBL:ParseGuildNotes()                   -- Auto-detect "alt of X" patterns
GBL:SuggestAltLinks()                   -- Returns suggestions with confidence
GBL:GetAggregatedConsumption(main, dateRange)  -- Main + all alts combined
```

### Edge Cases

1. Circular alt links (A→B→A) → prevent in `LinkAlt()`
2. Player leaves guild → keep data, mark "(left)"
3. Alt linked to non-existent main → validate on link
4. "I'm not an alt" guild note matching "alt of" → negative pattern exclusion
5. Team deletion with members → unassign all, no data loss
6. Player in transactions but not in roster → show as "unknown"

### Tests

- `spec/teams_spec.lua` (11 tests): CRUD, max 4 limit, assign/reassign, team consumption, unassigned list
- `spec/alts_spec.lua` (13 tests): link/unlink, GetMain, circular prevention, note pattern detection, case insensitivity, aggregated consumption

### Accessibility

- Team colors paired with pattern indicators (stripe, dot, diamond, star)
- Alt suggestions include text descriptions
- Team member list keyboard-navigable

### Audit Checklist (v0.7.0)
- [ ] `/gbl` → Teams tab visible
- [ ] Create team "Team 1" with color → appears in list
- [ ] Assign players to team → consumption view shows team totals
- [ ] Link an alt → consumption aggregates under main
- [ ] Guild note parsing suggests alt links → accept/reject works
- [ ] Delete team → players become unassigned, no data lost
- [ ] Circular alt link → prevented with error message
- [ ] Max 4 teams → 5th creation fails with message
- [ ] All tests pass
- [ ] Luacheck clean

---

## M8: Snapshots + Alerts + Polish + Release (v1.0.0)

**Goal:** Inventory snapshots with diff, stock level alerts, performance
optimization, Guild Bank Sort integration, and CurseForge release.

**Why now:** All core features are complete. This is the polish and
nice-to-have layer before public release.

### Deliverables

**Snapshots:**
- `Snapshots.lua` — Serialize bank state, compress with LibDeflate, store
- Diff two snapshots: added/removed/count changed items
- Auto-snapshot on bank close (throttled to 1/hour)
- Prune old snapshots (keep max 50)
- UI: Snapshot list, select two to diff, diff view

**Alerts:**
- `Alerts.lua` — Set minimum stock level per item
- Check after scan, fire chat + sound notification if below threshold
- Re-arm when stock recovers above threshold
- Never sound alone (always text + sound per accessibility)

**Guild Bank Sort integration:**
- Detect GBS addon via `OptionalDeps`
- Pause tx recording during sort (pre-sort snapshot → post-sort snapshot → single "Sort" meta-tx)
- No-op if GBS not installed

**Performance:**
- Cache `C_Item.GetItemInfoInstant` results
- Debounce rapid UI refreshes (0.1s)
- Coroutine-sliced compaction for large datasets
- Lazy UI tab creation (only build tab content on first view)
- Warn if SavedVariables approaching 5MB

**CurseForge release:**
- `X-Curse-Project-ID` in .toc
- Verify `.pkgmeta` ignore section
- Final README with installation instructions
- Tag v1.0.0

### Libraries Needed

- `LibDeflate` — compression for snapshots (and sync in M5)

### Tests

- `spec/snapshots_spec.lua` (10 tests): capture, compress/decompress round-trip, diff, pruning, throttle
- `spec/alerts_spec.lua` (9 tests): set/remove, fire below min, re-arm above, multiple independent

### Audit Checklist (v1.0.0)
- [ ] Open bank → snapshot taken automatically
- [ ] `/gbl` → Snapshots tab → list of snapshots with timestamps
- [ ] Select two snapshots → diff shows added/removed/changed items
- [ ] Set stock alert for Flask of Power at min 20
- [ ] Scan with <20 flasks → chat notification fires
- [ ] Scan with >20 flasks → alert re-armed (no notification)
- [ ] With GBS installed: sort bank → single "Sort" entry in ledger, not 98 individual moves
- [ ] Without GBS: no errors, no GBS-related UI
- [ ] SavedVariables <5MB after extended use
- [ ] UI opens in <500ms, subsequent opens <100ms
- [ ] `.pkgmeta` packages correctly (test with CurseForge packager if available)
- [ ] All tests pass
- [ ] Luacheck clean
- [ ] `v1.0.0` tag created

---

## Dependency Graph (Revised)

```
M1 (v0.1.0) ── M2 (v0.2.0) ── M3 (v0.3.0) ── M4 (v0.4.0) ── M5 (v0.5.0)
                                                                    │
                                                    M6 (v0.6.0) ───┤
                                                    M7 (v0.7.0) ───┤
                                                    M8 (v1.0.0) ───┘
```

M4-M5 are sequential (consumption detail feeds into sync UI).
M6, M7, M8 can parallel after M5 but benefit from ordering shown.

## Library Additions Per Milestone

| Milestone | New Libraries |
|-----------|--------------|
| M1 | LibStub, CallbackHandler, AceAddon, AceDB, AceConsole, AceEvent |
| M2 | (none) |
| M3 | AceGUI, AceConfig, AceConfigDialog, AceConfigCmd, LibDBIcon, LibDataBroker |
| M4 | (none) |
| M5 | AceComm, AceSerializer, LibDeflate, ChatThrottleLib |
| M6 | (none) |
| M7 | (none) |
| M8 | (LibDeflate if not added in M5) |

## Test Budget

| Milestone | New Tests | Running Total |
|-----------|-----------|---------------|
| M1 | 20 | 20 |
| M2 | 54 | 74 |
| M3 | 78 | 152 |
| M4 | 21 | 173 |
| M5 | 68 | 241 |
| M6 | ~13 | ~191 |
| M7 | ~24 | ~215 |
| M8 | ~19 | ~234 |
