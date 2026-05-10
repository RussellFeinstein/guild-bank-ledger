# GuildBankLedger — Project Instructions

## Overview

WoW addon that persistently logs guild bank transactions. Lua 5.1 + Ace3 stack. Tests via busted.

## Architecture

- **src/Core.lua** — AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
- **src/Logger.lua**: Per-channel session log. Sync cap 2000, sort cap 1000, system cap 500. Severity levels DEBUG/INFO/WARN/ERROR; printf format with `pcall(string.format)` fallback so a bad format string never crashes. INFO/WARN/ERROR always record; DEBUG drops unless `db.profile.<channel>.debugChat` is on. Public API: `GBL:LogSync/LogSort/LogSystem(level, fmt, ...)` plus convenience wrappers (`SyncInfo`, `SortWarn`, etc.), `GetLog(channel)`, `GetMasterLog(opts)`, `ClearLog(channel)`. Surfaced on demand via `/gbl synclog`, `/gbl sortlog`, `/gbl logs` (master, interleaved by timestamp).
- **src/Scanner.lua** — Guild bank slot scanning (inventory snapshots)
- **src/Categories.lua** — Item classification via WoW classID/subclassID
- **src/Dedup.lua** — Deduplication engine (occurrence-based hashing, fuzzy matching, event count metadata, count-based cleanup)
- **src/Ledger.lua** — Transaction recording from GetGuildBankTransaction API
- **src/Storage.lua** — Tiered storage, compaction (30d daily, 90d weekly), pruning
- **src/Fingerprint.lua** — Dataset fingerprinting (djb2 hash, XOR aggregation, 6-hour bucket hashes)
- **src/ItemCache.lua** — Lazy async item info cache (GetItemInfo + GET_ITEM_INFO_RECEIVED for synced records)
- **src/Sync.lua** — Guild-wide sync via AceComm (HELLO/SYNC_REQUEST/SYNC_DATA/ACK/BUSY/MANIFEST protocol, epidemic gossip propagation, concurrent send+receive, smart peer selection, hash-gated HELLO reply suppression, fingerprint-based delta sync, pending peers queue, NACK backoff, combat/zone guards, bidirectional sync, jitter)
- **src/BankLayout.lua** — Per-guild saved bank layout templates (display/overflow/ignore tab modes with per-item slot counts and stack sizes); validation (exactly one overflow, no duplicate items across display tabs, ≤98 slots); capture-from-snapshot; stock reserves storage
- **src/SortPlanner.lua** — Pure-function move planner: given a bank snapshot + layout, produces deterministic ordered op list (split/move) to reshape bank. Assign-then-schedule algorithm: Phase 0 pre-merges same-item partial stacks within the overflow tab (two-pointer pour up to the per-item max stack size from ItemCache or an opts.maxStackByItem override) so the overflow is compacted to its minimum slot count BEFORE any cross-tab routing happens. Phase 1 builds demands (slotOrder-pinned + items.slots extensions that right-extend then left-extend to keep each item's group contiguous), assigns each demand to the best source (same-tab direct → overflow → cross-tab; largest-count first within each tier; keep-slot harvest protection), and routes leftover supply to overflow via a capacity-aware pickOverflowSlot that prefers (1) topping up an existing same-item partial slot, then (2) right-extend, (3) left-extend, (4) first-empty; a single supply may split across multiple destinations until consumed or unplaced. Phase 2 schedules moves via a greedy feasibility loop and breaks swap cycles with a pivot slot (same-tab empty preferred, overflow fallback). Phase 3 sweeps stragglers using the same multi-destination overflow routing. Phase 4 packs overflow stacks into a deterministic contiguous run from slot 1 sorted by (itemID ASC, count DESC, origSlot ASC) — position-compaction only; partial-stack merging happens earlier in Phases 0/1B. Hard max-stack invariant: `canExecute` and `applyOpToState` refuse same-item merges that would exceed the per-item maxStack (looked up via the same getMaxStack closure as Phase 0/1B), so the planner cannot emit a plan that depends on illegal in-state over-stack accumulations — Phase 4 cascades that would otherwise over-stack are reordered by the greedy drain or bailed via the existing pivot/cycle paths. Items with unknown max stack (cold cache after `/reload`) skip Phase 0 merging and Phase 1B top-ups for that item only, falling back to grouping; a follow-up sort completes the work once item info loads. Repeat sorts are idempotent. Reports deficits, unplaced items (with reason code), and the overflow tab.
- **src/SortExecutor.lua** — Executes a plan one op at a time with throttling (0.3s gap), pre-step verification, cursor-leak safety, replan-on-foreign-activity (cap 5), bank-close abort, and `GUILDBANKBAGSLOTS_CHANGED`-driven confirmation with timeout fallback. Each success branch (sync, async event, late-poll, late-ACK reclassify) requires both `slotHasAtLeast(dst, item, count)` AND a src-drained predicate before advancing — for "move" ops src must be empty or hold a different item; for "split" ops src.count must have decreased by at least op.count. This is what distinguishes a real success from a phantom one when WoW's optimistic client update makes a no-op pickup→drop look identical to a successful move. When the predicate fails, the executor audits a "no-op suspected" line and falls through to the timeout-poll path.
- **UI/Accessibility.lua** — Colorblind-safe palettes, font scaling, keyboard nav, triple encoding
- **UI/FilterBar.lua** — Transaction filter logic and AceGUI filter widgets
- **UI/ConsumptionView.lua** — Consumption aggregation: guild totals, per-player summaries, guild-wide item usage with time buckets
- **UI/LedgerView.lua** — Virtual-scrolling transaction list with sortable columns
- **UI/SyncStatus.lua**: Sync tab. Enable toggle, peer list. (Audit panel removed: log surfaces only via `/gbl synclog` or `/gbl logs`.)
- **UI/ChangelogView.lua** — Changelog tab: embedded version history and in-game renderer
- **UI/AboutView.lua** — About tab: addon info, Ko-fi donation link, CurseForge link, credits
- **UI/LayoutEditor.lua** — Layout tab: per-tab mode picker (display/overflow/ignore), item-template rows with slots/perSlot, Capture-from-current-tab button, Add-item input, Sort Access sub-section (two tiers: Layout Write and Sort-only, each with rank threshold + delegate list). Writes gated by `HasLayoutWrite()`; Sort Access writes gated by `IsGuildMaster()`. Write tier implies sort tier.
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
- **Public description sync**: `docs/CURSEFORGE-DESCRIPTION.md` is the source of truth for the CurseForge project page. When user-facing surface changes (slash commands, UI tabs, access control, sync features, planned-feature framing), update it in the same PR. CI emits a `::warning::` annotation on PRs that change feature-surface files (`README.md`, `docs/ROADMAP.md`, `src/**/*.lua`, `UI/**/*.lua`, `GuildBankLedger.toc`) without updating the description; treat it as a checklist prompt, not a blocking gate. Pasting the updated content into the CurseForge web UI is a manual release step until BigWigsMods/packager#187 lands.

## Branch Workflow

`main` is the integration target and is GitHub-protected (PR + `test-and-lint` CI required, merge commits only, force-push and deletion blocked). Auto branch deletion on merge is **off**, so topic branches survive their PRs and can be reused.

### Topic branches (long-lived, per area)

Recurring areas of work live on long-lived branches that accumulate multiple commits and PR to `main` as periodic checkpoints, similar to how an area-owning team would batch updates. Initial set:

- `ui` for UI/*.lua (except UI/Accessibility.lua)
- `sync` for src/Sync.lua, src/Fingerprint.lua, sync diagnostics, audit plumbing
- `accessibility` for UI/Accessibility.lua and palette / font / keyboard work
- `layout-sort` for src/BankLayout.lua, src/SortPlanner.lua, src/SortExecutor.lua, UI/LayoutEditor.lua, UI/SortView.lua

Create a topic branch the first time work in that area appears, not preemptively. Add new topic branches when a fifth recurring area emerges.

### Single-purpose branches (frozen after PR closes)

Cross-cutting work, infra changes, and one-off refactors use single-purpose branches off `main`:

- `chore/<thing>` for maintainer chores, repo-config changes, doc-only updates
- `infra/<thing>` for CI / build / tooling changes
- `hotfix/<thing>` for urgent production-impact fixes (see Hotfix rule below)

These branches are **frozen** once their PR closes (merged, closed without merge, or declared done by the user). Frozen means no new commits land on the branch; follow-up work goes on a new branch off `main`. Nothing is deleted: the branch and its history are retained both locally and on the remote, and auto-delete-on-merge stays disabled. The user can unfreeze a branch at any point by explicit decision (typically by rebasing onto the current `main` and resuming work). Agents do not unfreeze on their own initiative.

See **Branch lifecycle: frozen vs long-lived** in `~/.claude/CLAUDE.md` for the full taxonomy and the agent-side decision rule.

### Rules

- **Hotfix rule**: an urgent production-impact fix never goes on a topic branch. Open `hotfix/<thing>` off `main`, PR it, merge, then rebase any affected topic branches onto the new `main`.
- **Cross-area rule**: when one feature spans two topic branches (e.g. a sync change that needs a UI tab), merge the upstream-of-the-dependency branch first, rebase the dependent branch onto the new `main`, then commit the dependent piece. Never PR both branches simultaneously hoping git resolves the order.
- **Two-PR-from-same-topic rule**: a topic branch can only have one open PR at a time. If `ui` has a ready batch and unrelated WIP, checkpoint-PR the ready batch first, then continue WIP after the merge + rebase. Splitting WIP off to a temporary `ui-<thing>` is a fallback when the WIP must continue in parallel.
- **Rebase cadence**: rebase each touched topic branch onto `origin/main` at the start of every working session in that area, and immediately after every merge. `git rebase origin/main` if conflicts are tame; fall back to `git merge origin/main` if not. Push back with `git push --force-with-lease` (allowed on topic branches since they are unprotected).
- **Version-stamp cadence (covers CHANGELOG and every other version artifact)**: a topic branch stamps every version artifact only when opening the PR, in a dedicated stamp commit. Stacked work on the topic branch leaves all of these untouched and lets `[Unreleased]` accumulate:
    - `VERSION` file
    - `GuildBankLedger.toc` `## Version:` field
    - `src/Core.lua` `local VERSION = "..."` constant
    - `CHANGELOG.md` (the `## [X.Y.Z] - YYYY-MM-DD` header; work lands under `[Unreleased]` until stamp time)
    - `UI/ChangelogView.lua` `CHANGELOG_DATA` table (in-game changelog)
    - This `CLAUDE.md`'s "Current: X.Y.Z" line at the bottom
    - `src/Core.lua` `local DEV_BUILD = ...` constant must be reset to `nil` in the stamp commit. CI rejects any other value via the `Verify DEV_BUILD is nil` workflow step.

  If two branches PR with the same target version, the second to merge rebases onto post-merge `main` and the stamp commit bumps to the next patch. The principle is: one version per PR, one stamp commit per PR, never per-commit churn on these artifacts during stacked work. (This is the project-level instance of the global `~/.claude/CLAUDE.md` "Commit Versioning" carve-out for bundle-and-PR repos.)
- **Dev-build isolation**: at the start of any topic-branch or single-purpose-branch session that ships protocol-affecting or schema-affecting changes, set `local DEV_BUILD = "<branch>"` in `src/Core.lua`. The runtime `self.version` becomes `X.Y.Z-dev.<branch>` and the existing exact-version-match rejection at `src/Sync.lua` HandleHello refuses to sync with production peers in both directions, including the user's own production-version characters on the same account. The flag is reset to `nil` in the stamp commit (see Version-stamp cadence above). Local `bash run_tests.sh` is intentionally not gated on the flag so dev iteration keeps working; CI is the enforcement boundary, and `scripts/hooks/pre-push` is the local-clone fast-fail (activate once per clone with `git config core.hooksPath scripts/hooks`).
- **CI cadence**: `.github/workflows/ci.yml` runs on `pull_request` and `push: main` only. Intermediate commits on a topic branch are unverified by CI. Run `bash run_tests.sh` and `bash run_tests.sh --lint` locally before each commit so topic branches stay green.
- **Stale-branch policy**: if a topic branch has had no commits for 3 months, delete it and recreate fresh from `main` when work resumes. Long-lived does not mean immortal.
- **Carve-out from the global "small, focused PRs" rule**: the user's global `~/.claude/CLAUDE.md` "Open Source / Public Repo Workflow" section says "Keep PRs small and focused, one concern per PR." That rule is for external-contributor PRs. For the maintainer's own topic-branch PRs in this repo, multiple related commits per PR is the intended pattern. External contributor PRs still follow the small-and-focused rule.

## Sync subsystem notes

### Protocol / transport

- Sync transport stack is **AceSerializer → LibDeflate → AceComm → ChatThrottleLib → `C_ChatInfo.SendAddonMessage`**. AceComm splits payloads into 255 B wire fragments; a 980 B compressed chunk is ~4 fragments. Whole-chunk loss compounds: at per-fragment drop probability `p`, chunk loss is `1 - (1-p)^n`. Moving from 3 to 4 fragments at p=5% raises chunk loss from 14% to 19%.
- AceComm WHISPER has an empirically ~2000 B reliability ceiling (`WHISPER_SAFE_BYTES` in `src/Sync.lua`). Staying under it is necessary but not sufficient — fragment *count* is an independent reliability factor.
- `ChatThrottleLib.avail` is the **client-side** bandwidth meter only. It does not model server-side per-recipient addon-message throttling that Blizzard's chat server applies to `SendAddonMessage` independent of CTL. A healthy `CTL.avail` can still coincide with server-dropped messages when chunks are issued <1s apart.
- `C_ChatInfo.SendAddonMessage` via `AceComm:SendCommMessage` does not return a useful delivery status — reliability is observed only via ACK/NACK/timeout at the protocol layer. Do not branch on its return value.
- AceComm's progress callback fires per CTL piece; only `sent == totalBytes` indicates "handed to the wire," and only then should the ACK timer start. This is the v0.23.0 contract codified in `SendNextChunk`.

### Name forms quick reference

GBL handles three distinct name forms. Mixing them is a collision risk; each has a dedicated producer and a fixed set of consumers:

| Form | Example | Where it lives | Producer |
|---|---|---|---|
| Qualified `Name-Realm` | `Katorriwl-Stormrage` | `record.player`, `record.scannedBy` (after the `sync:` prefix), all migrations | `GBL:ResolvePlayerName` |
| Canonical peer key | bare for same-realm, qualified for cross-realm | keys of `syncState.peers`, `guildData.knownPeers`, `syncState.peerManifests`, `syncState.pendingPeers` | `GBL:CanonicalPeerKey` |
| Bare name | `Bob` | `recentWhisperTargets` keys (chat-system suppression), UI filter inputs | `GBL:StripRealm` |
| Raw network sender | whatever AceComm passes | runtime only; must never be stored without canonicalization | always wrap in `GBL:CanonicalPeerKey` before keying any peer-state table |

Helpers:

- `GBL:NormalizeRealm(realm)`: strips whitespace from a realm portion (e.g. `"Aerie Peak"` → `"AeriePeak"`). Always normalize before equality comparison or persistence.
- `GBL:GetLocalRealm()`: normalized local realm, or `"UnknownRealm"` sentinel when realm APIs are cold.
- `GBL:_isLocalRealm(realm)`: `true` iff realm matches local (raw or normalized). Used by `CanonicalPeerKey` to decide whether to strip.
- `GBL:BuildRosterCache()`: populates `guildData.playerRealms[bareName] → realm`. Two-pass: detects bare-name ambiguity and writes the `false` sentinel when a bare name maps to multiple distinct realms in the roster (so `CanonicalPeerKey` can refuse to guess and keep ambiguous bare arrivals bare).
- `GBL:RepairCorruptedPlayerRealms(t)`: trims hyphen-corrupted realm strings carried forward from a long-fixed code path; called from `BuildRosterCache` on each invocation. Leaves `false` sentinels untouched.

`ResolvePlayerName` priority order: **explicit `playerRealms` arg → current guild's playerRealms → local realm fallback**. There is no cross-guild fallback. Bare names from the bank log are assumed to belong to the current guild, not a guild the user previously belonged to. Migrations pass the per-guild table explicitly via the `playerRealms` arg.

### Code invariants to preserve

- Logging is split across three channels owned by `src/Logger.lua`. Sync code calls `GBL:SyncInfo / SyncWarn / SyncError / SyncDebug`; sort code calls `GBL:Sort*`; system events call `GBL:System*`. The lower-level form `GBL:LogSync(level, fmt, ...)` exists for runtime-computed levels. Each channel is a session-only ring buffer (sync 2000 / sort 1000 / system 500, FIFO from tail). DEBUG entries are dropped entirely unless `db.profile.<channel>.debugChat` is on, which preserves the prior `chatOnly=true` "do not pollute the buffer with per-chunk noise" property without a separate side channel. Chat mirroring is gated by `chatLog` (INFO/WARN/ERROR) and `debugChat` (DEBUG). `GBL:AddAuditEntry(msg, chatOnly?)` is a deprecated shim that routes plain calls to `SyncInfo` and `chatOnly=true` calls to `SyncDebug`. `GBL:GetAuditTrail()` is a permanent alias for `GetLog("sync")` that also exposes a legacy `entry.timestamp` field; new readers should use `GetLog(channel)` or `GetMasterLog(opts)` directly. Slash commands: `/gbl synclog`, `/gbl sortlog`, `/gbl logs` (master pop-up), `/gbl logs dump [N]`, `/gbl logs clear sync|sort|system|all`, `/gbl logs debug sync|sort|system on|off`. The Sync tab no longer carries an always-visible audit panel; logs surface only on demand via slash command.
- `syncState.lastChunkBytes` is the canonical compressed chunk size. Reuse it for fragment-count estimates (`ceil(lastChunkBytes/255)`) rather than re-measuring.
- `HasSyncBandwidth()` uses a **dynamic** threshold `max(CTL_BANDWIDTH_MIN, lastChunkBytes)` — this is the v0.28.2 fix for the burst-stall regression from v0.28.0. Do not regress to a fixed threshold.
- The superset skip in `HandleHello` and again in the bidirectional check after `FinishSending` is load-bearing for convergence but lacks a "tried and failed, back off" state — when sends fail, both sides' bidirectional checks short-circuit on "likely superset" and the protocol re-enters the same failing pattern. Flagged as a candidate amplifier, not fixed in v0.28.4.
- Stale-ACK discard in `HandleAck` (v0.23.0) and `ScheduleReceiveTimeout` rescheduling (v0.25.3) are real defect fixes, not patches — do not remove during refactors.
- **Peer identity: always use `GBL:CanonicalPeerKey`** (src/Core.lua). The helper does its own local-realm-only strip via `GBL:_isLocalRealm`, NOT `Ambiguate("guild")`. Reason: retail's `Ambiguate("guild")` strips realm for ALL guildmates in a connected-realm group, which collapses two distinct same-name characters across connected realms (e.g. an Alice on Tichondrius and a different Alice on Stormrage in one guild) into one peer key. Custom strip rules: qualified `Name-Realm` keeps the suffix when realm differs from local (raw-or-normalized comparison), strips to bare when realm equals local. Bare input consults `guildData.playerRealms[name]` (built by `BuildRosterCache` on every `GUILD_ROSTER_UPDATE`, persistent across sessions); cross-realm bare names get re-realmed to `Name-Realm`, same-realm bare names stay bare. Both bare and qualified arrivals of the same character converge on the same canonical key in any realm topology, while two distinct same-name peers on different realms keep distinct keys. Bare names without a `playerRealms` entry (cold cache, departed peer, non-guildmate sender) pass through unchanged (best effort; the unresolvable case is two distinct same-name characters whose messages both arrive bare, which collide). **Defensive validation:** the helper rejects realm strings containing hyphens (corruption from a long-fixed code path; retail realm names never contain hyphens) and falls back to bare passthrough; `RepairCorruptedPlayerRealms` (called from `BuildRosterCache`) trims corrupt entries to their first segment so offline-peer corruption doesn't persist forever. `GBL:StripRealm` is reserved for true bare-name use cases where same-name on either realm should share state; the only current consumer is `recentWhisperTargets` for chat-system-message suppression (see comment near its declaration in `src/Sync.lua`). The test mock for `Ambiguate("guild")` is unused by `CanonicalPeerKey` now but still implements local-realm-only strip for any callers that legitimately want it. The `src/Sync.lua` `InitSync` knownPeers seed loop runs each persisted key through `CanonicalPeerKey` and consolidates `knownPeers` in place when a stale key collapses to a new canonical form. **Cold-roster gate:** `MigrateRecoverPeerRealms` returns 0 without bumping `schemaVersion` when `GetNumGuildMembers()` is 0 (cold roster); `GUILD_ROSTER_UPDATE` retriggers `MigrateAllGuilds` once per session via the `_migrationsRetried` flag so cold-roster short-circuits get a warm retry without waiting for the next login. Historical: v0.30.5 first patched the broken `Ambiguate(name, "none")` (identity in retail) with `StripRealm` (over-aggressive), then with `CanonicalPeerKey` wrapping `Ambiguate("guild")` (correct in tests but in-game collapsed all connected-realm guildmates to bare); the v0.30.5 follow-up replaced the `Ambiguate("guild")` delegation with custom local-realm-only logic, added the `playerRealms` fallback for bare arrivals, fixed the schema-11 cold-roster premature-bump, retriggered MigrateAllGuilds on first warm `GUILD_ROSTER_UPDATE`, and added `RepairCorruptedPlayerRealms`.
- **`chunkOutcomes[idx]` outcome vocabulary (v0.28.7):** `"pending"`, `"ok"`, `"aborted"` (ackTimeout), `"combatAbort"`, `"zoneAbort"`, `"busyAbort"`, `"sendFailed"` (target offline). Abort-tagging paths are all guarded by `outcome == "pending"` so a later ACK that sets `"ok"` wins correctly. **`retryReasons`** is a per-chunk array of `"ackTimeout"` / `"nack"` tags; only these two count toward the wire-loss `chunkFail` metric. Combat/zone/busy/offline aborts are bucketed separately — mixing them into a single "aborted" count loses the ability to tell a noisy test session from a reliability issue.

### Historical patch verdicts

- **Genuine root-cause fixes:** v0.11.x (ID normalization), v0.22.0 (BUSY + pending queue), v0.23.0 (stale-ACK + callback-timed ACK timer), v0.25.0 (epidemic gossip + MANIFEST), v0.25.3 (receive-timer reschedule), v0.27.0 (epoch-0 migration + unified audit), v0.28.2 (dynamic CTL threshold), v0.30.5 (peer-name realm canonicalization: replaced the broken `Ambiguate(name, "none")` at 16 sites with `GBL:CanonicalPeerKey`, which now uses custom local-realm-only strip via `GBL:_isLocalRealm` rather than `Ambiguate("guild")`; retail Ambiguate strips realm for all connected-realm guildmates and would collide same-name distinct-character peers; the custom strip preserves cross-realm suffixes so two Alices on different connected realms stay distinct; schema-9 migration is realm-aware; schema-11 `MigrateRecoverPeerRealms` re-realms bare keys via guild roster lookup for users who ran the intermediate StripRealm-everywhere build; v0.30.5 follow-up added the bare-name `playerRealms` fallback in `CanonicalPeerKey`, switched the strip rule from `Ambiguate("guild")` to custom local-only logic, fixed the schema-11 cold-roster premature-bump, retriggered `MigrateAllGuilds` once on first warm `GUILD_ROSTER_UPDATE` via `_migrationsRetried`, re-canonicalized the `InitSync` knownPeers seed loop to self-heal stuck saved variables on next reload, and added `RepairCorruptedPlayerRealms` to fix hyphen-corrupted realm strings carried forward from a long-fixed code path that BuildRosterCache cannot overwrite for offline peers).
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

Current: 0.32.1 (see `VERSION` file)
