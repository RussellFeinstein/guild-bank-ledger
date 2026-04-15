# GuildBankLedger Roadmap

## Shipped (v0.1.0 -- v0.20.0)

The core addon is feature-complete for persistent guild bank logging with guild-wide sync. See [CHANGELOG.md](../CHANGELOG.md) for the full version history.

**Core recording** (v0.1.0--v0.6.0):
- Automatic scanning, transaction recording, item categorization
- Occurrence-based deduplication with event count metadata
- Money tracking (deposits, withdrawals, repairs, tab purchases)
- Per-player statistics, tiered storage with compaction
- Periodic re-scan every 5 seconds while the bank is open

**Guild-wide sync** (v0.11.0--v0.20.0):
- AceComm protocol v4 (HELLO / SYNC_REQUEST / SYNC_DATA / ACK / NACK)
- Fingerprint-based delta sync (6-hour bucket hashing)
- LibDeflate compression, chunked transfer (15 records/chunk)
- Retry logic, FPS-adaptive throttling, zone change protection
- Peer tracking with directional version status (newer/outdated)
- Event count metadata propagation (max wins)

**UI** (v0.3.0--v0.20.0):
- 5-tab interface: Transactions, Gold Log, Consumption, Sync, Changelog
- Filter bar (date range, category, type, player, tab, hide moves)
- Sortable columns, virtual scrolling, minimap button
- Consumption dashboard: guild totals, top 10 consumers, top 15 items with trend columns
- Changelog tab with pagination (10 versions/page)
- Version label with update-available detection
- Right-aligned utility tabs (Sync, Changelog)

**Access control** (v0.15.0):
- GM-configurable rank threshold with 3 restriction modes
- Settings sync via HELLO protocol

**Accessibility** (v0.3.0):
- 4 colorblind-safe palettes (auto-detected from WoW settings)
- Triple encoding (shape + color + text), high contrast mode
- Keyboard navigation, font scaling (8--24pt)

**Infrastructure**:
- 433+ busted tests across 17 spec files
- Schema migrations v1--v7 (all tested)
- GitHub Actions release pipeline (CurseForge + GitHub Releases)

---

## Current: Beta Preparation (v0.20.x)

- Documentation sync (README, ROADMAP, CurseForge description)
- Bug fixes: pagination, column widths, resize artifacts, peer staleness
- Test coverage expansion for UI modules

---

## Next: Beta Release (v0.21.0)

**Export feature** -- the highest-value missing feature for officers who need to share data outside the game.

- Formats: CSV, Discord Markdown (2000-char split), BBCode
- Export from Transactions, Gold Log, and Consumption tabs
- Filter-aware: exports what is currently filtered/visible
- Copy-to-clipboard modal with format picker

---

## Stabilization (v0.22.0 -- v0.24.x)

- Sync rate limiting (per-peer bandwidth budgeting)
- Performance audit (SavedVariables size, compaction verification, UI debouncing)
- Community feedback iteration

---

## v1.0.0: Public Release

The v1.0.0 release signals production readiness -- not a feature gate. It means:
1. Core features (logging, sync, dedup, storage, UI, export) are stable and tested
2. Schema migration path is reliable
3. Documentation is accurate and comprehensive
4. Addon has been tested by multiple guilds
5. Breaking changes follow semver going forward

---

## Post-1.0

| Version | Feature | Scope |
|---------|---------|-------|
| v1.1.0 | **Teams** | Raid team assignment (up to 4 teams), per-team consumption reports, team settings sync |
| v1.2.0 | **Alt linking** | Manual alt-main linking + guild note auto-detect, aggregated consumption, team auto-assignment |
| v1.3.0 | **Stock alerts** | Minimum stock levels per item, chat + sound notifications, auto re-arm |
| v1.4.0 | **GBS integration** | Guild Bank Sort detection, pause recording during sorts, single "Sort" meta-transaction |
