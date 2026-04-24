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

    it("honors items[id].slots as authoritative when slotOrder has fewer entries (UI slots-edit mismatch)", function()
        -- Regression for the v0.29.7 field report: user captured 3 slots of X,
        -- then edited the Slots field in the Layout UI to 5. items[X].slots
        -- becomes 5, but slotOrder still only has 3 entries. Before this fix,
        -- the planner counted demands from slotOrder (3) and silently dropped
        -- the 2 extras. The planner must demand all 5 and place the 2 extras
        -- at the first unclaimed slot indices (slots 4 and 5 here).
        local snap = snapshot({
            [1] = {},
            [2] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 100, count = 20 },
                [3] = { itemID = 100, count = 20 },
                [4] = { itemID = 100, count = 20 },
                [5] = { itemID = 100, count = 20 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 5, perSlot = 20 } },
                    { [1] = 100, [2] = 100, [3] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        for i = 1, 5 do
            assert.is_not_nil(final[1][i], "slot " .. i .. " should be filled")
            assert.equals(100, final[1][i].itemID)
            assert.equals(20, final[1][i].count)
        end
        assert.is_nil(plan.deficits[100])
    end)

    it("extends Pass 2 demands contiguously adjacent to same-item claims", function()
        -- Two items, Power (lower ID) and Health. slotOrder captures only
        -- half of each — Power at 1-25, Health at 50-74. items[].slots say
        -- 49 each. Before the adjacency fix, Pass 2 iterated lower-ID first
        -- and filled "first unclaimed" (26-49 for Power, 75-98 for Health
        -- — which coincidentally came out neat). Swap IDs though and the
        -- lower-ID item (Health) would grab 26-49, fragmenting the sections
        -- to Power at 1-25 + 75-98 and Health at 26-49 + 50-74.
        --
        -- This test uses Health as the lower ID to verify the adjacency
        -- extension keeps each item's group contiguous regardless of ID
        -- ordering: Health stays at 50-98 (extending upward from 50-74),
        -- Power stays at 1-49 (extending upward from 1-25).
        local snap = snapshot({
            [1] = {}, [2] = {},  -- empty; irrelevant for this demand test
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    {
                        [100] = { slots = 49, perSlot = 20 },  -- Health (low ID)
                        [200] = { slots = 49, perSlot = 20 },  -- Power (high ID)
                    },
                    (function()
                        local so = {}
                        for s = 1, 25 do so[s] = 200 end    -- Power at 1-25
                        for s = 50, 74 do so[s] = 100 end   -- Health at 50-74
                        return so
                    end)()
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)

        -- The plan has no ops (no supplies) but plenty of deficits. The
        -- assertion we care about is that the planner's demand set placed
        -- each item contiguously. Pull it back out via deficits' slot
        -- mapping — but PlanSort doesn't expose demand positions directly,
        -- so inspect the Phase 3 sweep's effect instead: there is none,
        -- since the bank is empty. Instead, synthesize a bank that fills
        -- the expected demand positions and re-plan: if they're truly
        -- contiguous, the plan will be a full keep-set with zero ops.
        -- (Test this by placing Power at 1-49 and Health at 50-98 in the
        -- bank and confirming the planner treats every slot as a keep.)
        local snap2 = snapshot({
            [1] = (function()
                local s = {}
                for i = 1, 49 do s[i] = { itemID = 200, count = 20 } end
                for i = 50, 98 do s[i] = { itemID = 100, count = 20 } end
                return s
            end)(),
            [2] = {},
        })
        local plan2 = GBL:PlanSort(snap2, layout)
        assert.equals(0, #plan2.ops,
            "Power 1-49 + Health 50-98 should match the extended slotOrder with zero ops")
        assert.is_nil(plan2.deficits[100])
        assert.is_nil(plan2.deficits[200])
    end)

    it("groups overflow spills next to existing same-item stacks", function()
        -- Overflow already has Power at slot 1 and Health at slot 50.
        -- Two display tabs spill orphan stacks: Power at (2, 5) and
        -- Health at (2, 6). Before the adjacency fix, both spills went
        -- to "first empty" — slots 2 and 3 of overflow, interleaving with
        -- whatever came first. With the fix, Power lands adjacent to the
        -- existing Power (slot 2), Health adjacent to the existing Health
        -- (slot 51).
        local snap = snapshot({
            [1] = {},
            [2] = {
                [5] = { itemID = 100, count = 5 },   -- orphan Power
                [6] = { itemID = 200, count = 5 },   -- orphan Health
            },
            [3] = {
                [1]  = { itemID = 100, count = 200 },
                [50] = { itemID = 200, count = 200 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab({}, {}),
                [2] = displayTab({}, {}),
                [3] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        -- Power spill lands adjacent to overflow slot 1 (i.e. slot 2).
        assert.is_not_nil(final[3][2])
        assert.equals(100, final[3][2].itemID)
        -- Health spill lands adjacent to overflow slot 50 (i.e. slot 51).
        assert.is_not_nil(final[3][51])
        assert.equals(200, final[3][51].itemID)
    end)

    it("caps demands at items[id].slots even when slotOrder has too many entries", function()
        -- Converse: user reduced Slots via the UI from 5 to 3, but slotOrder
        -- still has 5 X entries (UI now syncs slotOrder on edit, but older
        -- saved layouts may still carry the surplus). Only 3 slots of X
        -- should be demanded; the extra 2 bank X stacks end up in overflow.
        local snap = snapshot({
            [1] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 100, count = 20 },
                [3] = { itemID = 100, count = 20 },
                [4] = { itemID = 100, count = 20 },
                [5] = { itemID = 100, count = 20 },
            },
            [2] = {},
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 3, perSlot = 20 } },
                    { [1] = 100, [2] = 100, [3] = 100, [4] = 100, [5] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        for i = 1, 3 do
            assert.is_not_nil(final[1][i])
            assert.equals(100, final[1][i].itemID)
            assert.equals(20, final[1][i].count)
        end
        -- The 2 surplus X stacks end up in overflow (tab 2).
        local overflowCount = 0
        for _, s in pairs(final[2] or {}) do
            if s.itemID == 100 then overflowCount = overflowCount + s.count end
        end
        assert.equals(40, overflowCount, "2 surplus X×20 stacks land in overflow")
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

    it("exposes plan.demandMap covering slotOrder and items.slots extensions", function()
        -- Layout has Power at slotOrder 1-3 plus items[Power].slots=5 so Pass 2
        -- adds two more demands (at slots 4 and 5 via right-extend). The plan's
        -- demandMap must reflect all 5 demand positions with correct perSlot,
        -- so /gbl deviations can compare the bank to the exact expected layout.
        local snap = snapshot({ [1] = {}, [2] = {} })
        local layout = {
            tabs = {
                [1] = displayTab(
                    { [100] = { slots = 5, perSlot = 20 } },
                    { [1] = 100, [2] = 100, [3] = 100 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        assert.is_table(plan.demandMap)
        assert.is_table(plan.demandMap[1])
        for s = 1, 5 do
            assert.is_not_nil(plan.demandMap[1][s], "demandMap missing slot " .. s)
            assert.equals(100, plan.demandMap[1][s].itemID)
            assert.equals(20, plan.demandMap[1][s].perSlot)
        end
        -- Slot 6 and beyond aren't demanded.
        assert.is_nil(plan.demandMap[1][6])
        -- Overflow tab has no demands.
        assert.is_nil(plan.demandMap[2])
    end)

    it("tags demand origins so diagnostics can distinguish pinned/extended/first-empty (v0.29.17)", function()
        -- Covers all four origin values in one plan:
        --   * Slots 1, 3, 4, 6: slotOrder-pinned by Pass 1 -> "pinned".
        --   * Slot 7: item 500 slots=2, pin at 6, Pass 2a right-extend ->
        --     "extend-right".
        --   * Slot 2: item 200 slots=2, pin at 3. Right side (slot 4) is
        --     pinned to item 300 so extend-right is blocked; Pass 2a
        --     extend-left claims slot 2 -> "extend-left".
        --   * Slot 5: item 400 has no pinned claim anywhere. Pass 2a
        --     right/left extend both skip (no existing claim to extend
        --     from). Pass 2b fallback picks slot 5 (first unused slot
        --     after claims at 1-4 and 6) -> "first-empty".
        local snap = snapshot({ [1] = {}, [2] = {} })
        local layout = {
            tabs = {
                [1] = displayTab(
                    {
                        [100] = { slots = 1, perSlot = 20 },
                        [200] = { slots = 2, perSlot = 20 },  -- extend-left
                        [300] = { slots = 1, perSlot = 20 },
                        [400] = { slots = 1, perSlot = 20 },  -- first-empty
                        [500] = { slots = 2, perSlot = 20 },  -- extend-right
                    },
                    { [1] = 100, [3] = 200, [4] = 300, [6] = 500 }
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local m = plan.demandMap[1]
        assert.equals("pinned",       m[1].origin)
        assert.equals("extend-left",  m[2].origin)
        assert.equals("pinned",       m[3].origin)
        assert.equals("pinned",       m[4].origin)
        assert.equals("first-empty",  m[5].origin)
        assert.equals("pinned",       m[6].origin)
        assert.equals("extend-right", m[7].origin)
    end)

    it("plans items-only layouts identically to heuristically pre-pinned slotOrder (v0.29.13)", function()
        -- After v0.29.13, Add Item and slots-up no longer populate slotOrder —
        -- only Capture does. This test verifies that a layout with items set
        -- but slotOrder={} produces the same final bank state as the old
        -- pre-pinning behavior (items at slots 1-5, 6-10, 11-15 for X/Y/Z).
        local snap = snapshot({
            [1] = {},
            [2] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 100, count = 20 },
                [3] = { itemID = 100, count = 20 },
                [4] = { itemID = 100, count = 20 },
                [5] = { itemID = 100, count = 20 },
                [6] = { itemID = 200, count = 20 },
                [7] = { itemID = 200, count = 20 },
                [8] = { itemID = 200, count = 20 },
                [9] = { itemID = 300, count = 20 },
                [10] = { itemID = 300, count = 20 },
            },
        })
        local layout = {
            tabs = {
                [1] = displayTab(
                    {
                        [100] = { slots = 5, perSlot = 20 },
                        [200] = { slots = 3, perSlot = 20 },
                        [300] = { slots = 2, perSlot = 20 },
                    },
                    {}   -- empty slotOrder — pure items-only layout
                ),
                [2] = overflow(),
            },
        }
        local plan = GBL:PlanSort(snap, layout)
        local final = applyPlan(snap, plan)
        -- Each item's group lands contiguous, in sortedID order, starting at S1.
        for s = 1, 5 do
            assert.is_not_nil(final[1][s], "expected item 100 at slot " .. s)
            assert.equals(100, final[1][s].itemID)
        end
        for s = 6, 8 do
            assert.is_not_nil(final[1][s], "expected item 200 at slot " .. s)
            assert.equals(200, final[1][s].itemID)
        end
        for s = 9, 10 do
            assert.is_not_nil(final[1][s], "expected item 300 at slot " .. s)
            assert.equals(300, final[1][s].itemID)
        end
        assert.is_nil(plan.deficits[100])
        assert.is_nil(plan.deficits[200])
        assert.is_nil(plan.deficits[300])
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
