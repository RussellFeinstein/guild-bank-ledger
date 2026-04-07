# Changelog

All notable changes to GuildBankLedger will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
