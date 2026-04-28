# Changelog

All notable changes to GuildBankLedger will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.30.4] - 2026-04-28

### Changed
- **Layout tab now uses nested tabs.** The previous monolithic vertical scroll (eight bank-tab sections stacked above a Sort Access section) is replaced with an inner tab strip: one inner tab per bank tab (Tab 1..Tab 8) plus a final Sort Access tab. Editing one bank tab at a time keeps slot maps and item lists short, and Sort Access policy gets its own focused screen. The active inner tab persists across rebuilds so edits do not bounce the view back to Tab 1. Save and Discard sit in an always-visible footer at the bottom of each bank-tab inner tab — they no longer get pushed below the viewport on long display tabs — and operate on the full draft (changes across all bank tabs save together). Sort Access keeps its own immediate-save semantics. Each inner tab keeps its own scroll position, so switching back to a tab returns the user to where they were instead of scroll=0. Mouse-wheel scrolling works inside every inner tab (the ScrollFrame lives inside each inner tab's content rather than wrapping the whole TabGroup, which is the canonical AceGUI fill-remainder pattern used elsewhere in the addon).

## [0.30.3] - 2026-04-27

### Changed
- Repository workflow: disabled auto branch deletion on merge and adopted long-lived per-area topic branches (`ui`, `sync`, `accessibility`, `layout-sort`) for recurring maintainer work. Short-lived `chore/*`, `infra/*`, `hotfix/*` branches still cover one-off and cross-cutting changes. Documented in the new `CLAUDE.md` Branch Workflow section and reflected in `CONTRIBUTING.md`. No addon behavior change.

## [0.30.2] - 2026-04-27

### Added
- **Sync audit trail now distinguishes silent receiver-side aborts from wire loss.** Two diagnostic-only additions, no behavior change:
  - **Receiver auto-bootstrap audit line.** When a `SYNC_DATA` chunk arrives while the receiver is not in an active receive session AND the chunk index is greater than 1, the audit log now records `Auto-bootstrap at chunk N from <sender> (prior abort signal likely missed)`. This signals that the receiver missed an earlier abort hand-off (combat with lost BUSY, or a sender-side state desync) and is recovering data mid-stream from chunk N onward. Bootstraps at `chunk = 1` stay silent (legitimate fresh start, e.g. addon reload between SYNC_REQUEST and the first chunk).
  - **Sender liveness tag on ACK timeout retries.** The `ACK timeout — retrying chunk N (attempt X/Y), fragments~=Z, gapSinceWire=Ts, nacksThisChunk=N` audit line now appends `, target=<online|offline|unknown>` from `IsGuildMemberOnline`. `unknown` covers both "not in roster" and "roster not yet populated" (the latter only relevant for the first few seconds after `PLAYER_ENTERING_WORLD`). Lets future capture analysis count how many timeouts happened against a peer who was already offline (failed-to-detect-disconnect) versus a peer who was nominally online (true wire loss or in-instance silent abort).

The motivation is observability before action: prior captures showed `chunkFail≈45–50%` patterns that conflate true wire loss, combat-with-lost-BUSY, full peer disconnect, and a separate auto-bootstrap desync path. Fixing chunk sizing without first measuring the cause distribution risks treating the wrong failure mode. These two log lines let the next 2–3 real failure captures be cross-correlated to pick the right v0.30.3 fix.

## [0.30.1] - 2026-04-25

### Changed
- Internal refactor: extracted a `GBL:SafeRecordTimestamp(record)` helper in `Dedup.lua` to replace ten copies of the `IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()` ternary across `Core.lua` (nine migration paths) and `Sync.lua` (one in `NormalizeRecordId`). No behavior change. Three of the call sites that had been wrapped onto two physical lines collapse back to one. Re-enables the 120-character line-length lint on `Core.lua` (the `.luacheckrc` file-specific override placed in v0.28.12 is now removed).

## [0.30.0] — 2026-04-24

### Added
- **Sort Access now has two independent tiers.** The Layout tab's Sort Access section is split into **Layout Write access** (edit templates, capture, pin slots, change stock reserves — inherently includes sort) and **Sort-only access** (press Execute on the Sort tab but cannot edit the layout). Each tier has its own rank threshold and its own delegate list, configured independently. Only the Guild Master can change the policy. The intent is to let the GM hand out sort execution widely (anyone in the sort tier can run a sort) while keeping layout edits locked down to a small trusted group.
- **Defense-in-depth gate at the storage API.** `SaveBankLayout` and `SetStockReserve` in `BankLayout.lua` now reject any caller who does not pass `HasLayoutWrite()`. Previously the check lived only in the UI callback layer; a future UI bug that forgot the check could have silently mutated the layout. This is belt-and-suspenders — the UI gate still runs first.
- **`GBL:HasLayoutWrite()`** as the canonical "can edit the layout" check. `HasSortAccess()` keeps its meaning (can press Execute), now with broader semantics: write implies sort, so anyone in the write tier is automatically counted as having sort access regardless of the sort tier's membership.

### Changed
- **Existing `sortAccess` configurations migrate into the new Layout Write tier.** On upgrade, anyone who had sort access before (via the old single-tier rank threshold or delegate list) keeps layout write access — no one silently loses a permission. The sort-only tier starts empty; populate it in the Layout tab if you want to grant sort without layout write. Migration is idempotent and runs automatically at addon load.



### Fixed
- **Sort progress counter no longer exceeds the plan total after a replan.** v0.29.23's display used `(done+failed) / total` — but `done` and `failed` accumulate across replans while `total` is the current (possibly-smaller) plan's size, so once a replan reissued work the numerator could overshoot (users saw `34/33`, `35/33`). Switched the display to `op N / T` using the executor's live `opIndex` and current-plan `total`, which is always in-range and reflects "where are we in the plan that's actually running."
- **Move list and per-op markers now realign after a replan.** SortExecutor's `doReplan` now emits a `phase="planupdated"` progress message with the new plan right after it's built. SortView swaps the cached `_sortLastPlan` to the new plan, clears the stale `_sortOpStatus` (old indices referred to different moves), and rebuilds the move list so the displayed rows match what the executor is actually working on. During execution, `_SortView_Preview` now uses the cached plan instead of re-running `PlanSort` — otherwise a rescan-triggered rebuild could show a plan different from the one executing.

## [0.29.25] — 2026-04-24

### Fixed
- **Sort progress markers now render in WoW's default font.** v0.29.23 used `▶` / `✓` / `✗` Unicode glyphs that FRIZQT__ doesn't ship; users saw colored tofu boxes instead. Swapped to colored ASCII: `>` for currently executing, `+` for completed (including late-ACK reclassified), `x` for failed. Same colors, intelligible shapes.
- **Per-op status markers now survive Sort tab rebuilds mid-sort.** `Ledger.lua` fires `RefreshUI` every time a rescan sees new transactions — and every successful move creates one — which routed through `UI/UI.lua`'s generic `SelectTab("sort")` fallback, re-entering `BuildSortTab` and wiping `self._sortOpRows`. Only the top progress label recovered (via the next event). Per-op markers were lost because they were transition-triggered and those events had already fired. Fix: the progress handler now writes every transition into a persistent `self._sortOpStatus` table (and the progress label text into `self._sortProgressText`) in addition to the live SetText calls. On rebuild, the Preview loop repaints each row from the status table and the progress label from the text cache. Tab-switching away and back mid-sort now preserves the full visual state too.

## [0.29.24] — 2026-04-24

### Changed
- **Every sort now ends by tidying the overflow (stock) tab.** Added a Phase 4 to `SortPlanner` that, after Phase 3's defensive sweep, reshapes the overflow tab into a deterministic contiguous layout starting at slot 1: stacks sorted by (itemID ASC, count DESC, original slot ASC), closing gaps and grouping same-item stacks. Previously the overflow was a dumping ground — Phase 1B/3 only grouped *new* spills via adjacency, so pre-existing scattered stacks stayed scattered. Repeat sorts are now idempotent (already-compact overflow → zero Phase 4 ops). Swap cycles within the overflow resolve through the same `findPivot` Phase 2 uses. Partial-stack merging (e.g. 10+10 → 20) is out of scope here — the planner has no max-stack knowledge; that's a follow-up.
- **Internal: extracted Phase 2's pivot-break loop into a reusable `pivotBreakLoop` local** so Phase 2 and Phase 4 share the same cycle-breaking machinery. No behavioral change to Phase 2.

## [0.29.23] — 2026-04-23

### Added
- **Live sort progress in the Sort tab.** While a sort is running, the Sort view now shows a running `Executing — N / T (X done, Y failed, Z replans)` line at the top of the move list, updated on every op transition via a new `GBL_SORT_PROGRESS` message. Each individual move row gets a status marker prepended as it advances: `▶` for currently executing, `✓` for completed (including late-ACK reclassification), and `✗` for failed. No network cost — sort execution is 100% local, and the UI updates are direct `SetText` calls on persistent widget references, not full tab rebuilds.
- **`GBL_SORT_PROGRESS` AceEvent message.** Emitted by SortExecutor on every state transition: `start`, `step`, `complete`, `failed`, `replan`, `reclassify`, `finish`. Payload includes `opIndex`, `done`, `failed`, `replans`, `total`, `currentOp`, and per-phase extras (`completedOpIndex`, `failedOpIndex`, `reclassifiedOpIndex`, `replanReason`, `ok`, `reason`). External consumers (UI, chat formatters, audit plumbing) can subscribe without poking into executor-local state.

## [0.29.22] — 2026-04-23

### Fixed
- **Late-ACK reclassification now fires during an in-flight op, not just when idle.** v0.29.19 added the grace window but gated it on `state.waiting == nil` — which in a live sort is almost never true (the inter-move gap is 0.3s, so a delayed 4-second ACK almost always arrives while the next op is already armed). The handler now checks `lastTimedOutOp` independently of `state.waiting`, so a late server ACK retroactively reclassifies the prior op as success even if the executor has already moved on. The second-pass check for the current in-flight op runs separately, so the event still advances the plan when it confirms the current op. This should collapse the noisy "op N timed out, op N+1 pre-check fail" audit lines down to clean "op N confirmed by late event" lines on realistic sorts.

### Changed
- **Dialed back the Capture button diagnostics to happy-path-silent.** v0.29.21 added loud chat output on every Capture click to chase a reported regression (turned out to be transient UI state that cleared on /reload). The pcall-wrapped error handler and the pinned-slot count in the success message both stay — they're cheap and useful. The per-branch state prints are removed since the regression isn't reproducible.

## [0.29.21] — 2026-04-23

### Added
- **Capture-button diagnostics in the Layout editor.** Clicking Capture now emits a chat line at every branch: the initial click (`Capture: click on tab N...`), the guard state (`scan=true/false slots=true/false dirty=... writable=...`), and a pcall-wrapped capture attempt so an unexpected Lua error in `CaptureTabLayout` surfaces as a visible message instead of a silent failure. The success message now also reports the number of pinned slots alongside distinct items. Purpose: chase down a reported regression where Capture on a freshly-switched-to-Display tab appeared to do nothing.

## [0.29.20] — 2026-04-23

### Added
- **Timeout-time state diagnostics in SortExecutor.** When a move op times out, the audit trail now dumps three extra lines per timeout: (1) a one-word classification — `[none]` (move never executed), `[partial]` (pickup done, drop failed), `[complete]` (move succeeded, ACK was lost), or `[other]` (anomalous); (2) the full op details (src/dst tab+slot, itemID, count, op type); (3) observed live state of src, dst, and cursor. Purpose: distinguish server-drop vs. late-ACK vs. cursor-leak scenarios without round-tripping for more data. Also added the same op-details line to dst-mismatch pre-check failures so the cascading-replan case is legible in the audit trail.

## [0.29.19] — 2026-04-23

### Fixed
- **Late ACK after move timeout no longer triggers a cascade abort.** The SortExecutor waits up to `MOVE_CONFIRM_TIMEOUT` seconds after issuing each move for `GUILDBANKBAGSLOTS_CHANGED`; when the timeout fired first, the subsequent (legitimate but late) event was misclassified as "foreign activity" and triggered a replan. Replan's fresh scan saw the move already settled, but the new plan still listed the just-completed move as op 1 in some cases, producing a pre-check failure loop that chewed through all 5 replans before aborting. Observed in-game with 2/222 ops completed before abort. The executor now tracks the most recent timed-out op for a short grace window (`LATE_ACK_GRACE = 5s`) and, if a stray `GUILDBANKBAGSLOTS_CHANGED` arrives while idle AND the timed-out op's dst slot is now populated as expected, retroactively reclassifies the op as success rather than replanning.

### Changed
- **`MOVE_CONFIRM_TIMEOUT` raised from 2s → 4s** to reduce how often legitimate server ACKs race the timeout on high-latency realms. Sort throughput is unchanged in the happy path (fast ACKs still advance immediately); this only matters for slow ACKs that would otherwise get misclassified.
- **`SCAN_WAIT_TIMEOUT` raised from 5s → 10s.** Full-bank scans on 7+ populated tabs were observed taking ~4s in-game, too close to the 5s cap — one slow scan was enough to abort an otherwise-recoverable sort run.

## [0.29.18] — 2026-04-23

### Added
- **"Unpin all slots" button per display tab.** Sits next to "Capture current layout" in the Layout editor. Clicking wipes `tab.slotOrder` and leaves `items` intact — so the same item list is retained but every slot position becomes planner-decided at sort time. The intended use case (and v0.29.17 diagnostic target): you captured a tab with N items pinned to specific slots, then bumped Slots on some items to restock, and the new stacks scattered to the end of the tab instead of landing adjacent to their same-item group. One click of Unpin All lets the planner pack everything by adjacency on the next sort.
- **Per-item "Unpin" button** on every item row in the Layout editor. Clears `slotOrder` entries just for that one item; the rest stay pinned. Useful when you want most of a captured tab frozen but one high-churn item to flow freely. Disabled when the item has no pinned slots.
- **Pin-count label on every item row.** Between the `= N` total and the action buttons, each row now shows `N pinned` (yellow) or `not pinned` (gray) so the pin state is visible at a glance without scrolling down to the slot map.

### Mode guidance
There are now three legible modes per display tab:
1. **Fully pinned** — `Capture` a tab; every slot is pinned to a specific item. Sort enforces exact positions. Best for tabs you've deliberately arranged and don't want shuffled.
2. **Fully declarative** — `Capture` then `Unpin all slots`, or just `Add Item` without ever capturing. Items are listed with slot counts but no positions. Planner packs items by adjacency at sort time. Best for gem/stock tabs where you care about "these items exist" more than exact placement.
3. **Mixed** — Capture to fix some items, then `Unpin` the rows that should flow freely. Use when a handful of items deserve fixed positions but the rest should restock cleanly.

## [0.29.17] — 2026-04-23

### Added
- **Demand origin tracking in SortPlanner.** Each demand now carries an `origin` field — one of `"pinned"` (slotOrder entry from Capture), `"extend-right"` / `"extend-left"` (Pass 2a adjacency extension from a pinned claim), or `"first-empty"` (Pass 2b fallback when no adjacency is possible). Exposed on `plan.demandMap[tabIndex][slotIndex].origin`. The gem-tab restock pattern — pinned gems forcing new stacks to scatter to the end of the tab — is now visible in diagnostics as a high first-empty count alongside a high pinned count.
- **`/gbl sortpreview` per-tab origin breakdown.** After the `Plan: N moves, …` line, each display tab prints `T2 origins: 47 pinned + 3 auto-placed (0 extend-right, 0 extend-left, 3 first-empty)`. Each planned-move line is now annotated with `(dst pinned)` / `(dst extend-right)` / etc. so you can trace why each move lands where it lands.
- **Layout editor slot map header shows the three-way split.** Previous wording `"98/98 pinned"` is replaced with `"47 pinned + 3 auto-placed; 48 empty"`. The per-item line under "auto-placed at sort time" now distinguishes `(3 auto-placed)` from `(1 pinned + 3 auto-placed)` — the second form is the gem-tab pattern where an item has captured stacks plus new ones.

## [0.29.16] — 2026-04-23

### Fixed
- **Layout tab edits no longer show a visible scroll-snap flicker.** v0.29.15 preserved scroll position across rebuilds, but the Release → Build → SetScroll sequence was still visible as a brief blank-then-snap. The TabGroup's content frame is now hidden (alpha 0) for the duration of the rebuild and revealed (alpha 1) after scroll has been re-applied, masking the flicker entirely. From the user's perspective the tab appears static during edits.

## [0.29.15] — 2026-04-23

### Fixed
- **Layout tab no longer scrolls to the top every time you press Enter in an EditBox.** The tab rebuilds itself on every edit (to keep the slot budget label, save/discard buttons, and slot map panel in sync with the draft state), but that rebuild also recreated the ScrollFrame — throwing away scroll position. Editing a Slots or Per slot value halfway down the page would jump you back to the top, making anything past the first tab untenable to configure. The ScrollFrame now persists its scroll position across rebuilds via `SetStatusTable` on a table owned by the addon, and is re-applied once the new layout settles so the user stays where they were.

## [0.29.14] — 2026-04-23

### Added
- **Slot map panel in the Layout editor.** Every display tab now shows its `slotOrder` as a compact run-length list right under the item-row table — e.g. `S1-S23 (23): Silvermoon Health Potion × 20`, `S24 (1): Light's Potential × 20`, `S25-S49 (25): Silvermoon Health Potion × 20`. A 1-slot run wedged between two long runs of another item now stands out visually, which is exactly what the v0.29.12 "hidden swap" incident needed. When a recent bank scan is loaded, each run is compared against live slot contents and annotated with a green ✓ (all match) or red ✗ (N mismatches) plus per-slot detail lines naming what's actually sitting there. Items whose `items[id].slots` exceeds their pinned slotOrder count list below as "auto-placed at sort time" — matches the v0.29.13 ownership split (Capture pins, everything else is planner-placed).
- **Pure `computeSlotRuns(slotOrder)` helper** exposed as `GBL._layoutEditorComputeSlotRuns` for the spec suite. Seven new tests cover empty input, contiguous fills, gap-breaks-run, the v0.29.12 anomaly shape (four runs including two 1-slot outliers), sparse non-adjacent keys, and nil inputs.

## [0.29.13] — 2026-04-23

### Changed
- **Layout editor no longer pre-pins `slotOrder` positions for Add Item or Slots-up edits.** The UI used to call a `pickSlotForItem` heuristic (right-extend → left-extend → first-empty) to pre-populate `slotOrder` every time a user added an item or bumped its Slots count. That pre-pin was indistinguishable from a real captured position — the planner would then rigidly enforce it as if the user had deliberately chosen that slot. The same adjacency logic already lives in `SortPlanner` Pass 2, so the prefill was pure duplication that just muddied the semantics of `slotOrder`. `slotOrder` is now written only by Capture (which reflects an observed bank state) and left untouched by Add Item / Slots-up (the planner places those demands adjacent to any existing pins at plan time). Result: saved layouts are smaller, `slotOrder` always means "pin these exact positions because I observed them," and the behavior for Add-Item-then-Sort is byte-identical to before. Slots-down still trims stale `slotOrder` pins, and Remove still clears entries for the removed item.

### Fixed
- **No more silent partial state from Add Item on a full captured tab.** Previously, if you added an item to a nearly-full captured tab, `items[id].slots` would be set but only some of the requested slots would get `slotOrder` entries (the rest silently dropped when `pickSlotForItem` ran out of empty slots). Validation caught the aggregate over-budget at save time, but not the specific "this item couldn't be placed" failure. With the prefill gone, the over-budget case surfaces cleanly at save time against the authoritative `items[id].slots` sum.

### Tests
- New `spec/sortplanner_spec.lua` test: a layout with three items, `items[].slots` set, and `slotOrder={}` produces the exact same final bank placement as the old pre-pinned variant — X/Y/Z packed contiguously at slots 1-5, 6-10, 11-15 in sortedID order.

## [0.29.12] — 2026-04-23

### Added
- **`/gbl deviations` (alias `/gbl devs`)** compares the current bank scan to the layout's expected demand map and prints every slot that doesn't match. Three categories of deviation are reported: wrong item, wrong count (same item), and empty-where-expected; plus "extras" for items sitting in unclaimed slots. Output is capped at 40 lines so a disastrous state doesn't flood chat; full detail stays in the audit trail.
- **Auto-run deviation check after Execute.** The Sort tab already rescans after Execute (v0.29.9); it now also runs `PrintDeviations` once the fresh scan lands, so you immediately see what didn't match without having to type the command.
- **`plan.demandMap` exposed by `PlanSort`.** Maps `tabIndex` → `slotIndex` → `{itemID, perSlot}` for every display demand including `items[id].slots` extensions. Consumed by the deviations check and available to other diagnostics. Backward-compatible additive field; consumers that don't read it are unaffected.
- **Pre-check failure audit entries now include the observed state.** Instead of `"Sort: replan (src mismatch at op N)"`, the audit now records `"Sort op N/M pre-check fail src T1/S5: expected it:12345 x>=20, got it:99999 x10"`. Makes it obvious whether foreign activity, a split-size drift, or a planner bug caused the replan.

## [0.29.11] — 2026-04-23

### Fixed
- **Sort now keeps each item's span contiguous in the display tab.** When `items[id].slots` exceeded the captured `slotOrder` entries (e.g., you captured 25 slots and then edited Slots up to 49), the planner's Pass 2 used to fill "first unclaimed slot" and could land items in the middle of another item's section depending on itemID ordering. The planner now extends an item's contiguous group RIGHT first, then LEFT, only falling back to arbitrary empty slots when both ends are blocked. Result: a group that started at 50-74 grows to 50-98 before it ever reaches back to slot 49.
- **Overflow (stock) tab stays organized by item.** Before, spills routed to the first empty overflow slot regardless of what was next to it — a stray Power Potion would land between a Health block and whatever else was in stock. The planner now prefers slots adjacent to existing same-item stacks (right-extend first, then left-extend), so stock grows by item group instead of filling the next free slot.
- **Layout editor's Add Item and Slots field apply the same adjacency rule.** New item rows and Slots-increase edits now extend the item's contiguous group instead of picking the first empty slotOrder position. Keeps saved layouts neat without requiring a recapture.

## [0.29.10] — 2026-04-23

### Fixed
- **First-bank-open scan after login no longer misses every item.** The scanner was scanning each tab immediately after calling `QueryGuildBankTab`, but on first open the client has no slot data yet — so 98 slots read as nil, the event handler was unregistered too early, and when the server's actual response arrived the scanner had already moved on. Result: the first scan after login saw the bank as empty, and the Sort tab reported everything as "missing." The scanner now waits for `GUILDBANKBAGSLOTS_CHANGED` before scanning a tab, with a 3-second timeout fallback for tabs that genuinely have nothing to send.

## [0.29.9] — 2026-04-23

### Fixed
- **Sort tab now auto-refreshes after Execute.** Preview was previously re-running against the pre-sort snapshot (the cached scan is stale until you rescan), so the plan looked unchanged even after sort had actually run. The tab now triggers a fresh scan when Execute completes, shows a "Rescanning bank after sort…" placeholder while it waits, then re-previews against the post-sort state.

## [0.29.8] — 2026-04-23

### Fixed
- **Sort planner now honors `items[id].slots` as the authoritative demand count.** Before, the planner counted demands from `slotOrder` entries only — so if you captured a layout with 3 slots of an item and then edited the Slots field in the Layout UI to 5, the 2 extra slots were silently dropped from the plan (reported as "no discrepancy"). The planner now emits demands up to `items[id].slots`, adding extras at the first unclaimed slot indices. Both directions are handled: increasing Slots adds demands at new positions; decreasing Slots caps demands at the new count and routes the surplus to overflow.
- **Phase 3 sweep no longer mis-evicts items placed by dynamically-added demands.** The sweep consulted raw `slotOrder` rather than the effective demand set, so items placed at Pass 2's extended positions were treated as stragglers and routed to overflow on the next op. Fixed by checking the effective demand map.
- **Layout editor's Slots input now keeps `slotOrder` in sync.** Increasing Slots adds slot-order entries at the first unclaimed indices; decreasing Slots trims from the highest slot index down. Prevents the mismatch above from ever being saved again.

### Added
- **`/gbl sortpreview` now prints a diagnostic breakdown.** Shows per-display-tab demand counts, overflow/ignore tab assignments, scan contents by tab, and an explicit reason when the plan is empty ("layout has no display-tab demands" vs. "every demand is already satisfied") — makes it obvious whether a 0-op result is a config issue or the bank truly matches.
- Two new regression tests in `spec/sortplanner_spec.lua`: `items[id].slots` exceeds `slotOrder` count (pass extras into unclaimed slots) and `slotOrder` exceeds `items[id].slots` (cap at items count and send surplus to overflow).

## [0.29.7] — 2026-04-23

**Milestone M-sort-2.5: Planner algorithm upgrade**

### Changed
- **Sort planner rewritten from three-pass greedy to assign-then-schedule.** Same public contract (`PlanSort(snapshot, layout)` returns the same shape), no UI or saved-variable changes — a drop-in upgrade. Phase 1 assigns every demand to the best available source (same-tab direct → overflow → cross-tab; largest-count first within each tier). Phase 2 schedules the moves against a mutating state model and breaks swap cycles with a pivot slot (same-tab empty preferred, overflow fallback). Phase 3 sweeps any stragglers.
- **Direct intra-tab moves skip the overflow round-trip.** An item in the wrong slot of the right tab now moves straight to its template slot — one op instead of two (evict + pull back).
- **Oversize stacks serve multiple demands from a single source.** An oversize stack is no longer pre-split to overflow before the planner has looked at other demands; it splits directly into each destination that needs the item.
- **Largest-source-first source selection minimizes split count.** When multiple same-item stacks can fill a demand, the planner picks the largest first so a single split ends the work.
- **Swap cycles are detected and resolved with a pivot.** 2-cycles cost 3 ops (was 4 via overflow), 3-cycles cost 4 ops (was 6). Unreachable cycles — no empty unclaimed slot anywhere — are now reported as `unplaced` entries with `reason = "cycle-no-pivot"` instead of silently emitting half-broken ops.

### Added
- `plan.unplaced[].reason` field — one of `"overflow-full"`, `"cycle-no-pivot"`, `"no-overflow-defined"`. Backward-compatible (old callers ignore it); the existing SortExecutor and UI/SortView are unaffected.
- 9 new planner tests in `spec/sortplanner_spec.lua` pinning the algorithmic wins (direct move, oversize split sharing, same-tab pivot, overflow pivot fallback, 3-cycle break, largest-first, unreachable-cycle unplaced, oversize-keep excess harvest).
- `spec/sortplanner_perf_spec.lua` — benchmark asserting a worst-case plan (8 tabs × 98 slots, 90 demands) completes in under 250 ms.

## [0.29.6] — 2026-04-23

### Changed
- **Layout tab save-bar is now self-explanatory.** The explicit save model (edits buffer in a draft until you click Save) is unchanged — that's deliberate so validation and sync broadcasts happen once per logical change, not per keystroke — but the UI now makes the state obvious. A status banner above the save row reads "You have unsaved changes…" when the draft differs from storage, or "Layout is up to date…" when clean. The save button is disabled and labels itself "Saved ✓" when there's nothing to commit, "Save Layout" when dirty. "Revert" was renamed to "Discard changes" and disables when clean. Capture now explicitly notes "Click Save Layout to commit" in its success message.

## [0.29.5] — 2026-04-23

### Fixed
- **Capture current layout** now works in more states. Previously it silently did nothing when the addon had no stored scan for the target tab (no visible feedback either — the failure print was easy to miss). It now: (a) warns if the bank is closed, (b) kicks off a scan automatically if no scan exists, (c) polls for scan completion up to 5 seconds, (d) applies the capture when data arrives, and (e) surfaces a specific error if the scan never produced data for the target tab (e.g., the character can't view it). Prints a green success line on completion.

## [0.29.4] — 2026-04-23

### Fixed
- **Layout tab dropdowns are now interactive.** Mode changes (display / overflow / ignore) were being wiped immediately on refresh because `BuildLayoutTab` re-initialized the in-progress draft from saved storage on every render. The draft now persists across rebuilds and is only reset explicitly on Save or Revert.
- **Sort Access rank dropdown now shows all options and defaults correctly.** It was built as an array instead of a hash keyed by option value, so AceGUI rendered the first two entries as blank. The dropdown now shows "None (GM only)" followed by "Rank N and above (rankname)" for each guild rank.

## [0.29.3] — 2026-04-23

**Milestone M-sort-2 (UI): Layout editor + Sort tab**

### Added
- **Layout tab** — one section per guild-bank tab with a Mode dropdown (Display / Overflow / Ignore). Display tabs gain an item-template editor: a row per item with Slots / Per-slot inputs and a live slot-budget readout; a "Capture current layout" button that snapshots a hand-arranged tab into the template; and an Add-item input that accepts either a numeric itemID or a pasted item link. Save / Revert buttons on the bottom. Tab is only visible to characters with sort access; all controls are read-only when viewed without access.
- **Sort tab** — Preview button builds a plan from the latest scan and renders the planned moves, deficits, and unplaced items with human-readable item names. Execute button runs the plan through `SortExecutor` (gated by `HasSortAccess()`), Cancel button aborts. A Scan-bank shortcut is included so you don't have to leave the tab to refresh.
- **Sort Access** sub-section inside the Layout tab — GM-only rank-threshold dropdown (populated from guild ranks) + delegate add/remove. Non-GMs see the current policy read-only.
- Tab visibility is now access-aware: the Layout tab only appears for characters with sort access. Others still see Sort for read-only preview.

### Notes
- This completes M-sort-2. Next milestone (M-sort-3) adds the Stock tab + bag restocker.

## [0.29.2] — 2026-04-23

**Milestone M-sort-2 (backbone): Sort executor + sort-access policy**

### Added
- `SortAccess` policy — a new AceDB field (`sortAccess`) and `GBL:HasSortAccess()` helper that mirror the existing access-control pattern. The Guild Master configures a rank threshold and an optional list of named delegates; any character who is the GM, at-or-above the threshold, or explicitly delegated can edit bank layouts and execute sort. Writes to the policy itself remain GM-only so delegates can't self-escalate. Default is GM-only on fresh install.
- `SortExecutor` module — executes a plan one op at a time with a 0.3s inter-move throttle, pre-step verification against live bank state, `GUILDBANKBAGSLOTS_CHANGED`-driven confirmation plus a 2-second polling fallback, replan-on-foreign-activity (capped at 5 replans per run), bank-close abort, and cursor-leak safety on every exit path. Audit entries trace every step, retry, replan, and failure.
- Two new slash commands for end-to-end in-game testing without UI:
  - `/gbl sortexec` — executes the currently saved layout's plan against the latest scan (GM/delegate-gated).
  - `/gbl sortcancel` — cancels a running sort.
- Mock WoW APIs for bank movement (`PickupGuildBankItem`, `SplitGuildBankItem`, `ClearCursor`, `CursorHasItem`) with cursor state tracking and `GUILDBANKBAGSLOTS_CHANGED` firing, plus test helpers to simulate foreign deposits/withdrawals. 10 new executor tests in `spec/sortexecutor_spec.lua` and 9 new access-policy tests in `spec/sortaccess_spec.lua`.

### Notes
- This is the non-UI half of M-sort-2. Layout editing and sort preview/execute UI come next. The executor can be fully exercised via the slash commands above.

## [0.29.1] — 2026-04-23

**Milestone M-sort-1.1: Audit cleanup for M-sort-1**

### Added
- CLAUDE.md Architecture section now lists `BankLayout` and `SortPlanner` alongside the existing modules, per the mandatory doc-sync-on-every-commit policy.
- Four regression tests in `spec/sortplanner_spec.lua`:
  - Ignore tabs are invisible to sort even when they hold an item the template wants — planner reports a deficit rather than pulling from ignore.
  - Keep-slot harvest protection: an already-correct slot is never cannibalized to fill another slot, even if it is the only source for that item. Pins the bug caught during M-sort-1 development.
  - Multiple display tabs: orphan items in a non-claiming display tab are evicted to overflow, then pulled into the claiming tab.
  - Overflow-full scenarios produce exactly one unplaced entry per stuck slot (no duplicates across passes).

### Fixed
- `SortPlanner` no longer emits duplicate `unplaced` entries when the overflow tab is full. Pass 1 now clears the working-bank copy of a slot it has recorded as unplaced so later passes don't re-process it. No effect on well-formed scenarios; only affects the overflow-saturated edge case.

### Notes
- No user-visible behavior change outside the overflow-full edge case. Pure audit follow-up.

## [0.29.0] — 2026-04-23

**Milestone M-sort-1: Bank sorting foundation (data + planner)**

### Added
- New `BankLayout` module: per-guild saved templates that describe each tab's role (`display`, `overflow`, or `ignore`). Display tabs list the items they hold along with how many slots each occupies and the target stack size per slot. Exactly one overflow tab is required; ignored tabs are untouched by sort. Includes `CaptureTabLayout` — reads the most recent scan of a tab and produces a template that mirrors its current contents, so officers can hand-arrange a tab once and save the result as the canonical layout.
- New `SortPlanner` module: given a bank scan and a saved layout, produces an ordered list of moves that will reshape the bank to match. Splits oversize stacks, pulls from other display tabs or the overflow tab to fill deficits, routes unassigned items to overflow, and reports shortfalls it could not satisfy. Pure function — no WoW API calls, fully deterministic, straightforward to test.
- AceDB schema: new per-guild `bankLayout` and `stockReserves` tables.
- Layout validation: exactly one overflow tab, no duplicate items across display tabs, per-tab slot budget ≤ 98, every `slotOrder` entry backed by a matching `items[]` row.

### Notes
- This milestone ships data + planner only. No execution, no UI, no sync wiring yet — those arrive in M-sort-2 through M-sort-4 on the `feature/sort-stock` branch.

## [0.28.12] - 2026-04-24

### Added
- GitHub Actions CI workflow (`.github/workflows/ci.yml`). Runs busted tests and luacheck on every pull request and on every push to `main`. Job context is `test-and-lint`, which Phase C will require as a passing status check before merge.

### Changed
- `.luacheckrc` extended to keep luacheck clean under CI: added `GameFontNormalLarge`, `GetItemInfo`, `GetRealmName`, `GetNormalizedRealmName` to read-only globals; ignored warning code 542 (intentional empty-if-branch pattern used for early-out comments); suppressed `max_line_length` for `Core.lua` (TODO: extract a `SafeRecordTimestamp` helper for the six repeated migration lines) and `UI/ChangelogView.lua` (changelog strings are intentionally one line per entry).

### Removed
- Dead `local savedSchema` capture in `Core.lua`'s migration pass-1 path. The variable was assigned but never read.

## [0.28.11] - 2026-04-24

### Added
- `CONTRIBUTING.md` with quick-start setup, commit + versioning conventions, test expectations, code style, and WoW-specific gotchas for new contributors.
- `.github/PULL_REQUEST_TEMPLATE.md` with structured Summary / Testing / Screenshots / Checklist sections.
- `.github/CODEOWNERS` so the maintainer is auto-requested as reviewer on every PR.
- README "Contributing" section linking to `CONTRIBUTING.md`.

## [0.28.10] — 2026-04-24

### Fixed
- Removed blank space at the bottom of all six tabs — Transactions, Gold Log, Consumption, Sync, Changelog, and About — by anchoring each tab's content frame to the container's `BOTTOMRIGHT`. Thanks @katogaming88 for spotting it and fixing the first three tabs in #1; extended to Sync / Changelog / About in a follow-up on the same PR.

## [0.28.9] — 2026-04-24

### Added
- LuaLS workspace config (`.luarc.json`) so contributors get consistent IDE diagnostics out of the box (Lua 5.1 runtime + WoW API globals).
- Internal design doc (`docs/sync-bucket-analysis.md`) capturing the v0.26.0-era throughput audit that justifies the 6-hour fingerprint bucket size — preserved for reproducibility now that the analysis lives outside the memory index.

### Changed
- CurseForge listing copy refreshed (Beta tag, reorganized sections, updated category counts). No code change.

### Fixed
- `.gitignore` now excludes `.claude/walkthrough/` and `.claude/settings.local.json` so machine-local Claude Code state stops appearing in `git status`.

## [0.28.8] — 2026-04-23

### Added
- Receiver-side redundancy metric in sync audit. New `Redundancy from <peer>` line in `FinishReceiving` reports total dupes/received plus item-vs-money split (e.g., `Redundancy from PeerX: 78% duped (1023/1314 received) — items: 65% (412/635), money: 90% (611/679)`). Per-chunk audit lines also gain a running `X% dup` annotation in the "total so far" segment. Diagnostics-only — no protocol or behavior change. Suppression rules: line omitted entirely when no records were received; items/money segments individually omitted when their record type is absent. Purpose: measure how often the bucket-filtered sync ships records the receiver already has, to inform whether a future manifest-exchange protocol change is justified by observed redundancy in real syncs.

## [0.28.7] — 2026-04-22

### Fixed
- Sync reliability: chunk budget reduced to a true 1-fragment target (`MAX_RECORDS_PER_CHUNK`: 10→4, `CHUNK_BYTE_BUDGET`: 2500→900). v0.28.6 aimed for 2 fragments but real cross-realm compression ratio is 23–26%, not ~18% as assumed — compressed chunks landed at 659–737 bytes (3 fragments) and the sync aborted at chunk 38/331 with `p_frag_est=44.9%`. At 900 raw bytes with 26% worst-case compression, compressed stays ≤240 bytes = 1 AceComm fragment per chunk. Per-attempt loss drops from ~45% (v0.28.6) to ~18%; 6-retry failure drops from ~0.8% to ~0.003% per chunk; likelihood of a full bootstrap sync completing goes from ~6% to ~97% on a cross-realm peer. Total sync time ~18 min for a ~3300-record bootstrap (subsequent syncs much shorter after bucket-delta convergence).

### Added
- Diagnostics bundle for per-sync A/B comparison:
  - **Retry cause tagging.** Each retry is tagged with its trigger (`ackTimeout` or `nack`). Aborts are split by cause: `combatAbort`, `zoneAbort`, `busyAbort`, `sendFailed` (target offline). Previous single-bucket `aborted` lost the distinction between a noisy test session and a genuine wire-loss problem.
  - **Corrected `p_frag_est` math.** Old metric computed `failedAttempts/totalAttempts` (chunk-fail rate) but labeled it per-fragment. New output reports both: `chunkFail` (raw retry rate attributed to wire loss only) and `p_frag` (back-solved per-fragment estimate using observed average fragments per chunk). At n=1 frag the two are equal; at higher n the inversion kicks in so comparisons across chunk-size changes are valid.
  - **Per-peer attribution.** `FinishSending` now emits three per-peer audit lines: `Sync outcomes for <peer>`, `Retry causes for <peer>`, `Compression for <peer>` (min/med/max compression percentage). With rotating cross-realm testers, per-peer is the only meaningful axis — a version that works on same-realm but fails cross-realm is no longer averaged away.
  - **Per-chunk compression capture.** Each chunk's compressed bytes and ratio stored in `chunkOutcomes`, aggregated at end-of-sync. The v0.28.6 compression-ratio miss (23–26% vs ~18% predicted) would have been visible from one sync's audit line rather than requiring hand-parsing multiple chunk lines.

## [0.28.6] — 2026-04-22

### Fixed
- Sync reliability: chunk density reduced further (`MAX_RECORDS_PER_CHUNK`: 25→10, `CHUNK_BYTE_BUDGET`: 3200→2500) so compressed chunks fit in 2 AceComm wire fragments instead of 4. v0.28.5 logs showed the v0.28.5 chunk revert (25/3200) did not actually cross the 3-fragment threshold — compressed payload stayed at ~836 bytes, still 4 fragments. Observed per-attempt chunk-loss rate on cross-realm whispers was ~67%, implying ~24% per-fragment drop. Halving the fragment count per chunk cuts per-attempt loss to ~42% and the 6-retry failure probability to under 1% per chunk. Total sync time roughly doubles in chunk count but actually completes instead of aborting.
- A conservative 1-fragment fallback (5 records / 1500 byte budget) is pinned as a commented block in `Sync.lua` and documented in `CLAUDE.md` — flip to it if v0.28.6 still aborts on cross-realm syncs.

## [0.28.5] — 2026-04-22

### Fixed
- Sync reliability: inter-chunk gap floor of 1.0s added between chunk transmissions to avoid WoW's server-side per-recipient whisper throttle, which silently drops the 3rd+ rapid-succession addon message to a single peer. Paired sender/receiver logs captured with v0.28.4 instrumentation confirmed this was the dominant failure mode — chunk 3 vanished deterministically across 6 ACK-timeout retries plus 2 NACK retransmits, while CTL and client-side pacing reported healthy. The floor is independent of `CTL_BACKOFF_DELAY` and the post-ACK `GetSyncDelay()`; the first chunk is exempt, zone/combat pause resumes already exceed it, and ACK-timeout retries naturally satisfy it.
- Chunk density reverted from v0.28.0's aggressive tuning back to v0.27.0 values (`MAX_RECORDS_PER_CHUNK`: 35→25, `CHUNK_BYTE_BUDGET`: 5000→3200). Compressed chunks drop from ~4 AceComm wire fragments to ~3, making each chunk cheaper in the throttle budget and more resilient to residual fragment-level loss. Trade-off accepted: ~40% more chunks per sync, but total sync time is longer only because syncs now complete instead of aborting.

## [0.28.4] — 2026-04-22

### Added
- Sync diagnostic instrumentation — additive audit-log fields to distinguish between four competing failure hypotheses (fragment loss, server-side throttle, receiver-buffer contention, wire-vs-ACK timing) without changing protocol behavior:
  - `Sending chunk` entries now include `CTLq=A/N/B` — ChatThrottleLib priority-queue depths (ALERT/NORMAL/BULK) — when `ChatThrottleLib.Prio` is exposed. Distinguishes "CTL clear" from "CTL has bandwidth but other addons have queued traffic ahead of us."
  - `Sending chunk` entries now include `gap=X.XXs` — wall-clock delta since the previous chunk was issued. Directly tests the server-side per-recipient throttle hypothesis by correlating failures with sub-second inter-chunk spacing.
  - Successful ACK entries (first, every 10th, last) now include `wire-to-ACK=X.XXs` — elapsed time from AceComm wire-completion callback to ACK receipt. Discriminates "AceComm callback fires before wire transmission actually completes" from genuine peer/network latency.
  - ACK timeout entries now include `fragments~=N`, `gapSinceWire=X.XXs`, and `nacksThisChunk=N` — converts the previously terse timeout line into the primary forensic row for every failed chunk.
  - `FinishSending` now emits `Sync outcomes: a on 1st, b on 2nd, c on 3rd+, d aborted, p_frag_est=X.X%` — per-sync retry histogram with a rough fragment-loss-probability estimate (clamped to [0, 50%], reported `n/a` when fewer than 3 chunks are observed). Quantifies the fragment-loss hypothesis directly.

## [0.28.3] — 2026-04-21

### Changed
- Interface version updated from 120001 to 120005 (WoW 12.0.5)

### Added
- GitHub Action to auto-detect WoW interface version bumps and create PRs (`toc-update.yml`)

## [0.28.2] — 2026-04-21

### Fixed
- Sync send pacing: `HasSyncBandwidth` now requires CTL.avail > compressed chunk size (dynamic threshold) instead of a fixed 200 bytes, eliminating burst-queue pattern where 6-7 chunks would drain CTL to zero followed by 60-90 second stalls.
- CTL_BANDWIDTH_MIN raised back to 400 (floor) and CTL_BACKOFF_DELAY increased to 1.0s for efficient polling during recovery.
- HELLO replies suppressed during active sync — prevents third-party peers from consuming CTL bandwidth needed for SYNC_DATA transmission.

## [0.28.1] — 2026-04-20

### Added
- Sync diagnostic logging to identify two observed failure modes: CTL deferral death spiral (Mode A) and AceComm message loss (Mode B).
- CTL deferral entries now include `CTL.avail` value, monotonic counter, and `GetTime()` precision timestamps for chain analysis.
- CTL deferral audit entries rate-limited: first 10 verbose, then every 20th — prevents eviction of protocol events in long syncs.
- "Sending chunk" entries now include `CTL.avail` at send time (headroom diagnostic).
- AceComm transmit callback logged ("Chunk X transmitted") with queue-to-wire duration and post-transmit CTL.avail — absence between send and ACK timeout proves message stuck in queue.
- HELLO replies during active sync tagged `[DURING SYNC — CTL cost]` with per-session counter.
- NACK receipt entries include `CTL.avail` to prove sender-stuck-in-deferral feedback loop.
- Per-sync summary at FinishSending: CTL deferrals, HELLO replies during sync, NACKs received.

### Changed
- Audit trail cap increased from 200 to 2000 entries to capture full sync lifecycle.

## [0.28.0] — 2026-04-19

### Changed
- Sync throughput optimized: HELLO and MANIFEST broadcasts suppressed during active sync (keepalive every ~280s prevents peer staleness), CTL backoff delay reduced from 1.0s to 0.25s, CTL bandwidth threshold lowered from 400 to 200 bytes.
- Chunk density increased: byte budget raised from 3200 to 5000 and record cap from 25 to 35, reducing chunk count by ~36% for large syncs.

## [0.27.0] — 2026-04-19

### Fixed
- Records with Unix epoch 0 timestamps repaired — multiple `or 0` fallbacks replaced with validated timestamps across Dedup, Sync, Ledger, Core, Fingerprint, and ConsumptionView.
- Schema migration 7→8 repairs existing epoch-0 records (recovers timestamps from ID when possible) and cleans up bogus 1970-01-01 compacted summaries.

### Added
- "Open Sync Log" button in Sync tab for quick access to the copy-pastable sync log.
- Bottleneck diagnostics in audit trail: per-chunk RTT, CTL bandwidth backoff, compression ratio, pending peer queue time.
- `IsValidTimestamp` validation helper prevents future epoch-0 writes at all storage boundaries (StoreTx, StoreMoneyTx, MarkSeen).

### Changed
- Sync logging unified into single `AddAuditEntry` system — `SyncLog` function removed; chat and audit trail now report identical information via `chatOnly` parameter.
- Enriched audit messages: hard timeout includes duration, ACK retry includes "ACK timeout" prefix, NACK includes retry limit, received chunks include running totals.
- BUSY abort-send and BUSY clear-receive now create audit entries (previously chat-only).

## [0.26.0] — 2026-04-17

### Added
- Sync aborts immediately when entering combat (M+, raid) and notifies the partner via BUSY — previously the sync stalled through ~95 seconds of NACK timeout cycles.
- Separate 2-second combat cooldown prevents sync from resuming during rapid trash-pack combat cycling.
- HandleBusy now also aborts sending when the send target reports busy — previously only aborted receiving.
- Sync status UI shows "Paused (combat)" when combat pause is active.

## [0.25.5] — 2026-04-17

### Fixed
- Periodic rescan no longer double-stores records that arrived via sync — session caches are invalidated after each sync chunk so the next rescan uses ground-truth record counts.

## [0.25.4] — 2026-04-17

### Fixed
- Sync no longer requests data from peers with fewer records — avoids receiving 100% duplicate chunks that waste bandwidth and slow down the outbound sync that actually matters.
- Bidirectional check after sending now skips reverse-requesting from peers with fewer records, deferring to the peer's post-sync HELLO for convergence.

## [0.25.3] — 2026-04-17

### Fixed
- Sync receiving state no longer gets permanently stuck when a sync request goes unanswered — `RequestSync` now uses `ScheduleReceiveTimeout()` with proper NACK backoff and retry limits instead of a single-fire timer that expired after one attempt.
- BUSY response from a peer now clears receiving state even when partial data has been received, preventing permanent sync blockage.
- Added 30-minute safety net (`MAX_RECEIVE_DURATION`) to auto-abort any stuck receive session, providing defense-in-depth against future edge cases.

## [0.25.2] — 2026-04-16

### Fixed
- Sync whispers to offline players no longer generate "No player named" system errors in chat — online status is checked before every whisper, and any errors from roster-lag race conditions are suppressed.
- In-progress sync aborts cleanly when the target peer goes offline instead of hanging for up to 120 seconds.

## [0.25.1] — 2026-04-16

### Fixed
- Online peers list showed peers for up to 5 minutes after they went offline — roster is now cross-checked even for recently-seen peers.

## [0.25.0] — 2026-04-16

### Added
- **Epidemic gossip sync**: data propagates exponentially across guild members — each peer becomes a seed after receiving data, leveraging N independent bandwidth budgets for O(log N) convergence instead of O(N).
- Concurrent send + receive: clients can send data to one peer while simultaneously receiving from another, doubling sync throughput per client.
- Smart peer selection: pending peer queue uses priority scoring (divergence, BUSY cooldown, starvation prevention) instead of FIFO — most divergent peers sync first.
- GUILD manifest broadcast: bucket hash manifests broadcast every 5 minutes so all peers know each other's data state without N² WHISPER exchanges.
- Hash-gated HELLO reply suppression: WHISPER replies to broadcast HELLOs are suppressed when our data hasn't changed, reducing O(N²) traffic to near-zero in large guilds.
- Forced HELLO rate limiting: post-sync forced HELLOs capped at one per 10 seconds to prevent broadcast storms during rapid epidemic propagation.

### Changed
- Bidirectional check delay reduced from 3s to 0.5s — peers discover new data faster after sync.
- Post-receive HELLO broadcast delay reduced from 2s to 0.5–2s with jitter — faster re-seeding without storms.
- Pending peers queue processing delay reduced from 1s to 0.2s — faster epidemic chain reactions.
- Sync initiation jitter reduced from 0–2s to 0–1s — sufficient for oscillation prevention with bucket-based delta sync.

## [0.24.0] — 2026-04-15

### Added
- "Show minimap button" toggle in settings — hides the minimap icon while keeping the LibDataBroker launcher active for display addons (Titan Panel, ChocolateBar, etc.). (Requested by Rox)

## [0.23.0] — 2026-04-15

### Changed
- Sync chunk budget doubled (1600→3200 bytes) and record cap raised (15→25) — halves chunk count for faster syncs.
- ACK timeout reduced from 15s to 8s with more retries (3→5) — faster recovery from message loss.
- ACK and NACK messages now sent with ALERT priority for faster delivery through ChatThrottleLib.

### Fixed
- Stale ACKs from retried chunks no longer orphan active timers, which could cause 120-second sync stalls.

## [0.22.4] — 2026-04-15

### Added
- Peers in M+ dungeons or raid boss fights now stay visible in the Online Peers list as "online (no HELLO)" using guild roster fallback — previously they disappeared after 5 minutes.
- Known peers are persisted across sessions so addon users appear immediately on login even if currently in instanced content.
- Stale known peer entries automatically expire after 30 days without a HELLO.

## [0.22.3] — 2026-04-15

### Fixed
- Sync status now shows both "Sending" and "Receiving" when active simultaneously — previously only showed sending due to `if/elseif` precedence bug.
- Receive progress displays "waiting..." instead of confusing "0/0" while awaiting first chunk from peer.

## [0.22.2] — 2026-04-15

### Fixed
- Pending peers queue no longer attempts sync with peers confirmed offline by guild roster — `PopPendingPeer()` now checks `IsGuildMemberOnline()` before returning a queued peer.
- `FinishReceiving()` now removes the sender from the pending queue, preventing immediate re-request after a sync completes or aborts.

## [0.22.1] — 2026-04-15

### Fixed
- Automatic duplicate cleanup now runs after bank scan refreshes eventCounts, fixing a bug where duplicates from prior sync sessions survived because the OnEnable cleanup lacked fresh API ground truth to detect them.

## [0.22.0] — 2026-04-15

### Added
- **BUSY message type** — When a sync request is declined (sender already busy), a BUSY response is sent immediately so the requester doesn't wait 60s for data that will never come.
- **Pending peers queue** — Missed sync opportunities (busy, combat, zone change) are queued and automatically retried after the current sync completes. Capped at 10 peers.
- **Post-sync HELLO broadcast** — After receiving new data, broadcasts updated dataset fingerprint so peers discover the new data and can request it.
- **Post-sync queue processing** — After completing a receive, automatically syncs with the next queued peer.
- **Bidirectional sync** — After finishing sending data to a peer, checks if that peer has data we need and requests it (3s delay for processing).
- **Combat guard** — Sync initiation deferred during combat (PLAYER_REGEN_ENABLED resumes pending queue).
- **Mutual sync jitter** — 0-2s random delay on sync initiation to prevent collisions when multiple peers respond to the same HELLO.
- **Sender offline detection** — During receive timeout, checks guild roster to abort early if the sender went offline instead of waiting for NACK retries.
- **NACK backoff** — Progressive timeout delays (20s → 30s → 45s) instead of fixed 20s intervals for NACK retries.

### Changed
- **Shorter first-chunk timeout** — Initial receive timeout reduced from 20s to 10s since in-game addon messages have no network latency.
- **GetSyncStatus** now includes `pendingPeersCount` and `receiveNackCount` fields.

## [0.21.0] — 2026-04-14

### Added
- **About tab** — New right-aligned tab with addon info, author credit (RexxyBear), copyable Ko-fi and CurseForge URLs, library credits, and license info. Visible to all access levels.
- **GitHub Sponsors integration** — `.github/FUNDING.yml` enables the Sponsor button on the repository (GitHub Sponsors + Ko-fi).
- **Support section in README** — Ko-fi and GitHub Sponsors links.
- **`.toc` donation metadata** — `X-Donate` field for CurseForge integration.

## [0.20.1] — 2026-04-14

### Changed
- **Roadmap: moved Export to post-1.0** — Export feature (CSV, Discord Markdown, BBCode) deprioritized from beta release path to post-1.0. Stabilization is now the next milestone after beta preparation.

## [0.20.0] — 2026-04-14

### Changed
- **Documentation sync for beta preparation** — Updated README with accurate feature list (guild-wide sync, changelog tab, version label, peer version status, access control, 4 colorblind modes). Replaced stale ROADMAP with forward-looking release plan (v0.20.x beta prep, v0.21.0 export/beta, v1.0.0 public release, post-1.0 features). Updated CurseForge description from "Alpha" to "Beta" with correct consumption dashboard description. Updated .toc Notes to mention sync.

### Fixed
- **Changelog tab showing blank content** — pagination nav bar was added as a sibling before the ScrollFrame, preventing it from getting proper height in AceGUI's List layout. Moved nav controls inside the ScrollFrame so it remains the only direct container child.

### Removed
- `docs/IMPLEMENTATION_PLAN.md` — Obsolete planning document (v0.11.0 era), superseded by ROADMAP.md and CHANGELOG.md.
- `docs/PLAN.md` — Obsolete planning document, superseded by ROADMAP.md.

## [0.19.3] — 2026-04-14

### Changed
- **Sync and Changelog tabs right-aligned** — utility tabs (Sync, Changelog) are now pushed to the right side of the tab bar, visually separating them from the data tabs (Transactions, Gold Log, Consumption). Hooks AceGUI TabGroup's `BuildTabs` to reanchor on resize.

## [0.19.2] — 2026-04-14

### Changed
- **Changelog tab pagination** — changelog now loads 10 versions per page with Previous/Next navigation, eliminating the slow full-render on tab open. Nav bar hidden when data fits a single page. Buttons use dual-channel disabled state (text change + grayed) for accessibility. Page label respects font scaling.

## [0.19.1] — 2026-04-14

### Fixed
- **Sync chunk 1 oversized** — eventCounts metadata (dedup ground truth) was stuffed entirely into chunk 1, causing it to exceed AceComm's ~2KB WHISPER safe limit on full syncs. EventCounts are now partitioned into batches and spread across chunks. Fully backwards-compatible (no protocol version bump).

## [0.19.0] — 2026-04-14

### Changed
- **Consumption tab redesigned as guild-wide overview** — replaced collapsible per-player rows with a three-section dashboard: Guild Totals (items + gold in/out/net), Top Consumers (flat ranked table, top 10 players with full gold breakdown), and Most Used Items (top 15 items with 7d/30d/all-time withdrawal trend columns).
- Click a player name in Top Consumers to jump to the Transactions tab filtered by that player.

### Removed
- Collapsible player expand/collapse rows in the Consumption tab (replaced by flat tables).

## [0.18.1] — 2026-04-14

### Fixed
- **Changelog tab content truncated** — each version entry was rendered as a single AceGUI Label widget, which has a fixed single-line height and truncated multi-line text with "...". Refactored to emit one widget per visual line (version header, section headers, bullet items) so the full changelog is readable in-game.

## [0.18.0] — 2026-04-14

### Added
- **Directional peer version status** — sync peer list now distinguishes "newer — update available" (blue, when the peer has a newer version) from "outdated — no sync" (red-orange, when the peer is behind). Previously both cases showed the same ambiguous text.
- **Version label** — addon version now displayed in the top-right corner of the main frame. When any online peer has a newer version, the label turns orange with "update available (vX.Y.Z)!" text. Uses `GetScaledFont()` for accessibility.
- **`CompareSemver` utility** — new `GBL:CompareSemver(a, b)` method for numeric semver comparison (-1/0/1). Used by sync and UI for version directionality.
- **`GetHighestPeerVersion` getter** — scans active peers and returns the highest version string for update detection.

## [0.17.0] — 2026-04-14

### Added
- **Event count metadata** — `StoreBatchRecords` now persists API-observed event counts per prefix+hour as ground truth for dedup cleanup. Counts propagate via sync (max wins) and survive across sessions.
- **Count-based cleanup** — new `CleanupWithEventCounts` replaces the anchor-based heuristic for post-schema-6 data. Uses persisted event counts to correctly distinguish diverged-index duplicates (trim) from genuine repeated events (preserve).
- **Post-sync cleanup** — `FinishReceiving` runs count-based cleanup after merging synced records, preventing diverged-index duplicates from accumulating between sync cycles.
- **eventCounts in sync protocol** — SYNC_DATA chunk 1 includes event counts; receiver merges with max(). Fully backwards-compatible with older peers (nil handled gracefully, no protocol version bump).
- **eventCounts pruning** — `PruneEventCounts` mirrors `PruneSeenHashes` lifecycle (90-day default in compaction, configurable in purge).

### Changed
- **`DeduplicateRecords`** — legacy anchor-based cleanup now only runs for pre-schema-6 data. Post-schema-6 data uses the authoritative count-based cleanup.

### Fixed
- **Genuine synced records no longer deleted by cleanup** — the "diverged-index duplicate vs genuine second event" problem is resolved. Both contradictory test cases now pass: count=1 trims excess, count=2 preserves both.

## [0.16.0] — 2026-04-14

### Added
- **Changelog tab** — new tab in the addon UI (next to Sync) displaying the full version history with color-coded sections. Available to all users including those in restricted access modes. Changelog data is embedded in `UI/ChangelogView.lua` and rendered via AceGUI ScrollFrame.

## [0.15.2] — 2026-04-14

### Fixed
- **Sync re-introducing duplicates after cleanup** — after independent migrations reassign occurrence indices on each client, `IsDuplicate` fails to match records with diverged indices. Fix: `DeduplicateRecords` now runs on every login/reload (before sync starts), cleaning dirty data from any source before the session begins.

### Added
- **`DeduplicateRecords` function** — schema-independent two-pass dedup (same-slot + cross-slot) extracted from `RunCleanup`. Runs automatically on every startup; also used by `/gbl cleanup`.

## [0.15.1] — 2026-04-13

### Fixed
- **ItemCache error on uncached items** — `C_Item.RequestLoadItemData` expects an `ItemLocation` struct, not a numeric itemID. Replaced with `C_Item.RequestLoadItemDataByID(itemID)` which accepts a plain item ID. Caused a Lua error when opening the ledger UI with items not yet cached by the WoW client.

## [0.15.0] — 2026-04-13

### Added
- **Access control system** — GM (rank 0) can set a rank threshold that determines who gets full addon access. Players below the threshold are restricted to one of two modes, also configurable by the GM:
  - **Sync Only** — restricted users see only the Sync tab
  - **Own Transactions Only** — restricted users see all tabs but data is filtered to only their own transactions
- **Access control configuration UI** — GM-only section on the Sync tab with rank threshold dropdown, restriction mode dropdown, and Apply button
- **Access control sync** — settings propagate to guild members via the HELLO protocol; newer timestamps overwrite older ones
- **Restricted mode banner** — yellow label shown to restricted users explaining their access level
- **Schema migration v6→v7** — initializes the accessControl field on guild data

### Changed
- Settings row (Open with Guild Bank, Lock while scanning, Auto re-scan) now visible to all full-access users, not just a hardcoded officer rank
- Auto-open on bank visit works for all users except those in Sync Only mode (previously gated to a hardcoded officer rank)
- Tab list is now dynamic — rebuilds when access control settings change

### Fixed
- **Automatic migration now runs full dedup cleanup** — the v5→v6 migration skipped the same-slot dedup pass (v4→v5 logic) because `schemaVersion` was already 5 from v0.14.2. But the counting bug continued creating new same-slot duplicates between v0.14.2 and v0.14.3. The migration now re-runs both passes so duplicates are cleaned up on login without requiring `/gbl cleanup`.

### Removed
- `IsOfficerRank()` function and `autoOpenMaxRank` profile setting — replaced by the guild-wide access control system

## [0.14.3] — 2026-04-13

### Fixed
- **Duplicate records from seenTxHashes gaps after sync** — sync normalization (`NormalizeRecordId`) could remove an occurrence entry (e.g. `:1`) from `seenTxHashes` while moving it to a different slot, creating a gap. `CountStoredAtSlot` stopped at the gap and returned 0, causing `StoreBatchRecords` to store all records as "new" on the next bank open. Fix: initial scan now counts from the actual records array (`BuildStoredRecordIndex`) instead of `seenTxHashes`. Ground truth cannot have gaps.
- **Duplicate records from split adjacent slots** — `CountStoredForHash` returned at the first adjacent slot with matches, without checking the other side. Records split across slots 99 and 101 (from normalization) caused a query for slot 100 to only find one side, undercounting and creating duplicates. Fix: `CountFromRecordIndex` sums counts across all three slots (exact ± 1).
- **Occurrence ID collision after normalization** — new records could be assigned `:1` when `:1` was removed by normalization but `:2` still existed, causing ID collisions. Fix: `MaxOccurrenceAtSlot` scans past gaps to find the true next available index.

### Added
- **Schema migration v5→v6** — `MigrateCrossSlotDedup` removes cross-slot duplicates missed by the v4→v5 migration (which grouped by baseHash including slot). Groups by prefix (slot-independent), clusters by timestamp proximity (< 3600s), and anchors on earliest local scan. Rebuilds indices and stats.
- **`/gbl cleanup` enhanced** — now runs both same-slot (v4→v5) and cross-slot (v5→v6) dedup passes.

## [0.14.2] — 2026-04-13

### Fixed
- **Existing bug duplicates removed on upgrade** — one-time schema migration (v4→v5) identifies and removes duplicate records created by the occurrence index shift bug. Groups records by baseHash, anchors on the earliest local scan (which is always correct), and removes all excess copies. Rebuilds occurrence indices, `seenTxHashes`, and `playerStats` from surviving records. Prevents duplicate propagation via sync.

### Added
- **`/gbl cleanup` command** — manually re-runs the deduplication pass. Safety net for guild members who update late and receive stale duplicates via sync.

## [0.14.1] — 2026-04-13

### Fixed
- **Within-slot duplicate records on rescan** — v0.14.0 fixed cross-slot occurrence index shift but left the within-slot case broken: when a new identical transaction appeared in the same hour (same player, item, count, tab), WoW API's newest-first ordering caused it to steal occurrence `:0` from the existing record, creating a duplicate on every rescan. Root cause: `AssignOccurrenceIndices` assigns indices by batch position, which shifts when new records are prepended. Fix: replaced position-dependent occurrence indexing with count-based batch dedup (`StoreBatchRecords`). Compares "how many records exist per baseHash" against a session-local cache (rescans) or `seenTxHashes` (initial scan), storing only the difference. Immune to API ordering changes. Also handles hour-boundary drift via adjacent-slot probing.

## [0.14.0] — 2026-04-13

### Fixed
- **Duplicate records from occurrence index shift** — withdrawing the same item at different times caused each new withdrawal to shift the occurrence indices of all previously-stored same-prefix records, making them fail dedup on the next rescan. Example: 3 real breastplate withdrawals scanned incrementally could produce 6 records. Root cause: `AssignOccurrenceIndices` counted by prefix (without timeslot), so records in different hour slots shared a single counter. Fix: counter scope changed to per-baseHash (prefix + timeSlot), making each hour slot's counter independent. The `< 3600` timestamp check in `IsDuplicate` already prevents false-positive dedup between genuinely different events in adjacent slots.

### Changed
- **Schema migration v3→v4** — on first load, existing records are reindexed from cross-slot to per-slot occurrence indices and `seenTxHashes` is rebuilt. Existing duplicate records are preserved (indistinguishable from genuine same-hour events); future rescans will not create new duplicates.
- **Sync protocol version bumped to 4** — prevents cross-version sync between clients with old (cross-slot) and new (per-slot) occurrence schemes.

## [0.13.2] — 2026-04-13

### Fixed
- **Player name consolidation failure** — v0.13.0 migration ran before guild roster loaded, so `ResolvePlayerName` couldn't look up cross-realm players' actual realms (e.g., Katorri got assigned to local realm instead of Stormrage). Root cause: `GetGuildData()` returns nil during `OnEnable` because `GetGuildInfo("player")` isn't ready yet. Fix: migration now passes `playerRealms` directly instead of calling `GetGuildData()`, and `ResolvePlayerName` searches all guilds' caches as a fallback. Added `RepairPlayerNames()` which runs once after `GUILD_ROSTER_UPDATE` to fix records that were incorrectly resolved, rebuilds hashes, and merges duplicate playerStats.

## [0.13.1] — 2026-04-13

### Fixed
- **Outdated peers now visible in Online Peers** — peers with mismatched protocol or addon versions are tracked in the peer list instead of silently dropped. Displayed as "outdated — no sync" in red to indicate they are visible but will not participate in sync.

## [0.13.0] — 2026-04-13

### Added
- **Item name resolution for synced records** — new `ItemCache.lua` module lazily resolves item names from IDs using `GetItemInfo` + `GET_ITEM_INFO_RECEIVED`. Synced records that previously showed "Item #XXXXX" or blank item columns now display actual item names after a brief async load.
- **Guild roster cache** — persistent `playerRealms` mapping in SavedVariables tracks which realm each guild member belongs to. Updated on every `GUILD_ROSTER_UPDATE`. Survives guild departures.
- **StoreTx/StoreMoneyTx validation** — defense-in-depth: records with empty `type` or `player` are rejected at storage time, preventing corrupted records from entering the database.

### Changed
- **Player names always stored as Name-Realm** — all transaction records, playerStats keys, and summary player sets now use realm-qualified names (e.g., "Alice-Tichondrius" instead of "Alice"). Cross-realm and cross-faction guilds no longer fragment player data.
- **Sync restricted to exact version match** — peers on different addon versions are refused sync with an audit trail warning. Prevents data corruption when data formats change between versions. Protocol version bumped to 3.
- **Schema migration v2→v3** — on first load, all existing bare player names are resolved to Name-Realm format, corrupted records are removed, record IDs and seenTxHashes are rebuilt, playerStats entries are merged on collision, and daily/weekly summary player sets are normalized.

### Fixed
- **Sync chunk count off-by-one** — "send complete" log previously reported x+1/x chunks (e.g., "6/5 chunks"). The counter was incremented past the last chunk before `FinishSending()` read it. Now reports the correct count.
- **Consumption view player fragmentation** — players appearing as both "Alice" and "Alice-Realm" in the consumption view are now correctly merged into a single entry.
- **Player filter with realm names** — filter comparison now uses `StripRealm()` on both sides, so filtering works whether the user types a bare name or Name-Realm format.

## [0.12.2] — 2026-04-12

### Fixed
- **Corrupted sync records** — AceSerializer field boundary corruption during sync could produce records with mangled keys (`typyer`, `typelassID`, etc.), losing type and player fields. `reconstructSyncRecord` now validates required fields and rejects corrupted records. Migration cleanup removes 6 existing corrupted records from SavedVariables.

## [0.12.1] — 2026-04-12

### Added
- **Chat Log toggle** on Sync tab — checkbox controls whether sync progress messages are printed to chat. Defaults to off. Warnings (e.g., oversized chunks) always print regardless of this setting. All sync chat output now routed through `SyncLog()` helper.

## [0.12.0] — 2026-04-12

### Fixed
- **Cross-client false positives (~50%) for same-prefix adjacent-hour events** — `AssignOccurrenceIndices` counted per-baseHash (which includes timeSlot), so two genuinely different events with the same prefix in adjacent hours both got occurrence `:0`. When a second client's timeSlot shifted by +1 hour, the incoming record's ID exactly matched a different event on the receiver, bypassing fuzzy matching entirely. Now counts by prefix (without timeSlot) so events get sequential occurrences `:0`, `:1`, `:2` regardless of hour slot.

### Added
- One-time data migration (`MigrateOccurrenceScheme`) reassigns all existing record occurrence indices to the new prefix-based scheme and rebuilds `seenTxHashes`. Guarded by `schemaVersion` bump (1 → 2). Deterministic sort (timestamp + old ID tiebreaker) ensures identical results across clients.
- 8 new tests: prefix-based occurrence counting (3 dedup tests) + migration correctness (5 core tests). 433 total tests.

## [0.11.3] — 2026-04-12

### Added
- 20 regression tests for sync convergence fixes (v0.11.0–v0.11.2): bucket key consistency after normalization, multi-record normalization, hash cache invalidation, bidirectional convergence proof, occurrence index edge cases, reconstructSyncRecord pipeline, mixed outcomes in same bucket, NormalizeRecordId edge cases, seenTxHashes atomic update, and full end-to-end two-peer convergence cycle (425 total tests)

## [0.11.2] — 2026-04-12

### Fixed
- **Bucket hashes still mismatching after ID normalization** — `ComputeBucketHashes` grouped records by `tx.timestamp`, but two peers with the same record (same ID) could have different timestamps from scanning at different times. The record landed in different 6-hour buckets on each side, causing 4 buckets to re-sync 627 records endlessly (all duped, 0 normalized). Bucket keys are now derived from the timeSlot embedded in the record ID (which is normalized), ensuring consistent bucket placement across peers regardless of timestamp differences.

## [0.11.1] — 2026-04-12

### Fixed
- **Sync still looping after v0.11.0** — deterministic tiebreaker (smaller ID wins) left records unnormalized when the receiver's ID was smaller, since the sender never got feedback. Switched to sender-wins: receiver always adopts the sender's ID and timestamp, converging fully in one sync cycle. The sync protocol serializes direction (one side sends per cycle), preventing oscillation.
- **Bucket hash mismatch after normalization** — normalizing the record ID without also normalizing the timestamp caused the same record to land in different 6-hour buckets on each peer. The "last bucket" would re-sync endlessly. Timestamps are now normalized alongside IDs.

## [0.11.0] — 2026-04-12

### Added
- **Sync ID normalization** — when two peers have the same transaction recorded under different IDs (due to different scan times producing different timeSlots), the receiver now converges the IDs to stop the perpetual sync loop where peers with identical data kept triggering syncs on every HELLO.
- `NormalizeRecordId` method in Sync.lua with pre-built ID lookup table for O(1) record access
- `BuildTxPrefix` exposed on Dedup module for external use
- `IsDuplicate` now returns a second value (the matched seenTxHashes key) on fuzzy matches, enabling callers to detect and resolve ID divergence
- Compaction now guards against running during sync receive (`_syncReceiving` flag)
- Sync completion audit trail now reports number of IDs converged per session
- 12 new tests (405 total) covering normalization, edge cases, and hash convergence

## [0.10.2] — 2026-04-12

### Fixed
- **Sync dedup false positives** — genuinely new transactions were incorrectly rejected as duplicates when the same player performed the same action (e.g. guild repair for the same amount) in consecutive hours. The fuzzy ±1 hour dedup now checks timestamp proximity (< 3600s) to distinguish same-event re-scans from genuinely different events. Recovers missing records during sync that were previously lost to false-positive matching.

## [0.10.1] — 2026-04-12

### Fixed
- **Stale peers wiped while still online** — peers expired from the Online list after 5 minutes even when still logged in, because HELLO broadcasts only fired on discrete events (login, bank open/close) with no periodic heartbeat. Added a HELLO heartbeat timer (every 2 minutes) that keeps peers alive as long as the addon is running. Heartbeat is properly cancelled on sync disable and addon teardown.

## [0.10.0] — 2026-04-11

### Added
- **LibDeflate compression** — all sync messages are now compressed with LibDeflate before transmission, significantly reducing wire size. Chunk capacity increased from 5 to 15 records (budget from 600 to 1600 bytes pre-serialized). Audit trail shows pre/post compression sizes for SYNC_DATA chunks.

### Changed
- **Sync protocol version bumped to 2** — v0.10.0 clients are incompatible with older versions. Both sync peers must upgrade together.

## [0.9.7] — 2026-04-11

### Fixed
- **Stale peers in Online list** — peers now expire from the "Online peers" tab after 5 minutes without contact. Previously, peers accumulated for the entire session even after logging off. `GetAllPeers()` still available for diagnostics.

## [0.9.6] — 2026-04-11

### Changed
- **Bucket hash granularity** — sync fingerprint buckets now use 6-hour windows instead of daily bins, reducing the blast radius when a single new record triggers a hash mismatch. Fewer records re-sent per delta sync.

## [0.9.5] — 2026-04-11

### Fixed
- **Audit trail flooding** — per-chunk log entries (send, transmit, ACK check, ACK) were evicting the handshake/bucket-filter entries needed for diagnostics. Chunk progress now logs every 10th chunk instead of every chunk. RECV entries suppressed for ACK/NACK/SYNC_DATA. Audit trail cap raised from 50 to 200.

## [0.9.4] — 2026-04-11

### Added
- `/gbl synclog` — opens a copy-pastable editbox with the full sync audit trail for easy diagnostics

## [0.9.3] — 2026-04-11

### Fixed
- **Peer discovery after reload** — guild members are now discoverable immediately after login/reload without opening the guild bank. Previously, the initial HELLO fired 5 seconds after login when guild data was not yet available, silently aborting. Now deferred to GUILD_ROSTER_UPDATE when data is guaranteed ready
- **Known-peer reply gate** — peers that were already known (from before a reload) would not reply to new HELLOs, making the reloading player invisible. Removed the `isNewPeer` gate; all broadcast HELLOs now receive a reply
- **Broadcast debounce swallowing peers** — when multiple peers heard a HELLO, the debounce coalesced all replies into one broadcast, so the sender only discovered one peer. Replies are now sent individually via WHISPER to each sender

### Changed
- HELLO replies use targeted WHISPER instead of guild-wide broadcast, with an `isReply` flag to prevent ping-pong loops
- Hash comparison audit trail now includes bucket count for fingerprint diagnostics
- SYNC_REQUEST audit trail now includes serialized byte size for diagnosing WHISPER size issues
- sinceTimestamp fallback path (no bucket hashes) now logs explicitly instead of being silent

## [0.9.2] — 2026-04-11

### Changed
- Verbose sync audit trail: HELLO now logs remote hash/count/version, hash comparison logs both values and trigger reason (hash mismatch vs count), bucket filter logs total/matching/differing day counts with dates, received chunks break out item vs money new/duped counts, sync completion logs post-sync total tx count and updated hash

## [0.9.1] — 2026-04-11

### Fixed
- **Hash-mismatch sync gap** — peers with the same transaction count but different data now trigger bidirectional sync. Previously, sync only triggered when one peer had MORE records, so two officers who scanned different tabs at different times would never exchange data. The dataHash fingerprint correctly detected the mismatch but the sync trigger ignored it.

### Changed
- Sync decision in HandleHello now uses hash comparison as the primary trigger, with count-based comparison as backward-compatible fallback for peers without hash support

## [0.9.0] — 2026-04-11

### Added
- **Receive-side NACK retry** — when a chunk times out, the receiver requests a specific re-send via NACK instead of aborting the entire sync. Sender re-transmits from stored chunks. Retries up to 3 times per chunk before giving up
- **Zone change protection** — sync pauses during loading screens (`LOADING_SCREEN_ENABLED`/`DISABLED`) and resumes after a 5-second cooldown, preventing silent message loss during zone transitions
- **FPS-adaptive throttling** — monitors client framerate via OnUpdate; increases inter-chunk delay from 0.1s to 0.5s when FPS drops below 20, recovers when FPS exceeds 25 (hysteresis prevents oscillation)
- **ChatThrottleLib awareness** — checks `ChatThrottleLib.avail` before sending; defers chunks by 1 second when other addons are consuming bandwidth, yielding to avoid mutual message drops
- `GetSyncStatus()` now includes `zonePaused` field for UI display

### Changed
- Reduced `MAX_RECORDS_PER_CHUNK` from 15 to 5 — smaller chunks mean less data at risk per timeout
- Replaced fixed 0.1s inter-chunk delay with adaptive `GetSyncDelay()` that responds to FPS conditions
- Receive timeout now uses `RECEIVE_CHUNK_TIMEOUT` (20s) and sends NACK instead of aborting

## [0.8.0] — 2026-04-11

### Added
- **Fingerprint-based sync** — HELLO now includes a `dataHash` (XOR-aggregated djb2 of all record IDs). When both `dataHash` and `txCount` match between peers, sync is skipped entirely — zero WHISPER traffic for the common "already in sync" case
- **Bucket-filtered sync** — SYNC_REQUEST includes per-day bucket fingerprints. When datasets differ, only records from differing days are sent instead of everything, dramatically reducing transfer size for partial sync and retries after failure
- `Fingerprint.lua` module: `HashString` (djb2), `XOR32` (with pure-Lua fallback for tests), `ComputeDataHash`, `ComputeBucketHashes`, `GetDataHash` (cached)

### Changed
- `FinishReceiving` always checkpoints `lastSyncTimestamp` (previously reset to 0 when still behind, causing full re-sends). Bucket fingerprints handle the "still behind" case more precisely

## [0.7.17] — 2026-04-11

### Changed
- Reverted inter-chunk delay back to 100ms — 1s delay reduced throughput without improving reliability

## [0.7.15] — 2026-04-11

### Changed
- Reduced CHUNK_BYTE_BUDGET from 1400 to 600 — produces ~3 records per chunk (~800 bytes) to improve AceComm WHISPER reliability in cross-realm guilds

## [0.7.14] — 2026-04-11

### Fixed
- Crash syncing records from older/newer addon versions with missing fields: `reconstructSyncRecord` now guarantees `id`, `timestamp`, `scanTime`, `scannedBy` are always non-nil regardless of what the sender provides — computes missing `id` from record fields, recovers `timestamp` from id or falls back to current time, and `MarkSeen` guards against nil hash

## [0.7.13] — 2026-04-10

### Fixed
- Cross-realm sync failures: replaced `Ambiguate` with realm-stripping `baseName()` for peer identity matching in HandleAck and HandleSyncData — Ambiguate is context-dependent (behaves differently per client's realm), causing silent ACK rejection in cross-realm guilds where GUILD and WHISPER channels may format sender names differently

### Added
- Diagnostic audit entries: "RECV" logs raw channel + sender for all incoming messages, "ACK check" logs raw sender vs target before comparison — aids cross-realm debugging

## [0.7.12] — 2026-04-10

### Fixed
- Sync chunks could exceed WHISPER ~2000-byte limit and be silently dropped — PrepareChunks now uses estimated serialized size (1400-byte budget) instead of fixed record count, preventing ACK timeout loops on oversized chunks
- Money transactions now stripped via stripForSync before sync sending — previously sent raw with scanTime/scannedBy fields, wasting payload bytes and leaking mutable references

### Changed
- CHUNK_SIZE (10) replaced with MAX_RECORDS_PER_CHUNK (15) as a hard cap alongside new size-based splitting — typical chunks will be 7–9 records based on estimated byte size

## [0.7.11] — 2026-04-10

### Fixed
- Sync request could stall permanently if sender never responded — `receiving` stayed true with no timeout, blocking all future syncs. Now aborts after 30s with a chat message.

### Added
- Chat print when sync request is declined (sender already busy)
- Chat print per chunk on the send side (record count + byte size)
- Chat print for oversized chunk warnings (red text)
- Chat print for hard timeout (AceComm never finished transmitting)
- Audit trail entry when HELLO decides not to sync (with reason: counts equal, already receiving, or autoSync off)

## [0.7.10] — 2026-04-10

### Added
- Chat output for all sync events: request, chunk progress (new/duped counts), retries, timeouts, completion summary with elapsed time
- ACK receipt logging in audit trail
- Dedup breakdown per chunk (new vs duplicate record counts)
- Sync completion summary: total new, total duped, chunks received, elapsed seconds

## [0.7.9] — 2026-04-10

### Fixed
- Crash when syncing records from older addon versions that lack a `timestamp` field (`attempt to compare nil with number` in UpdatePlayerStats)
- Sync receiver now recovers missing `timestamp` from the id's timeSlot when receiving old-format records

## [0.7.8] — 2026-04-10

### Changed
- Sync chunk size increased from 3 to 10 records per chunk — ~3x faster sync throughput with fewer round-trips
- Sync payloads now strip 6 additional reconstructable fields (category, tabName, destTabName, scanTime, scannedBy, _occurrence) — smaller messages, more records fit per chunk
- Received sync records automatically reconstruct stripped fields (category from classID, occurrence from id, scanTime set to receipt time)

## [0.7.7] — 2026-04-10

### Fixed
- Sync data chunks too large for reliable WHISPER delivery — reduced from 25 to 3 transactions per chunk (~900 bytes vs ~6400 bytes), preventing silent AceComm reassembly failures
- Single dropped chunk no longer kills entire sync — ACK timeouts now retry the same chunk up to 3 times before aborting
- HandleAck timer cancellation still using `.cancelled = true` instead of `:Cancel()` (missed in v0.7.6 timer fix pass)

## [0.7.6] — 2026-04-10

### Fixed
- Sync timers never firing in WoW — `C_Timer.After` returns nil so timeouts could not be tracked or cancelled; switched all sync timers to `C_Timer.NewTicker(..., 1)` which returns a cancellable handle
- Timer cancellation using `.cancelled = true` (only worked in tests, not WoW API); replaced with `:Cancel()` method calls
- Manual "Broadcast Hello" button now bypasses the 60s cooldown

### Added
- Audit trail entry when receiving a HELLO from a peer (e.g. "Received HELLO from Katorri (tx: 556)")
- Diagnostic audit entries for chunk send lifecycle: bytes queued, transmission complete, and ACK wait

## [0.7.5] — 2026-04-10

### Fixed
- Peer discovery failure: new-peer HELLO reply was silently blocked by the 60s cooldown, preventing mutual peer detection until one side independently triggered a broadcast (e.g. closing the guild bank)
- HELLO cooldown consumed even when broadcast fails due to missing guild data at login — subsequent retries blocked for 60s

### Added
- HELLO broadcast on guild bank open for immediate peer discovery
- Debounced new-peer HELLO replies bypass the cooldown; multiple new peers discovered within 2s coalesce into a single reply (prevents HELLO flood in large guilds)

## [0.7.4] — 2026-04-10

### Added
- HELLO response: receiving a HELLO from a new peer now triggers a HELLO back so both sides discover each other (previously required both players to independently trigger a broadcast)
- Version indicator in Sync tab peer list — peers on a different version show "(outdated)" in orange

## [0.7.3] — 2026-04-10

### Fixed
- Sync data rejected by receiver due to name format mismatch between GUILD and WHISPER channels — HELLO arrives with "PlayerName" but SYNC_DATA arrives with "PlayerName-RealmName"; now uses `Ambiguate` on all sender comparisons in HandleSyncData and HandleAck
- Updated sync comments and UI strings from "officers" to "guild members" (sync is guild-wide, officer rank only gates UI)

## [0.7.2] — 2026-04-10

### Fixed
- Column text wrapping to new lines on all tabs — disabled word wrap on all fixed-width Label and InteractiveLabel cells (headers, data rows, summary panel, breakdown rows)

## [0.7.1] — 2026-04-10

### Fixed
- Sync ACK timeout — timer started immediately on message queue instead of after AceComm finished transmitting; large chunks exceeded the 10s timeout before the receiver even got the data
- Self-message filtering broken in retail WoW — realm-qualified sender names (e.g. "Player-Realm") never matched `UnitName("player")` output; now uses `Ambiguate`

### Changed
- Sync chunk size reduced from 200 to 25 transactions per message to fit within AceComm bandwidth constraints
- ACK timeout increased from 10s to 15s to allow for receiver dedup + round-trip
- `itemLink` stripped from sync payload (reconstructable from `itemID`) to reduce message size by ~30%
- Added 120s hard timeout safety net in case AceComm send callback never fires

## [0.7.0] — 2026-04-08

### Added
- Gold summary panel on Gold Log tab with per-type breakdown (deposits, withdrawals, repairs, tab purchases, net) rendered to the right of transaction columns with vertical divider
- Date range filters: added Last Hour, Last 3 Hours, Last 24 Hours to all tabs
- Pagination for Transactions tab (100 rows per page)

### Fixed
- Re-scan no longer resets selected date range and filters — `RefreshUI` now uses per-tab refresh functions that preserve filter state
- Runtime crash: `attempt to register unknown event "GUILD_BANK_LOG_UPDATE"` — corrected to `GUILDBANKLOG_UPDATE` (WoW uses `GUILDBANK` as a single token in event names)

## [0.6.2] — 2026-04-07

### Fixed
- Re-scan not detecting new transactions (withdrawals, deposits) while guild bank remains open — restored event-driven `GUILDBANKLOG_UPDATE` listener so reads happen after server responds, not after an arbitrary delay

## [0.6.1] — 2026-04-07

### Fixed
- Periodic re-scan not functioning in-game due to unreliable `C_Timer.After` return value tracking and event-driven overhead
- Re-scan chain silently breaking on Lua errors (now protected with pcall)

### Changed
- Reduced default re-scan interval from 5s to 3s (effective ~3.5s cycles, within 2-4s target)
- Simplified re-scan to use fixed 0.5s delay instead of event-driven debounce with 2s fallback
- Re-scan state tracked via boolean flag instead of timer handle (works across all WoW versions)

## [0.6.0] — 2026-04-07

### Added
- Periodic re-scan of all transaction logs while guild bank is open (every 5 seconds)
- Catches item and money transactions before they roll off the 25-entry-per-tab WoW API limit
- Auto-starts after initial scan completes, stops on bank close
- "Auto re-scan" toggle in settings row
- Re-scan status shown in `/gbl status` output

## [0.5.0] — 2026-04-07

**Milestone M5: Multi-Officer Sync**

### Added
- Multi-officer transaction sync via AceComm addon channel (prefix `GBLSync`)
- HELLO broadcast on login and bank close — announces version, tx count, and last scan time to guild
- Automatic sync: when a peer's HELLO shows more transactions, requests delta sync with chunked transfer (200 tx/chunk with ACK flow)
- Sync tab in main UI with enable/disable toggle, auto-sync toggle, and Broadcast Hello button
- Peer list showing online officers with version, tx count, and last seen time
- Sync audit trail (last 50 events) displayed in the Sync tab
- Sync progress messages (`GBL_SYNC_STARTED`, `GBL_SYNC_PROGRESS`, `GBL_SYNC_COMPLETE`) for UI updates
- ACK timeout (10s) — aborts stalled transfers, retries on next HELLO
- Receive timeout (30s) — resets stuck receive state if sender goes offline mid-sync
- Major version mismatch detection — warns in audit log and refuses sync across incompatible versions
- HELLO cooldown (60s) prevents broadcast flooding
- Wrong-sender guard — rejects SYNC_DATA from a third party during an active receive session
- 68 new tests (241 total) covering HELLO, sync request/response, chunking, dedup, dispatch, audit trail, and edge cases

### Changed
- Core addon now mixes in `AceComm-3.0` and `AceSerializer-3.0`
- Bank close now broadcasts HELLO to notify peers of fresh scan data
- Delta sync filters by `scanTime` (when record was created) instead of `timestamp` (when event happened) — ensures recently-scanned old transactions are not missed

## [0.4.1] — 2026-04-07

### Fixed
- Gold/money transactions now appear in the Transactions tab (were previously only visible in Consumption)
- Added "Amount" column to ledger view showing formatted gold amounts for money transactions
- Money transaction types (Repair, Tab Purchase, Deposit Summary) now appear in the Type filter dropdown
- Player stats now correctly track repair, buyTab, and depositSummary money types (were silently dropped)
- Money transactions no longer show misleading "0" in Count column or blank Item/Category/Location fields
- Transaction scan now uses debounced GUILDBANKLOG_UPDATE handler (0.5s after last event) so money tab data arrives before reading — previous next-frame read was too fast and missed money log responses
- Money log now queried at `MAX_GUILDBANK_TABS+1` (constant 9), not `GetNumGuildBankTabs()+1` — guilds with <8 tabs were querying the wrong tab index, so money data was never loaded from the server
- WoW API returns `"withdrawal"` for money transactions but code checked for `"withdraw"` — added normalization in CreateMoneyTxRecord so all downstream code matches correctly

### Changed
- Ledger "Action" column widened to 80px to fit "Tab Purchase" label; "Item" narrowed to 180px to accommodate new Amount column

## [0.4.0] — 2026-04-07

**Milestone M4: Consumption Detail + UI Polish**

### Added
- Click-to-expand player rows in consumption tab — click a player to see per-item breakdown with item name, category, withdrawn/deposited counts
- Sortable column headers on consumption tab (Player, Withdrawn, Deposited, Net, Last Active) with [asc]/[desc] indicators
- Category filter dropdown on consumption tab (reuses existing filter pipeline)
- Top Item column showing the #1 most active item name (extracted from item link)
- `ExtractItemName()` utility for extracting display names from WoW item links
- `GetBreakdownForDisplay()` transforms raw breakdown data into sorted display arrays with category labels
- `FormatTopItems()` formats top items as truncated comma-separated names
- 21 new tests (173 total) covering breakdown display, sort state, indicators, category filtering, item name extraction, edge cases

### Changed
- Ledger view column widths tightened to fit 720px usable frame (645px total: 130+90+70+200+40+80+35)
- Consumption tab filter bar now includes date range, category dropdown, and reset button (was date-only)

### Fixed
- Guild bank open no longer stutters — transaction scanning and compaction deferred via `C_Timer.After(0)` so the bank frame renders first

## [0.3.3] — 2026-04-07

### Fixed
- Sort direction indicators showed as boxes (UTF-8 unsupported by WoW font); changed to [asc]/[desc] text

### Added
- Revised roadmap (`docs/ROADMAP.md`) with sync moved to M5 and audit checklists per milestone

## [0.3.2] — 2026-04-07

### Fixed
- UI rows overflowed frame — ledger and consumption views now use AceGUI ScrollFrame for scrollable content
- LibDBIcon-1.0 `.toc` path pointed to nonexistent `lib.xml`; corrected to `LibDBIcon-1.0.lua`
- Interface version updated from 110105 to 120001 (WoW Midnight Season 1)

## [0.3.1] — 2026-04-07

### Fixed
- `fetch-libs.sh` pointed to nonexistent GitHub repos under `BigWigsMods/`; corrected to `WoWUIDev/Ace3`, `lua-wow/LibStub`, `zerosnake0/LibDBIcon-1.0`
- AceConfigDialog-3.0 and AceConfigCmd-3.0 are nested inside AceConfig-3.0 in the Ace3 repo; script now copies them correctly

### Removed
- LibSharedMedia-3.0 from `.toc` load list (no standalone GitHub repo; addon doesn't use it yet)

## [0.3.0] — 2026-04-07

**Milestone M3: UI**

### Added
- Main UI window toggled via `/gbl` or minimap button (left-click)
- Transaction ledger view with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar: text search, date range (7d/30d/all), category, transaction type, reset button
- Per-player consumption summary with net contribution, top items, last active
- Minimap button via LibDataBroker + LibDBIcon
- Accessibility: 4 colorblind-safe palettes auto-detected from WoW CVar, high contrast mode (WCAG AAA)
- Triple encoding for transaction types: shape icon + color + text label (WCAG 1.4.1)
- Keyboard navigation (Tab/Shift+Tab) with visible 2px yellow focus indicator, focus trap (WCAG 2.1.1, 2.4.7)
- Font size scaling (8-24pt) via addon settings
- Frame position clamping to screen bounds
- Library fetch script (`fetch-libs.sh`) for development setup
- 78 new tests (152 total) covering accessibility, filters, consumption, keyboard nav

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.6] — 2026-04-07

### Added
- Keyboard navigation: Tab/Shift+Tab focus traversal with wrap (focus trap per WCAG 2.1.1)
- Focus indicator: 2px yellow border tracked on each focusable widget (WCAG 2.4.7)
- Focus restore on frame reopen
- Frame position clamping to screen bounds
- 9 new keyboard nav and frame clamping tests (152 total)

## [0.2.5] — 2026-04-07

### Added
- Main UI window (`UI/UI.lua`) with tabbed view: Transactions and Consumption
- Scrolling transaction list (`UI/LedgerView.lua`) with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar widgets: search box, date range, category, type dropdowns, reset button
- Consumption table with per-player summaries, net contribution, last active
- Minimap button via LibDataBroker + LibDBIcon (left-click toggles window)
- `.toc` updated with all M3 library and UI file entries
- 4 new integration tests (143 total)

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.4] — 2026-04-07

### Added
- Per-player consumption aggregation (`UI/ConsumptionView.lua`): withdrawal/deposit totals, net contribution, money tracking, top items, last active timestamp
- Sortable consumption summaries by any column (player, withdrawn, deposited, net, last active)
- Per-player item breakdown with withdrawn/deposited per item
- Money formatting utility (`FormatMoney`: copper to "Xg Ys Zc")
- 18 new consumption tests (139 total)

## [0.2.3] — 2026-04-07

### Added
- Transaction filter logic (`UI/FilterBar.lua`) with AND-combined criteria: text search, date range (7d/30d/all), category, transaction type, player, tab
- AceGUI-3.0 mock framework for UI unit testing
- LibDataBroker-1.1 and LibDBIcon-1.0 mocks
- 19 new filter tests (121 total)

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
