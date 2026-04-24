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
--
--   Phase 3 Sweep
--     * Defensive: any display-tab slot that still holds a non-fitting
--       item in the post-schedule state (and is not already unplaced) is
--       routed to overflow. In a well-formed plan this is a no-op; it
--       guards against edge cases in Phase 1's assignment.
--
-- Public contract — identical to v0.29.x for drop-in compatibility with
-- SortExecutor and UI/SortView:
--
--   PlanSort(snapshot, layout) -> {
--       ops = { {op="split"|"move", srcTab, srcSlot,
--                dstTab, dstSlot, itemID, count}, ... },
--       deficits = { [itemID] = count },
--       unplaced = { {tabIndex, slotIndex, itemID, count, reason}, ... },
--       overflowTab = tabIndex | nil,
--   }
--
-- Invariants:
--   * Ignore tabs are never read as source nor written as destination.
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

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function extractItemID(itemLink)
    if BankLayout and BankLayout.ExtractItemID then
        return BankLayout.ExtractItemID(itemLink)
    end
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

--- Apply a planned op to a working state (mutates in place).
local function applyOpToState(state, op)
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
        dst.count = dst.count + op.count
    else
        state[op.dstTab][op.dstSlot] = { itemID = op.itemID, count = op.count }
    end
end

--- Return true iff an op can fire against `state`.
local function canExecute(op, state)
    local src = state[op.srcTab] and state[op.srcTab][op.srcSlot]
    if not src or src.itemID ~= op.itemID or src.count < op.count then
        return false
    end
    local dst = state[op.dstTab] and state[op.dstTab][op.dstSlot]
    if dst and dst.itemID ~= op.itemID then
        return false
    end
    return true
end

--- Pick "split" or "move" label based on whether the op fully drains src.
local function opLabel(state, ass)
    local src = state[ass.srcTab] and state[ass.srcTab][ass.srcSlot]
    if src and src.count > ass.count then return "split" end
    return "move"
end

------------------------------------------------------------------------
-- Main entry
------------------------------------------------------------------------

function GBL:PlanSort(snapshot, layout)
    local plan = { ops = {}, deficits = {}, unplaced = {}, overflowTab = nil }

    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return plan
    end

    -- --------------------------------------------------------------
    -- Classify tabs.
    -- --------------------------------------------------------------
    local displayTabs = {}
    local overflowTab = nil
    local ignoreSet = {}
    for tabIndex, tab in pairs(layout.tabs) do
        if tab.mode == "overflow" then
            overflowTab = tabIndex
        elseif tab.mode == "display" then
            table.insert(displayTabs, { tabIndex = tabIndex, tab = tab })
        elseif tab.mode == "ignore" then
            ignoreSet[tabIndex] = true
        end
    end
    plan.overflowTab = overflowTab
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
    if overflowTab and not bank[overflowTab] then bank[overflowTab] = {} end

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
        -- reduced Slots below the captured count).
        local emitted = {}
        for slotIndex = 1, MAX_SLOTS do
            local itemID = slotOrder[slotIndex]
            local row = itemID and items[itemID] or nil
            if row and (emitted[itemID] or 0) < row.slots then
                local dem = {
                    tabIndex = tabIndex, slotIndex = slotIndex,
                    itemID = itemID, perSlot = row.perSlot, filled = 0,
                }
                table.insert(demands, dem)
                demandOfSlot[tabIndex][slotIndex] = dem
                emitted[itemID] = (emitted[itemID] or 0) + 1
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

        local function addDemandAt(s, itemID, row)
            local dem = {
                tabIndex = tabIndex, slotIndex = s,
                itemID = itemID, perSlot = row.perSlot, filled = 0,
            }
            table.insert(demands, dem)
            demandOfSlot[tabIndex][s] = dem
            usedSlots[s] = true
            claimedByItem[itemID] = claimedByItem[itemID] or {}
            claimedByItem[itemID][s] = true
            emitted[itemID] = (emitted[itemID] or 0) + 1
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
                        addDemandAt(hi + 1, itemID, row)
                        need = need - 1
                        hi = hi + 1
                    end
                    while need > 0 and lo <= MAX_SLOTS and lo > 1
                          and not usedSlots[lo - 1] do
                        addDemandAt(lo - 1, itemID, row)
                        need = need - 1
                        lo = lo - 1
                    end

                    -- Phase 2b — fall back to any unclaimed slot (used
                    -- only when the item has no existing claim to extend
                    -- from, or both ends are blocked).
                    if need > 0 then
                        for s = 1, MAX_SLOTS do
                            if need <= 0 then break end
                            if not usedSlots[s] then
                                addDemandAt(s, itemID, row)
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
    if overflowTab then table.insert(tabOrder, overflowTab) end
    table.sort(tabOrder)

    local supplies = {}
    for _, tabIndex in ipairs(tabOrder) do
        local tab = bank[tabIndex]
        if tab then
            for slotIndex = 1, MAX_SLOTS do
                local slot = tab[slotIndex]
                if slot then
                    table.insert(supplies, {
                        tabIndex = tabIndex, slotIndex = slotIndex,
                        itemID = slot.itemID, count = slot.count,
                        available = slot.count,
                        isOverflow = (tabIndex == overflowTab),
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
        local best, bestP, bestAvail, bestTab, bestSlot = nil, 4, -1, math.huge, math.huge
        for _, sup in ipairs(supplies) do
            if sup.itemID == dem.itemID and sup.available > 0
               and not (sup.tabIndex == dem.tabIndex and sup.slotIndex == dem.slotIndex) then
                local p
                if sup.tabIndex == dem.tabIndex then p = 1
                elseif sup.isOverflow then p = 2
                else p = 3 end
                local pick = false
                if p < bestP then
                    pick = true
                elseif p == bestP then
                    if sup.available > bestAvail then
                        pick = true
                    elseif sup.available == bestAvail then
                        if sup.tabIndex < bestTab
                           or (sup.tabIndex == bestTab and sup.slotIndex < bestSlot) then
                            pick = true
                        end
                    end
                end
                if pick then
                    best, bestP, bestAvail = sup, p, sup.available
                    bestTab, bestSlot = sup.tabIndex, sup.slotIndex
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
        end
    end

    -- Phase 1B — route leftover non-overflow supply to overflow.
    --
    -- Virtual overflow layout: starts with the initial bank state and is
    -- extended as we plan spills. Used by pickOverflowSlot to group stacks
    -- by item — a spill of X lands adjacent to an existing X stack rather
    -- than in the first empty slot, so the stock tab stays organized.
    local overflowVirtual = {}
    if overflowTab then
        for s = 1, MAX_SLOTS do
            local slot = bank[overflowTab] and bank[overflowTab][s]
            if slot then
                overflowVirtual[s] = slot.itemID
            end
        end
    end

    local function pickOverflowSlot(itemID)
        if not overflowTab then return nil end
        -- Right-extend an existing same-item group first (natural reading order).
        for s = 2, MAX_SLOTS do
            if not overflowVirtual[s] and overflowVirtual[s - 1] == itemID then
                return s
            end
        end
        -- Left-extend if no right-extension is possible.
        for s = MAX_SLOTS - 1, 1, -1 do
            if not overflowVirtual[s] and overflowVirtual[s + 1] == itemID then
                return s
            end
        end
        -- First empty slot (new item in overflow).
        for s = 1, MAX_SLOTS do
            if not overflowVirtual[s] then return s end
        end
        return nil
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

    for _, sup in ipairs(supplies) do
        if sup.available > 0 and not sup.isOverflow then
            if not overflowTab then
                recordUnplaced(sup.tabIndex, sup.slotIndex, sup.itemID,
                    sup.available, REASON_NO_OVERFLOW_DEFINED)
            else
                local ovSlot = pickOverflowSlot(sup.itemID)
                if not ovSlot then
                    recordUnplaced(sup.tabIndex, sup.slotIndex, sup.itemID,
                        sup.available, REASON_OVERFLOW_FULL)
                else
                    overflowVirtual[ovSlot] = sup.itemID
                    table.insert(assignments, {
                        srcTab = sup.tabIndex, srcSlot = sup.slotIndex,
                        dstTab = overflowTab, dstSlot = ovSlot,
                        itemID = sup.itemID, count = sup.available,
                    })
                    sup.available = 0
                end
            end
        end
    end

    -- --------------------------------------------------------------
    -- PHASE 2: Schedule
    -- --------------------------------------------------------------

    -- Deep-copy bank into a mutable working state for Phase 2.
    local state = {}
    for tabIndex, tab in pairs(bank) do
        state[tabIndex] = {}
        for slotIndex, slot in pairs(tab) do
            state[tabIndex][slotIndex] = {
                itemID = slot.itemID, count = slot.count,
            }
        end
    end

    local remaining = {}
    for i = 1, #assignments do remaining[i] = true end

    local function emitAssignment(ass)
        local op = {
            op = opLabel(state, ass),
            srcTab = ass.srcTab, srcSlot = ass.srcSlot,
            dstTab = ass.dstTab, dstSlot = ass.dstSlot,
            itemID = ass.itemID, count = ass.count,
        }
        table.insert(plan.ops, op)
        applyOpToState(state, op)
    end

    local function greedyDrain()
        local progressed
        repeat
            progressed = false
            for i = 1, #assignments do
                if remaining[i] then
                    local ass = assignments[i]
                    if canExecute(ass, state) then
                        emitAssignment(ass)
                        remaining[i] = nil
                        progressed = true
                    end
                end
            end
        until not progressed
    end

    greedyDrain()

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
        -- Priority 2: empty overflow slot not reserved by a pending op.
        if overflowTab then
            for s = 1, MAX_SLOTS do
                local slot = state[overflowTab] and state[overflowTab][s]
                if not slot then
                    local reserved = false
                    for i = 1, #assignments do
                        if remaining[i] then
                            local a = assignments[i]
                            if a.dstTab == overflowTab and a.dstSlot == s then
                                reserved = true
                                break
                            end
                        end
                    end
                    if not reserved then
                        return overflowTab, s
                    end
                end
            end
        end
        return nil, nil
    end

    local guard = 0
    while next(remaining) ~= nil and guard < 500 do
        guard = guard + 1

        -- Find the first remaining op whose dst currently holds a foreign item.
        local stuckIdx
        for i = 1, #assignments do
            if remaining[i] then
                local a = assignments[i]
                local dstCur = state[a.dstTab] and state[a.dstTab][a.dstSlot]
                if dstCur and dstCur.itemID ~= a.itemID then
                    stuckIdx = i
                    break
                end
            end
        end

        if not stuckIdx then
            -- No op is dst-blocked but some remain — should only happen if
            -- a src drifted (shouldn't in pure-planner mode). Bail safely.
            for i = 1, #assignments do
                if remaining[i] then
                    local a = assignments[i]
                    recordUnplaced(a.srcTab, a.srcSlot, a.itemID, a.count,
                        REASON_CYCLE_NO_PIVOT)
                    remaining[i] = nil
                end
            end
            break
        end

        local stuck = assignments[stuckIdx]
        local pivotTab, pivotSlot = findPivot(stuck.dstTab)
        if not pivotTab then
            for i = 1, #assignments do
                if remaining[i] then
                    local a = assignments[i]
                    recordUnplaced(a.srcTab, a.srcSlot, a.itemID, a.count,
                        REASON_CYCLE_NO_PIVOT)
                    remaining[i] = nil
                end
            end
            break
        end

        local blockerSlot = state[stuck.dstTab][stuck.dstSlot]
        local pivotOp = {
            op = (blockerSlot.count > 0) and
                 ((state[stuck.dstTab][stuck.dstSlot].count > blockerSlot.count)
                    and "split" or "move") or "move",
            srcTab = stuck.dstTab, srcSlot = stuck.dstSlot,
            dstTab = pivotTab, dstSlot = pivotSlot,
            itemID = blockerSlot.itemID, count = blockerSlot.count,
        }
        -- Simplify: pivot always moves the entire slot content away.
        pivotOp.op = "move"
        table.insert(plan.ops, pivotOp)
        applyOpToState(state, pivotOp)

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

    -- --------------------------------------------------------------
    -- PHASE 3: Sweep (defensive)
    -- --------------------------------------------------------------
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
                    local ovSlot = pickOverflowSlot(slot.itemID)
                    if overflowTab and ovSlot then
                        overflowVirtual[ovSlot] = slot.itemID
                        local sweepOp = {
                            op = "move",
                            srcTab = tabIndex, srcSlot = slotIndex,
                            dstTab = overflowTab, dstSlot = ovSlot,
                            itemID = slot.itemID, count = slot.count,
                        }
                        table.insert(plan.ops, sweepOp)
                        applyOpToState(state, sweepOp)
                    else
                        recordUnplaced(tabIndex, slotIndex, slot.itemID, slot.count,
                            overflowTab and REASON_OVERFLOW_FULL
                            or REASON_NO_OVERFLOW_DEFINED)
                    end
                end
            end
        end
    end

    return plan
end

------------------------------------------------------------------------
-- Summarize a plan for preview UIs and /gbl sortpreview.
------------------------------------------------------------------------

function GBL:SummarizeSortPlan(plan)
    local lines = {}
    if not plan then
        return { "No plan." }
    end
    for _, op in ipairs(plan.ops or {}) do
        table.insert(lines, string.format(
            "%s %d x item:%d  T%d/%d -> T%d/%d",
            op.op, op.count, op.itemID,
            op.srcTab, op.srcSlot, op.dstTab, op.dstSlot))
    end
    for itemID, count in pairs(plan.deficits or {}) do
        table.insert(lines, string.format("deficit: %d x item:%d (need more)", count, itemID))
    end
    for _, u in ipairs(plan.unplaced or {}) do
        table.insert(lines, string.format("unplaced: %d x item:%d at T%d/%d",
            u.count, u.itemID, u.tabIndex, u.slotIndex))
    end
    if #lines == 0 then
        table.insert(lines, "Bank already matches layout; no moves needed.")
    end
    return lines
end

-- Expose helper for tests.
GBL._sortPlannerExtractItemID = extractItemID

-- Expose reason codes for tests/UI.
GBL._sortPlannerReasons = {
    OVERFLOW_FULL       = REASON_OVERFLOW_FULL,
    CYCLE_NO_PIVOT      = REASON_CYCLE_NO_PIVOT,
    NO_OVERFLOW_DEFINED = REASON_NO_OVERFLOW_DEFINED,
}
