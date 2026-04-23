------------------------------------------------------------------------
-- GuildBankLedger — SortPlanner.lua
-- Given a bank snapshot and a layout, produce an ordered list of moves
-- that reshapes the bank toward the layout.
--
-- Design:
--   * Pure function: PlanSort(snapshot, layout) -> planTable
--   * No WoW API calls. All inputs come through arguments.
--   * Plan ops use named fields so the executor can validate each step:
--       { op = "split"|"move", srcTab, srcSlot, dstTab, dstSlot,
--         itemID, count }
--     "split" means "take `count` from src, place at dst" (maps to
--     SplitGuildBankItem + Pickup). "move" means "take everything
--     from src, place at dst" (plain Pickup + Pickup).
--   * Overflow: single tab marked mode="overflow". Anything not
--     in a display template ends up there. If overflow fills up,
--     remaining items are recorded as unplaced.
--   * Stack reshape: display tabs always match template perSlot.
--   * Replan-friendly: the plan is idempotent if partially executed.
--     Re-running PlanSort on a later snapshot produces whatever is
--     still needed.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98

local BankLayout = GBL.BankLayout

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

--- Build a working copy of the snapshot as a flat slot map:
--   slots[tabIndex][slotIndex] = { itemID, count } or nil
-- The plan mutates this during planning to reflect post-move state.
local function buildWorkingBank(snapshot)
    local bank = {}
    for tabIndex, tabResult in pairs(snapshot or {}) do
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
    return bank
end

--- Find any empty slot in a given tab, starting from slot 1.
-- Returns slotIndex or nil.
local function findEmptySlot(bank, tabIndex, skipSlotOrder)
    local tab = bank[tabIndex]
    if not tab then return nil end
    for slot = 1, MAX_SLOTS do
        if not tab[slot] and not (skipSlotOrder and skipSlotOrder[slot]) then
            return slot
        end
    end
    return nil
end

--- Find any empty slot in the overflow tab, or nil if full.
local function findOverflowSlot(bank, overflowTab)
    if not overflowTab then return nil end
    return findEmptySlot(bank, overflowTab)
end

--- Find a slot holding itemID somewhere in `sources` (list of {tabIndex, skipSet}).
-- `skipSet[slotIndex] = true` means don't harvest from this slot (it's a keep).
-- Returns srcTab, srcSlot, slotCount or nil.
local function findSource(bank, itemID, sources)
    for _, src in ipairs(sources) do
        local tab = bank[src.tabIndex]
        if tab then
            for slotIndex = 1, MAX_SLOTS do
                local slot = tab[slotIndex]
                if slot and slot.itemID == itemID and not (src.keepSlots and src.keepSlots[slotIndex]) then
                    return src.tabIndex, slotIndex, slot.count
                end
            end
        end
    end
    return nil, nil, 0
end

------------------------------------------------------------------------
-- Plan ops
------------------------------------------------------------------------

--- Emit a plan op and apply it to the working bank.
local function doSplit(plan, bank, srcTab, srcSlot, dstTab, dstSlot, itemID, count)
    assert(count > 0, "split count must be > 0")
    local src = bank[srcTab] and bank[srcTab][srcSlot]
    assert(src and src.itemID == itemID, "split source mismatch")
    assert(src.count >= count, "split source has fewer than count")
    if not bank[dstTab] then bank[dstTab] = {} end
    local dst = bank[dstTab][dstSlot]
    if dst then
        assert(dst.itemID == itemID, "split destination occupied by wrong item")
        dst.count = dst.count + count
    else
        bank[dstTab][dstSlot] = { itemID = itemID, count = count }
    end
    src.count = src.count - count
    local op = "split"
    if src.count == 0 then
        bank[srcTab][srcSlot] = nil
        op = "move" -- whole slot drained; executor can use plain move
    end
    table.insert(plan.ops, {
        op = op,
        srcTab = srcTab, srcSlot = srcSlot,
        dstTab = dstTab, dstSlot = dstSlot,
        itemID = itemID, count = count,
    })
end

--- Top-level planner. snapshot is { [tabIndex] = { slots = { [slotIndex] = { itemLink, count, ... } } } }.
-- layout is { tabs = { [tabIndex] = { mode, items, slotOrder } } } as returned by GetBankLayout.
-- Returns a plan table:
--   {
--     ops = { {op, srcTab, srcSlot, dstTab, dstSlot, itemID, count}, ... },
--     deficits = { [itemID] = count },     -- items template wanted but bank lacks
--     unplaced = { { tabIndex, slotIndex, itemID, count } }, -- spill we couldn't route
--     overflowTab = tabIndex or nil,
--   }
function GBL:PlanSort(snapshot, layout)
    local bank = buildWorkingBank(snapshot)
    local plan = { ops = {}, deficits = {}, unplaced = {}, overflowTab = nil }

    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return plan
    end

    -- Classify tabs. Ignore tabs are simply skipped (never read or written).
    local displayTabs = {}    -- ordered list of { tabIndex, tab }
    local overflowTab = nil
    for tabIndex, tab in pairs(layout.tabs) do
        if tab.mode == "overflow" then
            overflowTab = tabIndex
        elseif tab.mode == "display" then
            table.insert(displayTabs, { tabIndex = tabIndex, tab = tab })
        end
    end
    plan.overflowTab = overflowTab

    -- Stable order: sort display tabs by tabIndex for determinism.
    table.sort(displayTabs, function(a, b) return a.tabIndex < b.tabIndex end)

    -- Ensure overflow tab exists in bank even if snapshot had no entry for it.
    if overflowTab and not bank[overflowTab] then bank[overflowTab] = {} end

    -- ------------------------------------------------------------------
    -- Pass 1: evict wrong items from display tabs.
    -- A slot in a display tab is "correct" if slotOrder[slotIndex] == itemID
    -- AND count == perSlot for that itemID.
    -- Wrong items go to the overflow tab (or unplaced).
    -- ------------------------------------------------------------------
    for _, entry in ipairs(displayTabs) do
        local tabIndex = entry.tabIndex
        local tab = entry.tab
        local slotOrder = tab.slotOrder or {}
        local items = tab.items or {}

        for slotIndex = 1, MAX_SLOTS do
            local slot = bank[tabIndex] and bank[tabIndex][slotIndex]
            if slot then
                local targetItemID = slotOrder[slotIndex]
                local itemRow = targetItemID and items[targetItemID] or nil
                local isCorrectItem = (slot.itemID == targetItemID)
                local hasRow = items[slot.itemID] ~= nil
                if not isCorrectItem and not hasRow then
                    -- Item doesn't belong in this tab at all -> overflow.
                    local ovSlot = findOverflowSlot(bank, overflowTab)
                    if ovSlot then
                        doSplit(plan, bank, tabIndex, slotIndex,
                            overflowTab, ovSlot, slot.itemID, slot.count)
                    else
                        table.insert(plan.unplaced, {
                            tabIndex = tabIndex, slotIndex = slotIndex,
                            itemID = slot.itemID, count = slot.count,
                        })
                        -- Drop from working bank so later passes don't re-process
                        -- this same slot and emit duplicate unplaced entries or
                        -- try to write into a slot already occupied by a foreign.
                        bank[tabIndex][slotIndex] = nil
                    end
                elseif not isCorrectItem and hasRow then
                    -- Item belongs in *this* tab but the slot belongs to a
                    -- different item. Move it aside to a temp spot in this
                    -- tab or overflow, so pass 2 can place it properly.
                    -- We move it to overflow; pass 2 will pull it back.
                    local ovSlot = findOverflowSlot(bank, overflowTab)
                    if ovSlot then
                        doSplit(plan, bank, tabIndex, slotIndex,
                            overflowTab, ovSlot, slot.itemID, slot.count)
                    else
                        table.insert(plan.unplaced, {
                            tabIndex = tabIndex, slotIndex = slotIndex,
                            itemID = slot.itemID, count = slot.count,
                        })
                        bank[tabIndex][slotIndex] = nil
                    end
                elseif isCorrectItem and itemRow and slot.count > itemRow.perSlot then
                    -- Slot has the right item but oversize: split off the excess.
                    local excess = slot.count - itemRow.perSlot
                    local ovSlot = findOverflowSlot(bank, overflowTab)
                    if ovSlot then
                        doSplit(plan, bank, tabIndex, slotIndex,
                            overflowTab, ovSlot, slot.itemID, excess)
                    else
                        table.insert(plan.unplaced, {
                            tabIndex = tabIndex, slotIndex = slotIndex,
                            itemID = slot.itemID, count = excess,
                        })
                    end
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Pass 2: fill display slots per slotOrder, taking from overflow /
    -- other display tabs / same-tab offslots.
    -- ------------------------------------------------------------------
    -- Build search order for sources: prefer same tab first, then overflow,
    -- then other display tabs.
    for _, entry in ipairs(displayTabs) do
        local tabIndex = entry.tabIndex
        local tab = entry.tab
        local slotOrder = tab.slotOrder or {}
        local items = tab.items or {}

        -- Identify "keep" slots: those already matching template exactly.
        -- Keep slots must NOT be harvested as sources — doing so would
        -- shuffle correct items off their correct slots and invent moves
        -- (and potentially swallow a genuine deficit).
        local keepSlotsThisTab = {}
        for slotIndex = 1, MAX_SLOTS do
            local target = slotOrder[slotIndex]
            local row = target and items[target] or nil
            if row then
                local existing = bank[tabIndex] and bank[tabIndex][slotIndex]
                if existing and existing.itemID == target and existing.count == row.perSlot then
                    keepSlotsThisTab[slotIndex] = true
                end
            end
        end

        for slotIndex = 1, MAX_SLOTS do
            local targetItemID = slotOrder[slotIndex]
            local itemRow = targetItemID and items[targetItemID] or nil
            if itemRow then
                local existing = bank[tabIndex] and bank[tabIndex][slotIndex]
                local have = (existing and existing.itemID == targetItemID) and existing.count or 0
                local need = itemRow.perSlot - have
                if need > 0 then
                    -- Same tab: skip keeps AND the destination slot itself.
                    local sameTabKeeps = {}
                    for k in pairs(keepSlotsThisTab) do sameTabKeeps[k] = true end
                    sameTabKeeps[slotIndex] = true

                    local sources = {
                        { tabIndex = tabIndex, keepSlots = sameTabKeeps },
                    }
                    if overflowTab and overflowTab ~= tabIndex then
                        table.insert(sources, { tabIndex = overflowTab })
                    end
                    for _, other in ipairs(displayTabs) do
                        if other.tabIndex ~= tabIndex then
                            table.insert(sources, { tabIndex = other.tabIndex })
                        end
                    end

                    while need > 0 do
                        local srcTab, srcSlot, srcCount = findSource(bank, targetItemID, sources)
                        if not srcTab then
                            plan.deficits[targetItemID] = (plan.deficits[targetItemID] or 0) + need
                            break
                        end
                        local take = math.min(need, srcCount)
                        doSplit(plan, bank, srcTab, srcSlot, tabIndex, slotIndex, targetItemID, take)
                        need = need - take
                    end
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Pass 3: sweep any stragglers.
    -- Items still left in display tabs that don't match template slotOrder
    -- for their slot: push to overflow. (Handles case where display tab
    -- had items in non-template slots after pass 1 tried to consolidate.)
    -- ------------------------------------------------------------------
    for _, entry in ipairs(displayTabs) do
        local tabIndex = entry.tabIndex
        local tab = entry.tab
        local slotOrder = tab.slotOrder or {}
        local items = tab.items or {}
        for slotIndex = 1, MAX_SLOTS do
            local slot = bank[tabIndex] and bank[tabIndex][slotIndex]
            if slot then
                local expected = slotOrder[slotIndex]
                local fitsHere = (expected == slot.itemID and items[expected])
                if not fitsHere then
                    local ovSlot = findOverflowSlot(bank, overflowTab)
                    if ovSlot then
                        doSplit(plan, bank, tabIndex, slotIndex,
                            overflowTab, ovSlot, slot.itemID, slot.count)
                    else
                        table.insert(plan.unplaced, {
                            tabIndex = tabIndex, slotIndex = slotIndex,
                            itemID = slot.itemID, count = slot.count,
                        })
                    end
                end
            end
        end
    end

    return plan
end

--- Summarize a plan for preview UIs / the sortpreview slash command.
-- Returns a short list of strings, one per op (plus deficit/unplaced lines).
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
