# GuildBankLedger Roadmap

## Shipped (v0.1.0 -- v0.37.0)

See [CHANGELOG.md](../CHANGELOG.md) for the full version history.

**Core recording** (v0.1.0--v0.6.0):
- Automatic scanning, transaction recording, item categorization
- Occurrence-based deduplication with event count metadata
- Money tracking (deposits, withdrawals, repairs, tab purchases)
- Per-player statistics, tiered storage with compaction (shipped, but compaction has never actually run: issue #62)
- Periodic re-scan every 5 seconds while the bank is open
- Tab recording for deposits and withdrawals (v0.37.0): every item transaction now stores the tab it happened in; previously only moves carried one

**Guild-wide sync** (v0.11.0--v0.30.x):
- AceComm protocol (HELLO / SYNC_REQUEST / SYNC_DATA / ACK / NACK / BUSY / LAYOUT_REQUEST / LAYOUT_DATA). MANIFEST shipped in v0.25.0 and was retired in v0.37.6: it existed only to score which peer to sync with next, which gossip does not need.
- Fingerprint-based delta sync with 6-hour bucket hashing
- LibDeflate compression, chunked transfer with 1-fragment chunks (510 B whole-message budget, covering records, event counts and the envelope together) and a 1.0s gap floor for cross-realm reliability
- Epidemic gossip propagation, free-agent pairing (retired the scored peer selection in v0.37.6), hash-gated HELLO reply suppression
- Retry logic, FPS-adaptive throttling, combat / zone change protection
- Peer canonicalization (`CanonicalPeerKey`) handling cross-realm and bare-name ambiguity correctly
- Per-chunk audit outcomes (ok / ackTimeout / nack / combatAbort / zoneAbort / busyAbort / sendFailed)
- Cross-version sync (v0.37.0): a `MIN_SYNC_VERSION` floor replaced the exact-match version gate, enforced at all three doors (`HandleHello`, `HandleSyncRequest`, `RequestSync`), so a mixed-version guild keeps converging; dev builds stay isolated in both directions
- Intake validation and repair (v0.37.0): type, enum, and shape checks on every synced record, `classID`/`subclassID` recomputed from `itemID` when damaged in transit, rejects counted separately from duplicates

**UI** (v0.3.0--v0.32.x):
- Tabbed interface: Transactions, Gold Log, Consumption, Sort, Layout, Sync, Changelog, About
- Filter bar (date range, category, type, player, tab, hide moves)
- Sortable columns, virtual scrolling, minimap button
- Consumption dashboard: guild totals, top 10 consumers, top 15 items with trend columns
- Changelog tab with pagination (10 versions/page)
- Version label with update-available detection
- Right-aligned utility tabs (Sync, Changelog, About)
- Ko-fi donation link and CurseForge link on About tab
- Optional Silvermoon Citizen ambient-chatter filter (chat + bubbles)

**Sort + layout** (v0.28.0--v0.31.1):
- BankLayout: per-guild saved templates (display / overflow / ignore tab modes) with per-item slot counts and stack sizes
- SortPlanner: pure-function move planner with multi-pass cycle resolution
- SortExecutor: throttled per-op execution with cursor-leak safety and replan-on-foreign-activity
- Layout tab editor with rank-gated write access
- Sort tab preview + rank-gated execute

**Restock** (v0.34.0):
- Restock tab: layout-driven item list grouped by bank tab, showing each item's target, current stock, and shortfall; gated by sort access
- Auction House buying via the optional Auctionator addon (per-item and Buy-all), spending real gold through the commodity flow with an affordability check and an optional per-run gold budget

**Logging** (v0.32.0):
- Per-channel session logs (sync cap 2000, sort cap 1000, system cap 500)
- Severity levels (DEBUG / INFO / WARN / ERROR) with `pcall(string.format)` fallback
- Surfaced on demand via `/gbl synclog`, `/gbl sortlog`, `/gbl logs` (master, interleaved by timestamp)
- Audit panel removed from the Sync tab; logs are diagnostic artifacts, not always-visible UI
- Persistent capture (v0.36.0): all three channels persist to `GuildBankLedgerAuditDB` per session (version-stamped headers, per-channel caps, 10-session rotation), managed via `/gbl audit`. On by default; nothing is transmitted. The opt-in uploader is phases 2-3 of docs/PLAN-audit-log-upload.md and stays unbuilt

**Access control** (v0.15.0):
- GM-configurable rank threshold with 3 restriction modes (full / sync-only / own-transactions-only)
- Settings sync via HELLO protocol

**Accessibility** (v0.3.0):
- 4 colorblind-safe palettes (auto-detected from WoW settings)
- Triple encoding (shape + color + text), high contrast mode (WCAG AAA)
- Keyboard-navigation primitives (`RegisterFocusable`, `AdvanceFocus`, `SetFocusIndicator`); see Pre-1.0 readiness below for the wiring audit
- Font scaling (8-24pt)

**Infrastructure**:
- 1578 busted tests across spec/
- Schema migrations v1--v11 (all tested)
- GitHub Actions release pipeline (CurseForge + GitHub Releases via BigWigsMods/packager)
- Daily TOC interface-version auto-update workflow
- Doc-sync CI advisory for CurseForge description drift

---

## Current: Beta (v0.37.x)

Per-area status:

- **Mature**: recording, categorization, deduplication.
- **Active** (in guild use, improvements queued): sync (rate limiting pending), UI (sort/filter polish, pagination layout, window resize), sort + layout (confirmation-speed tuning, the overflow-pack full-stack-merge edge case, layout editor slot visibility, refresh flicker). Restock (new in v0.34.0): layout-driven targets and Auctionator buying are in initial use, with a UI polish pass and the reserve-targets producer queued.
- **Under audit**: accessibility. Palettes, contrast, triple encoding, and font scaling are wired; keyboard-navigation primitives exist but are not threaded through all UI widgets. An independent audit pass is the next planned milestone and is a v1.0 release gate.
- **Under audit**: the storage layer. `docs/DATA-MODEL.md` measured the declared schema against a live 12,310-record file and found the defaults block, the record builders and the stored data all disagreeing. Tiered storage is being retired rather than repaired, because compaction has never once run (issue #62). Schema migrations work but nothing pins the entry point of the ladder, and roughly 12% of everything ever received via sync arrived with mangled field names. Intake validation and repair shipped in v0.37.0, so new arrivals are checked before they land; the corrupted backlog already on disk is issue #75. Tracked under the Data model integrity milestone and a v1.0 release gate.

---

## Next: Pre-1.0 readiness

Items below block the v1.0 release.

- **Accessibility audit and keyboard-nav completion**: wire `RegisterFocusable` into every AceGUI widget, hook Tab/Shift+Tab via a key handler, verify focus indicators advance correctly across all tabs and modal dialogs, screen-reader audit, palette validation against WCAG AAA contrast targets. The v0.3.0-v0.32.x infrastructure-without-wiring miss surfaced during the May 2026 doc sweep is the reason this is a release gate, not a Post-1.0 polish item.
- **Data model integrity** (milestone): converge the declared schema, the record builders and the stored data. The MIN_SYNC_VERSION floor (#74) shipped in v0.37.0 carrying the milestone's two id-adjacent items, sync intake validation (#68) and the tab deposits and withdrawals never recorded (#67), because that release was the last compatibility break available cheaply. What remains lands as ordinary releases at no guild cost: repairing the corrupted records already on disk (#75), the defaults block (#71), the `peers` collision (#72), retiring tiered storage (#62), the AceDB write-path test net (#77), the guard against raising the schemaVersion default (#76), and the per-player category totals that are declared but never accumulated (#64).
- **Sync rate limiting**: per-peer bandwidth budgeting layered on top of the current adaptive CTL backoff work.
- **Performance audit**: SavedVariables size profile and a UI debouncing pass on the heavy tabs. Compaction verification came off this list when compaction itself was retired.
- **Community feedback iteration**: address reports from active guild testers before the production-readiness signal.

---

## v1.0.0: Public Release

v1.0.0 signals production readiness, not a feature gate. It means:

1. Core features (logging, sync, dedup, storage, UI) are stable and tested.
2. Accessibility audit complete: keyboard navigation wired end-to-end across every UI widget, focus indicators verified, screen-reader audit passed, palettes validated against WCAG AAA contrast targets.
3. Schema migration path is reliable.
4. Sync protocol is rate-limited per peer, and gossip convergence is capture-verified: a guild whose members hold divergent datasets converges to a shared hash through HELLO-driven pairing alone, within a small number of session cycles and with no starved peer. Demonstrated from audit captures, not asserted from reading the code.
5. Breaking changes follow semver from v1.0.0 onward.

---

## Post-1.0

| Version | Feature | Scope |
|---------|---------|-------|
| v1.1.0 | **Analytics dashboard** | Six-section dashboard: headline stats, activity timeline (Tuesday-based WoW weeks via `C_DateAndTime.GetSecondsUntilWeeklyReset()`), category breakdown, gold flow, engagement distribution, item velocity. Consumption tab refocuses to per-player view, renamed "Players." The planned summary schema bump to v9 with `playerCounts` needs rethinking: it was designed against the daily/weekly summary tables that #62 retires |
| v1.2.0 | **Teams** | Raid team assignment (up to 4 teams), per-team consumption reports, team settings sync |
| v1.3.0 | **Alt linking** | Manual alt-main linking + guild note auto-detect, aggregated consumption, team auto-assignment |
| v1.4.0 | **Stock tab** | Passive view of current bank inventory; per-item quantities and categories; composes with existing BankLayout templates without new sync messages |
| v1.5.0 | **Stock alerts** | Configurable minimum stock levels per item; chat + sound notifications with per-item on/off toggle; auto re-arm after restock |
| v1.6.0 | **GBS integration** | Guild Bank Sort detection, pause recording during sorts, single "Sort" meta-transaction |
| v1.7.0 | **Export** | CSV, Discord Markdown, BBCode; filter-aware copy-to-clipboard from Transactions, Gold Log, Players |

## Engineering / Technical debt

Non-feature internal work, scheduled opportunistically (not version-gated).

- **Core.lua decomposition**: `src/Core.lua` is a roughly 2200-line monolith (AceAddon bootstrap, lifecycle, slash commands, migrations, access control, and more). Break it into focused `src/` modules over time. The identified first slice is access control: extract `IsGuildMaster`, `GetAccessLevel`, `HasFullAccess`, `HasLayoutWrite`, `HasSortAccess`, `SaveSortAccess`, `MigrateSortAccessShape`, and their file-local helpers into a new `src/Access.lua` (methods stay on `GBL`, so the call sites do not change), optionally adding `BuildAccessPayload` / `MergeRemoteAccess` helpers so `src/Sync.lua` stops embedding access internals. Mechanical only, fully covered by existing access specs (`sortaccess_spec`, `access_control_spec`, `layout_write_access_spec`). Best done after the sortAccess sync work lands so those helpers absorb its merge code.
