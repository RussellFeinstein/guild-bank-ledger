# GuildBankLedger -- Implementation Plan

## Context

WoW's guild bank log stores only **25 entries per tab**, which rolls over in minutes for a 90+ raider guild with 3 raid teams. Officers have zero visibility into who's consuming what. GuildBankLedger persistently logs all guild bank transactions, provides per-player consumption tracking, item categorization, raid team management, and multi-officer sync.

**Repo**: `/home/russellfeinstein/GitHub/guild-bank-ledger` (git init, zero commits)
**Remote**: `RussellFeinstein/guild-bank-ledger`
**Stack**: Lua 5.1, Ace3, busted, CurseForge distribution
**Companion**: Guild Bank Sort addon (by Bisse) -- integration planned for M5

### Critical API Facts

- **GUILDBANKFRAME_OPENED/CLOSED removed in 10.0.2** -- use `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` with `Enum.PlayerInteractionType.GuildBanker`
- `GetGuildBankTransaction(tab, i)` returns: type, name, itemLink, count, tab1, tab2, **year, month, day, hour** (RELATIVE offsets, not absolute timestamps -- must compute absolute via `GetServerTime() - offset`)
- `QueryGuildBankLog(tab)` MUST be called before reading transactions; `QueryGuildBankTab(tab)` MUST be called before reading slots
- Use `GetServerTime()` never `time()` or `os.time()`
- Use numeric `classID`/`subclassID` via `C_Item.GetItemInfoInstant()`, never localized strings
- `GetGuildBankItemLink(tab, slot)` for item data (not `GetGuildBankItemInfo` for itemID)
- `MAX_GUILDBANK_SLOTS_PER_TAB = 98`
- Money log: `QueryGuildBankLog(GetNumGuildBankTabs() + 1)`
- Compression: LibDeflate (3.15-3.71x ratio) >> LibCompress

### Market Gaps We Fill

1. No addon does comprehensive per-player consumption tracking with statistics/trends
2. No addon aggregates multi-officer scan data with conflict resolution
3. No addon integrates with Guild Bank Sort
4. No addon has accessibility-first design (colorblind, keyboard nav, font scaling)

---

## Directory Structure (Final State)

```
guild-bank-ledger/
  GuildBankLedger.toc
  .pkgmeta
  .luacheckrc
  .gitignore
  .busted
  CLAUDE.md
  README.md
  CHANGELOG.md
  VERSION
  LICENSE
  Core.lua                 -- AceAddon bootstrap, lifecycle, slash commands, bank open/close
  Scanner.lua              -- Guild bank slot scanning (inventory snapshots)
  Ledger.lua               -- Transaction recording from GetGuildBankTransaction
  Dedup.lua                -- Deduplication engine (hour-bucket fuzzy matching)
  Categories.lua           -- Item classification via classID/subclassID
  Storage.lua              -- Tiered storage, pruning, compaction
  Teams.lua                -- Raid team assignment
  Alts.lua                 -- Alt linking (manual + guild note parsing)
  Snapshots.lua            -- Periodic inventory snapshots + LibDeflate compression
  Alerts.lua               -- Stock level alerts
  Export.lua               -- CSV and formatted text generation
  Sync.lua                 -- Multi-officer AceComm sync
  UI/
    UI.lua                 -- Main frame, AceGUI-based, tab switching
    LedgerView.lua         -- Scrolling transaction list
    FilterBar.lua          -- Filter/search controls
    ConsumptionView.lua    -- Per-player consumption summary
    TeamView.lua           -- Per-team consumption reports
    SnapshotView.lua       -- Snapshot diff viewer
    SyncStatus.lua         -- Multi-officer sync status
    ExportFrame.lua        -- CSV/text export with copy-to-clipboard
    Accessibility.lua      -- Colorblind mode, font scaling, keyboard nav helpers
  Libs/                    -- (externals via .pkgmeta, gitignored)
    LibStub/ CallbackHandler-1.0/ AceAddon-3.0/ AceDB-3.0/ AceDBOptions-3.0/
    AceConsole-3.0/ AceEvent-3.0/ AceComm-3.0/ AceSerializer-3.0/
    AceGUI-3.0/ AceConfig-3.0/ AceConfigDialog-3.0/ AceConfigCmd-3.0/
    LibDeflate/ LibDBIcon-1.0/ LibDataBroker-1.1/ LibSharedMedia-3.0/
    ChatThrottleLib/
  spec/
    mock_wow.lua           -- WoW API mock environment for busted
    mock_ace.lua           -- Ace3 library mocks
    helpers.lua            -- Shared test utilities
    core_spec.lua
    scanner_spec.lua
    ledger_spec.lua
    dedup_spec.lua
    categories_spec.lua
    storage_spec.lua
    teams_spec.lua
    alts_spec.lua
    snapshots_spec.lua
    alerts_spec.lua
    export_spec.lua
    sync_spec.lua
    ui/
      filter_spec.lua
      consumption_spec.lua
```

---

## AceDB Schema

```lua
local defaults = {
    global = {
        guilds = {
            ["*"] = {  -- keyed by guild name
                transactions = {},         -- array of tx records
                moneyTransactions = {},    -- array of money tx records
                dailySummaries = {},       -- keyed by "YYYY-MM-DD"
                weeklySummaries = {},      -- keyed by "YYYY-Wxx"
                snapshots = {},            -- array of {timestamp, compressedData}
                playerStats = {
                    ["*"] = {              -- keyed by player name
                        withdrawals = {}, deposits = {},
                        totalWithdrawCount = 0, totalDepositCount = 0,
                        moneyWithdrawn = 0, moneyDeposited = 0,
                        firstSeen = 0, lastSeen = 0,
                    },
                },
                teams = {},                -- up to 4: {name, color={r,g,b}, members={}}
                altLinks = {},             -- mainName -> {altName1, ...}
                stockAlerts = {},          -- itemID -> {min=N, notified=false}
                seenTxHashes = {},         -- hash -> timestamp (pruned on compaction)
                syncState = { lastSyncTimestamp = 0, syncVersion = 0, peers = {} },
                schemaVersion = 1,
            },
        },
    },
    profile = {
        minimap = { hide = false },
        ui = { scale = 1.0, width = 800, height = 600,
               font = "Fonts\\FRIZQT__.TTF", fontSize = 12,
               colorblindMode = false, highContrast = false, lockFrame = false },
        scanning = { autoScan = true, scanDelay = 0.5, notifyOnScan = true },
        alerts = { enabled = true, chatNotify = true, soundNotify = true },
        export = { delimiter = ",", includeHeaders = true, dateFormat = "%Y-%m-%d %H:%M" },
        sync = { enabled = false, autoSync = true },
        filters = { defaultDays = 7, defaultCategory = "ALL" },
    },
}
```

### Transaction Record Schema

```lua
-- Item transaction
{ id="hash", type="withdraw"|"deposit"|"move", player="Name",
  itemLink="|cff...|r", itemID=12345, count=5, tab=2, destTab=nil,
  classID=0, subclassID=5, category="flask",
  timestamp=1711700000, scanTime=1711700500, scannedBy="OfficerName" }

-- Money transaction
{ id="hash", type="deposit"|"withdraw"|"repair"|"buyTab"|"depositSummary",
  player="Name", amount=50000, timestamp=1711700000,
  scanTime=1711700500, scannedBy="OfficerName" }
```

---

## Milestone 1: v0.1.0 -- Scaffold + Scanner

**Goal**: Project skeleton with working AceAddon lifecycle, event registration, guild bank open/close detection, slot-level scanning, slash commands, and full test infrastructure.

### Files to Create

| File | Purpose |
|------|---------|
| `GuildBankLedger.toc` | Addon metadata, `## Interface: 110105`, `## SavedVariables: GuildBankLedgerDB`, lib load order |
| `.pkgmeta` | CurseForge packaging config with externals (LibStub, CallbackHandler, Ace libs) |
| `.luacheckrc` | Lua linting: `std = "lua51"`, WoW globals whitelist, exclude `Libs/` |
| `.busted` | Test runner config: `lpath = "?.lua;spec/?.lua"`, pattern = `_spec` |
| `.gitignore` | Ignore `Libs/`, `*.zip`, `.DS_Store` |
| `VERSION` | `0.1.0` |
| `CLAUDE.md` | Project-specific instructions (API gotchas, test commands, conventions) |
| `README.md` | Project description, installation, usage |
| `CHANGELOG.md` | Initial changelog |
| `LICENSE` | MIT |
| `Core.lua` | AceAddon bootstrap, OnInitialize/OnEnable/OnDisable, bank open/close via `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`, slash commands `/gbl` and `/guildbankledger` |
| `Scanner.lua` | `StartFullScan()`, `ScanTab(tabIndex)`, `ScanNextTab()`, `FinalizeScan()` -- reads all 98 slots per viewable tab via `GetGuildBankItemLink`/`GetGuildBankItemInfo`, chains tabs with `C_Timer.After(scanDelay)` |

### Key Functions

```lua
-- Core.lua
GBL:OnInitialize()                    -- AceDB:New, register slash commands
GBL:OnEnable()                        -- Register events
GBL:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(event, type) -- bank open detection
GBL:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(event, type) -- bank close detection
GBL:OnBankOpened()                    -- set state, trigger scan
GBL:OnBankClosed()                    -- cancel pending timers
GBL:IsBankOpen()                      -- return self.bankOpen
GBL:GetGuildName()                    -- GetGuildInfo("player")
GBL:HandleSlashCommand(input)         -- "scan", "status", "config", "help"
GBL:PrintStatus()                     -- version, guild, tx count, last scan

-- Scanner.lua
GBL:StartFullScan()                   -- init scan state, query first tab
GBL:ScanTab(tabIndex)                 -- read 98 slots, store results
GBL:ScanNextTab()                     -- advance to next viewable tab
GBL:FinalizeScan()                    -- store snapshot, notify, fire callback
GBL:GUILDBANKBAGSLOTS_CHANGED()       -- confirm tab data ready
```

### Events Registered

| Event | Purpose |
|-------|---------|
| `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` | Detect guild bank open (check `Enum.PlayerInteractionType.GuildBanker`) |
| `PLAYER_INTERACTION_MANAGER_FRAME_HIDE` | Detect guild bank close |
| `GUILDBANKBAGSLOTS_CHANGED` | Tab data ready after `QueryGuildBankTab` |
| `GUILDBANK_UPDATE_TABS` | Tab list changed |
| `GUILD_ROSTER_UPDATE` | Guild membership changes |

### Edge Cases

1. Player not in a guild (`GetGuildInfo` returns nil) -- guard all operations
2. Bank opened with no viewable tabs -- `isViewable = false`, skip those tabs
3. Bank closed mid-scan -- cancel `C_Timer.After` callbacks, set `scanInProgress = false`
4. Server throttle on `QueryGuildBankTab` -- use `GUILDBANKBAGSLOTS_CHANGED` as confirmation
5. `Enum.PlayerInteractionType.GuildBanker` may not exist on Classic -- guard with `if Enum and Enum.PlayerInteractionType`
6. Empty slots (nil texture) -- skip
7. Locked items (being moved) -- skip or retry
8. AceDB profile reset -- handle `OnProfileChanged`/`OnProfileCopied`/`OnProfileReset`

### Tests

**`spec/mock_wow.lua`**: `MockGuildBank` table with configurable tabs/slots, mock `GetServerTime()`, `GetGuildBankItemLink()`, `GetGuildBankItemInfo()`, `GetGuildBankTabInfo()`, `C_Timer.After()` (immediate), `Enum.PlayerInteractionType.GuildBanker`, `CreateFrame()` stub, `print()` capture

**`spec/mock_ace.lua`**: `LibStub` mock, `AceAddon-3.0:NewAddon()`, `AceDB-3.0:New()`, `AceEvent-3.0` Register/Unregister/SendMessage stubs

**`spec/helpers.lua`**: `makeItemLink(itemID, name, quality)`, `populateTab(tabIndex, items)`, `resetMocks()`, `capturedPrints()`

**`spec/core_spec.lua`** (10 tests):
- Addon initializes without error
- AceDB created with correct SavedVariables name
- Slash commands registered
- Bank open/close detected via correct events
- Non-GuildBanker interaction types ignored
- `IsBankOpen()` correct state
- `GetGuildName()` nil when not in guild
- Slash "status" prints version/guild
- Slash "help" prints usage

**`spec/scanner_spec.lua`** (10 tests):
- Full scan reads all slots from all viewable tabs
- Empty slots skipped
- Non-viewable tabs skipped
- Correct item counts per tab
- Bank closing mid-scan cancels gracefully
- `QueryGuildBankTab` called for each tab
- Results include tab, slot, itemLink, count, quality
- Single tab scan works
- Zero tabs returns empty
- Locked items handled

### Accessibility (M1)
- Chat output: yellow headers + white data (pass contrast against dark chat)
- No color-only information -- always text labels
- Slash help structured with clear command/description pairs

---

## Milestone 2: v0.2.0 -- Ledger + Dedup + Categories

**Goal**: Record transactions, deduplicate across officers, categorize items, track money, implement tiered storage.

### Files to Create

| File | Purpose |
|------|---------|
| `Ledger.lua` | `ScanTransactions()`, `ReadTabTransactions(tab)`, `ReadMoneyTransactions()`, `ComputeAbsoluteTimestamp(y,m,d,h)` (CRITICAL: relative offsets to absolute), `CreateTxRecord()`, `StoreTx()`, `UpdatePlayerStats()` |
| `Dedup.lua` | `ComputeTxHash(record)` (hour-bucket key: `type|player|itemID|count|tab|timeSlot`), `IsDuplicate(record)` (checks 3 adjacent hour slots for drift tolerance), `MarkSeen()`, `PruneSeenHashes(maxAge)` |
| `Categories.lua` | `CATEGORY_MAP` (classID -> subclassID -> category), `CategorizeItem(classID, subclassID)`, `GetItemCategory(itemID)` via `C_Item.GetItemInfoInstant`, `GetCategoryDisplayName()`, `GetAllCategories()` |
| `Storage.lua` | `RunCompaction()`, `CompactToDailySummaries()` (30d+), `CompactToWeeklySummaries()` (90d+), `GetStorageStats()`, `EstimateStorageSize()`, `PurgeOldData(daysToKeep)` |

### Dedup Strategy

The API only has hour-level precision. Two officers scanning 45min apart get different computed timestamps for the same tx. Solution:
- Hash key: `type|player|itemID|count|tab|floor(timestamp/3600)`
- `IsDuplicate` checks **3 adjacent hour slots** (timeSlot-1, timeSlot, timeSlot+1)
- Known limitation: same player depositing same item+count in same tab within same hour = false positive (accepted; hour precision is all the API gives)

### Tiered Storage

- **0-30 days**: Full transaction records
- **30-90 days**: Daily summaries (aggregated per day: item counts, player counts, money totals)
- **90+ days**: Weekly summaries (aggregated per ISO week)
- Estimated steady state: ~2.4 MB
- Compaction runs on bank open, guarded against running mid-scan

### Edge Cases

1. Relative timestamp drift between officers (~45min) -- 3-hour-slot dedup handles it
2. Same player, same item, same count, same hour -- accepted false positive
3. Item not in cache (`C_Item.GetItemInfoInstant` nil) -- queue async, return "UNKNOWN", retry on `ITEM_DATA_LOAD_RESULT`
4. Very old transactions (year > 0) -- handle gracefully
5. Tab with 0 transactions -- skip
6. Compaction during scan -- guard with `scanInProgress` check
7. All money tx types: "deposit", "withdraw", "repair", "buyTab", "depositSummary"
8. Guild name changes -- new namespace (documented limitation)

### Tests

**`spec/ledger_spec.lua`** (10 tests): timestamp computation, itemID extraction from links, move transactions, storage into correct guild namespace, playerStats increment for withdrawals/deposits, firstSeen/lastSeen, money transactions, full tab processing

**`spec/dedup_spec.lua`** (10 tests): identical tx duplicate, 30-min drift duplicate, 2-hour drift not duplicate, hour-boundary adjacent-slot detection, different player not duplicate, different item/count/tab not duplicate, `PruneSeenHashes` removes old/preserves recent

**`spec/categories_spec.lua`** (12 tests): flask/potion/food/herb/ore/gem/weapon/armor classification, unknown classID, wildcard subclass, `GetAllCategories` sorted, profession items (classID=19)

**`spec/storage_spec.lua`** (11 tests): within-30d not compacted, older compacted to daily, daily aggregation correct, daily->weekly at 90d, compacted records removed, stats accurate, purge works, idempotent compaction, empty list safe

---

## Milestone 3: v0.3.0 -- UI

**Goal**: Full GUI with scrolling transaction list, filter/search, per-player consumption, minimap button. Accessible design: keyboard nav, colorblind-safe, font scaling.

### Files to Create

| File | Purpose |
|------|---------|
| `UI/UI.lua` | Main AceGUI Frame, tab switching (Transactions/Consumption), resize/position save, Escape closes, `ToggleMainFrame()`, `RefreshUI()` |
| `UI/LedgerView.lua` | Scroll frame with columns: Timestamp, Player, Action, Item, Count, Category, Tab. Sortable headers. Item links show tooltips. Virtual scroll for 10k+ records |
| `UI/FilterBar.lua` | Search box, date range (7d/30d/custom), category dropdown, tx type, player dropdown, tab dropdown, reset button. All AND-combined. Tab-key navigation between controls |
| `UI/ConsumptionView.lua` | Table: Player, Total Withdrawn, Total Deposited, Net, Top Items, Last Active. Sortable. Click to expand per-item breakdown |
| `UI/Accessibility.lua` | Colorblind-safe palette, shape+color+text triple encoding, `GetColorblindMode()` (reads CVar), `GetAccessibleColor()`, `CreateAccessibleIcon()`, `SetupKeyboardNav()`, `GetScaledFont()` |
| Core.lua additions | `SetupMinimapButton()` via LibDBIcon + LibDataBroker |

### Accessibility Design

```lua
GBL.A11Y = {
    COLORS = {  -- Pass 4.5:1 contrast, work with all 3 WoW colorblind modes
        WITHDRAW = {r=0.9, g=0.3, b=0.3},  DEPOSIT = {r=0.3, g=0.8, b=0.4},
        MOVE = {r=0.3, g=0.5, b=0.9},      ALERT = {r=1.0, g=0.7, b=0.0},
    },
    ICONS = {  -- Shape indicators (never color alone)
        WITHDRAW = "Interface\\BUTTONS\\UI-GroupLoot-Pass-Up",    -- down arrow
        DEPOSIT  = "Interface\\BUTTONS\\UI-GroupLoot-Coin-Up",    -- up arrow
        MOVE     = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up",  -- horizontal
    },
}
```

- Every interactive element reachable via Tab key
- Focus indicator: 2px bright yellow border
- Transaction type: shape + color + text label (triple encoding)
- All icon buttons have tooltip text
- Font size adjustable 8-24pt
- High contrast mode option
- Category dropdown: text labels, not color swatches

### Edge Cases
1. 10k+ records -- virtual scrolling (only render visible + buffer)
2. Item links not in cache -- show itemID as fallback
3. Frame scaling -- respect `UIParent:GetEffectiveScale()`
4. Zero filter results -- "No transactions match" message
5. Non-ASCII player names -- raw string comparison
6. Font scaling extremes -- clamp 8-24pt
7. Resolution changes -- re-anchor on `DISPLAY_SIZE_CHANGED`

### Tests

**`spec/ui/filter_spec.lua`** (11 tests): player name exact/partial, date range, category, tx type, tab, combined filters, reset, empty search, zero results

**`spec/ui/consumption_spec.lua`** (9 tests): withdrawal/deposit aggregation, net calculation, top 3 items, sorting by column, date range filtering, deposits-only/withdrawals-only players

---

## Milestone 4: v0.4.0 -- Teams + Alts

**Goal**: Raid team assignment (up to 4 teams), alt linking (manual + guild note parsing), per-team reports, alt-aggregated consumption.

### Files to Create

| File | Purpose |
|------|---------|
| `Teams.lua` | `CreateTeam(name, color)`, `DeleteTeam(id)`, `AssignPlayerToTeam(name, id)`, `GetPlayerTeam(name)` (checks alts), `GetTeamConsumption(id, dateRange)`, `GetUnassignedPlayers()` |
| `Alts.lua` | `LinkAlt(main, alt)`, `UnlinkAlt(main, alt)`, `GetMain(name)`, `GetAlts(main)`, `ParseGuildNotes()`, `DetectAltPatterns(noteText)` (matches "alt of X", "Main: X", "X's alt"), `SuggestAltLinks()` (returns suggestions with confidence), `GetAggregatedConsumption(main, dateRange)` |
| `UI/TeamView.lua` | Left panel: team list with CRUD. Right panel: member list + consumption. Alt linking section with detected suggestions |

### Edge Cases
1. Player leaves guild -- keep data, mark "(left)"
2. Alt linked to non-existent main -- validate
3. Circular alt links (A alt of B, B alt of A) -- prevent in `LinkAlt`
4. "I'm not an alt" matching "alt of" -- negative pattern exclusion
5. Team deletion with members -- confirm dialog, unassign all
6. Player in transactions but not roster -- show as "unknown" guild status

### Tests

**`spec/teams_spec.lua`** (11 tests): create/delete/rename, MAX_TEAMS limit, assign/reassign/remove, team consumption aggregation, unassigned players list

**`spec/alts_spec.lua`** (13 tests): link/unlink, GetMain for alt/main/unknown, GetAllCharacters, circular prevention, pattern detection ("alt of X", "Main: X", "X's alt"), case insensitivity, nil for unrelated notes, aggregated consumption with breakdown

### Accessibility
- Team colors paired with pattern indicators (stripe, dot, diamond, star)
- Alt suggestions include text descriptions
- Team member list keyboard-navigable with arrow keys

---

## Milestone 5: v0.5.0 -- Snapshots + Alerts + GBS Integration

**Goal**: Compressed inventory snapshots with diff, stock alerts, Guild Bank Sort integration.

### Files to Create

| File | Purpose |
|------|---------|
| `Snapshots.lua` | `TakeSnapshot()` (serialize -> LibDeflate compress -> encode), `RestoreSnapshot(index)`, `DiffSnapshots(older, newer)` (added/removed/moved), `AutoSnapshot()` (throttle 1/hour), `PruneSnapshots(maxCount=50)` |
| `Alerts.lua` | `SetStockAlert(itemID, minCount)`, `CheckStockAlerts()` (after scan, fire if below min, re-arm if above), `NotifyStockAlert()` (chat + sound, never sound alone) |
| Core.lua additions | `DetectGuildBankSort()`, `OnGBSSortStart()` (pause tx recording, pre-sort snapshot), `OnGBSSortComplete()` (post-sort snapshot, single "Sort" meta-tx) |

### Edge Cases
1. LibDeflate not available -- fallback to uncompressed
2. Snapshot during active scan -- wait for completion
3. Diff between snapshots with different tab counts -- handle added/removed tabs
4. GBS not installed -- all hooks are no-ops (`OptionalDeps`)
5. Compression failure -- fallback to uncompressed
6. 8 tabs * 98 slots = 784 entries max -- well within limits

### Tests

**`spec/snapshots_spec.lua`** (10 tests): capture all items, compression ratio > 1.5x, restore round-trip, diff added/removed/count changes/empty tabs/identical, pruning, auto-throttle

**`spec/alerts_spec.lua`** (9 tests): set/remove alert, fires below min, not above, single-fire (notified flag), re-arm above min, GetCurrentStock sums tabs, non-existent item = 0, multiple alerts independent

### Accessibility
- Snapshot diff: "+Added" / "-Removed" text labels alongside colors
- Stock alerts: text + sound + icon (alert triangle), never color alone

---

## Milestone 6: v0.6.0 -- Export

**Goal**: CSV and formatted text export with copy-to-clipboard UI.

### Files to Create

| File | Purpose |
|------|---------|
| `Export.lua` | `ExportTransactionsCSV(filters)`, `ExportConsumptionCSV(dateRange)`, `ExportForDiscord(filters)` (Markdown table, split at 2000 chars), `ExportForForums(filters)` (BBCode), `ExportSnapshot(index)`, `ExportSnapshotDiff(older, newer)` |
| `UI/ExportFrame.lua` | Modal frame: format dropdown (CSV/Discord/BBCode), data dropdown, filter summary, large EditBox (auto-select, "Ctrl+A then Ctrl+C" instruction), character count |

### Edge Cases
1. Very large export -- row limit option with warning
2. Item links in CSV -- strip color codes, output plain name + itemID
3. Commas in item names -- proper CSV escaping (quote fields)
4. Empty export -- "No data to export" message
5. EditBox character limit -- truncate with warning
6. Discord 2000-char limit -- split with "(1/3)" headers

### Tests

**`spec/export_spec.lua`** (13 tests): CSV header/data/formatting/delimiter/escaping/color stripping, Discord Markdown table + 2000-char split, BBCode format, consumption CSV, snapshot export, diff export, empty data message, filter match count

### Accessibility
- EditBox keyboard-focusable
- "Ctrl+A then Ctrl+C" always visible as text
- Format dropdown keyboard-navigable
- Export output plain text (no color-dependent formatting)

---

## Milestone 7: v1.0.0 -- Sync + Polish + Release

**Goal**: Multi-officer sync via AceComm, conflict resolution, audit trail, performance optimization, CurseForge release.

### Files to Create

| File | Purpose |
|------|---------|
| `Sync.lua` | Prefix `"GBLSync"`, message types: HELLO/REQUEST/RESPONSE/ACK/FULL_SYNC. `InitSync()`, `OnCommReceived()` (validate officer rank, decode/decompress/deserialize), `SendSyncMessage()` (serialize/compress/encode), `BroadcastHello()` (every 10min), `HandleHello/Request/Response()`, `ResolveConflict()` (most recent scanTime wins, lexicographic tie-break), `GetAuditTrail()`, `GetSyncStatus()` |
| `UI/SyncStatus.lua` | Enable checkbox, last sync, peer list (name/status/last sync/version), collapsible audit trail, "Force Full Sync" button with confirm dialog |
| Performance pass | Lazy UI creation, virtual scroll, debounce rapid events, cache `GetItemInfoInstant`, batch DB writes, sync chunking (200 tx/msg, 0.5s delay), coroutine-sliced compaction |
| CurseForge finalization | All externals in `.pkgmeta`, `X-Curse-Project-ID` in .toc, `ignore` section, MIT license |

### Edge Cases
1. Version mismatch between officers -- warn, refuse sync
2. Large initial sync -- chunk with delays
3. Officer demoted mid-sync -- check rank per message
4. Clock skew -- `GetServerTime()` is server-synchronized
5. Sync loop prevention -- only broadcast locally-scanned data
6. SavedVariables size -- warn if approaching 5MB
7. Channel throttle -- ChatThrottleLib handles rate limiting

### Tests

**`spec/sync_spec.lua`** (14 tests): HELLO/REQUEST/RESPONSE serialize/deserialize, dedup on received tx, conflict resolution (scanTime + tie-break), version mismatch warning, audit trail, peer list update, non-officer rejection, full sync cycle, compression round-trip, empty sync

### Accessibility
- Sync status: text labels alongside icons ("Connected", "Syncing...", "Error")
- Audit trail structured text
- Confirm dialog keyboard-navigable
- Peer status colors + text labels

---

## Dependency Graph

```
M1 --- M2 --- M3 --- M6
              |       |
              M4 -----+
              |       |
              M5 -----+
                      |
                      M7
```

M1-M3 sequential. M4 and M5 can parallel after M3. M6 needs M3 UI + benefits from M4/M5 data. M7 depends on all.

## Library Additions Per Milestone

| Milestone | New Libraries |
|-----------|--------------|
| M1 | LibStub, CallbackHandler, AceAddon, AceDB, AceConsole, AceEvent |
| M2 | (none) |
| M3 | AceGUI, AceConfig, AceConfigDialog, AceConfigCmd, LibDBIcon, LibDataBroker, LibSharedMedia |
| M4 | (none) |
| M5 | LibDeflate, AceSerializer |
| M6 | (none) |
| M7 | AceComm, ChatThrottleLib |

## Performance Budgets

- Full 8-tab scan: < 5 seconds
- UI first open: < 500ms; subsequent: < 100ms
- SavedVariables steady state: < 5 MB
- Sync message processing: < 50ms per batch
- Compaction: < 200ms for typical dataset (< 10k records)

## Verification

### Per-Milestone Testing
```bash
busted                          # run all tests
busted spec/scanner_spec.lua    # run specific file
busted --verbose                # verbose output
busted --coverage               # with luacov
```

### Manual In-Game Testing (each milestone)
1. Install addon in WoW `Interface/AddOns/GuildBankLedger/`
2. `/gbl status` -- verify version and guild detection
3. Open guild bank -- verify scan triggers and completes
4. `/gbl` -- verify UI opens (M3+)
5. Check `WTF/Account/.../SavedVariables/GuildBankLedgerDB.lua` for data integrity

### Total Test Count: ~133 tests across 14 spec files
