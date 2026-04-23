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
