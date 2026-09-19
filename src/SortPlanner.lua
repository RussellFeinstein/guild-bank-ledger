------------------------------------------------------------------------
-- GuildBankLedger — SortPlanner.lua
-- Given a bank snapshot and a layout, produce an ordered list of moves
-- that reshapes the bank toward the layout.
--
-- Algorithm: assign-then-schedule.
--
--   Phase 1 Assignment
--     * Build demands (one per slot claimed by any display tab's slotOrder).
--     * Build supplies (every occupied slot outside ignore tabs).
--     * Identify keep-slots — supplies whose (tab, slot, itemID) already
--       match a demand. Reserve perSlot against the demand; any excess
--       (oversize keep) becomes a free supply.
--     * For each unfilled demand, pick sources in priority order:
--         1. Same display tab, not-keep, same-item.
--         2. Overflow tab, same-item.
--         3. Other display tabs, not-keep, same-item.
--       Within each tier, largest available first; deterministic tiebreak
--       by (tab, slot) lex order. Emit assignment records.
--     * Any non-overflow supply with leftover `available` → assignment to
--       an empty overflow slot. If no overflow slot is free, record as
--       unplaced with reason="overflow-full". Unmet demand → deficit.
--
--   Phase 2 Schedule
--     * Topologically fire assignments whose preconditions hold against
--       a mutable working-state model. Repeat until no progress.
--     * Anything still remaining is a swap cycle. Pick a pivot:
--         1. Same-tab empty slot not claimed by any demand.
--         2. Empty overflow slot (not reserved by a remaining assignment).
--       Emit a pivot move from the blocked op's destination, then redirect
--       any other pending assignment that was reading from that slot to
--       pull from the pivot instead. Re-run the greedy loop.
--     * If no pivot is available, record all remaining cycle participants
--       as unplaced with reason="cycle-no-pivot" and stop — do not emit
--       half-broken ops.
--     * A same-item destination that would over-stack counts as blocked
--       too, but only for a Phase 4 packing assignment (#147). There it
--       means two stacks of one item must exchange places, which a pivot
--       resolves. On anything else the same refusal means the layout wants
--       more of the item than one slot holds, and pivoting would re-plan
--       the same moves every pass, so those stay a zero-op residual.
--     * The loop is bounded (GBL.SORT_PIVOT_BUDGET, overridable per plan
--       by opts.pivotBudget for tests). Running out records what is left
--       as unplaced with reason="cycle-budget-exhausted" and clears it,
--       so it is reported once and never moved afterwards (#138).
--
--   Phase 3 Sweep
--     * Defensive: any display-tab slot that still holds a non-fitting
--       item in the post-schedule state (and is not already unplaced) is
--       routed to overflow. In a well-formed plan this is a no-op; it
--       guards against edge cases in Phase 1's assignment.
--
--   Phase 4 Overflow Compaction
--     * Reorders each overflow tab into a deterministic contiguous run
--       starting at slot 1, sorted by (itemID ASC, count DESC, slot ASC).
--       Closes gaps, groups same-item stacks, and makes repeat sorts
--       idempotent. Swap cycles resolve via the same findPivot used in
--       Phase 2. Within each same-item run, partial stacks are merged
--       up to the item's max stack size (read from ItemCache or the
--       optional opts.maxStackByItem override) so each run ends as
--       [full, full, ..., partial?]. Items with unknown max stack
--       (cold cache) skip merging and fall back to grouping only.
--       Within a run of stacks sharing an itemID AND a count, which slot
--       each one lands in is arbitrary, so the assignment minimises
--       movement: a stack already inside the run's slot range stays put.
--       Ranking them by origSlot instead makes the target depend on
--       current positions, which executing the plan changes, so a pass
--       that ends early re-aims the rest of it (#140).
--       A slot Phase 2 gave up on is left out of the packing entirely,
--       targets included, so the run closes around it rather than
--       through it and the stack reported unplaced is never moved (#143).
--
-- Public contract — drop-in compatible with SortExecutor and UI/SortView.
-- The optional third arg opts is read by tests; production callers omit it.
--
--   PlanSort(snapshot, layout, opts?) -> {
--       ops = { {op="split"|"move", srcTab, srcSlot,
--                dstTab, dstSlot, itemID, count}, ... },
--       deficits = { [itemID] = count },
--       unplaced = { {tabIndex, slotIndex, itemID, count, reason}, ... },
--       overflowTabs = { tabIndex, ... },  -- routing (fill) order, {} if none
--       overflowTab = tabIndex | nil,      -- alias for overflowTabs[1]
--   }
--
--   opts.maxStackByItem :: { [itemID]=number } | nil
--       Per-item max stack override used by tests. When absent, the
--       planner reads max stack via GBL:GetMaxStack(itemID).
--
--   opts.pivotBudget :: number | nil
--       How many pivot iterations one run of the Phase 2 loop may spend
--       before it gives up and reports what is left (default
--       GBL.SORT_PIVOT_BUDGET). Test-only: 500 interlocking swap cycles
--       cannot be built in a fixture, so specs drive the exit with a small
--       budget instead. Production callers omit it.
--
--   opts.coverage :: { viewableTabs = { tabIndex, ... } } | nil   (#137)
--       What the scan that produced `snapshot` was able to read, from
--       GBL:GetLastScanCoverage(). A declared overflow tab outside it is
--       dropped from routing and reported in plan.unviewableOverflowTabs,
--       because absence from the snapshot otherwise reads as an empty tab
--       and the planner offers a tab the client cannot deposit into as 98
--       free slots. nil means no filter, which is the fresh-layout case:
--       a tab declared before anything scanned it stays usable. An empty
--       viewableTabs list is NOT nil; it means a scan saw no tab at all.
--
--   opts.bagSnapshot :: { [pseudoTab] = tabResult } | nil   (#139)
--       The player's bags, from GBL:ScanBags(), keyed by NEGATIVE
--       pseudo-tab (bagID N is tab -(N+1)). Deliberately a separate arg
--       rather than part of `snapshot`: tab classification, the
--       perTabOccupied breakdown and BankLayout.Validate must never see
--       a negative tab, and Validate rejects tabIndex < 1 outright.
--       Only items named by some display tab's `items` table are taken
--       in; everything else stays in the player's bags untouched.
--
-- Invariants:
--   * Ignore tabs are never read as source nor written as destination.
--   * Bags are a SOURCE ONLY. No op may target a pseudo-tab, and none
--     can: findPivot walks the blocked tab plus overflow tabs, Phase 3
--     sweeps display tabs, and Phase 4 packs overflow tabs, so a
--     negative key is never a candidate destination in any of them.
--   * Keep-slots (slot matching its own demand exactly) are never harvested.
--   * Unplaced entries never duplicate (their source slot is flagged so
--     Phase 3 skips it).
--   * Plan is idempotent for replan: re-running against a later snapshot
--     produces whatever moves are still needed.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98

local BankLayout = GBL.BankLayout

local REASON_OVERFLOW_FULL       = "overflow-full"
local REASON_CYCLE_NO_PIVOT      = "cycle-no-pivot"
local REASON_NO_OVERFLOW_DEFINED = "no-overflow-defined"
local REASON_CYCLE_BUDGET        = "cycle-budget-exhausted"
local REASON_OVERFLOW_UNVIEWABLE = "overflow-unviewable"

-- What each reason code says to a player, in words. The two surfaces that
-- render plan.unplaced AS PROSE read this one table: SummarizeSortPlan
-- below, whose lines /gbl sortpreview prints, and the Sort tab Unplaced
-- list. One table rather than a copy each, because #137 shipped with the
-- preview and the tab formatting the same field separately and disagreeing
-- about the same plan.
--
-- The sort log is the deliberate third renderer and is NOT prose: the
-- "bags stay:" line further down prints the raw code, because a capture is
-- searched by code and a reworded sentence would break that. Two registers,
-- on purpose. Do not "fix" them into agreement.
local REASON_TEXT = {
    [REASON_OVERFLOW_FULL]       = "every usable overflow tab is full",
    [REASON_NO_OVERFLOW_DEFINED] = "the layout declares no overflow tab",
    [REASON_OVERFLOW_UNVIEWABLE] = "no overflow tab is visible to this character",
    [REASON_CYCLE_NO_PIVOT]      = "the sort could not free up the slot it needs",
    [REASON_CYCLE_BUDGET]        = "the sort ran out of attempts to free up slots",
}

--- Human text for an unplaced entry reason code.
-- An unknown code returns the code itself rather than nothing: a reason
-- added later (#150 would add one) must show something the player can
-- search for, and a blank row is worse than a raw code. A missing reason
-- says so plainly.
-- @param reason string|nil a value from GBL._sortPlannerReasons
-- @return string always a non-empty string
function GBL:SortReasonText(reason)
    if reason == nil then return "reason not recorded" end
    return REASON_TEXT[reason] or tostring(reason)
end

-- How many pivot iterations one call of the pivot-break loop may spend.
-- Each iteration emits one pivot and then re-drains, and a plan holds far
-- fewer independent swap cycles than this, so no plan is known to reach it
-- and it is a defensive stop rather than a tuning knob. It earns its keep
-- because reaching it used to drop the remaining moves out of the plan
-- silently; they are now reported. Exported so specs can drive that exit
-- with a small budget instead of building 500 real cycles.
local PIVOT_BUDGET = 500
GBL.SORT_PIVOT_BUDGET = PIVOT_BUDGET

-- How many stacks the "bags stay:" plan-line continuation names before it
-- switches to a count. A bag full of one item would otherwise turn a single
-- log entry into a page.
local STAY_LINE_MAX_NAMED = 10

--- Render one slot reference. Routes through GBL:FormatSlotRef (Scanner.lua,
--- loaded ahead of this file) so a bag pseudo-tab prints "Bag0/5" instead of
--- the "T-1/5" a bare format would produce. The fallback only matters for a
--- partial test setup that loads the planner without the scanner.
local function slotRef(self, tabIndex, slotIndex)
    if self and self.FormatSlotRef then
        return self:FormatSlotRef(tabIndex, slotIndex)
    end
    return string.format("T%d/%d", tabIndex, slotIndex)
end

--- Fold plan.unplaced down to one entry per distinct bag slot.
---
--- A single bag slot can be recorded more than once: Phase 1B records the
--- leftover a supply could not place, and either Phase 2 abort then records
--- one entry per remaining assignment, several of which share a source when
--- a stack was split across destinations. Those portions are disjoint takes
--- from one stack, so the counts add up and the slot is named once. The
--- first entry's reason wins; a slot with two reasons was blocked by the
--- first one it hit.
---
--- Bank-origin entries (non-negative tabIndex) are not bag stays and are
--- dropped. Recording order is preserved so the continuation line names
--- stacks in the order the planner met them.
---
--- Exported as GBL._BagStays for the spec: it is otherwise file-local, and
--- the multi-entry arrangement it exists for is expensive to build through
--- PlanSort.
--- @param unplaced table plan.unplaced
--- @return table Array of { tabIndex, slotIndex, itemID, count, reason }
local function bagStays(unplaced)
    local out, byKey = {}, {}
    for _, u in ipairs(unplaced or {}) do
        if type(u.tabIndex) == "number" and u.tabIndex < 0 then
            local key = u.tabIndex .. ":" .. tostring(u.slotIndex)
            local seen = byKey[key]
            if seen then
                seen.count = (seen.count or 0) + (u.count or 0)
            else
                seen = {
                    tabIndex = u.tabIndex, slotIndex = u.slotIndex,
                    itemID = u.itemID, count = u.count or 0, reason = u.reason,
                }
                byKey[key] = seen
                out[#out + 1] = seen
            end
        end
    end
    return out
end
GBL._BagStays = bagStays

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Canonical overflow stack order, shared by Phase 0 (merge runs) and
--- Phase 4 (position packing): itemID ASC, count DESC, original slot ASC.
--- This comparator IS the packing contract; change it in one place only.
local function overflowStackOrder(a, b)
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.count ~= b.count then return a.count > b.count end
    return a.origSlot < b.origSlot
end

local function extractItemID(itemLink)
    if BankLayout and BankLayout.ExtractItemID then
        return BankLayout.ExtractItemID(itemLink)
    end
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

--- Apply a planned op to a working state (mutates in place).
--- @param getMaxStack function|nil Optional `(itemID) -> maxStack|nil` lookup.
---     When provided AND maxStack is known, asserts that merging into a
---     same-item dst would not exceed maxStack — surfaces planner bugs
---     that bypass canExecute. When nil OR the lookup returns nil, the
---     guard is skipped (cold-cache fallback).
local function applyOpToState(state, op, getMaxStack)
    if not state[op.srcTab] then state[op.srcTab] = {} end
    if not state[op.dstTab] then state[op.dstTab] = {} end
    local src = state[op.srcTab][op.srcSlot]
    assert(src and src.itemID == op.itemID and src.count >= op.count,
        "applyOpToState: src invariant violated")
    src.count = src.count - op.count
    if src.count == 0 then state[op.srcTab][op.srcSlot] = nil end
    local dst = state[op.dstTab][op.dstSlot]
    if dst then
        assert(dst.itemID == op.itemID,
            "applyOpToState: dst occupied by wrong item")
        if getMaxStack then
            local m = getMaxStack(op.itemID)
            if m then
                assert((dst.count + op.count) <= m,
                    "applyOpToState: would exceed maxStack for itemID "
                    .. tostring(op.itemID))
            end
        end
        dst.count = dst.count + op.count
    else
        state[op.dstTab][op.dstSlot] = { itemID = op.itemID, count = op.count }
    end
end

--- Return true iff an op can fire against `state`.
--- @param getMaxStack function|nil Optional `(itemID) -> maxStack|nil` lookup.
---     When provided AND maxStack is known AND dst is same-item, returns
---     false if merging would exceed maxStack. This is the guard that
---     prevents Phase 4 packing from emitting cascades that depend on
---     illegal in-state over-stack accumulations.
-- v0.32.8 B4a: returns (ok, reason) where reason names the failing
-- predicate on a false return. Existing callers in greedyDrain and the
-- emit-feasibility checks wrap canExecute in a boolean condition, so
-- Lua picks up only the first return value and their control flow is
-- unchanged. Phase 2 instrumentation reads the reason on a refusal to
-- attribute WHY the planner couldn't emit the assignment.
local function canExecute(op, state, getMaxStack)
    local src = state[op.srcTab] and state[op.srcTab][op.srcSlot]
    if not src or src.itemID ~= op.itemID or src.count < op.count then
        return false, "src-shortfall"
    end
    local dst = state[op.dstTab] and state[op.dstTab][op.dstSlot]
    if dst then
        if dst.itemID ~= op.itemID then return false, "dst-mismatch" end
        if getMaxStack then
            local m = getMaxStack(op.itemID)
            if m and (dst.count + op.count) > m then
                return false, "max-stack-overflow"
            end
        end
    end
    return true, nil
end

--- Pick "split" or "move" label based on whether the op fully drains src.
--- The ONLY writer of `op.op`; all three op producers route through it
--- (emitAssignment, the Phase 2 pivot, the Phase 3 sweep). Two of those used
--- to hardcode "move", and the sweep was wrong to: tier 1 caps its take at
--- the destination partial's capacity (#161). Call it against `state` BEFORE
--- applyOpToState mutates the source, or the label inverts.
local function opLabel(state, ass)
    local src = state[ass.srcTab] and state[ass.srcTab][ass.srcSlot]
    if src and src.count > ass.count then return "split" end
    return "move"
end

------------------------------------------------------------------------
-- Main entry
------------------------------------------------------------------------

function GBL:PlanSort(snapshot, layout, opts)
    local plan = {
        ops = {}, deficits = {}, unplaced = {},
        overflowTabs = {},
        -- Declared overflow tabs the scan could not see (#137). Ascending
        -- by tab index. On the plan literal so the invalid-layout early
        -- return below carries it too.
        unviewableOverflowTabs = {},
        -- demandMap is the authoritative expected layout: for each display
        -- tab, a map slotIndex -> {itemID, perSlot} including both
        -- slotOrder-pinned demands and items[id].slots extensions. Populated
        -- at the end of Phase 1 and exposed for diagnostic / deviation
        -- commands.
        demandMap = {},
    }

    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return plan
    end

    -- Diagnostic timing: record planner cost so /gbl synclog shows a
    -- single line per plan. Replans on foreign-activity go through the
    -- same path, so this captures both first-plan and replan latency.
    local profileStart = debugprofilestop and debugprofilestop() or nil
    local inputSlots, inputTabs = 0, 0
    local perTabOccupied = {}
    for tabIndex, tabResult in pairs(snapshot or {}) do
        inputTabs = inputTabs + 1
        local n = 0
        if tabResult and tabResult.slots then
            for _ in pairs(tabResult.slots) do
                n = n + 1
            end
        end
        perTabOccupied[tabIndex] = n
        inputSlots = inputSlots + n
    end

    -- Per-phase counters. Populated as each phase runs and dumped to the
    -- audit trail at the end alongside the existing one-line summary.
    -- This is the layer that lets a post-mortem distinguish "Phase 0
    -- merged 4 stacks" from "Phase 1B spilled 4 fresh stacks to overflow"
    -- when both produce 4 ops.
    local diag = {
        phase0Merges = 0, phase0SlotsFreed = 0,
        phase1aAssignments = 0,
        phase1bTopup = 0, phase1bExtendRight = 0,
        phase1bExtendLeft = 0, phase1bFirstEmpty = 0,
        phase1bUnplaced = 0,
        -- phase2CycleAborts counts abort EVENTS; phase2StrandedAssignments
        -- counts the assignments those aborts gave up on. They used to be one
        -- field under the first name, so a single cycle abandoning eight
        -- pending assignments reported itself as eight aborts (#165).
        phase2Pivots = 0, phase2CycleAborts = 0, phase2StrandedAssignments = 0,
        phase3Sweeps = 0,
        phase4PositionShifts = 0,
        demandPinned = 0, demandExtendRight = 0,
        demandExtendLeft = 0, demandFirstEmpty = 0,
        -- #139 bag sourcing: supplies admitted from bags, how many filled
        -- a display demand, and how many spilled to overflow. A run with
        -- bagSupplies > 0 and both others 0 means the layout named the
        -- items but had nowhere to put them.
        bagSupplies = 0, bagDemandFills = 0, bagSpills = 0,
        -- What the scan saw and the sort left alone, so a capture can say
        -- why a bag stack was never a candidate: not named by the layout
        -- (ignored), or skipped by ScanBags as bound, locked or link-less.
        -- bagStay is the number of admitted stacks the plan could not place,
        -- counted from plan.unplaced once every phase has run.
        bagIgnored = 0, bagBound = 0, bagLocked = 0, bagNoLink = 0,
        bagStay = 0,
    }

    -- v0.32.8 B4a: Phase 2 instrumentation. SortDebug emissions are
    -- gated by db.profile.sort.debugChat in Logger.lua, so normal users
    -- see clean sort logs; debugging a cycle requires flipping the flag.
    -- Cap emissions per plan to avoid flooding the debug channel when
    -- the planner refuses many ops in a degenerate input.
    local PHASE2_EMIT_CAP = 20
    local phase2EmitCount = 0
    local function phase2Debug(fmt, ...)
        if phase2EmitCount >= PHASE2_EMIT_CAP then return end
        if not self.SortDebug then return end
        phase2EmitCount = phase2EmitCount + 1
        self:SortDebug(fmt, ...)
    end

    -- --------------------------------------------------------------
    -- Classify tabs.
    -- --------------------------------------------------------------
    local displayTabs = {}
    local ignoreSet = {}
    for tabIndex, tab in pairs(layout.tabs) do
        if tab.mode == "display" then
            table.insert(displayTabs, { tabIndex = tabIndex, tab = tab })
        elseif tab.mode == "ignore" then
            ignoreSet[tabIndex] = true
        end
    end
    -- Overflow tabs in routing (fill) order, from the shared helper
    -- (BankLayout.OrderedOverflowTabs). Never iterate overflow tabs via
    -- pairs(): the ordered array is what keeps plan output deterministic
    -- with more than one overflow tab.
    local overflowTabsOrdered = BankLayout.OrderedOverflowTabs(layout)
    -- Scan coverage (#137). Tells a tab the scan could not see from one
    -- nobody has scanned yet; without it the seeding loop offers both as
    -- 98 free slots. No coverage means no filter.
    local coverage = opts and opts.coverage
    local haveCoverage = coverage and type(coverage.viewableTabs) == "table"
    local declaredOverflow = #overflowTabsOrdered
    if haveCoverage then
        local viewable = {}
        for _, t in ipairs(coverage.viewableTabs) do viewable[t] = true end
        local usable, hidden = {}, {}
        for _, t in ipairs(overflowTabsOrdered) do
            if viewable[t] then
                usable[#usable + 1] = t
            else
                hidden[#hidden + 1] = t
            end
        end
        -- By index, not routing order: this names tabs a player looks for
        -- in the bank frame, where they are numbered.
        table.sort(hidden)
        overflowTabsOrdered = usable
        plan.unviewableOverflowTabs = hidden
    end
    -- Which "nowhere to put it" this is. A layout declaring no overflow tab
    -- needs a layout edit; one whose tabs are all hidden needs a rank
    -- change. Only reachable with coverage, since nothing else empties the
    -- list once tabs are declared.
    local noOverflowReason = REASON_NO_OVERFLOW_DEFINED
    if declaredOverflow > 0 and #overflowTabsOrdered == 0 then
        noOverflowReason = REASON_OVERFLOW_UNVIEWABLE
    end
    local overflowSet = {}
    for _, t in ipairs(overflowTabsOrdered) do overflowSet[t] = true end
    -- The helper returns a fresh caller-owned array and the planner never
    -- mutates it, so publishing it directly is safe. overflowTab is the
    -- documented alias for the first tab in routing order.
    plan.overflowTabs = overflowTabsOrdered
    plan.overflowTab = overflowTabsOrdered[1]
    table.sort(displayTabs, function(a, b) return a.tabIndex < b.tabIndex end)

    -- --------------------------------------------------------------
    -- Build working bank (excluding ignore tabs).
    -- --------------------------------------------------------------
    local bank = {}
    for tabIndex, tabResult in pairs(snapshot or {}) do
        if not ignoreSet[tabIndex] then
            bank[tabIndex] = {}
            if tabResult and tabResult.slots then
                for slotIndex, slot in pairs(tabResult.slots) do
                    local itemID = extractItemID(slot.itemLink)
                    if itemID then
                        bank[tabIndex][slotIndex] = {
                            itemID = itemID,
                            count = slot.count or 1,
                        }
                    end
                end
            end
        end
    end
    for _, ovTab in ipairs(overflowTabsOrdered) do
        if not bank[ovTab] then bank[ovTab] = {} end
    end

    -- --------------------------------------------------------------
    -- Bags (#139): admit opts.bagSnapshot under its negative pseudo-tabs.
    --
    -- This must land after the overflow ensure loop and before the state
    -- deep copy below, which is `bank`'s only consumer: nothing else
    -- reads it, so a pseudo-tab cannot leak past `state` from here. The
    -- classification and perTabOccupied passes ran off `snapshot`, which
    -- bags never enter, so they are already past.
    --
    -- Only items some display tab's template names are taken. A
    -- slotOrder entry without an items entry produces no demand, so the
    -- items keys are exactly the demand-capable set; anything else in
    -- the player's bags is none of the sort's business.
    -- --------------------------------------------------------------
    local bagTabs = {}
    if opts and type(opts.bagSnapshot) == "table" then
        local layoutItems = {}
        for _, entry in ipairs(displayTabs) do
            for itemID in pairs(entry.tab.items or {}) do
                layoutItems[tonumber(itemID) or itemID] = true
            end
        end
        for tabIndex, tabResult in pairs(opts.bagSnapshot) do
            if type(tabIndex) == "number" and tabIndex < 0 then
                local held = {}
                local any = false
                diag.bagBound = diag.bagBound + ((tabResult or {}).boundSkips or 0)
                diag.bagLocked = diag.bagLocked + ((tabResult or {}).lockedSkips or 0)
                diag.bagNoLink = diag.bagNoLink + ((tabResult or {}).noLink or 0)
                for slotIndex, slot in pairs((tabResult or {}).slots or {}) do
                    local itemID = slot.itemID or extractItemID(slot.itemLink)
                    if itemID and layoutItems[itemID] then
                        held[slotIndex] = { itemID = itemID, count = slot.count or 1 }
                        any = true
                        diag.bagSupplies = diag.bagSupplies + 1
                    else
                        diag.bagIgnored = diag.bagIgnored + 1
                    end
                end
                if any then
                    bank[tabIndex] = held
                    table.insert(bagTabs, tabIndex)
                end
            end
        end
        -- Descending, so bag 0 leads: the pseudo-tabs run -1, -2, ... in
        -- bagID order, and supply order has to be stable across replans.
        table.sort(bagTabs, function(a, b) return a > b end)
    end

    -- --------------------------------------------------------------
    -- Working state + emit machinery (used by Phase 0 onward).
    -- --------------------------------------------------------------
    -- Deep-copy bank into a mutable working state. Phases 0-4 all
    -- mutate this; bank is treated as read-only after this point.
    local state = {}
    for tabIndex, tab in pairs(bank) do
        state[tabIndex] = {}
        for slotIndex, slot in pairs(tab) do
            state[tabIndex][slotIndex] = {
                itemID = slot.itemID, count = slot.count,
            }
        end
    end

    -- Per-item max stack lookup. opts.maxStackByItem (test override)
    -- wins; otherwise read the cached itemStackCount from ItemCache.
    -- Hoisted from Phase 4 so Phase 0 (overflow pre-merge) and Phase
    -- 1B (capacity-aware spill routing) can both consume it.
    local function getMaxStack(itemID)
        if opts and opts.maxStackByItem then
            return opts.maxStackByItem[itemID]
        end
        if GBL.GetMaxStack then
            return GBL:GetMaxStack(itemID)
        end
        return nil
    end

    -- Snapshot what the planner sees at a slot RIGHT NOW (before applying
    -- the op). The returned table is independent of state, so subsequent
    -- mutations don't disturb it. Returning nil means the planner expected
    -- the slot to be empty at this point in the plan.
    local function snapshotSlot(t, s)
        local v = state[t] and state[t][s]
        if v then return { itemID = v.itemID, count = v.count } end
        return nil
    end

    local function emitAssignment(ass)
        local op = {
            op = opLabel(state, ass),
            srcTab = ass.srcTab, srcSlot = ass.srcSlot,
            dstTab = ass.dstTab, dstSlot = ass.dstSlot,
            itemID = ass.itemID, count = ass.count,
            -- plannerSrcAt / plannerDstAt freeze what the planner THOUGHT
            -- the src/dst slots held at the moment this op was emitted.
            -- The executor compares these against live bank state on a
            -- pre-check fail to distinguish stale-snapshot bugs from
            -- execution drift (an earlier op didn't actually clear the
            -- slot the way the planner projected).
            plannerSrcAt = snapshotSlot(ass.srcTab, ass.srcSlot),
            plannerDstAt = snapshotSlot(ass.dstTab, ass.dstSlot),
        }
        table.insert(plan.ops, op)
        applyOpToState(state, op, getMaxStack)
    end

    -- --------------------------------------------------------------
    -- PHASE 0: Overflow pre-merge
    -- --------------------------------------------------------------
    -- Before Phase 1 builds supplies and Phase 1B routes spills to
    -- overflow, walk each same-item run on each overflow tab and pour
    -- partial stacks together up to the per-item max stack size.
    -- This compacts each overflow tab to its minimum slot count so
    -- pickOverflowSlot has maximum free slots to work with — fixes
    -- the "out of space" cascade where partial stacks consumed slots
    -- that could be merged. Items with unknown maxStack (cold cache)
    -- skip the merge for that item only and fall back to grouping.
    -- Merging is per tab: pours are always srcTab == dstTab, so Phase 0
    -- never moves stock between overflow tabs (no rebalancing).
    for _, ovTab in ipairs(overflowTabsOrdered) do
        local ovStacks = {}
        for s = 1, MAX_SLOTS do
            local slot = state[ovTab] and state[ovTab][s]
            if slot then
                table.insert(ovStacks, {
                    origSlot = s, itemID = slot.itemID, count = slot.count,
                })
            end
        end

        table.sort(ovStacks, overflowStackOrder)

        local runStart = 1
        while runStart <= #ovStacks do
            local runEnd = runStart
            while runEnd < #ovStacks
                  and ovStacks[runEnd + 1].itemID == ovStacks[runStart].itemID do
                runEnd = runEnd + 1
            end

            local maxStack = getMaxStack(ovStacks[runStart].itemID)
            if maxStack and runEnd > runStart then
                local L, R = runStart, runEnd
                while L < R do
                    local left  = ovStacks[L]
                    local right = ovStacks[R]
                    if left.count >= maxStack then
                        L = L + 1
                    elseif right.count == 0 then
                        R = R - 1
                    else
                        local pour = math.min(maxStack - left.count,
                                              right.count)
                        emitAssignment({
                            srcTab = ovTab, srcSlot = right.origSlot,
                            dstTab = ovTab, dstSlot = left.origSlot,
                            itemID = left.itemID, count = pour,
                        })
                        left.count  = left.count  + pour
                        right.count = right.count - pour
                        diag.phase0Merges = diag.phase0Merges + 1
                        if right.count == 0 then
                            diag.phase0SlotsFreed = diag.phase0SlotsFreed + 1
                        end
                    end
                end
            end

            runStart = runEnd + 1
        end
    end

    -- --------------------------------------------------------------
    -- PHASE 1: Assignment
    -- --------------------------------------------------------------

    -- Demands: items[id].slots is the authoritative count. slotOrder pins
    -- specific positions (one entry = one slot). When a user edits Slots
    -- up via the Layout UI, slotOrder may fall behind; the second pass
    -- below fills the gap by emitting demands at the first unclaimed slot
    -- indices so items[id].slots is always honored.
    local demands = {}
    local demandOfSlot = {}  -- demandOfSlot[t][s] -> demand | nil
    for _, entry in ipairs(displayTabs) do
        local tabIndex = entry.tabIndex
        local items = entry.tab.items or {}
        local slotOrder = entry.tab.slotOrder or {}
        demandOfSlot[tabIndex] = demandOfSlot[tabIndex] or {}

        -- Pass 1: emit demands from slotOrder positions, capped per item at
        -- items[id].slots (ignore surplus slotOrder entries if the user
        -- reduced Slots below the captured count). These are the "pinned"
        -- demands — placement comes from an explicit user action (Capture).
        local emitted = {}
        for slotIndex = 1, MAX_SLOTS do
            local itemID = slotOrder[slotIndex]
            local row = itemID and items[itemID] or nil
            if row and (emitted[itemID] or 0) < row.slots then
                local dem = {
                    tabIndex = tabIndex, slotIndex = slotIndex,
                    itemID = itemID, perSlot = row.perSlot, filled = 0,
                    origin = "pinned",
                }
                table.insert(demands, dem)
                demandOfSlot[tabIndex][slotIndex] = dem
                emitted[itemID] = (emitted[itemID] or 0) + 1
                diag.demandPinned = diag.demandPinned + 1
            end
        end

        -- Pass 2: for any items[id].slots that exceeds emitted count (user
        -- increased Slots via the UI but slotOrder wasn't extended), add
        -- extra demands preferring slots adjacent to existing same-item
        -- demands. This keeps each item's claim contiguous so the planned
        -- layout looks neat (no Health demand landing in the middle of a
        -- Power section just because that gap happened to come first).
        -- Deterministic iteration over sorted itemIDs so positions are
        -- stable across runs.
        local usedSlots = {}
        for s = 1, MAX_SLOTS do
            if demandOfSlot[tabIndex][s] then usedSlots[s] = true end
        end
        -- claimedByItem[item][s] = true when s is a demand position for item.
        -- We mutate this as we extend so each iteration sees prior additions.
        local claimedByItem = {}
        for s = 1, MAX_SLOTS do
            local d = demandOfSlot[tabIndex][s]
            if d then
                claimedByItem[d.itemID] = claimedByItem[d.itemID] or {}
                claimedByItem[d.itemID][s] = true
            end
        end
        local sortedIDs = {}
        for id in pairs(items) do table.insert(sortedIDs, id) end
        table.sort(sortedIDs)

        local function addDemandAt(s, itemID, row, origin)
            local dem = {
                tabIndex = tabIndex, slotIndex = s,
                itemID = itemID, perSlot = row.perSlot, filled = 0,
                origin = origin,
            }
            table.insert(demands, dem)
            demandOfSlot[tabIndex][s] = dem
            usedSlots[s] = true
            claimedByItem[itemID] = claimedByItem[itemID] or {}
            claimedByItem[itemID][s] = true
            emitted[itemID] = (emitted[itemID] or 0) + 1
            if origin == "extend-right" then
                diag.demandExtendRight = diag.demandExtendRight + 1
            elseif origin == "extend-left" then
                diag.demandExtendLeft = diag.demandExtendLeft + 1
            elseif origin == "first-empty" then
                diag.demandFirstEmpty = diag.demandFirstEmpty + 1
            end
        end

        for _, itemID in ipairs(sortedIDs) do
            local row = items[itemID]
            if type(row) == "table" and type(row.slots) == "number" then
                local need = row.slots - (emitted[itemID] or 0)
                if need > 0 then
                    local myClaims = claimedByItem[itemID] or {}
                    local hi, lo = 0, MAX_SLOTS + 1
                    for s = 1, MAX_SLOTS do
                        if myClaims[s] then
                            if s > hi then hi = s end
                            if s < lo then lo = s end
                        end
                    end

                    -- Phase 2a — extend the item's contiguous group RIGHT
                    -- first, then LEFT. Extending in one direction at a
                    -- time keeps each item's span clean: a group starting
                    -- at 50-74 grows to 50-98 before it ever dips below 50,
                    -- leaving slots 1-49 available for the item whose
                    -- group starts there.
                    while need > 0 and hi >= 1 and hi < MAX_SLOTS
                          and not usedSlots[hi + 1] do
                        addDemandAt(hi + 1, itemID, row, "extend-right")
                        need = need - 1
                        hi = hi + 1
                    end
                    while need > 0 and lo <= MAX_SLOTS and lo > 1
                          and not usedSlots[lo - 1] do
                        addDemandAt(lo - 1, itemID, row, "extend-left")
                        need = need - 1
                        lo = lo - 1
                    end

                    -- Phase 2b — fall back to any unclaimed slot (used
                    -- when the item has no existing claim to extend from,
                    -- or both ends are blocked). Each add re-checks
                    -- adjacency to existing claims, so an items-only
                    -- layout (slotOrder empty, all demands fall through
                    -- here) surfaces as one "first-empty" seed per item
                    -- followed by "extend-right"/"extend-left" rather
                    -- than every demand collapsing to "first-empty".
                    if need > 0 then
                        for s = 1, MAX_SLOTS do
                            if need <= 0 then break end
                            if not usedSlots[s] then
                                local mine = claimedByItem[itemID]
                                local origin
                                if mine and mine[s - 1] then
                                    origin = "extend-right"
                                elseif mine and mine[s + 1] then
                                    origin = "extend-left"
                                else
                                    origin = "first-empty"
                                end
                                addDemandAt(s, itemID, row, origin)
                                need = need - 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Supplies: iterate tabs in deterministic order.
    local tabOrder = {}
    for _, entry in ipairs(displayTabs) do
        table.insert(tabOrder, entry.tabIndex)
    end
    for _, ovTab in ipairs(overflowTabsOrdered) do
        table.insert(tabOrder, ovTab)
    end
    table.sort(tabOrder)

    -- Read supplies from POST-Phase-0 state (not bank): if Phase 0
    -- merged overflow partials, the source slots no longer exist as
    -- supply. bank stays as the original snapshot for unrelated reads.
    local supplies = {}
    for _, tabIndex in ipairs(tabOrder) do
        local tab = state[tabIndex]
        if tab then
            for slotIndex = 1, MAX_SLOTS do
                local slot = tab[slotIndex]
                if slot then
                    table.insert(supplies, {
                        tabIndex = tabIndex, slotIndex = slotIndex,
                        itemID = slot.itemID, count = slot.count,
                        available = slot.count,
                        isOverflow = overflowSet[tabIndex] or false,
                        isKeep = false,
                    })
                end
            end
        end
    end

    -- Bag supplies (#139) are appended AFTER the tabOrder walk rather than
    -- joining tabOrder, for two reasons. tabOrder is numerically sorted, so
    -- a negative key would sort to the front and put bags ahead of every
    -- bank tab in Phase 1B, which is backwards: bank leftovers should claim
    -- overflow before a deposit does. And keeping the sort key positive
    -- leaves the existing ordering contract untouched.
    for _, bagTab in ipairs(bagTabs) do
        local tab = state[bagTab]
        if tab then
            for slotIndex = 1, MAX_SLOTS do
                local slot = tab[slotIndex]
                if slot then
                    table.insert(supplies, {
                        tabIndex = bagTab, slotIndex = slotIndex,
                        itemID = slot.itemID, count = slot.count,
                        available = slot.count,
                        isOverflow = false,
                        isBag = true,
                        isKeep = false,
                    })
                end
            end
        end
    end

    -- Keep-slot identification: reserve perSlot against the matching demand.
    -- An oversize keep-slot retains identity but exposes its excess as
    -- `available` supply for other demands of the same item.
    for _, sup in ipairs(supplies) do
        local dem = demandOfSlot[sup.tabIndex] and demandOfSlot[sup.tabIndex][sup.slotIndex]
        if dem and dem.itemID == sup.itemID then
            local reserve = math.min(sup.count, dem.perSlot)
            dem.filled = reserve
            sup.available = sup.count - reserve
            sup.isKeep = true
        end
    end

    -- Phase 1A — fill demands from the best source.
    local function findBestSource(dem)
        -- bestP starts one past the lowest tier so every tier is reached
        -- through the `p < bestP` branch. It sits above tier 4 rather than
        -- on it: a first candidate is admitted either way, because
        -- bestAvail's -1 sentinel loses to any positive `available`, but
        -- an init equal to the lowest tier reads as if bags were the
        -- sentinel and breaks the moment a tier 5 is added.
        local best, bestP, bestAvail, bestTab, bestSlot = nil, 5, -1, math.huge, math.huge
        for _, sup in ipairs(supplies) do
            if sup.itemID == dem.itemID and sup.available > 0
               and not (sup.tabIndex == dem.tabIndex and sup.slotIndex == dem.slotIndex) then
                -- Tier order is the cost of the move. Bags are last (#139):
                -- shuffling stock already inside the bank is free, while
                -- pulling from a bag spends a deposit, so bank stock always
                -- wins even when a bag holds far more of the item. Without
                -- this tier a bag lands at 3 and beats a bank tab twice
                -- over, on `available` and again on the negative tabIndex.
                local p
                if sup.isBag then p = 4
                elseif sup.tabIndex == dem.tabIndex then p = 1
                elseif sup.isOverflow then p = 2
                else p = 3 end
                -- Tiebreak position. A bag's pseudo-tab is negative, so a
                -- raw compare ranks the reagent bag ahead of the backpack
                -- and disagrees with the spill walk below, which takes bags
                -- in bagID order. Mapping bags onto an ascending key makes
                -- both paths agree that bag 0 goes first. Bags are the only
                -- tier-4 supplies, so they never tiebreak against a bank
                -- tab and this cannot reorder bank sources.
                local supPos = sup.isBag and -sup.tabIndex or sup.tabIndex
                local pick = false
                if p < bestP then
                    pick = true
                elseif p == bestP then
                    if sup.available > bestAvail then
                        pick = true
                    elseif sup.available == bestAvail then
                        if supPos < bestTab
                           or (supPos == bestTab and sup.slotIndex < bestSlot) then
                            pick = true
                        end
                    end
                end
                if pick then
                    best, bestP, bestAvail = sup, p, sup.available
                    bestTab, bestSlot = supPos, sup.slotIndex
                end
            end
        end
        return best
    end

    local assignments = {}
    for _, dem in ipairs(demands) do
        while dem.filled < dem.perSlot do
            local sup = findBestSource(dem)
            if not sup then
                plan.deficits[dem.itemID] = (plan.deficits[dem.itemID] or 0)
                    + (dem.perSlot - dem.filled)
                dem.filled = dem.perSlot  -- sentinel to exit loop
                break
            end
            local take = math.min(dem.perSlot - dem.filled, sup.available)
            table.insert(assignments, {
                srcTab = sup.tabIndex, srcSlot = sup.slotIndex,
                dstTab = dem.tabIndex, dstSlot = dem.slotIndex,
                itemID = dem.itemID, count = take,
            })
            sup.available = sup.available - take
            dem.filled = dem.filled + take
            diag.phase1aAssignments = diag.phase1aAssignments + 1
            if sup.isBag then
                diag.bagDemandFills = diag.bagDemandFills + 1
            end
        end
    end

    -- Phase 1B — route leftover non-overflow supply to overflow.
    --
    -- Capacity-aware virtual overflow: starts from POST-Phase-0 state
    -- and tracks {itemID, count, capacity} per overflow tab per slot.
    -- Within one tab the preference is (1) top up an existing same-item
    -- partial with remaining capacity, then (2) right-extend,
    -- (3) left-extend, (4) first-empty. The supply loop iterates while
    -- sup.available > 0 so a single supply can split across a
    -- partial-target plus a fresh slot (possibly in the next overflow
    -- tab) when one destination doesn't fully absorb it.
    --
    -- A whole stack skips tier 1 while more whole stacks of its item are
    -- still to come (#146). Topping up from a whole stack splits it and
    -- leaves a remainder that is itself a partial, so the next whole
    -- stack split into that, and so on: two ops per stack, one odd
    -- remainder walking through every stack of the item. The last whole
    -- stack still tops up, which lands the remainder at the tail of the
    -- run in one split and leaves Phase 4 nothing to reorder. A deferred
    -- stack that no tab can take whole tops up after all: with nothing
    -- free its remainder cannot open a new partial, so that cannot
    -- restart the cascade, and skipping it would strand the room a
    -- second tab's partial still has (Phase 0 merges within a tab, so
    -- two tabs can each hold one) or spend a deposit on a top-up a bank
    -- stack should have made. And within one source (the bank tabs as
    -- one source, then each bag) whole stacks are
    -- walked before partials, so an odd stack sitting ahead of whole
    -- stacks in slot order lands after them instead of opening the run
    -- they then have to split around.
    --
    -- capacity = max(0, maxStack - count) when maxStack is known;
    -- 0 (treated as full, can't top up) when maxStack is unknown
    -- (cold cache). This is the conservative fallback — a future
    -- sort after the item info loads will route through the top-up
    -- branch instead of always extending.
    local overflowSlotInfo = {}
    local function rebuildOverflowSlotInfo()
        for _, ovTab in ipairs(overflowTabsOrdered) do
            local tabInfo = {}
            for s = 1, MAX_SLOTS do
                local slot = state[ovTab] and state[ovTab][s]
                if slot then
                    local m = getMaxStack(slot.itemID)
                    tabInfo[s] = {
                        itemID = slot.itemID,
                        count = slot.count,
                        capacity = m and math.max(0, m - slot.count) or 0,
                    }
                end
            end
            overflowSlotInfo[ovTab] = tabInfo
        end
    end
    rebuildOverflowSlotInfo()

    -- The four-tier preference within ONE overflow tab. deferTopup skips
    -- tier 1 (see the #146 note above): the caller passes it for a whole
    -- stack that is not the last of its item.
    local function pickOverflowSlotInTab(ovTab, itemID, want, deferTopup)
        local info = overflowSlotInfo[ovTab]
        -- 1. Top up an existing same-item partial with capacity.
        if not deferTopup then
            for s = 1, MAX_SLOTS do
                local slot = info[s]
                if slot and slot.itemID == itemID and slot.capacity > 0 then
                    return s, math.min(want, slot.capacity), "topup"
                end
            end
        end
        -- 2. Right-extend an existing same-item group.
        for s = 2, MAX_SLOTS do
            local prev = info[s - 1]
            if not info[s] and prev and prev.itemID == itemID then
                return s, want, "extend-right"
            end
        end
        -- 3. Left-extend if no right-extension is possible.
        for s = MAX_SLOTS - 1, 1, -1 do
            local nextInfo = info[s + 1]
            if not info[s] and nextInfo and nextInfo.itemID == itemID then
                return s, want, "extend-left"
            end
        end
        -- 4. First empty slot (new item in this tab).
        for s = 1, MAX_SLOTS do
            if not info[s] then
                return s, want, "first-empty"
            end
        end
        return nil
    end

    -- Tab-major walk in routing order: all four tiers in one tab before
    -- any tier in the next. Deliberate (#57): priority means "fill this
    -- tab first", so a first-empty in tab A beats topping up a same-item
    -- partial sitting in tab B, even though that can leave a partial in
    -- each of two tabs. Do not "fix" this into a cross-tab topup-first
    -- scan; the tab order is the contract the layout editor shows.
    local function pickOverflowSlot(itemID, want, deferTopup)
        for _, ovTab in ipairs(overflowTabsOrdered) do
            local s, take, mode = pickOverflowSlotInTab(ovTab, itemID, want, deferTopup)
            if s then return ovTab, s, take, mode end
        end
        return nil
    end

    -- Mirror a placement into overflowSlotInfo so the next pick sees
    -- the new capacity. Required for split-across-multiple-destinations;
    -- shared by Phase 1B and the Phase 3 sweep.
    local function notePlacement(ovTab, ovSlot, itemID, take)
        local info = overflowSlotInfo[ovTab][ovSlot]
        if info then
            info.count    = info.count + take
            info.capacity = math.max(0, info.capacity - take)
        else
            local m = getMaxStack(itemID)
            overflowSlotInfo[ovTab][ovSlot] = {
                itemID = itemID, count = take,
                capacity = m and math.max(0, m - take) or 0,
            }
        end
    end

    local unplacedSlots = {}  -- unplacedSlots[t][s] = true
    local function recordUnplaced(tabIndex, slotIndex, itemID, count, reason)
        table.insert(plan.unplaced, {
            tabIndex = tabIndex, slotIndex = slotIndex,
            itemID = itemID, count = count, reason = reason,
        })
        unplacedSlots[tabIndex] = unplacedSlots[tabIndex] or {}
        unplacedSlots[tabIndex][slotIndex] = true
    end

    -- How many whole stacks of each item are about to spill (#146). A
    -- whole stack defers its top-up while this count says another whole
    -- stack of the item is still behind it in the walk. Unknown maxStack
    -- means nothing counts as whole, which is also the state in which
    -- tier 1 cannot fire (every capacity reads 0).
    local function isWholeStack(sup)
        local m = getMaxStack(sup.itemID)
        return type(m) == "number" and sup.available >= m
    end
    local wholesLeft, wholeAt = {}, {}
    for i, sup in ipairs(supplies) do
        if sup.available > 0 and not sup.isOverflow and isWholeStack(sup) then
            wholeAt[i] = true
            wholesLeft[sup.itemID] = (wholesLeft[sup.itemID] or 0) + 1
        end
    end

    -- Walk order (#146). Sources keep the order the supply list gave
    -- them: bank tabs first, then bags by bagID, which is the contract
    -- the supply builder above explains. Within one source, whole stacks
    -- go before partials, so a partial never opens a run that the whole
    -- stacks behind it would then have to split around. The supply index
    -- is the final key, which keeps the sort total and the walk
    -- deterministic.
    local function spillGroup(sup)
        return sup.isBag and -sup.tabIndex or 0
    end
    local spillOrder = {}
    for i, sup in ipairs(supplies) do
        if sup.available > 0 and not sup.isOverflow then
            spillOrder[#spillOrder + 1] = i
        end
    end
    table.sort(spillOrder, function(a, b)
        local sa, sb = supplies[a], supplies[b]
        local ga, gb = spillGroup(sa), spillGroup(sb)
        if ga ~= gb then return ga < gb end
        local wa, wb = wholeAt[a] or false, wholeAt[b] or false
        if wa ~= wb then return wa end
        return a < b
    end)

    for _, supIndex in ipairs(spillOrder) do
        local sup = supplies[supIndex]
        local deferTopup = false
        if wholeAt[supIndex] then
            wholesLeft[sup.itemID] = wholesLeft[sup.itemID] - 1
            deferTopup = wholesLeft[sup.itemID] > 0
        end
        if #overflowTabsOrdered == 0 then
            recordUnplaced(sup.tabIndex, sup.slotIndex, sup.itemID,
                sup.available, noOverflowReason)
            diag.phase1bUnplaced = diag.phase1bUnplaced + 1
        else
            while sup.available > 0 do
                local ovTab, ovSlot, take, mode =
                    pickOverflowSlot(sup.itemID, sup.available, deferTopup)
                if not ovTab and deferTopup then
                    -- No tab can take this stack whole. Topping up is the
                    -- only room left, and with nothing free the remainder
                    -- cannot open a new partial, so the cascade cannot
                    -- restart from here (#146).
                    deferTopup = false
                    ovTab, ovSlot, take, mode =
                        pickOverflowSlot(sup.itemID, sup.available, false)
                end
                if not ovTab or not take or take <= 0 then
                    recordUnplaced(sup.tabIndex, sup.slotIndex, sup.itemID,
                        sup.available, REASON_OVERFLOW_FULL)
                    diag.phase1bUnplaced = diag.phase1bUnplaced + 1
                    sup.available = 0
                    break
                end
                if mode == "topup" then
                    diag.phase1bTopup = diag.phase1bTopup + 1
                elseif mode == "extend-right" then
                    diag.phase1bExtendRight = diag.phase1bExtendRight + 1
                elseif mode == "extend-left" then
                    diag.phase1bExtendLeft = diag.phase1bExtendLeft + 1
                elseif mode == "first-empty" then
                    diag.phase1bFirstEmpty = diag.phase1bFirstEmpty + 1
                end
                table.insert(assignments, {
                    srcTab = sup.tabIndex, srcSlot = sup.slotIndex,
                    dstTab = ovTab, dstSlot = ovSlot,
                    itemID = sup.itemID, count = take,
                })
                if sup.isBag then
                    diag.bagSpills = diag.bagSpills + 1
                end
                notePlacement(ovTab, ovSlot, sup.itemID, take)
                sup.available = sup.available - take
            end
        end
    end

    -- --------------------------------------------------------------
    -- PHASE 2: Schedule
    -- --------------------------------------------------------------

    local remaining = {}
    for i = 1, #assignments do remaining[i] = true end

    local function greedyDrain()
        local progressed
        repeat
            progressed = false
            for i = 1, #assignments do
                if remaining[i] then
                    local ass = assignments[i]
                    -- v0.32.8 B4a: capture canExecute's reason on refusal
                    -- so a cycle-blocked op's blocking predicate is named
                    -- in the debug audit trail.
                    local ok, reason = canExecute(ass, state, getMaxStack)
                    if ok then
                        emitAssignment(ass)
                        remaining[i] = nil
                        progressed = true
                    else
                        phase2Debug(string.format(
                            "sort plan Phase 2: refused emit %s->%s "
                            .. "(item %d x%d): %s",
                            slotRef(self, ass.srcTab, ass.srcSlot),
                            slotRef(self, ass.dstTab, ass.dstSlot),
                            ass.itemID or 0, ass.count or 0, reason or "unknown"))
                    end
                end
            end
        until not progressed
    end

    -- Pivot-break loop for any remaining cycle-blocked assignments.
    local function findPivot(blockedDstTab)
        -- Priority 1: same-tab empty, unclaimed by any demand.
        for s = 1, MAX_SLOTS do
            local claimed = demandOfSlot[blockedDstTab]
                and demandOfSlot[blockedDstTab][s]
            if not claimed then
                local slot = state[blockedDstTab] and state[blockedDstTab][s]
                if not slot then
                    return blockedDstTab, s
                end
            end
        end
        -- Priority 2: empty overflow slot not reserved by a pending op,
        -- searching the overflow tabs in routing order.
        for _, ovTab in ipairs(overflowTabsOrdered) do
            for s = 1, MAX_SLOTS do
                local slot = state[ovTab] and state[ovTab][s]
                if not slot then
                    local reserved = false
                    for i = 1, #assignments do
                        if remaining[i] then
                            local a = assignments[i]
                            if a.dstTab == ovTab and a.dstSlot == s then
                                reserved = true
                                break
                            end
                        end
                    end
                    if not reserved then
                        return ovTab, s
                    end
                end
            end
        end
        return nil, nil
    end

    local function pivotBreakLoop()
        local budget = (opts and opts.pivotBudget) or PIVOT_BUDGET
        local guard = 0
        while next(remaining) ~= nil and guard < budget do
            guard = guard + 1

            -- Find the first remaining op a pivot could unblock. A foreign
            -- item in the destination is the classic case. A same-item
            -- destination that would over-stack is the other one, and only
            -- for a Phase 4 packing assignment (#147): there it means two
            -- stacks of one item have to exchange positions, which a pivot
            -- resolves in three ops. The same refusal on a demand fill means
            -- the layout asks for more of the item than one slot holds, and
            -- pivoting there would empty the demand slot, fill it, and plan
            -- the identical pair of moves again on the next pass, so those
            -- stay a zero-op residual.
            local stuckIdx
            for i = 1, #assignments do
                if remaining[i] then
                    local a = assignments[i]
                    local dstCur = state[a.dstTab] and state[a.dstTab][a.dstSlot]
                    if dstCur then
                        if dstCur.itemID ~= a.itemID then
                            stuckIdx = i
                            break
                        elseif a.pack then
                            -- Cheap test first: getMaxStack is unmemoized
                            -- and reaches the item cache (#147).
                            local _, reason = canExecute(a, state, getMaxStack)
                            if reason == "max-stack-overflow" then
                                stuckIdx = i
                                break
                            end
                        end
                    end
                end
            end

            if not stuckIdx then
                -- No op is dst-blocked but some remain — should only happen if
                -- a src drifted (shouldn't in pure-planner mode). Bail safely.
                -- v0.32.8 B4a: log the abort cause so a planner-state-desync
                -- shows up in the debug trace.
                local remainingCount = 0
                for i = 1, #assignments do
                    if remaining[i] then remainingCount = remainingCount + 1 end
                end
                phase2Debug(string.format(
                    "sort plan Phase 2: no-stuck abort with %d remaining "
                    .. "(unexpected src drift)", remainingCount))
                diag.phase2CycleAborts = diag.phase2CycleAborts + 1
                for i = 1, #assignments do
                    if remaining[i] then
                        local a = assignments[i]
                        recordUnplaced(a.srcTab, a.srcSlot, a.itemID, a.count,
                            REASON_CYCLE_NO_PIVOT)
                        remaining[i] = nil
                        diag.phase2StrandedAssignments =
                            diag.phase2StrandedAssignments + 1
                    end
                end
                break
            end

            local stuck = assignments[stuckIdx]
            -- v0.32.8 B4a: cycle detected. Record the stuck op (the one
            -- whose dst is occupied by a foreign item) so a chain like
            -- T6/S6 → S5 → S4 → … shows up in the debug trace. The full
            -- chain isn't enumerated here because the planner doesn't
            -- track the chain structure explicitly; what it sees is one
            -- blocked assignment at a time. The accompanying pivot or
            -- no-pivot log lines below cover what happened.
            local stuckBlocker = state[stuck.dstTab][stuck.dstSlot]
            phase2Debug(string.format(
                "sort plan Phase 2: cycle blocked at T%d/S%d "
                .. "(wants item %d x%d; blocked by item %d x%d)",
                stuck.dstTab, stuck.dstSlot, stuck.itemID or 0,
                stuck.count or 0,
                stuckBlocker and stuckBlocker.itemID or 0,
                stuckBlocker and stuckBlocker.count or 0))

            local pivotTab, pivotSlot = findPivot(stuck.dstTab)
            if not pivotTab then
                -- v0.32.8 B4a: no-pivot abort — Phase 2 gave up.
                local remainingCount = 0
                for i = 1, #assignments do
                    if remaining[i] then remainingCount = remainingCount + 1 end
                end
                phase2Debug(string.format(
                    "sort plan Phase 2: no-pivot abort for cycle at T%d/S%d "
                    .. "(%d remaining ops unplaced)",
                    stuck.dstTab, stuck.dstSlot, remainingCount))
                diag.phase2CycleAborts = diag.phase2CycleAborts + 1
                for i = 1, #assignments do
                    if remaining[i] then
                        local a = assignments[i]
                        recordUnplaced(a.srcTab, a.srcSlot, a.itemID, a.count,
                            REASON_CYCLE_NO_PIVOT)
                        remaining[i] = nil
                        diag.phase2StrandedAssignments =
                            diag.phase2StrandedAssignments + 1
                    end
                end
                break
            end

            local blockerSlot = state[stuck.dstTab][stuck.dstSlot]
            local pivotOp = {
                srcTab = stuck.dstTab, srcSlot = stuck.dstSlot,
                dstTab = pivotTab, dstSlot = pivotSlot,
                itemID = blockerSlot.itemID, count = blockerSlot.count,
                plannerSrcAt = snapshotSlot(stuck.dstTab, stuck.dstSlot),
                plannerDstAt = snapshotSlot(pivotTab, pivotSlot),
            }
            -- Provably "move": count IS blockerSlot.count, so opLabel's
            -- `src.count > ass.count` is false. Routed through it anyway so
            -- opLabel is the single writer of the field (#161).
            pivotOp.op = opLabel(state, pivotOp)
            table.insert(plan.ops, pivotOp)
            applyOpToState(state, pivotOp, getMaxStack)
            diag.phase2Pivots = diag.phase2Pivots + 1
            -- v0.32.8 B4a: pivot chosen — log the destination slot.
            phase2Debug(string.format(
                "sort plan Phase 2: pivot T%d/S%d chosen for blocker at "
                .. "T%d/S%d (item %d x%d)",
                pivotTab, pivotSlot, stuck.dstTab, stuck.dstSlot,
                blockerSlot.itemID or 0, blockerSlot.count or 0))

            -- Redirect any still-remaining assignment whose src was the pivot's
            -- original source slot — the item now lives at the pivot.
            for j = 1, #assignments do
                if remaining[j] then
                    local other = assignments[j]
                    if other.srcTab == stuck.dstTab and other.srcSlot == stuck.dstSlot then
                        other.srcTab = pivotTab
                        other.srcSlot = pivotSlot
                    end
                end
            end

            greedyDrain()
        end

        -- The budget ran out with assignments still pending (#138). Both
        -- designed aborts above clear `remaining` as they record, and this
        -- exit used to do neither, so those assignments vanished from the
        -- plan's accounting: the abort count undercounted, and because
        -- their source slots were never flagged, Phase 3 swept the very
        -- stacks the plan had given up on into overflow. Record them with
        -- their own reason so a capture can tell an exhausted budget from a
        -- genuine no-pivot, and clear them so Phase 4's run of this loop
        -- does not re-abort assignments whose sources have since drained.
        if next(remaining) ~= nil then
            local remainingCount = 0
            for i = 1, #assignments do
                if remaining[i] then remainingCount = remainingCount + 1 end
            end
            phase2Debug(string.format(
                "sort plan Phase 2: pivot budget exhausted with %d remaining",
                remainingCount))
            diag.phase2CycleAborts = diag.phase2CycleAborts + 1
            for i = 1, #assignments do
                if remaining[i] then
                    local a = assignments[i]
                    recordUnplaced(a.srcTab, a.srcSlot, a.itemID, a.count,
                        REASON_CYCLE_BUDGET)
                    remaining[i] = nil
                    diag.phase2StrandedAssignments =
                        diag.phase2StrandedAssignments + 1
                end
            end
        end
    end

    greedyDrain()
    pivotBreakLoop()

    -- Reconcile the virtual overflow with reality before the sweep.
    -- Phase 2 can move items into overflow slots that notePlacement never
    -- saw (a pivot parking a cycle blocker), and an aborted cycle can
    -- leave such a slot occupied for good; conversely an aborted Phase 1B
    -- assignment leaves its target genuinely free. state is ground truth
    -- once the drain finishes, so rebuild rather than patch.
    rebuildOverflowSlotInfo()

    -- --------------------------------------------------------------
    -- PHASE 3: Sweep (defensive)
    -- --------------------------------------------------------------
    -- Same multi-destination loop pattern as Phase 1B: a stragglers
    -- stack may need to split across a topup and a fresh slot.
    for _, entry in ipairs(displayTabs) do
        local tabIndex = entry.tabIndex
        for slotIndex = 1, MAX_SLOTS do
            local slot = state[tabIndex] and state[tabIndex][slotIndex]
            local isUnplaced = unplacedSlots[tabIndex]
                and unplacedSlots[tabIndex][slotIndex]
            if slot and not isUnplaced then
                -- A slot "fits" if it matches a demand for this tab+slot —
                -- using demandOfSlot (which includes both slotOrder-pinned
                -- and items.slots-extended demands) rather than raw slotOrder.
                local dem = demandOfSlot[tabIndex]
                    and demandOfSlot[tabIndex][slotIndex]
                local fits = (dem and dem.itemID == slot.itemID)
                if not fits then
                    if #overflowTabsOrdered == 0 then
                        recordUnplaced(tabIndex, slotIndex, slot.itemID, slot.count,
                            noOverflowReason)
                    else
                        local remaining_ = slot.count
                        while remaining_ > 0 do
                            -- No deferral here (#146): a straggler only
                            -- exists after a Phase 2 abort, and two whole
                            -- stragglers of one item cascading would be
                            -- that abort's symptom, not a routing choice.
                            local ovTab, ovSlot, take =
                                pickOverflowSlot(slot.itemID, remaining_)
                            if not ovTab or not take or take <= 0 then
                                recordUnplaced(tabIndex, slotIndex, slot.itemID,
                                    remaining_, REASON_OVERFLOW_FULL)
                                break
                            end
                            local sweepOp = {
                                srcTab = tabIndex, srcSlot = slotIndex,
                                dstTab = ovTab, dstSlot = ovSlot,
                                itemID = slot.itemID, count = take,
                                plannerSrcAt = snapshotSlot(tabIndex, slotIndex),
                                plannerDstAt = snapshotSlot(ovTab, ovSlot),
                            }
                            -- pickOverflowSlot tier 1 caps take at the
                            -- destination partial's capacity, so this op can
                            -- leave part of the stack behind and is then a
                            -- split. Hardcoding "move" here made the preview
                            -- and the sort log describe it wrongly (#161).
                            sweepOp.op = opLabel(state, sweepOp)
                            table.insert(plan.ops, sweepOp)
                            applyOpToState(state, sweepOp, getMaxStack)
                            diag.phase3Sweeps = diag.phase3Sweeps + 1
                            notePlacement(ovTab, ovSlot, slot.itemID, take)
                            remaining_ = remaining_ - take
                        end
                    end
                end
            end
        end
    end

    -- --------------------------------------------------------------
    -- PHASE 4: Overflow Position Compaction
    -- --------------------------------------------------------------
    -- Pack each overflow tab's stacks into a contiguous run from slot 1,
    -- sorted by (itemID ASC, count DESC, origSlot ASC). Phase 0 has
    -- already merged same-item partials within each tab, and Phase 1B has
    -- topped up existing partials before extending, so by the time this
    -- phase runs the only work left is positional: shifting stacks into a
    -- deterministic per-tab packing. Packing never moves a stack between
    -- overflow tabs; a pivot may park a blocker in another tab
    -- transiently, but every destination is within the stack's own tab,
    -- so per-tab idempotence composes. Reuses the Phase-2 greedy drain
    -- and pivot-break loop by appending new assignments to
    -- `assignments` / `remaining` and re-running both once for all tabs.
    local phase4Added = false
    for _, ovTab in ipairs(overflowTabsOrdered) do
        -- A stranded slot (one of Phase 2's aborts gave up on an assignment
        -- reading from it, so it is already reported unplaced) is left out
        -- of the packing entirely: out of ovStacks here, and out of the
        -- target list below, so nothing is aimed at it either. Moving a
        -- stack the plan has already told the player it could not place
        -- would contradict the report and, at the tab's own abort, could
        -- name the same slot twice.
        local ovStacks = {}
        for s = 1, MAX_SLOTS do
            local slot = state[ovTab] and state[ovTab][s]
            local isUnplaced = unplacedSlots[ovTab]
                and unplacedSlots[ovTab][s]
            if slot and not isUnplaced then
                table.insert(ovStacks, {
                    origSlot = s, itemID = slot.itemID, count = slot.count,
                })
            end
        end

        table.sort(ovStacks, overflowStackOrder)

        -- Where each rank lands. A slot Phase 2 gave up on is excluded from
        -- ovStacks above but stays occupied, so packing rank i to slot i
        -- would aim some other stack at it and pivot the abandoned stack
        -- away, which is the one thing the skip exists to prevent (#143).
        -- The target list is the leading slots that are NOT stranded, so
        -- the run closes around such a slot instead of through it. With
        -- nothing stranded targets[i] == i and this is the old behaviour.
        local targets = {}
        for s = 1, MAX_SLOTS do
            if #targets >= #ovStacks then break end
            local isUnplaced = unplacedSlots[ovTab]
                and unplacedSlots[ovTab][s]
            if not isUnplaced then
                targets[#targets + 1] = s
            end
        end

        -- Within a run of indistinguishable stacks (same itemID AND same
        -- count) it does not matter which stack lands in which slot: the
        -- resulting tab is identical either way, so any move between two of
        -- them is work with no observable result. The comparator ranks them
        -- by origSlot, which makes the target depend on where they are now,
        -- and executing a plan rewrites exactly that. A pass that ends early
        -- therefore re-aims the rest of the plan instead of shortening it,
        -- the next plan comes back larger than the work that was left, and
        -- the executor's non-decreasing rule stops the sort with a residual
        -- (#140: 28 ops issued, 124-op replan, on a bank whose overflow tab
        -- held dozens of identical full stacks).
        --
        -- So assign each run to minimise movement: a stack already sitting
        -- inside the run's slot range stays where it is, and only the rest
        -- fill the gaps. The packing contract is unchanged, because the
        -- contract is about which item and count occupies each slot.
        local runStart = 1
        while runStart <= #ovStacks do
            local runEnd = runStart
            while runEnd < #ovStacks
                and ovStacks[runEnd + 1].itemID == ovStacks[runStart].itemID
                and ovStacks[runEnd + 1].count == ovStacks[runStart].count do
                runEnd = runEnd + 1
            end
            if runEnd > runStart then
                local group = {}
                for k = runStart, runEnd do
                    group[#group + 1] = ovStacks[k]
                end
                -- The comparison is against the SLOTS this run will occupy,
                -- not against its rank indices. Those were the same thing
                -- until a stranded slot could push the targets apart (#143),
                -- and reading the indices then calls a stack that is already
                -- in place a mover and scrambles the run. origSlot is unique
                -- per stack, so the stayPut map can never collide.
                local firstSlot, lastSlot = targets[runStart], targets[runEnd]
                local stayPut, movers = {}, {}
                for _, st in ipairs(group) do
                    -- A stranded slot never reaches ovStacks, and targets
                    -- holds every non-stranded slot up to the last one it
                    -- uses, so "inside the range" and "one of this run's
                    -- target slots" are the same test for a group member.
                    if st.origSlot >= firstSlot and st.origSlot <= lastSlot then
                        stayPut[st.origSlot] = st
                    else
                        movers[#movers + 1] = st
                    end
                end
                local mi = 1
                for k = runStart, runEnd do
                    local slotForRank = targets[k]
                    if stayPut[slotForRank] then
                        ovStacks[k] = stayPut[slotForRank]
                    else
                        ovStacks[k] = movers[mi]
                        mi = mi + 1
                    end
                end
            end
            runStart = runEnd + 1
        end

        for i, stack in ipairs(ovStacks) do
            local dstSlot = targets[i]
            if stack.origSlot ~= dstSlot then
                local idx = #assignments + 1
                assignments[idx] = {
                    srcTab = ovTab, srcSlot = stack.origSlot,
                    dstTab = ovTab, dstSlot = dstSlot,
                    itemID = stack.itemID, count = stack.count,
                    -- Marks this as position packing rather than a demand
                    -- fill, which is what lets the pivot loop treat a
                    -- same-item over-stack refusal as stuck (#147).
                    pack = true,
                }
                remaining[idx] = true
                phase4Added = true
                diag.phase4PositionShifts = diag.phase4PositionShifts + 1
            end
        end
    end

    if phase4Added then
        greedyDrain()
        pivotBreakLoop()
    end

    -- Expose the effective demand map for diagnostics / deviation checks.
    -- `origin` is one of "pinned" | "extend-right" | "extend-left" |
    -- "first-empty" so callers can see why each demand is at its slot
    -- (Capture vs adjacency extension vs first-empty fallback).
    for tabIndex, slotMap in pairs(demandOfSlot) do
        plan.demandMap[tabIndex] = {}
        for s, dem in pairs(slotMap) do
            plan.demandMap[tabIndex][s] = {
                itemID = dem.itemID,
                perSlot = dem.perSlot,
                origin = dem.origin,
            }
        end
    end

    -- Admitted bag stacks the plan could not place. plan.unplaced is final
    -- here (Phases 1B, 2 and 3 are the producers). Folded by slot, because
    -- one slot can be recorded several times and the unit a player counts
    -- is the stack in the slot, not the number of takes that failed.
    local stays = bagStays(plan.unplaced)
    diag.bagStay = #stays

    -- Planner diagnostics. The first line is always emitted (baseline
    -- timing + replan hitch investigation). The phase / demand breakdown
    -- lines fire only when there's plan or demand activity, so quiet
    -- replan-no-op cycles don't spam the sort log. SortInfo is provided
    -- by Logger.lua; guard for partial test setups.
    if self.SortInfo then
        local elapsed = profileStart and (debugprofilestop() - profileStart) or 0
        local deficitCount = 0
        for _ in pairs(plan.deficits) do deficitCount = deficitCount + 1 end
        -- Per-tab occupied breakdown (tab-sorted) so a cold tab is visible in
        -- /gbl sortlog without the master log. Comparing a cold pre-execution
        -- plan's breakdown to the warm post-execution plan's breakdown shows
        -- exactly which tab gained the slots a stale snapshot missed.
        local tabKeys = {}
        for tabIndex in pairs(perTabOccupied) do
            table.insert(tabKeys, tabIndex)
        end
        table.sort(tabKeys)
        local breakdownParts = {}
        for _, tabIndex in ipairs(tabKeys) do
            table.insert(breakdownParts,
                string.format("T%d:%d", tabIndex, perTabOccupied[tabIndex]))
        end
        -- The breakdown is built from perTabOccupied, which was filled from
        -- `snapshot` before bags were admitted, so it stays bank-only and no
        -- "T-1:N" can appear here. Bag input is reported as its own term,
        -- present whenever bags were on (even with nothing admitted, so a
        -- capture can tell "on, nothing to deposit" from "off"): admitted
        -- over seen, what the admitted ones did, and why the rest were not
        -- candidates. seen is every occupied slot the scan classified.
        local bagsPart = ""
        if opts and type(opts.bagSnapshot) == "table" then
            local seen = diag.bagSupplies + diag.bagIgnored + diag.bagBound
                + diag.bagLocked + diag.bagNoLink
            -- Two units in one bracket, grouped and named (#165). admitted,
            -- seen and the five terms after it count SLOTS; fillops and
            -- spillops count assignments, so one bag stack split across two
            -- overflow destinations reads as 2. They used to lead the bracket
            -- under the bare names fill= and spill=, where they read as slots
            -- like everything beside them.
            bagsPart = string.format(
                " bags:%d/%d(stay=%d,ignored=%d,bound=%d,locked=%d,nolink=%d"
                .. ",fillops=%d,spillops=%d)",
                diag.bagSupplies, seen,
                diag.bagStay, diag.bagIgnored, diag.bagBound, diag.bagLocked,
                diag.bagNoLink, diag.bagDemandFills, diag.bagSpills)
        end
        -- Coverage term (#137), present whenever coverage was handed in,
        -- including when it hid nothing: "checked, all visible" and "not
        -- checked at all" are different states and a capture needs both.
        local coveragePart = ""
        if haveCoverage then
            local hidden = plan.unviewableOverflowTabs
            if #hidden == 0 then
                coveragePart = " unviewable:none"
            else
                local names = {}
                for i, t in ipairs(hidden) do names[i] = "T" .. t end
                coveragePart = " unviewable:" .. table.concat(names, ",")
            end
        end
        self:SortInfo(string.format(
            "Sort plan: %.1fms, %d ops, %d deficits, %d unplaced "
            .. "(input: %d slots / %d tabs)%s%s [%s]",
            elapsed, #plan.ops, deficitCount, #plan.unplaced,
            inputSlots, inputTabs, bagsPart, coveragePart,
            table.concat(breakdownParts, " ")))

        -- Which admitted bag stacks stay behind, and why. The term above
        -- carries the count; this names them, because "why is this still in
        -- my bags" is answered by the slot and the reason, not by a number.
        -- Bank-origin unplaced entries are not bag stays and are left out.
        if diag.bagStay > 0 then
            local parts = {}
            for _, u in ipairs(stays) do
                if #parts < STAY_LINE_MAX_NAMED then
                    local desc = self.DescribeItem and self:DescribeItem(u.itemID)
                        or ("it:" .. tostring(u.itemID))
                    table.insert(parts, string.format("%s x%d at %s (%s)",
                        desc, u.count or 0, slotRef(self, u.tabIndex, u.slotIndex),
                        tostring(u.reason)))
                end
            end
            local more = diag.bagStay - #parts
            self:SortInfo(string.format("  bags stay: %s%s",
                table.concat(parts, ", "),
                (more > 0) and string.format(", and %d more", more) or ""))
        end

        local totalDemands = diag.demandPinned + diag.demandExtendRight
            + diag.demandExtendLeft + diag.demandFirstEmpty
        if #plan.ops > 0 or totalDemands > 0 then
            self:SortInfo(string.format(
                "  phases: P0 merge=%d(free=%d) P1a assign=%d "
                .. "P1b spill=%d(top=%d,r=%d,l=%d,fe=%d,unp=%d) "
                .. "P2 pivot=%d(abort=%d,stranded=%d) P3 sweep=%d P4 pack=%d",
                diag.phase0Merges, diag.phase0SlotsFreed,
                diag.phase1aAssignments,
                diag.phase1bTopup + diag.phase1bExtendRight
                    + diag.phase1bExtendLeft + diag.phase1bFirstEmpty,
                diag.phase1bTopup, diag.phase1bExtendRight,
                diag.phase1bExtendLeft, diag.phase1bFirstEmpty,
                diag.phase1bUnplaced,
                diag.phase2Pivots, diag.phase2CycleAborts,
                diag.phase2StrandedAssignments,
                diag.phase3Sweeps, diag.phase4PositionShifts))
            self:SortInfo(string.format(
                "  demands: %d total (pinned=%d, ext-R=%d, ext-L=%d, first-empty=%d)",
                totalDemands, diag.demandPinned, diag.demandExtendRight,
                diag.demandExtendLeft, diag.demandFirstEmpty))
        end
    end

    -- Expose diagnostic counters on the plan so callers (UI, tests) can
    -- read them without re-running the planner. Untyped to avoid forcing
    -- consumers to handle a missing field on legacy plans.
    plan.diag = diag

    return plan
end

------------------------------------------------------------------------
-- Summarize a plan for preview UIs and /gbl sortpreview.
------------------------------------------------------------------------

--- The plan's deficits, ascending by itemID.
---
--- Two surfaces render them (this file's summary and the Sort tab's Deficits
--- list) and both walked the map with pairs, which is the only unordered
--- output in an otherwise fully ordered pipeline: two runs on identical input
--- could print the same deficits in a different order, so two people reading
--- one capture wrote different rows (#165). One accessor rather than a sort
--- at each site, for the reason SortReasonText exists: #137 shipped with two
--- surfaces formatting one field separately and disagreeing about it.
--- @param plan table|nil
--- @return table array of { itemID = N, count = N }, ascending by itemID
function GBL:OrderedDeficits(plan)
    local out = {}
    for itemID, count in pairs(plan and plan.deficits or {}) do
        out[#out + 1] = { itemID = itemID, count = count }
    end
    table.sort(out, function(a, b) return a.itemID < b.itemID end)
    return out
end

function GBL:SummarizeSortPlan(plan)
    local lines = {}
    if not plan then
        return { "No plan." }
    end
    local demandMap = plan.demandMap or {}
    for _, op in ipairs(plan.ops or {}) do
        -- Annotate each op with the destination demand's origin so
        -- /gbl sortpreview output shows why each move lands where
        -- (pinned vs planner-placed via adjacency or first-empty).
        -- Ops targeting overflow or a pivot slot have no dst demand
        -- and render without a suffix.
        local dstDem = demandMap[op.dstTab] and demandMap[op.dstTab][op.dstSlot]
        local suffix = ""
        if dstDem and dstDem.origin then
            suffix = "  (dst " .. dstDem.origin .. ")"
        end
        table.insert(lines, string.format(
            "%s %d x item:%d  %s -> %s%s",
            op.op, op.count, op.itemID,
            slotRef(self, op.srcTab, op.srcSlot),
            slotRef(self, op.dstTab, op.dstSlot), suffix))
    end
    for _, d in ipairs(self:OrderedDeficits(plan)) do
        table.insert(lines, string.format("deficit: %d x item:%d (need more)",
            d.count, d.itemID))
    end
    for _, u in ipairs(plan.unplaced or {}) do
        -- A bag-origin entry says what actually happens to the items rather
        -- than only naming the slot: nothing moved, so they are still in the
        -- player's bags and the sort is not going to come back for them.
        local tail = (type(u.tabIndex) == "number" and u.tabIndex < 0)
            and " (stays in bags)" or ""
        -- The tail says what happens to the items, the reason says why.
        -- Neither replaces the other, so both ride the line.
        table.insert(lines, string.format("unplaced: %d x item:%d at %s: %s%s",
            u.count, u.itemID, slotRef(self, u.tabIndex, u.slotIndex),
            self:SortReasonText(u.reason), tail))
    end
    if #lines == 0 then
        table.insert(lines, "Bank already matches layout; no moves needed.")
    end
    -- After the empty check, never inside it: a hidden overflow tab is one
    -- of the things that produces an otherwise empty plan, and "nothing to
    -- do" on its own is the misdiagnosis this warning exists to prevent.
    for _, tabIndex in ipairs(plan.unviewableOverflowTabs or {}) do
        table.insert(lines, string.format(
            "unviewable overflow tab: T%d (not in the last bank scan: not "
            .. "viewable to this character, or not yet purchased)", tabIndex))
    end
    return lines
end

-- Expose helper for tests.
GBL._sortPlannerExtractItemID = extractItemID
GBL._sortPlannerCanExecute = canExecute
GBL._sortPlannerApplyOpToState = applyOpToState

-- Expose reason codes for tests/UI.
GBL._sortPlannerReasons = {
    OVERFLOW_FULL           = REASON_OVERFLOW_FULL,
    CYCLE_NO_PIVOT          = REASON_CYCLE_NO_PIVOT,
    NO_OVERFLOW_DEFINED     = REASON_NO_OVERFLOW_DEFINED,
    CYCLE_BUDGET_EXHAUSTED  = REASON_CYCLE_BUDGET,
    OVERFLOW_UNVIEWABLE     = REASON_OVERFLOW_UNVIEWABLE,
}
