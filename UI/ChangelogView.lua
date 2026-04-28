------------------------------------------------------------------------
-- GuildBankLedger — UI/ChangelogView.lua
-- Changelog tab: embedded version history and in-game renderer.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Section rendering order and colors
------------------------------------------------------------------------

local SECTION_ORDER = { "Added", "Changed", "Fixed", "Removed", "Deprecated", "Security" }

local CHANGELOG_PAGE_SIZE = 10

local SECTION_COLORS = {
    Added      = "|cff55ff55",
    Changed    = "|cff55bbff",
    Fixed      = "|cffffaa55",
    Removed    = "|cffff5555",
    Deprecated = "|cff999999",
    Security   = "|cffcc66ff",
}

------------------------------------------------------------------------
-- Changelog data — newest first, concise summaries only.
-- Format: { version, date, { SectionType = { entries } }, milestone? }
------------------------------------------------------------------------

GBL.CHANGELOG_DATA = {
    -- v0.30.5
    {"0.30.5", "2026-04-28", {
        Changed = {
            "Sort: the planner now actively compacts the stock (overflow) tab at every stage, not just at the end. A new Phase 0 pre-merges same-item partials in overflow before any cross-tab routing happens, and Phase 1B prefers to top up existing same-item partial slots before extending into a new slot. The combined effect: a run that previously ended as two stacks of 160 Healing Potions (max 200) now ends as 200 then 20, AND a stock tab that was previously reported 'out of space' because partial stacks consumed slots is now correctly seen as having room. Repeat sorts remain no-ops. Items whose max stack size has not yet loaded into the client cache (cold cache after /reload) skip the merge for that item only and fall back to grouping; a second sort completes the work once the data arrives.",
        },
        Added = {
            "ItemCache now caches itemStackCount alongside name and link, with a new GBL:GetMaxStack(itemID) accessor used by the sort planner.",
            "Sort planner now writes a single timing line to the audit trail (visible in /gbl synclog) for every plan: Sort plan: 12.3ms, 47 ops, 0 deficits, 1 unplaced (input: 240 slots / 4 tabs). Captures both first-plan and replan latency on the same code path. Motivation: large plans and their replans cause a single-frame hitch in-game; this line gives the ms-per-input-size data needed to decide whether the planner needs to be split across frames.",
            "Per-phase sort instrumentation. /gbl synclog now also shows a phases line breaking each plan's ops down by phase (P0 merge, P1a assign, P1b spill with topup/extend/first-empty/unplaced split, P2 pivot, P3 sweep, P4 pack) and a demands line counting demand origins (pinned, extend-right, extend-left, first-empty). The same counters are exposed on the returned plan as plan.diag. Empty no-op plans stay quiet. SortExecutor also writes a one-line completion summary at every run end with elapsed time, ops/done/failed/replans/reclassify counts, pre-check fails, cursor-stuck count, and per-class timeout counts.",
            "Planner-vs-reality diagnostic on every op. Each emitted op now carries a frozen snapshot of what the planner thought the src/dst slots held when it emitted that op. When a pre-check fails or an op times out, the audit trail now adds a 'planner expected' line that pairs with the 'observed' / 'got' line, so a recurring 'dst occupied by wrong item' across replans now self-explains: either the snapshot read this slot wrong or an earlier op didn't do what the planner projected.",
            "Per-op success timeline in the audit. Every op the executor advances past now writes a one-liner with src/dst, item name and id, count, and elapsed time, tagged [sync] or [late-poll] depending on which success path resolved it. Combined with the existing pre-check-fail and timeout entries, /gbl synclog now serves as a complete per-op timeline of any sort run.",
            "Items-only layouts now show natural adjacency in the demands line. Pass 2b (the slot fallback that handles items-only layouts) labels each demand based on adjacency to existing same-item claims, so what previously looked like 437 unrelated 'first-empty' fallback adds now surfaces as one seed per item plus extend-right for the contiguous extension - the structure already in the layout but invisible before this change.",
            "Item-name resolution in the audit log. Plain it:NNN tokens are now rendered as <name> (it:NNN) wherever the cache has the item, in pre-check-fail, timeout, op-success, and slot-state lines. Cold-cache items still fall back to bare it:NNN; the helper deliberately does not warm the cache so audit emission paths cannot trigger async loads.",
            "Server-reversion detection. The per-op-success audit line now ends with src=<post> dst=<post> showing the client's view of both slots right after the op. When a foreign-activity event fires (the second GUILDBANKBAGSLOTS_CHANGED, which is the server's authoritative response), the executor compares live state to the projected post-op state and audits a 'server reversion suspected on op N' line if they diverge. This is the diagnostic that distinguishes 'the [sync] path advanced on the client's optimistic view of a Pickup that the server later rolled back' from genuine concurrent foreign bank activity.",
        },
    }},

    -- v0.30.3
    {"0.30.3", "2026-04-27", {
        Changed = {
            "Repository workflow change with no addon behavior impact: auto branch deletion on merge is disabled, and recurring maintainer work now lives on long-lived per-area topic branches (ui, sync, accessibility, layout-sort). Short-lived chore/, infra/, and hotfix/ branches still cover one-off and cross-cutting changes. Documented in the CLAUDE.md Branch Workflow section.",
        },
    }},

    -- v0.30.2
    {"0.30.2", "2026-04-27", {
        Added = {
            "Sync audit trail now records when a SYNC_DATA chunk arrives at chunk N>1 while no receive session is active — that means the receiver missed an earlier abort signal (combat with a lost BUSY, or a sender desync) and is recovering data mid-stream. Look for 'Auto-bootstrap at chunk N from <sender>' in /gbl synclog.",
            "Sync ACK timeout retry log now appends 'target=online|offline|unknown' so future capture analysis can tell apart 'peer was already offline and we kept retrying' from 'peer was nominally online but timed out anyway' (likely true wire loss or in-instance silent abort). 'unknown' covers both 'not in roster' and 'roster not yet populated' — the latter only happens for a few seconds right after login.",
        },
    }},

    -- v0.30.1
    {"0.30.1", "2026-04-25", {
        Changed = {
            "Internal refactor with no behavior change: a new GBL:SafeRecordTimestamp helper replaces ten copies of the same 'use record.timestamp if valid, else GetServerTime' ternary across the migration paths in Core.lua and the sender-wins reconciliation in Sync.lua. Also re-enables the 120-character line-length lint on Core.lua, since the long lines that originally forced an override are gone.",
        },
    }},

    -- v0.30.0
    {"0.30.0", "2026-04-24", {
        Added = {
            "Sort Access now has two independent tiers. The Layout tab's Sort Access section is split into Layout Write access (edit templates, capture, pin slots, change stock reserves — inherently includes sort) and Sort-only access (press Execute on the Sort tab but cannot edit the layout). Each tier has its own rank threshold and its own delegate list. Only the Guild Master can change the policy. Grant sort execution widely while keeping layout edits locked down.",
            "Defense-in-depth gate at the storage API. SaveBankLayout and SetStockReserve now reject any caller that does not pass HasLayoutWrite(), in addition to the existing UI callback check.",
        },
        Changed = {
            "Existing sortAccess configurations migrate into the new Layout Write tier on upgrade, so no one silently loses a permission. The sort-only tier starts empty; populate it in the Layout tab if you want to grant sort without layout write.",
        },
    }},

    -- v0.29.26
    {"0.29.26", "2026-04-24", {
        Fixed = {
            "Sort progress counter no longer shows impossible values like '34/33' after a replan. The old display used (done+failed)/total, but done and failed accumulate across replans while total is the current plan's size, so the numerator could exceed the denominator once a replan reissued work. Switched to 'op N / T' using the executor's live op index and current-plan total — always in range and reflects 'where are we in the plan that's actually running.'",
            "Move list and per-op status markers now realign after a replan. Previously the UI kept rendering the original plan's rows while the executor had moved on to a different post-replan plan, so row markers drifted onto the wrong moves and the counter referenced a plan that was no longer executing. SortExecutor now broadcasts the new plan via a 'planupdated' progress phase, and SortView swaps the cached plan, clears stale op markers, and rebuilds the move list to match what's actually running.",
        },
    }},

    -- v0.29.25
    {"0.29.25", "2026-04-24", {
        Fixed = {
            "Sort progress markers on each move row now render in WoW's default font. v0.29.23 used Unicode triangle/check/cross glyphs that FRIZQT__ doesn't ship, so users saw colored boxes instead. Replaced with colored ASCII: '>' (yellow) for the op currently in flight, '+' (green) for completed (including late-ACK reclassified), 'x' (red) for failed. Same colors, actual shapes.",
            "Per-op status markers now survive Sort tab rebuilds mid-sort. Previously, every successful move created a transaction log entry; the ledger rescan reacted by firing RefreshUI, which (for the Sort tab) full-rebuilt the tab and wiped all per-row widget refs. The top progress line recovered on the next event but the per-op markers on already-completed rows were lost forever. Fixed by persisting a '_sortOpStatus' table and a cached progress-text string that the Preview loop repaints into freshly-built widgets on every rebuild — so a rescan, a tab switch, or any other rebuild now preserves the full visual state.",
        },
    }},

    -- v0.29.24
    {"0.29.24", "2026-04-24", {
        Changed = {
            "Every sort now ends by tidying the overflow (stock) tab. A new Phase 4 in the planner reshapes the overflow tab into a deterministic contiguous layout starting at slot 1: stacks sorted by itemID, larger stacks first within a group, no gaps. Previously the overflow was a dumping ground — Phase 1B and Phase 3 only grouped *new* spills using adjacency, so any pre-existing scattered stacks or gaps stayed scattered. Repeat sorts are now idempotent (already-compact overflow → zero compaction ops). Partial-stack merging (e.g. merging two half-stacks of Linen Cloth) is explicitly out of scope here — the planner has no max-stack-size knowledge; that's a follow-up.",
        },
    }},

    -- v0.29.23
    {"0.29.23", "2026-04-23", {
        Added = {
            "Live progress display in the Sort tab while a sort is executing. A running 'Executing — N/T (X done, Y failed, Z replans)' line updates at the top of the move list every time an op starts, completes, fails, or gets reclassified by the late-ACK path. Each move row also gets a status marker prefixed to it as it advances: ▶ for the op currently in flight, ✓ for completed (including late-ACK success), ✗ for failed. Sort execution is 100% local so these updates have no bandwidth cost — they're just direct SetText calls on widgets we already have references to.",
            "On sort completion, the progress line switches to 'Sort complete — N done, M failed, K replans. Rescanning...' immediately, then the tab refreshes with the post-sort plan once the rescan lands. No more waiting on the scan to see whether the sort succeeded.",
        },
    }},

    -- v0.29.22
    {"0.29.22", "2026-04-23", {
        Fixed = {
            "Late server ACKs for move ops are now reclassified correctly even when the next op is already in flight. v0.29.19 added the grace window but only fired it when no op was waiting — in a live sort the 0.3s inter-move gap means an op is almost always armed, so the grace window essentially never fired. The handler now checks both 'is this a late ACK for a timed-out prior op' and 'does this advance the current in-flight op' as independent concerns. Expected effect: cleaner audit trails (fewer 'op N timed out / op N+1 pre-check fail' cascades) and more accurate done/failed counters after a sort completes.",
        },
        Changed = {
            "Removed the loud Capture-button diagnostics added in v0.29.21 now that the reported regression wasn't reproducible (it cleared on /reload). Kept the pcall-wrapped error handler and the pinned-slot count in the success message — cheap, informative, won't spam chat.",
        },
    }},

    -- v0.29.21
    {"0.29.21", "2026-04-23", {
        Added = {
            "Diagnostic output on the Layout editor's Capture button. When clicked, the button now always prints at least one chat line — the initial click, the guard state (scan/slots/writable), and either a success or a wrapped-pcall error message. Added to chase down a reported regression where Capture on a freshly-switched-to-Display tab looked like it was doing nothing.",
            "Capture success message now reports both the distinct-item count and the pinned-slot count ('Captured tab 5: 34 distinct item(s), 66 slot(s) pinned') so you can tell at a glance whether slotOrder got populated from the scan.",
        },
    }},

    -- v0.29.20
    {"0.29.20", "2026-04-23", {
        Added = {
            "Timeout-time diagnostics in the sort executor. When an op times out, the audit trail now dumps a classification ([none] / [partial] / [complete] / [other]), the op's full details, and the observed live state of the source/destination slots and cursor. This distinguishes 'server dropped the request,' 'pickup worked but drop didn't,' and 'move completed but ACK was lost' cases without needing to re-run the sort.",
            "Pre-check failures on destination slot mismatches now also log the op's full context (src/dst tab+slot, itemID, count), making it legible in the audit trail why a replan was triggered and what op the planner scheduled there.",
        },
    }},

    -- v0.29.19
    {"0.29.19", "2026-04-23", {
        Fixed = {
            "Sort no longer aborts mid-run when the server takes slightly longer than 2s to confirm a move. The executor used to classify the (legitimate but late) GUILDBANKBAGSLOTS_CHANGED event as 'foreign activity' and trigger a replan; the replan's fresh snapshot then saw the move already settled and the resulting plan sometimes pre-check-failed on op 1, cascading through all 5 replan retries before aborting. Now: if a recent op timed out and its destination slot is now populated as expected, the late event retroactively reclassifies the op as success and execution continues.",
            "Raised MOVE_CONFIRM_TIMEOUT from 2s to 4s to give high-latency realms more headroom before a legitimate server ACK is misclassified as a timeout. Happy-path sorts are unchanged (fast ACKs advance immediately); this only affects slow ACKs that would otherwise stall the run.",
            "Raised SCAN_WAIT_TIMEOUT from 5s to 10s. Full-bank scans on populated 7+ tab banks were observed taking ~4s in-game — uncomfortably close to the old 5s cap — and a single slow scan during a replan was enough to abort an otherwise-recoverable sort.",
        },
    }},

    -- v0.29.18
    {"0.29.18", "2026-04-23", {
        Added = {
            "'Unpin all slots' button on each display tab in the Layout editor. Wipes slotOrder (keeps items). Use when a captured layout is forcing new restock stacks to scatter to the end of the tab — after unpinning, the planner packs everything by adjacency at sort time.",
            "Per-item 'Unpin' button on every item row. Clears pinned slots for just that item while the rest of the tab stays pinned. Useful for 'mostly frozen, except this one high-churn item' setups. Disabled when the item has no pinned slots.",
            "Each item row now shows a pin count ('3 pinned' in yellow, or 'not pinned' in gray) between the = total and the action buttons, so you can see at a glance which items are fixed to positions and which aren't.",
            "Three modes now legible in the editor: Fully pinned (Capture everything, positions locked), Fully declarative (no pins, planner places at sort time), or Mixed (pin some, let others flow). Pick the mode that matches how much you care about exact placement vs. tolerating reorganization.",
        },
    }},

    -- v0.29.17
    {"0.29.17", "2026-04-23", {
        Added = {
            "Demand origin tracking in the sort planner. Each demand is tagged 'pinned' (from Capture), 'extend-right' / 'extend-left' (planner adjacency), or 'first-empty' (fallback when no adjacency is possible). The gem-tab restock pattern — pinned captures forcing new stacks to scatter — is now visible in diagnostics as a high first-empty count alongside many pinned demands.",
            "/gbl sortpreview now breaks down each display tab's demands by origin (pinned / auto-placed / extend-right / extend-left / first-empty) and annotates each planned move line with its destination origin so you can trace why each move lands where it lands.",
            "Layout editor slot map header now shows 'N pinned + M auto-placed; K empty' instead of just 'N/98 pinned.' The per-item 'auto-placed at sort time' list distinguishes all-new items from mixed ones ('1 pinned + 3 auto-placed') — the second form is the gem-tab pattern where Capture locked in old stacks and a later Slots bump added new ones.",
        },
    }},

    -- v0.29.16
    {"0.29.16", "2026-04-23", {
        Fixed = {
            "Layout tab edits no longer show a visible scroll-snap flicker. v0.29.15 preserved scroll position across rebuilds, but the Release → Build → SetScroll sequence was still visible as a brief blank-then-snap. The TabGroup's content frame is now hidden for the duration of the rebuild and revealed after scroll has been re-applied, so the tab appears static during edits.",
        },
    }},

    -- v0.29.15
    {"0.29.15", "2026-04-23", {
        Fixed = {
            "Layout tab no longer scrolls to the top every time you press Enter in an edit field. The tab rebuilds on every field change (to keep the slot budget, save/discard buttons, and slot map in sync), and that rebuild was also re-creating the ScrollFrame — throwing away scroll position. Editing Slots or Per slot halfway down the page used to jump you back to the top; the ScrollFrame now persists its scroll offset across rebuilds and snaps back to where you were.",
        },
    }},

    -- v0.29.14
    {"0.29.14", "2026-04-23", {
        Added = {
            "Slot map panel in the Layout editor. Every display tab now shows its slotOrder as a compact run-length list (e.g. 'S1-S23 (23): Silvermoon Health Potion × 20') right under the item rows. A 1-slot run wedged between two long runs of the same other item now stands out visually — which is exactly what the v0.29.12 hidden-swap incident needed.",
            "Slot map compares against the current bank scan when one is available: green ✓ if every slot in the run matches, red ✗ with per-slot detail lines naming what's actually sitting there otherwise. Items whose Slots count exceeds their pinned slotOrder entries list below as 'auto-placed at sort time,' matching the v0.29.13 ownership split (Capture pins, planner places everything else at sort time).",
        },
    }},

    -- v0.29.13
    {"0.29.13", "2026-04-23", {
        Changed = {
            "Layout editor no longer pre-pins slotOrder positions for Add Item or Slots-up. The UI used to heuristically pin positions on edit — indistinguishable from a real Capture — which the planner then rigidly enforced. Same adjacency logic now runs at plan time instead, so slotOrder unambiguously means 'pin because observed,' saved layouts are smaller, and the post-sort bank state is byte-identical to before. Capture, Slots-down trim, and Remove cleanup are unchanged.",
        },
        Fixed = {
            "Adding an item to a full captured tab no longer leaves partial slotOrder state. Previously items[id].slots would be set but only some of the requested slots got slotOrder entries when the tab was nearly full; the over-budget error surfaced only at save time. With the prefill gone, the authoritative items[].slots sum is what validation checks — single clean failure mode.",
        },
    }},

    -- v0.29.12
    {"0.29.12", "2026-04-23", {
        Added = {
            "/gbl deviations (alias /gbl devs) compares the current bank to the layout's expected demand map and prints every slot that doesn't match — wrong item, wrong count, empty-where-expected, or extras in unclaimed slots.",
            "Auto-run deviation check after Execute. The Sort tab already rescans after Execute (v0.29.9); it now also prints the deviation report when the fresh scan lands, so any mismatch between plan and result is immediately visible.",
            "Pre-check failure audit entries now include the observed state (e.g. 'expected it:12345 x>=20, got it:99999 x10') instead of a bare 'src mismatch' message — makes it obvious whether the failure was foreign activity, a stack-size drift, or a planner bug.",
        },
    }},

    -- v0.29.11
    {"0.29.11", "2026-04-23", {
        Fixed = {
            "Sort now keeps each item's span contiguous in the display tab. When items[id].slots exceeded the captured slotOrder entries, the planner used to fill first unclaimed slot and could drop items into another item's section depending on itemID ordering. It now extends an item's group RIGHT first, then LEFT, only falling back to arbitrary slots when both ends are blocked.",
            "Overflow (stock) tab stays organized by item. Spills used to land in the first empty slot regardless of what was next to it; they now prefer slots adjacent to existing same-item stacks.",
            "Layout editor's Add Item and Slots field use the same adjacency rule so saved layouts stay neat without a recapture.",
        },
    }},

    -- v0.29.10
    {"0.29.10", "2026-04-23", {
        Fixed = {
            "First bank scan after login no longer misses every item. The scanner was reading slots immediately after requesting tab data, but on first open the client has no data yet — 98 nil slots, event unregistered, real data ignored when it arrived. The scanner now waits for the server's response event before scanning, with a 3-second timeout fallback for empty tabs that don't fire the event.",
        },
    }},

    -- v0.29.9
    {"0.29.9", "2026-04-23", {
        Fixed = {
            "Sort tab now auto-refreshes after Execute. Preview was re-running against the pre-sort snapshot (stale), so the plan looked unchanged after sort had actually run. The tab now triggers a rescan on completion, shows a 'Rescanning...' placeholder, then re-previews against the post-sort state.",
        },
    }},

    -- v0.29.8
    {"0.29.8", "2026-04-23", {
        Fixed = {
            "Sort planner now honors items[id].slots as the authoritative demand count. Before, if you captured a layout with 3 slots of an item then edited Slots to 5 in the Layout UI, the 2 extra slots were silently dropped and sort saw 'no discrepancy' even when the bank was obviously off. The planner now emits demands up to items[id].slots, adding extras at the first unclaimed slot indices.",
            "Layout editor's Slots input now syncs slotOrder on edit so the mismatch above can't reappear. Increasing Slots pins new positions at the first unclaimed indices; decreasing Slots trims from the highest slot index down.",
            "Phase 3 sweep no longer mis-evicts items placed by dynamically-added demands (was a consequence of the above fix — discovered via the regression tests).",
        },
        Added = {
            "/gbl sortpreview now prints a diagnostic breakdown: per-display-tab demand counts, overflow/ignore tab indices, scan contents by tab, and a plain-English reason when the plan is empty. Tells you whether a 0-op result is a config issue (no demands) or the bank genuinely matches the layout.",
        },
    }},

    -- v0.29.7
    {"0.29.7", "2026-04-23", {
        Changed = {
            "Sort planner rewritten from three-pass greedy to assign-then-schedule. Same inputs and outputs — drop-in upgrade. Items in the wrong slot of the right tab now move directly instead of round-tripping through overflow; oversize stacks feed multiple demands from a single source; the planner picks the largest source first to minimize split count; and swap cycles are detected and resolved with a pivot (3 ops for a 2-cycle, 4 for a 3-cycle, down from 4 and 6).",
            "Unreachable swap cycles (no empty unclaimed slot anywhere) are now reported as unplaced with a 'cycle-no-pivot' reason instead of emitting half-broken ops.",
        },
    }, milestone = "M-sort-2.5: Planner algorithm upgrade"},

    -- v0.29.6
    {"0.29.6", "2026-04-23", {
        Changed = {
            "Layout tab save-bar is now self-explanatory: status banner reads 'You have unsaved changes' vs 'Layout is up to date', the save button is disabled and labels itself 'Saved ✓' when clean, and 'Revert' was renamed to 'Discard changes'. Edits still buffer until Save (deliberate, so validation and sync run once per logical change), just with clearer signals.",
        },
    }},

    -- v0.29.5
    {"0.29.5", "2026-04-23", {
        Fixed = {
            "Capture current layout now auto-triggers a scan when none exists, polls for completion, and gives clear success/failure feedback. Previously it silently failed when no scan had been performed yet.",
        },
    }},

    -- v0.29.4
    {"0.29.4", "2026-04-23", {
        Fixed = {
            "Layout tab dropdowns (mode + per-item Slots/Per-slot) now accept edits. The draft state was being wiped on every refresh, so changes applied then immediately reverted.",
            "Sort Access rank dropdown now shows all options including 'None (GM only)' as the default. It was previously rendering blank entries due to an array-vs-hash mismatch in the AceGUI dropdown call.",
        },
    }},

    -- v0.29.3
    {"0.29.3", "2026-04-23", {
        Added = {
            "Layout tab — per-tab mode picker (display/overflow/ignore), item template rows with Slots + Per-slot inputs, live slot-budget readout, Capture-current-layout button, and Add-item input that takes an itemID or a pasted item link.",
            "Sort tab — Preview builds and displays the planned moves with human-readable item names, deficits, and unplaced items. Execute runs the plan through SortExecutor with progress prints. Cancel aborts.",
            "Sort Access section (on the Layout tab) — GM sets a rank threshold and named delegates. Non-GMs see the policy read-only. Layout tab visibility itself now depends on sort access.",
        },
    }, milestone = "M-sort-2 (UI): Layout editor + Sort tab"},

    -- v0.29.2
    {"0.29.2", "2026-04-23", {
        Added = {
            "SortAccess policy — GM configures a rank threshold and named delegates to control who can edit layouts and execute sort. Default is GM-only; policy writes are GM-only so delegates can't self-escalate.",
            "SortExecutor — executes plans one op at a time with throttling, pre-step verification against live bank, replan-on-foreign-activity (cap 5), bank-close abort, and cursor-leak safety on every exit path.",
            "Slash commands: /gbl sortexec (run the current plan) and /gbl sortcancel (cancel a running sort), both gated by HasSortAccess.",
        },
    }, milestone = "M-sort-2 (backbone): Executor + Access policy"},

    -- v0.29.1
    {"0.29.1", "2026-04-23", {
        Added = {
            "CLAUDE.md architecture list now includes BankLayout and SortPlanner.",
            "Four sort-planner regression tests: ignore-tab invisibility, keep-slot protection, multi-tab orphan routing, and no-duplicate-unplaced under overflow saturation.",
        },
        Fixed = {
            "SortPlanner no longer produces duplicate unplaced entries when the overflow tab is full — Pass 1 now drops the working-bank copy of any slot it records as unplaced so later passes don't re-process it.",
        },
    }, milestone = "M-sort-1.1: Audit cleanup"},

    -- v0.29.0
    {"0.29.0", "2026-04-23", {
        Added = {
            "Bank layout model: per-guild saved templates that describe each tab's role (display, overflow, or ignore). Display tabs list the items they hold along with how many slots each occupies and the target stack size per slot. Includes a Capture tool that reads the current contents of a hand-arranged tab and saves it as the canonical layout.",
            "Sort planner: given a bank scan and a saved layout, produces an ordered list of moves that will reshape the bank to match — splitting oversize stacks, pulling from other display tabs or the overflow tab to fill deficits, and routing unassigned items to overflow. Pure function, fully tested. No execution or UI yet; those arrive in subsequent milestones.",
            "Debug: /gbl sortpreview prints the current sort plan to chat.",
        },
    }, milestone = "M-sort-1: Bank sorting foundation"},

    -- v0.28.12
    {"0.28.12", "2026-04-24", {
        Added = {
            "GitHub Actions CI workflow runs busted tests and luacheck on every pull request and on every push to main. Phase C will require passing CI before merge.",
        },
    }},

    -- v0.28.11
    {"0.28.11", "2026-04-24", {
        Added = {
            "Contributor docs: CONTRIBUTING.md, PR template, CODEOWNERS, and a README \"Contributing\" section. Aimed at external contributors but also documents internal conventions.",
        },
    }},

    -- v0.28.10
    {"0.28.10", "2026-04-24", {
        Fixed = {
            "Removed blank space at the bottom of all six tabs (Transactions, Gold Log, Consumption, Sync, Changelog, About). Thanks @katogaming88 for spotting and fixing the first three in #1.",
        },
    }},

    -- v0.28.9
    {"0.28.9", "2026-04-24", {
        Added = {
            "LuaLS workspace config so contributors get consistent IDE diagnostics out of the box.",
            "Internal design doc preserving the v0.26.0 throughput audit that justifies the 6h fingerprint bucket size.",
        },
        Changed = {
            "CurseForge listing copy refreshed (Beta tag, reorganized sections). No code change.",
        },
        Fixed = {
            ".gitignore now excludes .claude/walkthrough/ and .claude/settings.local.json so machine-local Claude Code state stops appearing in git status.",
        },
    }},

    -- v0.28.8
    {"0.28.8", "2026-04-23", {
        Added = {
            "Receiver-side redundancy metric in sync audit. New "
                .. "\"Redundancy from <peer>\" line reports total dupes/received "
                .. "with item-vs-money split; per-chunk audit gains a running "
                .. "\"X% dup\" annotation. Diagnostics-only — no protocol or "
                .. "behavior change. Informs whether bucket-granularity "
                .. "redundancy justifies a future manifest-exchange protocol change.",
        },
    }},

    -- v0.28.7
    {"0.28.7", "2026-04-22", {
        Fixed = {
            "Sync reliability: chunks shrunk to 1 AceComm wire fragment (4 records / 900 byte budget) after v0.28.6's 2-fragment target missed — actual compression ratio is 23–26%, not ~18% as assumed. Cross-realm syncs now complete instead of aborting mid-stream.",
        },
        Added = {
            "Diagnostics: retry cause tagging (ackTimeout/nack split out from combat/zone/busy/offline aborts), corrected p_frag math, per-peer outcome lines, and end-of-sync compression-ratio summary (min/med/max) so A/B analysis across chunk-size changes is now one-line rather than multi-line parse.",
        },
    }},
    -- v0.28.6
    {"0.28.6", "2026-04-22", {
        Fixed = {
            "Sync reliability: chunks shrunk to 2 AceComm wire fragments (10 records / 2500 byte budget) so cross-realm whisper delivery succeeds within 6 retries",
        },
    }},
    -- v0.28.5
    {"0.28.5", "2026-04-22", {
        Fixed = {
            "Sync reliability: 1.0s inter-chunk gap floor avoids WoW's server-side whisper throttle that was silently dropping the 3rd rapid-succession message",
            "Chunk density reverted to v0.27.0 values (25 records / 3200 byte budget) to reduce fragment count per chunk",
        },
    }},
    -- v0.28.4
    {"0.28.4", "2026-04-22", {
        Added = {
            "Sync diagnostics: CTL queue depth, inter-chunk gap, wire-to-ACK latency, enriched ACK-timeout context, and per-sync retry histogram with p_frag_est",
        },
    }},
    -- v0.28.3
    {"0.28.3", "2026-04-21", {
        Changed = {
            "Interface version updated to 120005 (WoW 12.0.5)",
        },
    }},
    -- v0.28.2
    {"0.28.2", "2026-04-21", {
        Fixed = {
            "Sync send pacing: dynamic CTL threshold based on chunk size eliminates burst-stall pattern",
            "HELLO replies suppressed during active sync to preserve CTL bandwidth for data transfer",
            "CTL backoff delay increased to 1.0s for efficient polling during bandwidth recovery",
        },
    }},
    -- v0.28.1
    {"0.28.1", "2026-04-20", {
        Added = {
            "Sync diagnostic logging: CTL.avail values, deferral counters with GetTime() precision, transmit callback timing, HELLO reply during-sync tags, NACK CTL state, per-sync summary stats",
        },
        Changed = {
            "Audit trail cap increased from 200 to 2000 entries to capture full sync lifecycle",
            "CTL deferral entries rate-limited: first 10 verbose, then every 20th — prevents audit eviction",
        },
    }},
    -- v0.28.0
    {"0.28.0", "2026-04-19", {
        Changed = {
            "Sync throughput optimized: broadcasts suppressed during active sync with keepalive every ~280s, CTL backoff reduced to 0.25s, bandwidth threshold lowered to 200",
            "Chunk density increased: byte budget 3200→5000, record cap 25→35, reducing chunk count by ~36% for large syncs",
        },
    }},
    -- v0.27.0
    {"0.27.0", "2026-04-19", {
        Fixed = {
            "Records with Unix epoch 0 timestamps repaired — multiple 'or 0' fallbacks replaced with validated timestamps",
            "Schema migration 7→8 repairs existing epoch-0 records and cleans up bogus 1970-01-01 compacted summaries",
        },
        Added = {
            "\"Open Sync Log\" button in Sync tab for quick access to the copy-pastable sync log",
            "Bottleneck diagnostics in audit trail: per-chunk RTT, CTL bandwidth backoff, compression ratio, pending peer queue time",
            "IsValidTimestamp validation helper prevents future epoch-0 writes at all storage boundaries",
        },
        Changed = {
            "Sync logging unified into single AddAuditEntry system — SyncLog function removed; chat and audit trail now report identical information",
        },
    }},
    -- v0.26.0
    {"0.26.0", "2026-04-17", {
        Added = {
            "Sync aborts immediately when entering combat and notifies partner via BUSY — no more 95-second NACK timeout stalls during M+ or raid",
            "Separate 2-second combat cooldown prevents sync from resuming during rapid trash-pack combat cycling",
            "HandleBusy now also aborts sending when the send target reports busy",
            "Sync status UI shows \"Paused (combat)\" when combat pause is active",
        },
    }},
    -- v0.25.5
    {"0.25.5", "2026-04-17", {
        Fixed = {
            "Periodic rescan no longer double-stores records that arrived via sync — session caches are invalidated after each sync chunk",
        },
    }},
    -- v0.25.4
    {"0.25.4", "2026-04-17", {
        Fixed = {
            "Sync no longer requests data from peers with fewer records — avoids receiving duplicate chunks that waste bandwidth",
            "Bidirectional check after sending skips reverse-requesting from peers with fewer records",
        },
    }},
    -- v0.25.3
    {"0.25.3", "2026-04-17", {
        Fixed = {
            "Sync receiving state no longer gets permanently stuck when a sync request goes unanswered — properly retries with backoff and aborts after 3 attempts",
            "BUSY response from a peer now clears receiving state even with partial data received, preventing stuck sync",
            "Added 30-minute safety net to auto-abort any stuck receive session",
        },
    }},
    -- v0.25.2
    {"0.25.2", "2026-04-16", {
        Fixed = {
            "Sync whispers to offline players no longer generate \"No player named\" system errors in chat",
            "In-progress sync aborts cleanly when target peer goes offline instead of hanging",
        },
    }},
    -- v0.25.1
    {"0.25.1", "2026-04-16", {
        Fixed = {
            "Online peers list showed peers for up to 5 minutes after disconnect — roster is now cross-checked for recently-seen peers",
        },
    }},
    -- v0.25.0
    {"0.25.0", "2026-04-16", {
        Added = {
            "Epidemic gossip sync — data propagates exponentially across guild; each peer becomes a seed after receiving",
            "Concurrent send + receive — send to one peer while receiving from another simultaneously",
            "Smart peer selection — priority scoring replaces FIFO queue (most divergent peers sync first)",
            "GUILD manifest broadcast — bucket hashes broadcast every 5 min for state discovery",
            "Hash-gated HELLO reply suppression — near-zero WHISPER traffic in large guilds",
            "Forced HELLO rate limiting — prevents broadcast storms during rapid propagation",
        },
        Changed = {
            "Bidirectional check delay: 3s → 0.5s",
            "Post-receive HELLO delay: 2s → 0.5–2s with jitter",
            "Pending peers processing delay: 1s → 0.2s",
            "Sync initiation jitter: 0–2s → 0–1s",
        },
    }},
    -- v0.24.0
    {"0.24.0", "2026-04-15", {
        Added = {
            "\"Show minimap button\" toggle — hide the minimap icon while keeping the LDB launcher for display addons (requested by Rox)",
        },
    }},
    -- v0.23.0
    {"0.23.0", "2026-04-15", {
        Changed = {
            "Sync chunk budget doubled and record cap raised (15→25) — halves chunk count for faster syncs",
            "ACK timeout reduced from 15s to 8s with more retries (3→5) — faster recovery from message loss",
            "ACK and NACK messages now sent with ALERT priority for faster delivery",
        },
        Fixed = {
            "Stale ACKs from retried chunks no longer orphan active timers (could cause 120s stalls)",
        },
    }},
    -- v0.22.4
    {"0.22.4", "2026-04-15", {
        Added = {
            "Peers in M+ or raids stay visible via guild roster fallback",
            "Known peers persisted across sessions for instant discovery on login",
        },
    }},
    -- v0.22.3
    {"0.22.3", "2026-04-15", {
        Fixed = {
            "Sync status now shows both Sending and Receiving when active simultaneously",
            "Receive progress shows waiting instead of 0/0 while awaiting first chunk",
        },
    }},
    -- v0.22.2
    {"0.22.2", "2026-04-15", {
        Fixed = {
            "Pending peers queue no longer requests sync from peers detected as offline",
            "FinishReceiving now removes the sender from the pending queue to prevent immediate re-request",
        },
    }},
    -- v0.22.1
    {"0.22.1", "2026-04-15", {
        Fixed = {
            "Automatic duplicate cleanup now runs after bank scan refreshes eventCounts",
        },
    }},
    -- v0.22.0
    {"0.22.0", "2026-04-15", {
        Added = {
            "BUSY message: declined sync requests now respond immediately instead of 60s dead air",
            "Pending peers queue: missed sync opportunities automatically retried after current sync",
            "Post-sync HELLO broadcast to trigger reciprocal sync",
            "Bidirectional sync: checks if peer has data we need after sending",
            "Combat guard: sync deferred during combat, resumes after",
            "Sync jitter: 0-2s random delay prevents mutual request collisions",
            "Sender offline detection: aborts early if sender disconnects mid-sync",
            "NACK backoff: progressive timeouts (20s, 30s, 45s) for retries",
        },
        Changed = {
            "First-chunk timeout reduced from 20s to 10s for faster failure detection",
        },
    }},
    -- v0.21.0
    {"0.21.0", "2026-04-14", {
        Added = {
            "About tab with addon info, Ko-fi donation link, CurseForge link, and credits",
            "GitHub Sponsors integration and README support section",
        },
    }},
    -- v0.20.1
    {"0.20.1", "2026-04-14", {
        Changed = {
            "Roadmap: moved Export feature to post-1.0; Stabilization is now the next milestone",
        },
    }},
    -- v0.20.0
    {"0.20.0", "2026-04-14", {
        Changed = {
            "Documentation sync for beta preparation: README, ROADMAP, CurseForge description updated",
        },
        Fixed = {
            "Changelog tab showing blank content — nav bar moved inside scroll frame",
        },
        Removed = {
            "Obsolete planning docs (IMPLEMENTATION_PLAN.md, PLAN.md) deleted",
        },
    }},
    -- v0.19.3
    {"0.19.3", "2026-04-14", {
        Changed = {
            "Sync and Changelog tabs right-aligned in tab bar to separate from data tabs",
        },
    }},
    -- v0.19.2
    {"0.19.2", "2026-04-14", {
        Changed = {
            "Changelog tab now paginates (10 versions per page) for faster loading",
            "Previous/Next navigation with accessible disabled-state labels",
        },
    }},
    -- v0.19.1
    {"0.19.1", "2026-04-14", {
        Fixed = {
            "Sync chunk 1 no longer oversized — eventCounts spread across chunks",
        },
    }},
    -- v0.19.0
    {"0.19.0", "2026-04-14", {
        Changed = {
            "Consumption tab redesigned as guild-wide overview dashboard",
            "Three sections: Guild Totals, Top Consumers (top 10), Most Used Items (top 15)",
            "Most Used Items shows withdrawal counts with 7d/30d/all-time trend columns",
            "Top Consumers shows full gold in/out/net breakdown per player",
            "Click player name in Top Consumers to jump to Transactions tab filtered by that player",
        },
        Removed = {
            "Collapsible player rows replaced by flat ranked tables",
        },
    }},
    -- v0.18.1
    {"0.18.1", "2026-04-14", {
        Fixed = {
            "Changelog tab now displays full content instead of truncating with '...'",
        },
    }},
    -- v0.18.0
    {"0.18.0", "2026-04-14", {
        Added = {
            "Directional peer version status — shows who needs to update",
            "Version label in top-right corner with peer-based update detection",
            "CompareSemver utility and GetHighestPeerVersion getter",
        },
    }},
    -- v0.17.0
    {"0.17.0", "2026-04-14", {
        Added = {
            "Event count metadata — persists API-observed counts for accurate dedup",
            "Count-based cleanup replaces heuristic anchor logic",
            "Post-sync cleanup trims diverged-index duplicates automatically",
            "eventCounts synced between peers (max wins, backwards-compatible)",
        },
        Fixed = {"Genuine synced records no longer deleted by cleanup"},
    }},
    -- v0.16.0
    {"0.16.0", "2026-04-14", {
        Added = {"Changelog tab in addon UI — scrollable version history"},
    }},
    -- v0.15.x
    {"0.15.2", "2026-04-14", {
        Fixed = {"Sync re-introducing duplicates after cleanup"},
        Added = {"DeduplicateRecords function for startup dedup"},
    }},
    {"0.15.1", "2026-04-13", {
        Fixed = {"ItemCache error on uncached items (wrong API for numeric itemID)"},
    }},
    {"0.15.0", "2026-04-13", {
        Added = {
            "GM-configurable access control system",
            "Access control sync via HELLO protocol",
        },
        Changed = {
            "Settings visible to all full-access users",
            "Tab list rebuilds dynamically on access changes",
        },
        Fixed = {"Migration now runs full dedup cleanup"},
        Removed = {"IsOfficerRank() replaced by access control"},
    }},
    -- v0.14.x
    {"0.14.3", "2026-04-13", {
        Fixed = {
            "Duplicate records from seenTxHashes gaps after sync",
            "Duplicate records from split adjacent slots",
            "Occurrence ID collision after normalization",
        },
    }},
    {"0.14.2", "2026-04-13", {
        Fixed = {"Existing duplicate records removed on upgrade"},
        Added = {"/gbl cleanup command"},
    }},
    {"0.14.1", "2026-04-13", {
        Fixed = {"Within-slot duplicate records on rescan"},
    }},
    {"0.14.0", "2026-04-13", {
        Fixed = {"Duplicate records from occurrence index shift"},
        Changed = {"Per-slot occurrence reindexing, sync protocol v4"},
    }},
    -- v0.13.x
    {"0.13.2", "2026-04-13", {
        Fixed = {"Player name consolidation failure at login"},
    }},
    {"0.13.1", "2026-04-13", {
        Fixed = {"Outdated peers now visible in Online Peers"},
    }},
    {"0.13.0", "2026-04-13", {
        Added = {
            "Item name resolution for synced records",
            "Guild roster cache for cross-realm tracking",
        },
        Changed = {
            "Player names always stored as Name-Realm",
            "Sync restricted to exact version match",
        },
        Fixed = {
            "Sync chunk count off-by-one",
            "Consumption view player fragmentation",
        },
    }},
    -- v0.12.x
    {"0.12.2", "2026-04-12", {
        Fixed = {"Corrupted sync records from serialization"},
    }},
    {"0.12.1", "2026-04-12", {
        Added = {"Chat Log toggle on Sync tab"},
    }},
    {"0.12.0", "2026-04-12", {
        Fixed = {"Cross-client false positives for adjacent-hour events"},
        Added = {"Occurrence scheme migration (v1 to v2)"},
    }},
    -- v0.11.x
    {"0.11.3", "2026-04-12", {
        Added = {"20 regression tests for sync convergence"},
    }},
    {"0.11.2", "2026-04-12", {
        Fixed = {"Bucket hashes mismatching after ID normalization"},
    }},
    {"0.11.1", "2026-04-12", {
        Fixed = {
            "Sync looping after normalization (sender-wins)",
            "Bucket hash mismatch from timestamp divergence",
        },
    }},
    {"0.11.0", "2026-04-12", {
        Added = {
            "Sync ID normalization for convergence",
            "Compaction guard during sync receive",
        },
    }},
    -- v0.10.x
    {"0.10.2", "2026-04-12", {
        Fixed = {"Sync dedup false positives for consecutive-hour events"},
    }},
    {"0.10.1", "2026-04-12", {
        Fixed = {"Stale peers wiped while still online (added heartbeat)"},
    }},
    {"0.10.0", "2026-04-11", {
        Added = {"LibDeflate compression for sync messages"},
        Changed = {"Sync protocol version bumped to 2"},
    }},
    -- v0.9.x
    {"0.9.7", "2026-04-11", {
        Fixed = {"Stale peers in Online list (5-minute expiry)"},
    }},
    {"0.9.6", "2026-04-11", {
        Changed = {"Sync buckets use 6-hour windows instead of daily"},
    }},
    {"0.9.5", "2026-04-11", {
        Fixed = {"Audit trail flooding from chunk logging"},
    }},
    {"0.9.4", "2026-04-11", {
        Added = {"/gbl synclog command"},
    }},
    {"0.9.3", "2026-04-11", {
        Fixed = {
            "Peer discovery after reload",
            "Known-peer reply gate blocking rediscovery",
        },
        Changed = {"HELLO replies use targeted WHISPER"},
    }},
    {"0.9.2", "2026-04-11", {
        Changed = {"Verbose sync audit trail diagnostics"},
    }},
    {"0.9.1", "2026-04-11", {
        Fixed = {"Hash-mismatch sync gap between peers"},
        Changed = {"Hash comparison as primary sync trigger"},
    }},
    {"0.9.0", "2026-04-11", {
        Added = {
            "Receive-side NACK retry for sync",
            "Zone change protection during sync",
            "FPS-adaptive throttling",
        },
        Changed = {"Smaller sync chunks (15 to 5 records)"},
    }},
    -- v0.8.x
    {"0.8.0", "2026-04-11", {
        Added = {
            "Fingerprint-based sync (hash comparison)",
            "Bucket-filtered delta sync",
        },
    }},
    -- v0.7.x
    {"0.7.17", "2026-04-11", {
        Changed = {"Reverted inter-chunk delay to 100ms"},
    }},
    {"0.7.15", "2026-04-11", {
        Changed = {"Reduced chunk byte budget for reliability"},
    }},
    {"0.7.14", "2026-04-11", {
        Fixed = {"Crash syncing records with missing fields"},
    }},
    {"0.7.13", "2026-04-10", {
        Fixed = {"Cross-realm sync name format mismatch"},
    }},
    {"0.7.12", "2026-04-10", {
        Fixed = {"Sync chunks exceeding WHISPER size limit"},
    }},
    {"0.7.11", "2026-04-10", {
        Fixed = {"Sync request stalling permanently"},
    }},
    {"0.7.10", "2026-04-10", {
        Added = {"Chat output for sync events"},
    }},
    {"0.7.9", "2026-04-10", {
        Fixed = {"Crash syncing records without timestamp"},
    }},
    {"0.7.8", "2026-04-10", {
        Changed = {
            "Sync chunk size increased to 10",
            "Sync strips reconstructable fields",
        },
    }},
    {"0.7.7", "2026-04-10", {
        Fixed = {
            "Sync chunks too large for WHISPER",
            "Single dropped chunk now retries",
        },
    }},
    {"0.7.6", "2026-04-10", {
        Fixed = {
            "Sync timers never firing in WoW",
            "Manual Hello button cooldown bypass",
        },
    }},
    {"0.7.5", "2026-04-10", {
        Fixed = {"Peer discovery failure from cooldown"},
        Added = {"HELLO on guild bank open"},
    }},
    {"0.7.4", "2026-04-10", {
        Added = {
            "HELLO response for mutual peer discovery",
            "Version indicator in peer list",
        },
    }},
    {"0.7.3", "2026-04-10", {
        Fixed = {"Sync data rejected from name format mismatch"},
    }},
    {"0.7.2", "2026-04-10", {
        Fixed = {"Column text wrapping to new lines"},
    }},
    {"0.7.1", "2026-04-10", {
        Fixed = {
            "Sync ACK timeout starting too early",
            "Self-message filtering in retail WoW",
        },
        Changed = {"Chunk size reduced, ACK timeout increased"},
    }},
    {"0.7.0", "2026-04-08", {
        Added = {
            "Gold summary panel on Gold Log tab",
            "Date range filters (1h, 3h, 24h)",
            "Pagination for Transactions tab",
        },
        Fixed = {"Re-scan no longer resets filters"},
    }},
    -- v0.6.x
    {"0.6.2", "2026-04-07", {
        Fixed = {"Re-scan not detecting new transactions"},
    }},
    {"0.6.1", "2026-04-07", {
        Fixed = {"Periodic re-scan not functioning in-game"},
    }},
    {"0.6.0", "2026-04-07", {
        Added = {
            "Periodic re-scan while guild bank open",
            "Auto re-scan toggle",
        },
    }},
    -- v0.5.0
    {"0.5.0", "2026-04-07", {
        Added = {
            "Multi-officer sync via AceComm",
            "Sync tab with controls, peer list, audit trail",
            "ACK timeout and receive timeout",
            "HELLO broadcast on login and bank close",
        },
    }, "Milestone M5: Multi-Officer Sync"},
    -- v0.4.x
    {"0.4.1", "2026-04-07", {
        Fixed = {
            "Gold transactions in Transactions tab",
            "Money tab queried at correct index",
            "Type normalization (withdrawal to withdraw)",
        },
    }},
    {"0.4.0", "2026-04-07", {
        Added = {
            "Click-to-expand player rows in consumption",
            "Sortable consumption column headers",
            "Category filter on consumption tab",
        },
        Fixed = {"Guild bank open stutter (deferred scanning)"},
    }, "Milestone M4: Consumption Detail + UI Polish"},
    -- v0.3.x
    {"0.3.3", "2026-04-07", {
        Fixed = {"Sort direction indicators (UTF-8 to text)"},
    }},
    {"0.3.2", "2026-04-07", {
        Fixed = {
            "UI rows overflowed frame (added ScrollFrame)",
            "Interface version updated to 120001",
        },
    }},
    {"0.3.1", "2026-04-07", {
        Fixed = {"fetch-libs.sh repo URLs corrected"},
    }},
    {"0.3.0", "2026-04-07", {
        Added = {
            "Main UI window with tabs",
            "Transaction ledger with sortable columns",
            "Filter bar and consumption summary",
            "Minimap button",
            "Accessibility features (WCAG 2.1 AA)",
            "Keyboard navigation",
        },
    }, "Milestone M3: UI"},
    -- v0.2.x
    {"0.2.6", "2026-04-07", {
        Added = {"Keyboard navigation and focus handling"},
    }},
    {"0.2.5", "2026-04-07", {
        Added = {"Main UI window, filter widgets, minimap button"},
    }},
    {"0.2.4", "2026-04-07", {
        Added = {
            "Per-player consumption aggregation",
            "Money formatting utility",
        },
    }},
    {"0.2.3", "2026-04-07", {
        Added = {"Transaction filter logic"},
    }},
    {"0.2.2", "2026-04-06", {
        Added = {
            "Accessibility module (WCAG 2.1 AA)",
            "Colorblind-safe palettes",
            "Triple encoding for transaction types",
        },
    }},
    {"0.2.1", "2026-04-06", {
        Added = {"Library fetch script for development"},
    }},
    {"0.2.0", "2026-04-06", {
        Added = {
            "Transaction recording from guild bank logs",
            "Item categorization by classID/subclassID",
            "Hour-bucket deduplication",
            "Money transaction tracking",
            "Per-player statistics",
            "Tiered storage compaction",
        },
    }, "Milestone M2: Ledger + Dedup + Categories + Storage"},
    -- v0.1.0
    {"0.1.0", "2026-04-06", {
        Added = {
            "AceAddon bootstrap with lifecycle",
            "Guild bank open/close detection",
            "Slot-level guild bank scanning",
            "Slash commands and AceDB saved variables",
        },
    }, "Milestone M1: Scaffold + Scanner"},
}

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------

--- Format a single changelog version entry into a WoW-colored string.
-- @param entry table { version, date, sections, milestone? }
-- @return string Formatted string with WoW color codes and newlines
function GBL:FormatChangelogEntry(entry)
    local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]
    local lines = {}

    -- Version header
    lines[#lines + 1] = string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date)

    -- Milestone label
    if milestone then
        lines[#lines + 1] = "  |cffffcc00" .. milestone .. "|r"
    end

    -- Section entries in standard order
    for _, sType in ipairs(SECTION_ORDER) do
        local entries = sections[sType]
        if entries then
            local color = SECTION_COLORS[sType] or "|cffcccccc"
            lines[#lines + 1] = "  " .. color .. sType .. ":|r"
            for _, text in ipairs(entries) do
                lines[#lines + 1] = "    - " .. text
            end
        end
    end

    -- Trailing blank line for spacing
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the Changelog tab inside a container.
-- Paginates by version entry (CHANGELOG_PAGE_SIZE per page).
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildChangelogTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local data = self.CHANGELOG_DATA or {}
    local totalEntries = #data

    -- Pagination math
    self._changelogCurrentPage = self._changelogCurrentPage or 1
    local totalPages = math.max(1, math.ceil(totalEntries / CHANGELOG_PAGE_SIZE))
    local page = math.max(1, math.min(self._changelogCurrentPage, totalPages))
    self._changelogCurrentPage = page
    local startIdx = (page - 1) * CHANGELOG_PAGE_SIZE + 1
    local endIdx = math.min(startIdx + CHANGELOG_PAGE_SIZE - 1, totalEntries)

    -- Scrollable content (only direct child of container, so List layout
    -- gives it proper height — adding siblings before it breaks sizing)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("List")
    container:AddChild(scroll)
    scroll.frame:SetPoint("BOTTOMRIGHT", container.content, "BOTTOMRIGHT", 0, 0)

    -- Navigation bar inside scroll (only when multiple pages)
    if totalPages > 1 then
        local navGroup = AceGUI:Create("SimpleGroup")
        navGroup:SetFullWidth(true)
        navGroup:SetLayout("Flow")
        scroll:AddChild(navGroup)

        -- Previous button
        local prevBtn = AceGUI:Create("Button")
        prevBtn:SetWidth(100)
        if page <= 1 then
            prevBtn:SetText("- Previous -")
            prevBtn:SetDisabled(true)
        else
            prevBtn:SetText("< Previous")
            prevBtn:SetDisabled(false)
        end
        prevBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page - 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(prevBtn)

        -- Page label
        local pageLabel = AceGUI:Create("Label")
        pageLabel:SetWidth(140)
        pageLabel:SetText(string.format("  Page %d of %d", page, totalPages))
        pageLabel:SetJustifyH("CENTER")
        local fontPath, fontSize = self:GetScaledFont()
        pageLabel:SetFont(fontPath, fontSize)
        navGroup:AddChild(pageLabel)

        -- Next button
        local nextBtn = AceGUI:Create("Button")
        nextBtn:SetWidth(100)
        if page >= totalPages then
            nextBtn:SetText("- Next -")
            nextBtn:SetDisabled(true)
        else
            nextBtn:SetText("Next >")
            nextBtn:SetDisabled(false)
        end
        nextBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page + 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(nextBtn)

        -- Register buttons for keyboard navigation
        self:ClearFocusOrder()
        self:RegisterFocusable(prevBtn, 1)
        self:RegisterFocusable(nextBtn, 2)
    end

    -- Render version entries for current page
    -- (AceGUI Labels are single-line; multi-line \n text gets truncated)
    for i = startIdx, endIdx do
        local entry = data[i]
        local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]

        -- Version header (larger font)
        local header = AceGUI:Create("Label")
        header:SetFullWidth(true)
        header:SetFontObject(GameFontNormalLarge)
        header:SetText(string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date))
        scroll:AddChild(header)

        -- Milestone label
        if milestone then
            local ml = AceGUI:Create("Label")
            ml:SetFullWidth(true)
            ml:SetText("  |cffffcc00" .. milestone .. "|r")
            scroll:AddChild(ml)
        end

        -- Section entries in standard order
        for _, sType in ipairs(SECTION_ORDER) do
            local entries = sections[sType]
            if entries then
                local color = SECTION_COLORS[sType] or "|cffcccccc"
                local sl = AceGUI:Create("Label")
                sl:SetFullWidth(true)
                sl:SetText("  " .. color .. sType .. ":|r")
                scroll:AddChild(sl)

                for _, text in ipairs(entries) do
                    local el = AceGUI:Create("Label")
                    el:SetFullWidth(true)
                    el:SetText("    - " .. text)
                    scroll:AddChild(el)
                end
            end
        end

        -- Spacer between entries
        local spacer = AceGUI:Create("Label")
        spacer:SetFullWidth(true)
        spacer:SetText(" ")
        scroll:AddChild(spacer)
    end
end
