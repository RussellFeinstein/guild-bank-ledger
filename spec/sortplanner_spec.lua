------------------------------------------------------------------------
-- sortplanner_spec.lua — Tests for SortPlanner.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("SortPlanner", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        Helpers.MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    --- Build a scanner-shaped snapshot from a compact description.
    -- tabs = { [tabIndex] = { [slotIndex] = { itemID = X, count = N }, ... }, ... }
    local function snapshot(tabs)
        local out = {}
        for tabIndex, slots in pairs(tabs) do
            local tabResult = { slots = {}, itemCount = 0 }
            for slotIndex, s in pairs(slots) do
                tabResult.slots[slotIndex] = {
                    itemLink = Helpers.makeItemLink(s.itemID, "Item" .. s.itemID, 1),
                    count = s.count,
                    slotIndex = slotIndex,
                    tabIndex = tabIndex,
                }
                tabResult.itemCount = tabResult.itemCount + 1
            end
            out[tabIndex] = tabResult
        end
        return out
    end

    local function displayTab(items, slotOrder)
        return { mode = "display", items = items, slotOrder = slotOrder or {} }
    end

    local function overflow()
        return { mode = "overflow" }
    end

    --- Count occurrences of itemID in a simulated final bank state after applying plan.ops.
    local function applyPlan(snap, plan)
        -- Deep-ish copy of snapshot into a flat bank[tab][slot] = {itemID,count}
        local bank = {}
        for tabIndex, tabResult in pairs(snap) do
            bank[tabIndex] = {}
            for slotIndex, slot in pairs(tabResult.slots or {}) do
                local id = GBL._sortPlannerExtractItemID(slot.itemLink)
                bank[tabIndex][slotIndex] = { itemID = id, count = slot.count }
            end
        end
        for _, op in ipairs(plan.ops) do
            local src = bank[op.srcTab] and bank[op.srcTab][op.srcSlot]
            assert(src, "plan op references empty src")
            assert(src.itemID == op.itemID, "plan op itemID mismatch with src")
            assert(src.count >= op.count, "plan op count exceeds src")
            src.count = src.count - op.count
            if src.count == 0 then
                bank[op.srcTab][op.srcSlot] = nil
            end
            if not bank[op.dstTab] then bank[op.dstTab] = {} end
            local dst = bank[op.dstTab][op.dstSlot]
            if dst then
                assert(dst.itemID == op.itemID, "plan op placed on wrong item")
                dst.count = dst.count + op.count
            else
                bank[op.dstTab][op.dstSlot] = { itemID = op.itemID, count = op.count }
            end
        end
        return bank
    end

    it("produces no ops when bank already matches layout", function()
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 100, count = 20 },
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(0, #plan.ops)
        assert.is_nil(next(plan.deficits))
    end)

    it("evicts a foreign item to overflow", function()
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 200, count = 5 }, -- foreign
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        -- Tab 1 slot 2 should now be empty or hold 100; foreign 200 in tab 2.
        assert.is_nil(final[1][2] and final[1][2].itemID == 200 or nil,
            "foreign item still in display tab")
        local foundForeign = false
        for _, slot in pairs(final[2]) do
            if slot.itemID == 200 then foundForeign = true end
        end
        assert.is_true(foundForeign, "foreign item should end up in overflow")
        -- Deficit: template wants slot 2 filled with 100 (20 count) but
        -- snapshot only had one 100 stack, so deficit of 20 is expected.
        assert.equals(20, plan.deficits[100])
    end)

    it("splits an oversize stack and keeps the template size", function()
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 200 }, -- oversize!
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        assert.equals(100, final[1][1].itemID)
        assert.equals(20, final[1][1].count)
        -- Remaining 180 should be in overflow tab 2.
        local overflowTotal = 0
        for _, slot in pairs(final[2]) do
            if slot.itemID == 100 then overflowTotal = overflowTotal + slot.count end
        end
        assert.equals(180, overflowTotal)
    end)

    it("merges deficit from overflow into display tab", function()
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 14 }, -- undersize
            },
            [2] = {
                [1] = { itemID = 100, count = 50 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        assert.equals(20, final[1][1].count)
        -- Overflow should retain 44.
        local left = 0
        for _, slot in pairs(final[2]) do
            if slot.itemID == 100 then left = left + slot.count end
        end
        assert.equals(44, left)
    end)

    it("records a deficit when an item is missing entirely", function()
        local snap = snapshot({
            [1] = {},
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(20, plan.deficits[100])
        assert.equals(0, #plan.ops)
    end)

    it("reports unplaced when overflow has no free slot", function()
        -- Fill overflow tab 2 to 98 slots, all holding itemID 999.
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 }, -- foreign item in display
            },
            [2] = (function()
                local slots = {}
                for i = 1, 98 do
                    slots[i] = { itemID = 999, count = 1 }
                end
                return slots
            end)(),
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        -- Foreign item can't be evicted; should appear in unplaced.
        local found = false
        for _, u in ipairs(plan.unplaced) do
            if u.itemID == 200 then found = true end
        end
        assert.is_true(found, "foreign item with full overflow should be unplaced")
    end)

    it("never reads or writes an ignore tab", function()
        -- Ignore tab has a bunch of random items; sort should not touch them.
        local snap = snapshot({
            [1] = { [1] = { itemID = 100, count = 20 } },
            [2] = {},
            [3] = {
                [1] = { itemID = 500, count = 7 },
                [2] = { itemID = 501, count = 3 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
                [3] = { mode = "ignore" },
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        for _, op in ipairs(plan.ops) do
            assert.is_not_equal(3, op.srcTab, "sort touched ignore tab as source")
            assert.is_not_equal(3, op.dstTab, "sort touched ignore tab as destination")
        end
    end)

    ------------------------------------------------------------------
    -- M-sort-1.1 audit-driven regression tests.
    ------------------------------------------------------------------

    it("does not harvest from or evict to ignore tabs even when item matches a template", function()
        -- Display wants item 100, but item 100 is ONLY in an ignore tab.
        -- Planner must report a deficit — not pull from ignore.
        local snap = snapshot({
            [1] = {},                                           -- display target
            [2] = {},                                           -- overflow
            [3] = { [1] = { itemID = 100, count = 50 } },       -- ignore tab holds 100
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
                [3] = { mode = "ignore" },
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(20, plan.deficits[100])
        for _, op in ipairs(plan.ops) do
            assert.is_not_equal(3, op.srcTab, "sort sourced from ignore tab")
            assert.is_not_equal(3, op.dstTab, "sort wrote to ignore tab")
        end
    end)

    it("protects already-correct slots from being harvested as sources (keep-slot invariant)", function()
        -- Template wants 2 slots of item 100 at perSlot=20.
        -- Bank has item 100 x 20 in slot 1 (matches slotOrder[1] exactly).
        -- No other source for 100 anywhere. Expected result:
        --   deficit[100] = 20 (slot 2 can't be filled)
        --   NO op moves item 100 out of slot 1 (would be a regression — the
        --   v0.29.0-dev bug did exactly this, shuffling the correct stack
        --   and swallowing the deficit).
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 20 },  -- matches template exactly
            },
            [2] = {},                                -- overflow empty
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(20, plan.deficits[100])
        for _, op in ipairs(plan.ops) do
            assert.is_false(
                op.srcTab == 1 and op.srcSlot == 1,
                "planner harvested from the correct slot; keep-slot protection regressed"
            )
        end
    end)

    it("evicts an orphan from a non-claiming display tab to overflow, then pulls to the claiming tab", function()
        -- Tab 1 display claims item 100. Tab 2 display claims items 200/201
        -- (NOT 100). Tab 2 slot 1 has an orphan 100×20. Tab 3 is overflow (empty).
        -- Planner should:
        --   1) evict 100 from tab 2 to overflow (tab 3)
        --   2) pull 100 from overflow (tab 3) into tab 1 slot 1
        -- This exercises the multi-tab source-priority path.
        local snap = snapshot({
            [1] = {},
            [2] = {
                [1] = { itemID = 100, count = 20 },  -- orphan: tab 2 doesn't claim 100
            },
            [3] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = displayTab(
                    { [200] = { slots = 1, perSlot = 5 }, [201] = { slots = 1, perSlot = 5 } },
                    { [1] = 200, [2] = 201 }
                ),
                [3] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        -- Tab 1 slot 1 should now hold item 100 x 20.
        assert.is_not_nil(final[1][1])
        assert.equals(100, final[1][1].itemID)
        assert.equals(20, final[1][1].count)
        -- Tab 2 slot 1 should no longer hold item 100.
        if final[2][1] then
            assert.is_not_equal(100, final[2][1].itemID)
        end
        -- No deficit: we successfully relocated the 20.
        assert.is_nil(plan.deficits[100])
    end)

    it("does not create duplicate unplaced entries when overflow is full", function()
        -- Regression for a bug where Pass 1 would record an unplaced entry
        -- but leave the item in the working bank, letting Pass 3 record a
        -- duplicate unplaced entry for the same slot+item.
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 }, -- foreign, display tab
            },
            [2] = (function()
                local slots = {}
                for i = 1, 98 do
                    slots[i] = { itemID = 999, count = 1 }
                end
                return slots
            end)(),
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local count = 0
        for _, u in ipairs(plan.unplaced) do
            if u.itemID == 200 and u.tabIndex == 1 and u.slotIndex == 1 then
                count = count + 1
            end
        end
        assert.equals(1, count, "unplaced should contain exactly one entry for the stuck foreign item")
    end)

    ------------------------------------------------------------------
    -- M-sort-2.5: Assign-then-Schedule planner regressions.
    -- These exercise the cases where the v0.29.0 three-pass greedy
    -- wasted moves: overflow round-trips that could be direct, pre-
    -- mature splits of oversize stacks, first-match (not largest-
    -- first) source selection, and the absence of swap-cycle handling.
    ------------------------------------------------------------------

    it("routes a direct intra-tab move instead of an overflow round-trip", function()
        -- X sits in tab 1 slot 3, template wants X at tab 1 slot 5
        -- (empty). Optimal: 1 direct op. Greedy would go via overflow (2 ops).
        local snap = snapshot({
            [1] = { [3] = { itemID = 100, count = 20 } },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [5] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(1, #plan.ops, "one direct op should suffice")
        assert.equals(1, plan.ops[1].srcTab)
        assert.equals(3, plan.ops[1].srcSlot)
        assert.equals(1, plan.ops[1].dstTab)
        assert.equals(5, plan.ops[1].dstSlot)
    end)

    it("splits an oversize stack across multiple demands without an overflow hop", function()
        -- Tab 1 slot 1 has X×40. Template wants X×20 at both slot 1 and slot 2.
        -- Optimal: 1 split moving 20 from slot 1 to slot 2. Slot 1 keeps 20.
        -- Greedy: splits excess to overflow first, then pulls back (2 ops).
        local snap = snapshot({
            [1] = { [1] = { itemID = 100, count = 40 } },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        assert.equals(1, #plan.ops)
        assert.equals(20, final[1][1].count, "slot 1 retains perSlot")
        assert.equals(20, final[1][2].count, "slot 2 filled from excess")
        for _, op in ipairs(plan.ops) do
            assert.is_not_equal(2, op.srcTab, "no overflow pickup")
            assert.is_not_equal(2, op.dstTab, "no overflow drop")
        end
    end)

    it("routes an oversize non-keep stack directly across tabs to meet multiple demands", function()
        -- Tab 1 slot 1 has X×40 but tab 1's template slot 1 wants Y (not X).
        -- Tab 2 claims X×20 at two slots. Optimal: split X×40 directly into tab 2
        -- without parking in overflow.
        local snap = snapshot({
            [1] = { [1] = { itemID = 100, count = 40 } },
            [2] = {},
            [3] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [200] = { slots = 1, perSlot = 5 } },
                    { [1] = 200 }
                ),
                [2] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [3] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        for _, op in ipairs(plan.ops) do
            if op.itemID == 100 then
                assert.is_not_equal(3, op.srcTab,
                    "X should not be harvested from overflow (it came from tab 1)")
                assert.is_not_equal(3, op.dstTab,
                    "X should not be parked in overflow (tab 2 wants it)")
            end
        end
        local final = applyPlan(snap, plan)
        local tab2X = 0
        for _, slot in pairs(final[2] or {}) do
            if slot.itemID == 100 then tab2X = tab2X + slot.count end
        end
        assert.equals(40, tab2X, "all X should reach tab 2")
    end)

    it("breaks a 2-cycle in the same tab using an unclaimed empty slot as pivot", function()
        -- Template: tab 1 slot 1 = X×10, slot 2 = Y×5.
        -- Bank: slot 1 = Y×5 and slot 2 = X×10 (a swap). Tab 1 has plenty of
        -- unclaimed empty slots (3..98) so a same-tab pivot is available.
        -- Expected: 3 ops, entirely within tab 1.
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 },
                [2] = { itemID = 100, count = 10 },
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    {
                        [100] = { slots = 1, perSlot = 10 },
                        [200] = { slots = 1, perSlot = 5 },
                    },
                    { [1] = 100, [2] = 200 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(3, #plan.ops, "2-cycle resolves in 3 ops")
        for _, op in ipairs(plan.ops) do
            assert.equals(1, op.srcTab, "pivot should stay in tab 1")
            assert.equals(1, op.dstTab, "pivot should stay in tab 1")
        end
        local final = applyPlan(snap, plan)
        assert.equals(100, final[1][1].itemID)
        assert.equals(10, final[1][1].count)
        assert.equals(200, final[1][2].itemID)
        assert.equals(5, final[1][2].count)
    end)

    it("falls back to the overflow tab for pivot when no unclaimed empty exists in the cycle's tab", function()
        -- Same 2-cycle as the previous test, but tab 1 claims every slot so
        -- no unclaimed same-tab pivot is available. Overflow is free.
        -- Expected: 3 ops, at least one touches the overflow tab.
        local items = {
            [100] = { slots = 1, perSlot = 10 },
            [200] = { slots = 1, perSlot = 5 },
        }
        local slotOrder = { [1] = 100, [2] = 200 }
        for i = 3, 98 do
            local id = 10000 + i
            items[id] = { slots = 1, perSlot = 1 }
            slotOrder[i] = id
        end
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 },
                [2] = { itemID = 100, count = 10 },
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(items, slotOrder),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local cycleOps = 0
        local touchedOverflow = false
        for _, op in ipairs(plan.ops) do
            if op.itemID == 100 or op.itemID == 200 then
                cycleOps = cycleOps + 1
                if op.srcTab == 2 or op.dstTab == 2 then
                    touchedOverflow = true
                end
            end
        end
        assert.equals(3, cycleOps, "2-cycle still resolves in 3 ops")
        assert.is_true(touchedOverflow, "overflow should serve as the pivot")
        local final = applyPlan(snap, plan)
        assert.equals(100, final[1][1].itemID)
        assert.equals(200, final[1][2].itemID)
    end)

    it("breaks a 3-cycle with a single pivot round-trip", function()
        -- A→B→C→A rotation. Optimal: 4 ops (3 cycle members + 1 pivot).
        -- Greedy: 6 ops (evict all three, pull all three back).
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 },  -- Y, wants X
                [2] = { itemID = 300, count = 15 }, -- Z, wants Y
                [3] = { itemID = 100, count = 10 }, -- X, wants Z
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    {
                        [100] = { slots = 1, perSlot = 10 },
                        [200] = { slots = 1, perSlot = 5 },
                        [300] = { slots = 1, perSlot = 15 },
                    },
                    { [1] = 100, [2] = 200, [3] = 300 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(4, #plan.ops, "3-cycle needs 4 ops (3 members + 1 pivot)")
        local final = applyPlan(snap, plan)
        assert.equals(100, final[1][1].itemID)
        assert.equals(10, final[1][1].count)
        assert.equals(200, final[1][2].itemID)
        assert.equals(5, final[1][2].count)
        assert.equals(300, final[1][3].itemID)
        assert.equals(15, final[1][3].count)
    end)

    it("picks the largest source first to minimize op count", function()
        -- Demand: X×20 at display slot. Sources: X×5 and X×30 in overflow.
        -- Largest-first: 1 op (split 20 from the 30 stack).
        -- First-match: 2 ops (pull 5, then split 15 from 30).
        local snap = snapshot({
            [1] = {},
            [2] = {
                [1] = { itemID = 100, count = 5 },
                [2] = { itemID = 100, count = 30 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(1, #plan.ops, "should pick the larger source")
        assert.equals(2, plan.ops[1].srcTab)
        assert.equals(2, plan.ops[1].srcSlot, "pick slot with X×30 first")
        assert.equals(20, plan.ops[1].count)
    end)

    it("records an unreachable cycle as unplaced instead of emitting broken ops", function()
        -- 2-cycle in tab 1. Tab 1's every slot is claimed by template (no
        -- unclaimed same-tab pivot). Overflow is completely full (no pivot
        -- available there either). Cycle is unreachable.
        local items = {
            [100] = { slots = 1, perSlot = 10 },
            [200] = { slots = 1, perSlot = 5 },
        }
        local slotOrder = { [1] = 100, [2] = 200 }
        for i = 3, 98 do
            local id = 10000 + i
            items[id] = { slots = 1, perSlot = 1 }
            slotOrder[i] = id
        end
        local overflowSlots = {}
        for i = 1, 98 do
            overflowSlots[i] = { itemID = 999, count = 1 }
        end
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 200, count = 5 },
                [2] = { itemID = 100, count = 10 },
            },
            [2] = overflowSlots,
        })
        local layout = {
            tabs = {
                [1] = displayTab(items, slotOrder),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local unplaced = {}
        for _, u in ipairs(plan.unplaced) do
            unplaced[u.itemID] = u
        end
        assert.is_not_nil(unplaced[100], "cycle participant X should be unplaced")
        assert.is_not_nil(unplaced[200], "cycle participant Y should be unplaced")
        assert.matches("cycle", unplaced[100].reason or "")
        assert.matches("cycle", unplaced[200].reason or "")
        for _, op in ipairs(plan.ops) do
            assert.is_false(
                op.itemID == 100 or op.itemID == 200,
                "no broken op should move cycle participants when unreachable"
            )
        end
    end)

    it("harvests excess from an oversize keep-slot to fill a sibling demand (keep identity preserved)", function()
        -- Tab 1 slot 1 has X×40. slotOrder[1]=X at perSlot=20 — keep-slot
        -- with 20 excess. Slot 2 needs X×20. Optimal: 1 split from slot 1
        -- to slot 2. Slot 1 should still read as X×20 after — the keep
        -- identity is preserved (we only touch the excess).
        local snap = snapshot({
            [1] = { [1] = { itemID = 100, count = 40 } },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 2, perSlot = 20 } },
                    { [1] = 100, [2] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.equals(1, #plan.ops)
        local final = applyPlan(snap, plan)
        assert.equals(20, final[1][1].count,
            "keep-slot retains exactly perSlot after excess harvest")
        assert.equals(20, final[1][2].count)
        assert.is_nil(plan.deficits[100])
    end)

    it("summarizes a plan into human-readable lines", function()
        local snap = snapshot({
            [1] = { [1] = { itemID = 100, count = 20 } },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 1, perSlot = 20 } },
                    { [1] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local lines = GBL:SummarizeSortPlan(plan)
        assert.is_true(#lines >= 1)
    end)
end)
