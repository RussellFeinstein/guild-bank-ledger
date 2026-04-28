<!-- Promoted from ~/.claude/plans/note-that-tomorrow-we-elegant-elephant.md on 2026-04-28 -->

# Opt-in audit log auto-upload

## Context

Diagnosing sync reliability currently requires asking guildies to manually copy their `GuildBankLedger.lua` SavedVariables or audit chat-frame contents and DM them. This is slow, lossy, and only happens when both parties are online and remember to do it. Per-peer p_frag baselines and rare-event captures (`project_per_peer_route_variance.md`, `project_offline_outcome_observed.md`, `project_ctl_stall_v028_8_recurrence.md`, `project_combat_abort_confounder.md`) all depend on this manual loop.

Goal: opt-in auto-upload of sync audit logs from each consenting guildie to a maintainer-controlled warehouse (Google Drive, a private GitHub repo, a small HTTP endpoint, or a DB). Maintainer can then pull complete records across versions and peers without coordinating real-time captures.

## Hard constraints

- **Opt-in only, off by default.** A privacy-first toggle in the addon's About/Sync settings, with a clear one-line description of what gets uploaded and where it goes. Toggling off must immediately stop new uploads.
- **Every log entry tags its source version.** Both addon `VERSION` and sync protocol version (`PROTOCOL_VERSION` at Sync.lua:11, exposed as `GBL.SYNC_PROTOCOL_VERSION`) on every record so cross-version corpora are partitionable. Without this tag, mixed-version corpora are unanalyzable.
- **No PII beyond character/realm names** (already in audit lines today). Do not start uploading bank contents or item lists. Scope is the audit trail, not the ledger.
- **Bounded volume.** Cap per-day upload size and rotate. A guildie should never see the addon balloon their disk usage or upload bandwidth.

## WoW API reality

WoW addons cannot make HTTP requests, write outside SavedVariables, or run background processes. The addon side can only produce a structured file inside `WoW/_retail_/WTF/Account/<acct>/SavedVariables/`. Therefore this feature is necessarily two pieces:

1. **Addon side (Lua):** write a structured rolling audit dump that includes version tags. Likely a new SavedVariable `GuildBankLedgerAuditDB` (separate from `GuildBankLedgerDB` so the ledger isn't dragged into uploads) keyed by session, capped by entry count, with each entry stamped `{addonVersion, syncVersion, timestamp, peer, outcome, …}`.

2. **Companion uploader (out-of-game):** a small cross-platform process (likely Python or Node, distributed alongside the addon) that:
   - Watches the SavedVariables file for changes.
   - Parses the audit DB Lua dump.
   - Uploads new entries to the configured destination.
   - Surfaces errors to the user (toast / log) without blocking the game.

The companion is the harder half. Distribution and onboarding friction will determine adoption — if guildies have to install Python, almost nobody will opt in.

## Destination options (decision deferred)

- **Private GitHub repo via PAT** — easy to set up, free, version-controlled. Requires each guildie to have a PAT scoped to the repo, which is a non-starter for non-technical users.
- **Google Drive folder via service account** — guildies upload anonymously to a maintainer-owned folder. Requires a service-account JSON shipped with the companion, which is a credential leak risk if the binary is shared.
- **Simple HTTP endpoint** (Cloudflare Worker, Fly.io, etc.) — maintainer controls auth via a shared write-only token. Lowest guildie friction but maintainer pays hosting and writes the endpoint.
- **Pastebin-style throwaway POST** — degenerate fallback for one-off captures; not a long-term warehouse.

Recommended starting point: simple HTTP endpoint with a maintainer-issued opt-in token (so revocation is trivial). Defer the choice until the addon-side dump format is stable.

## Phasing

1. **Addon-side dump only** (no uploader yet). Add `GuildBankLedgerAuditDB` with version-tagged structured entries, `/gbl audit-dump` slash command to flush to file, opt-in toggle wired to whether dumps accumulate at all. Ship this first; it's already useful for manual collection (one structured file instead of chat-frame scraping).
2. **Companion uploader prototype** in Python, single-binary via PyInstaller, watching the SavedVariables file and POSTing to a maintainer endpoint. Distribute via the GitHub releases page alongside the addon zip.
3. **Endpoint + warehouse** — small Cloudflare Worker writing to R2 / a SQLite over HTTP, partitioned by addon version.

## Out of scope for this note

- Endpoint implementation details (separate plan when phase 3 is reached).
- Companion-uploader installer UX (separate plan when phase 2 is reached).
- Bank-content telemetry — explicitly excluded; only audit trail data is uploaded.

## Critical files (phase 1 only)

- `Sync.lua` — every `GBL:AddAuditEntry` call site (defined at line 2184) is the source of records; entries already have `peer`, `outcome`, etc. Stamp `addonVersion` + `protocolVersion` at write time.
- `Core.lua` — register `GuildBankLedgerAuditDB` AceDB, wire the opt-in toggle, register the slash command.
- `UI/SyncStatus.lua` or `UI/AboutView.lua` — add the opt-in checkbox with the one-line disclosure.
- `VERSION` / `Sync.lua` `PROTOCOL_VERSION` constant — read at runtime for stamping.

## Testing (phase 1)

- Unit test that audit entries written with the toggle off do not appear in `GuildBankLedgerAuditDB`.
- Unit test that every entry written with the toggle on has both `addonVersion` and `protocolVersion` populated.
- Unit test that the dump rotation/cap behaves correctly at the boundary.
- Manual: enable opt-in, run a sync session, verify the SavedVariables file contains a structured audit DB with version tags on every entry.
