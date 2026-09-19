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
    -- @param bags table|nil Optional opts.bagSnapshot, absorbed under its own
    --   negative pseudo-tabs so a plan that sources from bags can be applied.
    -- @param maxStackByItem table|nil Optional `[itemID] = maxStack` map. When
    --   given, a same-item merge is held to the same ceiling `applyOpToState`
    --   enforces in production (#161); without it the simulator stacks without
    --   limit, which is what let an over-stack end-state test pass on an empty
    --   plan for as long as it did.
    local function applyPlan(snap, plan, bags, maxStackByItem)
        -- Deep-ish copy of snapshot into a flat bank[tab][slot] = {itemID,count}
        local bank = {}
        local function absorb(src)
            for tabIndex, tabResult in pairs(src or {}) do
                bank[tabIndex] = bank[tabIndex] or {}
                for slotIndex, slot in pairs(tabResult.slots or {}) do
                    local id = GBL._sortPlannerExtractItemID(slot.itemLink)
                    bank[tabIndex][slotIndex] = { itemID = id, count = slot.count }
                end
            end
        end
        absorb(snap)
        absorb(bags)
        for _, op in ipairs(plan.ops) do
            assert(op.dstTab >= 1, "plan op targets a non-bank tab")
            local src = bank[op.srcTab] and bank[op.srcTab][op.srcSlot]
            assert(src, "plan op references empty src")
            assert(src.itemID == op.itemID, "plan op itemID mismatch with src")
            assert(src.count >= op.count, "plan op count exceeds src")
            -- The label has to agree with what the op does to its source,
            -- which is opLabel's rule verbatim (#161). This is an assertion
            -- and not a second code path on purpose: #169 stopped the
            -- executor branching on op.op, and liftFromBank now takes exactly
            -- op.count whatever the label says, so the simulation below is
            -- faithful precisely because it is label-blind.
            local expectedLabel = (src.count > op.count) and "split" or "move"
            assert(op.op == expectedLabel,
                "plan op label " .. tostring(op.op) .. " should be "
                .. expectedLabel .. " (src holds " .. src.count
                .. ", op takes " .. tostring(op.count) .. ")")
            src.count = src.count - op.count
            if src.count == 0 then
                bank[op.srcTab][op.srcSlot] = nil
            end
            if not bank[op.dstTab] then bank[op.dstTab] = {} end
            local dst = bank[op.dstTab][op.dstSlot]
            if dst then
                assert(dst.itemID == op.itemID, "plan op placed on wrong item")
                local m = maxStackByItem and maxStackByItem[op.itemID]
                assert(not m or (dst.count + op.count) <= m,
                    "plan op would exceed maxStack for itemID "
                    .. tostring(op.itemID))
                dst.count = dst.count + op.count
            else
                local m = maxStackByItem and maxStackByItem[op.itemID]
                assert(not m or op.count <= m,
                    "plan op opens a slot with more than one stack of itemID "
                    .. tostring(op.itemID))
                bank[op.dstTab][op.dstSlot] = { itemID = op.itemID, count = op.count }
            end
        end
        return bank
    end

    --- Apply only the first `limit` ops. The executor issues a plan one op at
    --- a time and a pass can end early (bank closed, cancelled, the pump
    --- stopping), so a partially applied plan is an ordinary state the next
    --- plan has to cope with, not a synthetic one.
    local function applyPlanPartial(snap, plan, limit)
        local trimmed = { ops = {} }
        for i = 1, math.min(limit, #plan.ops) do
            trimmed.ops[i] = plan.ops[i]
        end
        return applyPlan(snap, trimmed)
    end

    --- Turn an applied bank state back into a snapshot description, so a plan
    --- can be fed its own result.
    local function redescribe(bank)
        local desc = {}
        for t, slots in pairs(bank) do
            desc[t] = {}
            for s, v in pairs(slots) do
                desc[t][s] = { itemID = v.itemID, count = v.count }
            end
        end
        return desc
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
        -- Phase 2's first op is the canonical "pick largest source" move.
        -- Phase 4 may append compaction ops afterward — they don't affect
        -- the Phase 2 decision we're checking here.
        assert.is_true(#plan.ops >= 1)
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

    describe("Phase 2 instrumentation (v0.32.8 B4a)", function()
        -- Phase 2 audit lines emit via self:SortDebug, which only records
        -- to the buffer when db.profile.sort.debugChat is true. Each test
        -- in this block flips the flag before running PlanSort so the
        -- audit lines land in the log buffer for inspection.

        before_each(function()
            GBL.db.profile.sort.debugChat = true
        end)

        it("emits cycle + pivot audit lines when Phase 2 resolves a 2-cycle", function()
            -- Reuse the 2-cycle shape from the existing "breaks a 2-cycle"
            -- test: T1/S1 has Y, T1/S2 has X; layout expects X@1, Y@2.
            -- Phase 2 detects the cycle (T1/S1 wants X but holds Y) and
            -- chooses a pivot (an unclaimed empty slot in T1).
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
            -- Both audit lines must appear: cycle-blocked + pivot-chosen.
            local trail = GBL:GetLog("sort")
            local sawCycleLine, sawPivotLine = false, false
            for _, entry in ipairs(trail or {}) do
                local m = entry.message or ""
                if m:find("sort plan Phase 2: cycle blocked at", 1, true) then
                    sawCycleLine = true
                end
                if m:find("sort plan Phase 2: pivot", 1, true) then
                    sawPivotLine = true
                end
            end
            assert.is_true(sawCycleLine,
                "expected cycle-blocked debug line; got nothing")
            assert.is_true(sawPivotLine,
                "expected pivot-chosen debug line; got nothing")
        end)

        it("emits no-pivot abort when cycle is unreachable", function()
            -- Reuse the "unreachable cycle" shape: T1 has every slot
            -- claimed by a distinct item and overflow has no room either.
            -- Phase 2 detects the cycle and fails to find a pivot.
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
            -- Pre-fill tab 1's "filler" slots and overflow's 98 slots so
            -- findPivot returns nil.
            local bankT1 = {
                [1] = { itemID = 200, count = 5 },
                [2] = { itemID = 100, count = 10 },
            }
            for i = 3, 98 do
                bankT1[i] = { itemID = 10000 + i, count = 1 }
            end
            local bankT2 = {}
            for i = 1, 98 do
                bankT2[i] = { itemID = 99999, count = 1 }
            end
            local snap = snapshot({ [1] = bankT1, [2] = bankT2 })
            local layout = {
                tabs = {
                    [1] = displayTab(items, slotOrder),
                    [2] = overflow(),
                },
            }
            GBL:PlanSort(snap, layout)
            local trail = GBL:GetLog("sort")
            local sawNoPivot = false
            for _, entry in ipairs(trail or {}) do
                if entry.message
                   and entry.message:find("Phase 2: no-pivot abort", 1, true) then
                    sawNoPivot = true
                    break
                end
            end
            assert.is_true(sawNoPivot,
                "expected no-pivot abort debug line; got nothing")

            -- And the counters behind that line. The debug string was the
            -- only thing pinned here, so deleting the abort increment at this
            -- site changed nothing the suite could see (#165).
            local plan = GBL:PlanSort(snap, layout)
            assert.equals(1, plan.diag.phase2CycleAborts)
            assert.is_true(plan.diag.phase2StrandedAssignments >= 1,
                "an abort strands at least the assignment it gave up on")
        end)

        it("does not emit Phase 2 lines when sort.debugChat is off", function()
            -- Verify the SortDebug gating: with debugChat off, the audit
            -- lines must not land in the log buffer at all.
            GBL.db.profile.sort.debugChat = false
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
            GBL:PlanSort(snap, layout)
            local trail = GBL:GetLog("sort")
            for _, entry in ipairs(trail or {}) do
                local m = entry.message or ""
                assert.is_nil(m:find("sort plan Phase 2:", 1, true),
                    "Phase 2 debug line leaked into log when debugChat off")
            end
        end)
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

    it("groups overflow contents by item after spills from display tabs", function()
        -- Overflow already has Power at slot 1 and Health at slot 50.
        -- Display tabs spill orphan stacks: Power and Health (5 each).
        -- Phase 1B uses adjacency to place spills near existing same-item
        -- stacks; Phase 4 then globally compacts so the tab ends grouped
        -- by itemID starting at slot 1, bigger stacks first within a
        -- group. Net effect: [1]=Power×200, [2]=Power×5,
        -- [3]=Health×200, [4]=Health×5, rest empty.
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
        assert.is_not_nil(final[3][1]); assert.equals(100, final[3][1].itemID); assert.equals(200, final[3][1].count)
        assert.is_not_nil(final[3][2]); assert.equals(100, final[3][2].itemID); assert.equals(5,   final[3][2].count)
        assert.is_not_nil(final[3][3]); assert.equals(200, final[3][3].itemID); assert.equals(200, final[3][3].count)
        assert.is_not_nil(final[3][4]); assert.equals(200, final[3][4].itemID); assert.equals(5,   final[3][4].count)
        assert.is_nil(final[3][50])
        assert.is_nil(final[3][51])
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

    -- ------------------------------------------------------------------
    -- Phase 4 — overflow compaction
    -- ------------------------------------------------------------------
    describe("Phase 4 overflow compaction", function()
        --- Convenience: layout with a single empty display tab [1] and
        --- overflow tab [2]. The display demand asks for N×perSlot of the
        --- given item so Phase 1/2/3 do not disturb the overflow contents
        --- (unless the test deliberately sets up eviction).
        local function emptyDisplayOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        it("is idempotent when overflow is already sorted", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 5 },
                    [2] = { itemID = 100, count = 3 },
                    [3] = { itemID = 200, count = 10 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            assert.equals(0, #plan.ops)
        end)

        it("consolidates scattered same-item stacks into contiguous group", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1]  = { itemID = 100, count = 5 },
                    [5]  = { itemID = 100, count = 3 },
                    [10] = { itemID = 200, count = 8 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            assert.is_true(#plan.ops > 0)
            local final = applyPlan(snap, plan)
            -- Slot 1: item 100 count 5 (bigger stack of 100 first).
            -- Slot 2: item 100 count 3.
            -- Slot 3: item 200 count 8.
            assert.is_not_nil(final[2][1]); assert.equals(100, final[2][1].itemID); assert.equals(5, final[2][1].count)
            assert.is_not_nil(final[2][2]); assert.equals(100, final[2][2].itemID); assert.equals(3, final[2][2].count)
            assert.is_not_nil(final[2][3]); assert.equals(200, final[2][3].itemID); assert.equals(8, final[2][3].count)
            for s = 4, 10 do
                assert.is_nil(final[2][s], "expected overflow slot " .. s .. " to be empty")
            end
        end)

        it("closes gaps in the overflow tab", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 5 },
                    [7] = { itemID = 200, count = 8 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            assert.is_true(#plan.ops > 0)
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[2][1]); assert.equals(100, final[2][1].itemID); assert.equals(5, final[2][1].count)
            assert.is_not_nil(final[2][2]); assert.equals(200, final[2][2].itemID); assert.equals(8, final[2][2].count)
            assert.is_nil(final[2][3])
            assert.is_nil(final[2][7])
        end)

        it("breaks a two-stack swap cycle via a same-tab pivot", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 200, count = 5 },
                    [2] = { itemID = 100, count = 5 },
                    -- slots 3..98 empty — pivot available.
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            assert.is_true(#plan.ops >= 3, "expected at least 3 ops (pivot + 2 moves)")
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[2][1]); assert.equals(100, final[2][1].itemID); assert.equals(5, final[2][1].count)
            assert.is_not_nil(final[2][2]); assert.equals(200, final[2][2].itemID); assert.equals(5, final[2][2].count)
        end)

        it("sorts overflow after evicting a foreign item from a display tab", function()
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 999, count = 3 }, -- foreign, will spill to overflow
                },
                [2] = {
                    [5] = { itemID = 500, count = 4 }, -- scattered pre-existing stack
                },
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
            -- Foreign 999 evicted from display.
            assert.is_true(final[1][2] == nil or final[1][2].itemID == 100,
                "expected display slot 2 to be empty or filled with 100")
            -- Overflow compacted: item 500 first (lower itemID), then 999.
            assert.is_not_nil(final[2][1]); assert.equals(500, final[2][1].itemID); assert.equals(4, final[2][1].count)
            assert.is_not_nil(final[2][2]); assert.equals(999, final[2][2].itemID); assert.equals(3, final[2][2].count)
            assert.is_nil(final[2][3])
            assert.is_nil(final[2][5])
        end)

        it("is a no-op when no overflow tab is defined", function()
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 20 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab(
                        { [100] = { slots = 1, perSlot = 20 } },
                        { [1] = 100 }
                    ),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.equals(0, #plan.ops)
            assert.is_nil(plan.overflowTab)
            assert.same({}, plan.overflowTabs)
        end)

        it("orders same-item stacks by count DESC (bigger stack first)", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 3 },
                    [5] = { itemID = 100, count = 10 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[2][1]); assert.equals(100, final[2][1].itemID); assert.equals(10, final[2][1].count)
            assert.is_not_nil(final[2][2]); assert.equals(100, final[2][2].itemID); assert.equals(3, final[2][2].count)
            assert.is_nil(final[2][3])
        end)

        ----------------------------------------------------------------
        -- Phase 4: partial-stack merging (v0.30.5)
        ----------------------------------------------------------------

        it("merges two partial stacks of one item into a single stack when sum < maxStack", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 100 },
                    [5] = { itemID = 100, count = 60 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[2][1])
            assert.equals(100, final[2][1].itemID)
            assert.equals(160, final[2][1].count)
            assert.is_nil(final[2][2])
            assert.is_nil(final[2][3])
            assert.is_nil(final[2][5])
        end)

        it("produces [full, partial] for three partials summing past one max stack", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 160 },
                    [5] = { itemID = 100, count = 160 },
                    [7] = { itemID = 100, count = 100 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            assert.equals(200, final[2][1].count)
            assert.equals(200, final[2][2].count)
            assert.equals(20,  final[2][3].count)
            for s = 4, 10 do
                assert.is_nil(final[2][s], "expected slot " .. s .. " empty")
            end
            -- Total preserved.
            local total = final[2][1].count + final[2][2].count + final[2][3].count
            assert.equals(420, total)
        end)

        it("is idempotent on a canonical [full, full, partial] run", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 200 },
                    [2] = { itemID = 100, count = 200 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            assert.equals(0, #plan.ops)
        end)

        it("falls back to grouping (no merge) when maxStack is unknown", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 100 },
                    [5] = { itemID = 100, count = 60 },
                },
            })
            -- Empty override map: getMaxStack returns nil for item 100.
            local opts = { maxStackByItem = {} }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            -- Two stacks remain, packed contiguously, count DESC.
            assert.equals(100, final[2][1].itemID); assert.equals(100, final[2][1].count)
            assert.equals(100, final[2][2].itemID); assert.equals(60,  final[2][2].count)
            assert.is_nil(final[2][3])
        end)

        it("merges only items with known maxStack and groups the rest", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 100 },
                    [2] = { itemID = 100, count = 60 },
                    [5] = { itemID = 200, count = 5 },
                    [6] = { itemID = 200, count = 3 },
                },
            })
            -- Only item 100 has a known maxStack. Item 200 should remain unmerged.
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            -- Item 100 collapsed into a single stack of 160 at slot 1.
            assert.equals(100, final[2][1].itemID); assert.equals(160, final[2][1].count)
            -- Item 200's two partials remain, count DESC, contiguous after item 100.
            assert.equals(200, final[2][2].itemID); assert.equals(5, final[2][2].count)
            assert.equals(200, final[2][3].itemID); assert.equals(3, final[2][3].count)
            assert.is_nil(final[2][4])
        end)

        it("handles distinct per-item maxStacks in the same overflow tab", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 150 },
                    [2] = { itemID = 100, count = 60 },
                    [4] = { itemID = 200, count = 700 },
                    [5] = { itemID = 200, count = 400 },
                },
            })
            local opts = {
                maxStackByItem = { [100] = 200, [200] = 1000 },
            }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            -- Item 100: 150+60=210 → [200, 10] (its 200 cap).
            assert.equals(100, final[2][1].itemID); assert.equals(200, final[2][1].count)
            assert.equals(100, final[2][2].itemID); assert.equals(10,  final[2][2].count)
            -- Item 200: 700+400=1100 → [1000, 100] (its 1000 cap).
            assert.equals(200, final[2][3].itemID); assert.equals(1000, final[2][3].count)
            assert.equals(200, final[2][4].itemID); assert.equals(100,  final[2][4].count)
            assert.is_nil(final[2][5])
        end)

        it("never merges items with maxStack == 1 (uniques)", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 999, count = 1 },
                    [5] = { itemID = 999, count = 1 },
                },
            })
            local opts = { maxStackByItem = { [999] = 1 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            local final = applyPlan(snap, plan)
            -- Two separate stacks of 1, packed contiguously.
            assert.equals(999, final[2][1].itemID); assert.equals(1, final[2][1].count)
            assert.equals(999, final[2][2].itemID); assert.equals(1, final[2][2].count)
            assert.is_nil(final[2][3])
        end)

        it("applyPlan helper merges counts when an op targets an occupied same-item slot", function()
            -- Direct sanity check for the test simulator used by the merge cases above.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 50 },
                    [5] = { itemID = 100, count = 30 },
                },
            })
            local fakePlan = {
                ops = {
                    { op = "move", srcTab = 2, srcSlot = 5, dstTab = 2, dstSlot = 3,
                      itemID = 100, count = 30 },
                },
            }
            local final = applyPlan(snap, fakePlan)
            assert.is_not_nil(final[2][3])
            assert.equals(100, final[2][3].itemID)
            assert.equals(80, final[2][3].count)
            assert.is_nil(final[2][5])
        end)

        ----------------------------------------------------------------
        -- Phase 0 + Phase 1B partial-targeting (overflow capacity)
        ----------------------------------------------------------------

        it("Phase 0 frees a slot that Phase 1B then uses for an unrelated supply", function()
            -- Overflow holds four 50-count partials of A (max 200) plus
            -- a foreign B sitting in a non-overflow display tab. Phase 0
            -- should merge A into a single 200-stack at slot 1, freeing
            -- slots 2-4 so Phase 1B can place B at slot 2.
            local snap = snapshot({
                [1] = {
                    [3] = { itemID = 200, count = 30 }, -- foreign B
                },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                    [2] = { itemID = 100, count = 50 },
                    [3] = { itemID = 100, count = 50 },
                    [4] = { itemID = 100, count = 50 },
                },
            })
            -- Display tab demands NOTHING — B has no demand → spills to overflow.
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 200, [200] = 200 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan)
            -- Slot 1: full stack of A.
            assert.is_not_nil(final[2][1])
            assert.equals(100, final[2][1].itemID)
            assert.equals(200, final[2][1].count)
            -- Slot 2: foreign B routed to slot freed by Phase 0.
            assert.is_not_nil(final[2][2])
            assert.equals(200, final[2][2].itemID)
            assert.equals(30, final[2][2].count)
            -- Slots 3+: empty.
            assert.is_nil(final[2][3])
            assert.is_nil(final[2][4])
        end)

        it("Phase 1B tops up an existing same-item partial in overflow", function()
            -- Existing A:50@1 in overflow with capacity for 150 more.
            -- An incoming A:30 supply from a non-overflow tab should land
            -- in slot 1 (top up) rather than extending into a new slot.
            local snap = snapshot({
                [1] = {
                    [5] = { itemID = 100, count = 30 },
                },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan)
            -- Slot 1 of overflow now holds 80 A.
            assert.is_not_nil(final[2][1])
            assert.equals(100, final[2][1].itemID)
            assert.equals(80, final[2][1].count)
            -- No new slot 2 entry.
            assert.is_nil(final[2][2])
        end)

        it("Phase 1B splits a supply across a partial topup and a new slot", function()
            -- Existing A:150@1 (capacity 50). Incoming A:80 supply has to
            -- split: 50 tops up slot 1, 30 lands in first-empty slot 2.
            local snap = snapshot({
                [1] = {
                    [5] = { itemID = 100, count = 80 },
                },
                [2] = {
                    [1] = { itemID = 100, count = 150 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[2][1])
            assert.equals(200, final[2][1].count)
            assert.is_not_nil(final[2][2])
            assert.equals(100, final[2][2].itemID)
            assert.equals(30, final[2][2].count)
        end)

        it("Phase 1B records unplaced when overflow capacity is exhausted", function()
            -- Overflow with one A slot at maxStack 200, and EVERY other
            -- slot occupied by a different item (also at maxStack to keep
            -- topup unavailable). Incoming A:50 → can top up slot 1 with 0
            -- (already at max → capacity 0); other slots blocked. Unplaced.
            local snap = snapshot({
                [1] = {
                    [5] = { itemID = 100, count = 50 },
                },
                [2] = {},
            })
            -- Fill slot 1 with A at max stack, slots 2-98 with foreign full stacks.
            for s = 1, 98 do
                snap[2].slots[s] = {
                    itemLink = Helpers.makeItemLink(s == 1 and 100 or (1000 + s),
                        "Item" .. (s == 1 and 100 or (1000 + s)), 1),
                    count = s == 1 and 200 or 200,
                    slotIndex = s,
                    tabIndex = 2,
                }
            end
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local maxByItem = { [100] = 200 }
            for s = 2, 98 do maxByItem[1000 + s] = 200 end
            local opts = { maxStackByItem = maxByItem }
            local plan = GBL:PlanSort(snap, layout, opts)
            -- A:50 from display has no destination — unplaced.
            assert.is_true(#plan.unplaced > 0)
            local found = false
            for _, u in ipairs(plan.unplaced) do
                if u.itemID == 100 and u.count == 50 then found = true end
            end
            assert.is_true(found, "expected an unplaced entry for the 50 A supply")
        end)

        it("Phase 0 + Phase 1B together: pre-merge frees slots, partial topped up", function()
            -- Overflow [A:50@1, A:50@2, A:50@3] (total 150). Display has
            -- A:200 supply (a single stack). Phase 0 merges to A:150@1.
            -- Phase 1B: top up slot 1 with 50 (capacity), then 150 spills
            -- to first-empty slot 2.
            local snap = snapshot({
                [1] = {
                    [5] = { itemID = 100, count = 200 },
                },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                    [2] = { itemID = 100, count = 50 },
                    [3] = { itemID = 100, count = 50 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan)
            -- Slot 1 full. Slot 2 holds the residual.
            assert.is_not_nil(final[2][1])
            assert.equals(200, final[2][1].count)
            assert.is_not_nil(final[2][2])
            assert.equals(100, final[2][2].itemID)
            assert.equals(150, final[2][2].count)
        end)

        it("cold cache: overflow with two 50-stacks of A and unset maxStack falls back", function()
            -- opts.maxStackByItem is empty so Phase 0 skips merging A.
            -- Phase 1B's pickOverflowSlot treats unknown-maxStack slots as
            -- capacity=0 (no top-up). An A spill extends into a new slot.
            local snap = snapshot({
                [1] = {
                    [5] = { itemID = 100, count = 30 },
                },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                    [2] = { itemID = 100, count = 50 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local opts = { maxStackByItem = {} }
            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan)
            -- Slots 1 and 2 retain their 50-count A stacks.
            -- Phase 4 position-compaction may reorder by count DESC, but
            -- since all three A stacks have the same count (50, 50, 30)
            -- they pack as [50, 50, 30].
            local total = 0
            for s = 1, 98 do
                if final[2][s] and final[2][s].itemID == 100 then
                    total = total + final[2][s].count
                end
            end
            assert.equals(130, total) -- 50 + 50 + 30
        end)

        it("idempotent on canonical merged + compacted overflow", function()
            -- [A:200@1, A:200@2, A:20@3] is the canonical post-Phase-0
            -- post-Phase-4 state. Re-running PlanSort emits zero ops.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 200 },
                    [2] = { itemID = 100, count = 200 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            assert.equals(0, #plan.ops)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Multiple overflow tabs (#57): classification, routing order, Phase 0
    -- ------------------------------------------------------------------
    describe("multiple overflow tabs: classification and Phase 0", function()
        it("publishes plan.overflowTabs in tab order with overflowTab as its first entry", function()
            local snap = snapshot({ [1] = {}, [2] = {}, [5] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.same({ 2, 5 }, plan.overflowTabs)
            assert.equals(2, plan.overflowTab)
        end)

        it("orders plan.overflowTabs by overflowPriority when set", function()
            local snap = snapshot({ [1] = {}, [2] = {}, [5] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = { mode = "overflow", overflowPriority = 1 },
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.same({ 5, 2 }, plan.overflowTabs)
            assert.equals(5, plan.overflowTab)
        end)

        it("Phase 0 merges partials within each overflow tab and never pours across tabs", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 30 },
                    [2] = { itemID = 100, count = 30 },
                },
                [5] = {
                    [1] = { itemID = 100, count = 40 },
                    [2] = { itemID = 100, count = 20 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 60 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(2, #plan.ops)
            for _, op in ipairs(plan.ops) do
                assert.equals(op.srcTab, op.dstTab,
                    "overflow-internal op crossed tabs: " .. op.srcTab .. "->" .. op.dstTab)
            end
            assert.equals(2, plan.diag.phase0Merges)
            assert.equals(2, plan.diag.phase0SlotsFreed)
            local final = applyPlan(snap, plan)
            assert.equals(60, final[2][1].count)
            assert.is_nil(final[2][2])
            assert.equals(60, final[5][1].count)
            assert.is_nil(final[5][2])
        end)

        -- Build a full overflow tab: n stacks of itemID at count, slots 1..n.
        local function fullTab(itemID, count, n)
            local t = {}
            for s = 1, (n or 98) do
                t[s] = { itemID = itemID, count = count }
            end
            return t
        end

        it("spills to the first routing tab and leaves the second untouched", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = {},
                [5] = {},
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout, { maxStackByItem = { [999] = 10 } })
            assert.equals(1, #plan.ops)
            assert.equals(2, plan.ops[1].dstTab)
            for _, op in ipairs(plan.ops) do
                assert.is_not.equals(5, op.dstTab)
                assert.is_not.equals(5, op.srcTab)
            end
        end)

        it("spills into the second overflow tab when the first is full", function()
            -- Tab 5 is absent from the snapshot entirely: the cold-tab
            -- seeding loop must still offer it as a destination.
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = fullTab(200, 200),
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [200] = 200, [999] = 10 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(0, #plan.unplaced)
            local final = applyPlan(snap, plan)
            assert.is_not_nil(final[5], "expected tab 5 to receive the spill")
            assert.is_not_nil(final[5][1])
            assert.equals(999, final[5][1].itemID)
            assert.equals(5, final[5][1].count)
        end)

        it("tab-major: a first-empty in the first tab beats a topup in the second", function()
            -- Deliberate design (#57): all four placement tiers run in tab A
            -- before any tier in tab B, because routing priority means
            -- "fill A first", even at the cost of a cross-tab partial.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
                [5] = { [1] = { itemID = 100, count = 30 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout, { maxStackByItem = { [100] = 60 } })
            local spill
            for _, op in ipairs(plan.ops) do
                if op.srcTab == 1 then spill = op end
            end
            assert.is_not_nil(spill, "expected the display stack to spill")
            assert.equals(2, spill.dstTab)
            assert.equals(20, spill.count)
        end)

        it("splits one supply across the tab boundary: topup in A, first-empty in B", function()
            -- Tab 2 is canonical and nearly full: item 100 partial at slot 1
            -- (capacity 10), item 200 full stacks at slots 2-98. The 30-count
            -- supply tops up 10 in tab 2 and overflows 20 into tab 5.
            local tab2 = { [1] = { itemID = 100, count = 50 } }
            for s = 2, 98 do
                tab2[s] = { itemID = 200, count = 200 }
            end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 30 } },
                [2] = tab2,
                [5] = {},
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 60, [200] = 200 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(0, #plan.unplaced)
            assert.equals(2, #plan.ops)
            assert.equals(1, plan.diag.phase1bTopup)
            assert.equals(1, plan.diag.phase1bFirstEmpty)
            local final = applyPlan(snap, plan)
            assert.equals(60, final[2][1].count)
            assert.equals(100, final[5][1].itemID)
            assert.equals(20, final[5][1].count)
        end)

        it("reports overflow-full only when every overflow tab is full", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = fullTab(200, 200),
                [5] = fullTab(300, 200),
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [200] = 200, [300] = 200, [999] = 10 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(1, #plan.unplaced)
            assert.equals(GBL._sortPlannerReasons.OVERFLOW_FULL, plan.unplaced[1].reason)
        end)

        it("still reports no-overflow-defined when the layout has no overflow tab", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
            })
            local layout = {
                tabs = { [1] = displayTab({}, {}) },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.equals(1, #plan.unplaced)
            assert.equals(GBL._sortPlannerReasons.NO_OVERFLOW_DEFINED, plan.unplaced[1].reason)
        end)

        it("pulls a demand deterministically from two overflow tabs by (tab, slot)", function()
            local snap = snapshot({
                [1] = {},
                [2] = { [3] = { itemID = 100, count = 20 } },
                [5] = { [3] = { itemID = 100, count = 20 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 20 } }, { [1] = 100 }),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout, { maxStackByItem = { [100] = 20 } })
            local fill
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 1 then fill = op end
            end
            assert.is_not_nil(fill, "expected a fill op into the display tab")
            assert.equals(2, fill.srcTab)
            assert.equals(3, fill.srcSlot)
        end)

        it("cold cache across two tabs: unknown maxStack extends in the first tab, totals preserved", function()
            local snap = snapshot({
                [1] = { [5] = { itemID = 100, count = 30 } },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                    [2] = { itemID = 100, count = 50 },
                },
                [5] = { [1] = { itemID = 100, count = 50 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout, { maxStackByItem = {} })
            local final = applyPlan(snap, plan)
            local total = 0
            for _, t in ipairs({ 2, 5 }) do
                for s = 1, 98 do
                    if final[t] and final[t][s] and final[t][s].itemID == 100 then
                        total = total + final[t][s].count
                    end
                end
            end
            assert.equals(180, total)
            assert.is_true(final[1][5] == nil, "display straggler should have spilled")
        end)

        it("finds a pivot in the second overflow tab when the first is full", function()
            -- Same fully-claimed-display 2-cycle as the single-tab pivot
            -- fallback test, but overflow tab 2 is completely full, so the
            -- pivot must come from overflow tab 5.
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
                [2] = fullTab(300, 200),
                [5] = {},
            })
            local layout = {
                tabs = {
                    [1] = displayTab(items, slotOrder),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout, { maxStackByItem = { [300] = 200 } })
            local touchedSecond = false
            for _, op in ipairs(plan.ops) do
                if (op.itemID == 100 or op.itemID == 200)
                   and (op.srcTab == 5 or op.dstTab == 5) then
                    touchedSecond = true
                end
            end
            assert.is_true(touchedSecond, "tab 5 should serve as the pivot")
            local final = applyPlan(snap, plan)
            assert.equals(100, final[1][1].itemID)
            assert.equals(200, final[1][2].itemID)
            for _, u in ipairs(plan.unplaced) do
                assert.is_not.equals(GBL._sortPlannerReasons.CYCLE_NO_PIVOT, u.reason)
            end
        end)

        it("packs each overflow tab into its own contiguous run, never across tabs", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 5 },
                    [7] = { itemID = 200, count = 8 },
                },
                [5] = {
                    [4] = { itemID = 150, count = 6 },
                    [9] = { itemID = 175, count = 4 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = {
                [100] = 20, [200] = 20, [150] = 20, [175] = 20,
            } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(4, #plan.ops)
            assert.equals(4, plan.diag.phase4PositionShifts)
            for _, op in ipairs(plan.ops) do
                assert.equals(op.srcTab, op.dstTab,
                    "Phase 4 op crossed tabs: " .. op.srcTab .. "->" .. op.dstTab)
            end
            local final = applyPlan(snap, plan)
            assert.equals(100, final[2][1].itemID)
            assert.equals(200, final[2][2].itemID)
            assert.is_nil(final[2][3]); assert.is_nil(final[2][7])
            assert.equals(150, final[5][1].itemID)
            assert.equals(175, final[5][2].itemID)
            assert.is_nil(final[5][4]); assert.is_nil(final[5][9])

            -- Replanning on the packed result is a no-op (idempotence
            -- composed across tabs).
            local desc = {}
            for t, slots in pairs(final) do
                desc[t] = {}
                for s, v in pairs(slots) do
                    desc[t][s] = { itemID = v.itemID, count = v.count }
                end
            end
            local plan2 = GBL:PlanSort(snapshot(desc), layout, opts)
            assert.equals(0, #plan2.ops)
        end)

        it("is idempotent on a canonical two-tab overflow state", function()
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 5 },
                    [2] = { itemID = 100, count = 3 },
                    [3] = { itemID = 200, count = 10 },
                },
                [5] = {
                    [1] = { itemID = 150, count = 8 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.equals(0, #plan.ops)
        end)

        it("leaves already-packed stock in a later overflow tab alone (no rebalancing)", function()
            local snap = snapshot({
                [1] = {},
                [2] = {},
                [5] = {
                    [1] = { itemID = 100, count = 60 },
                    [2] = { itemID = 100, count = 15 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 60 } }
            local plan = GBL:PlanSort(snap, layout, opts)
            assert.equals(0, #plan.ops)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Overflow tabs outside scan coverage (#137)
    --
    -- The scanner skips tabs the player's rank cannot view, so a hidden
    -- overflow tab is absent from the snapshot and the cold-tab seeding
    -- loop offers it as 98 free slots. The plan then routes into a tab the
    -- client cannot deposit into, every move fails, the replan is blind in
    -- the same way, and the run ends as "converged, N unresolved".
    --
    -- opts.coverage is what makes "not scanned" distinguishable from
    -- "scanned and empty". Absent, nothing changes.
    -- ------------------------------------------------------------------
    describe("overflow tabs outside scan coverage", function()
        local function fullTab(itemID, count, n)
            local t = {}
            for s = 1, (n or 98) do
                t[s] = { itemID = itemID, count = count }
            end
            return t
        end

        --- Tab 2 and tab 5 both declared overflow, display tab 1 empty.
        local function twoOverflowLayout()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                    [5] = overflow(),
                },
            }
        end

        local MAXSTACKS = { [200] = 200, [999] = 10 }

        it("does not route into an overflow tab the scan could not see", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = fullTab(200, 200),
            })
            local opts = { maxStackByItem = MAXSTACKS,
                           coverage = { viewableTabs = { 1, 2 } } }

            local plan = GBL:PlanSort(snap, twoOverflowLayout(), opts)

            for _, op in ipairs(plan.ops) do
                assert.is_not.equals(5, op.dstTab,
                    "planned a move into a tab the scan never saw")
            end
            assert.equals(0, #plan.ops)
            assert.equals(1, #plan.unplaced)
            assert.equals(1, plan.unplaced[1].tabIndex)
            assert.equals(1, plan.unplaced[1].slotIndex)
            assert.equals(5, plan.unplaced[1].count)
            assert.equals(GBL._sortPlannerReasons.OVERFLOW_FULL,
                plan.unplaced[1].reason)
            assert.same({ 2 }, plan.overflowTabs)
            assert.equals(2, plan.overflowTab)
            assert.same({ 5 }, plan.unviewableOverflowTabs)
        end)

        -- Every declared overflow tab hidden is a different fact from a
        -- layout that declares none, and the player needs to know which:
        -- one is fixed by a rank change, the other by editing the layout.
        it("reports overflow-unviewable when every overflow tab is hidden", function()
            local snap = snapshot({ [1] = { [1] = { itemID = 999, count = 5 } } })
            local layout = {
                tabs = { [1] = displayTab({}, {}), [5] = overflow() },
            }
            local opts = { maxStackByItem = MAXSTACKS,
                           coverage = { viewableTabs = { 1 } } }

            local plan = GBL:PlanSort(snap, layout, opts)

            assert.equals(0, #plan.ops)
            assert.equals(1, #plan.unplaced)
            assert.equals(GBL._sortPlannerReasons.OVERFLOW_UNVIEWABLE,
                plan.unplaced[1].reason)
            assert.same({}, plan.overflowTabs)
            assert.is_nil(plan.overflowTab)
            assert.same({ 5 }, plan.unviewableOverflowTabs)
        end)

        -- Ascending by tab index, not routing order: the message is about
        -- which tabs are invisible, and a player looking for tab 5 in the
        -- bank frame reads it by number.
        it("reports the hidden tabs by index, not in routing order", function()
            local snap = snapshot({ [1] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [5] = overflow(),
                    [7] = { mode = "overflow", overflowPriority = 1 },
                },
            }
            local opts = { coverage = { viewableTabs = { 1 } } }

            local plan = GBL:PlanSort(snap, layout, opts)

            assert.same({ 5, 7 }, plan.unviewableOverflowTabs)
        end)

        it("routes into a covered tab the scan found empty", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = fullTab(200, 200),
                [5] = {},
            })
            local opts = { maxStackByItem = MAXSTACKS,
                           coverage = { viewableTabs = { 1, 2, 5 } } }

            local plan = GBL:PlanSort(snap, twoOverflowLayout(), opts)

            assert.equals(0, #plan.unplaced)
            assert.same({}, plan.unviewableOverflowTabs)
            local final = applyPlan(snap, plan)
            assert.equals(999, final[5][1].itemID)
            assert.equals(5, final[5][1].count)
        end)

        -- No coverage means no filter. That is what every existing caller
        -- does today, and it is what keeps a layout declaring a tab nobody
        -- has scanned yet usable.
        it("seeds an unscanned tab as before when no coverage is supplied", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 999, count = 5 } },
                [2] = fullTab(200, 200),
            })

            local plan = GBL:PlanSort(snap, twoOverflowLayout(),
                { maxStackByItem = MAXSTACKS })

            assert.equals(0, #plan.unplaced)
            assert.same({ 2, 5 }, plan.overflowTabs)
            assert.same({}, plan.unviewableOverflowTabs)
            local final = applyPlan(snap, plan)
            assert.equals(999, final[5][1].itemID)
        end)

        -- A scan that ran and saw nothing is coverage, not the absence of
        -- it. Reading an empty list as "no coverage" would put a client
        -- with no tab visibility straight back on the seeding path.
        it("treats an empty coverage list as coverage of nothing", function()
            local snap = snapshot({ [1] = { [1] = { itemID = 999, count = 5 } } })
            local layout = {
                tabs = { [1] = displayTab({}, {}), [5] = overflow() },
            }
            local opts = { maxStackByItem = MAXSTACKS,
                           coverage = { viewableTabs = {} } }

            local plan = GBL:PlanSort(snap, layout, opts)

            assert.equals(0, #plan.ops)
            assert.same({}, plan.overflowTabs)
            assert.same({ 5 }, plan.unviewableOverflowTabs)
        end)

        it("exports the reason code", function()
            assert.equals("overflow-unviewable",
                GBL._sortPlannerReasons.OVERFLOW_UNVIEWABLE)
        end)

        -- The invalid-layout early return hands back the plan literal, so
        -- the field belongs on it too. A reader that walks the list would
        -- otherwise error on the one path that produces no plan at all.
        it("carries the field on the invalid-layout early return", function()
            local plan = GBL:PlanSort({}, nil)
            assert.same({}, plan.unviewableOverflowTabs)
        end)

        -- Phase 3 carries its own copy of the no-overflow branch. Reaching
        -- it needs a blocker that Phase 1B already flagged and Phase 2 then
        -- parked in an unclaimed display slot, which Phase 3 finds
        -- unflagged at its new position.
        --
        -- The same stack is reported twice, once by 1B at its old slot and
        -- once here at the pivot slot. That is pre-existing behaviour under
        -- no-overflow-defined and is not frozen by this spec: only the
        -- reason on the Phase 3 entry is.
        it("uses the same reason at the Phase 3 sweep", function()
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 500, count = 5 },
                    [2] = { itemID = 100, count = 10 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 10 } },
                                     { [1] = 100 }),
                    [5] = overflow(),
                },
            }
            local opts = { maxStackByItem = { [100] = 10, [500] = 10 },
                           coverage = { viewableTabs = { 1 } } }

            local plan = GBL:PlanSort(snap, layout, opts)

            assert.equals(1, plan.diag.phase2Pivots,
                "fixture no longer reaches Phase 3 through a pivot")
            local swept
            for _, u in ipairs(plan.unplaced) do
                if u.slotIndex == 3 then swept = u end
            end
            assert.is_not_nil(swept,
                "expected the pivoted blocker to be reported at its new slot")
            assert.equals(500, swept.itemID)
            assert.equals(GBL._sortPlannerReasons.OVERFLOW_UNVIEWABLE,
                swept.reason)
        end)

        describe("plan line", function()
            local function findLine(needle)
                for _, e in ipairs(GBL:GetLog("sort") or {}) do
                    local m = e.message or ""
                    if m:find(needle, 1, true) then return m end
                end
                return nil
            end

            it("names the hidden tabs", function()
                local snap = snapshot({
                    [1] = { [1] = { itemID = 999, count = 5 } },
                    [2] = {},
                })
                GBL:PlanSort(snap, twoOverflowLayout(), {
                    maxStackByItem = MAXSTACKS,
                    coverage = { viewableTabs = { 1, 2 } },
                })

                assert.is_not_nil(findLine("unviewable:T5"),
                    "the plan line should name the tab it routed around")
            end)

            -- Present even when nothing was hidden, so a capture can tell
            -- "coverage checked, all tabs visible" from "coverage absent".
            it("says none when coverage hid nothing", function()
                local snap = snapshot({ [1] = {}, [2] = {}, [5] = {} })
                GBL:PlanSort(snap, twoOverflowLayout(), {
                    coverage = { viewableTabs = { 1, 2, 5 } },
                })

                assert.is_not_nil(findLine("unviewable:none"))
            end)

            it("omits the term entirely when no coverage was supplied", function()
                local snap = snapshot({ [1] = {}, [2] = {}, [5] = {} })
                GBL:PlanSort(snap, twoOverflowLayout(), {})

                assert.is_nil(findLine("unviewable:"))
            end)
        end)
        -- SummarizeSortPlan is what /gbl sortpreview prints, line by line.
        -- The warning belongs there rather than in PrintSortPreview so the
        -- sentence has one home and one set of specs.
        describe("summary lines", function()
            it("names a hidden tab after the moves", function()
                local plan = {
                    ops = { { op = "move", srcTab = 1, srcSlot = 1,
                              dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
                    deficits = {}, unplaced = {},
                    unviewableOverflowTabs = { 5 },
                }
                local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")

                assert.is_truthy(blob:find("T5", 1, true))
                assert.is_truthy(blob:find("unviewable overflow tab", 1, true))
            end)

            -- An otherwise empty plan still has something to say. Without
            -- the warning it reads as "nothing to do" while a whole tab is
            -- invisible, which is the misdiagnosis this issue is about.
            it("names a hidden tab on a plan with nothing else in it", function()
                local plan = {
                    ops = {}, deficits = {}, unplaced = {},
                    unviewableOverflowTabs = { 5 },
                }
                local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")

                assert.is_truthy(blob:find("no moves needed", 1, true))
                assert.is_truthy(blob:find("unviewable overflow tab", 1, true))
            end)

            it("says nothing when no tab was hidden", function()
                local plan = { ops = {}, deficits = {}, unplaced = {},
                               unviewableOverflowTabs = {} }
                local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")
                assert.is_nil(blob:find("unviewable", 1, true))
            end)

            it("tolerates a plan built before the field existed", function()
                local plan = { ops = {}, deficits = {}, unplaced = {} }
                local lines = GBL:SummarizeSortPlan(plan)
                assert.is_true(#lines >= 1)
                assert.is_nil(table.concat(lines, "\n"):find("unviewable", 1, true))
            end)
        end)

    end)

    -- ------------------------------------------------------------------
    -- Unplaced reason text (#45)
    --
    -- Two surfaces render plan.unplaced as prose: SummarizeSortPlan, whose
    -- lines /gbl sortpreview prints, and the Sort tab's Unplaced list. Both
    -- read one mapping, so they cannot drift apart the way PrintSortPreview
    -- and the Sort tab did in #137. The sort log is a third renderer and
    -- deliberately keeps the raw code; see the REASON_TEXT header comment.
    -- ------------------------------------------------------------------
    describe("unplaced reason text (#45)", function()
        it("gives every shipped reason code its own words", function()
            local seen = {}
            for _, code in pairs(GBL._sortPlannerReasons) do
                local text = GBL:SortReasonText(code)
                assert.is_string(text)
                assert.is_true(#text > 0)
                assert.is_nil(text:find(code, 1, true),
                    "the text for " .. code .. " should read as words, not echo the code")
                assert.is_nil(seen[text],
                    "two reason codes share the same text: " .. text)
                seen[text] = code
            end
        end)

        -- #150 would add a sixth code. A code this table has not learned
        -- yet must not blank the row or raise; it falls back to the code.
        it("renders an unrecognised code rather than dropping it", function()
            assert.equals("over-stack-demand", GBL:SortReasonText("over-stack-demand"))
        end)

        it("tolerates an entry with no reason recorded", function()
            local text = GBL:SortReasonText(nil)
            assert.is_string(text)
            assert.is_true(#text > 0)
        end)

        it("carries the reason onto the summary line", function()
            local R = GBL._sortPlannerReasons
            local plan = { ops = {}, deficits = {}, unplaced = {
                { tabIndex = 2, slotIndex = 7, itemID = 100, count = 5,
                  reason = R.OVERFLOW_UNVIEWABLE },
            } }
            local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")

            assert.is_truthy(blob:find("T2/7", 1, true))
            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_UNVIEWABLE), 1, true))
        end)

        -- The bag tail says what happens to the items; the reason says why.
        -- Both belong on the line and neither replaces the other.
        it("keeps the stays-in-bags tail alongside the reason", function()
            local R = GBL._sortPlannerReasons
            local plan = { ops = {}, deficits = {}, unplaced = {
                { tabIndex = -1, slotIndex = 5, itemID = 100, count = 3,
                  reason = R.OVERFLOW_FULL },
            } }
            local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")

            assert.is_truthy(blob:find("stays in bags", 1, true))
            assert.is_truthy(blob:find("Bag0/5", 1, true))
            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_FULL), 1, true))
        end)

        it("distinguishes two entries that differ only by reason", function()
            local R = GBL._sortPlannerReasons
            local plan = { ops = {}, deficits = {}, unplaced = {
                { tabIndex = 2, slotIndex = 7, itemID = 100, count = 5,
                  reason = R.OVERFLOW_FULL },
                { tabIndex = 3, slotIndex = 9, itemID = 100, count = 5,
                  reason = R.OVERFLOW_UNVIEWABLE },
            } }
            local blob = table.concat(GBL:SummarizeSortPlan(plan), "\n")

            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_FULL), 1, true))
            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_UNVIEWABLE), 1, true))
        end)
    end)

    -- ------------------------------------------------------------------
    -- Per-phase diagnostic counters (v0.30.5)
    -- ------------------------------------------------------------------
    describe("plan.diag counters", function()
        local function emptyDisplayOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        it("empty plan exposes zero counters", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow())
            assert.is_not_nil(plan.diag)
            assert.equals(0, plan.diag.phase0Merges)
            assert.equals(0, plan.diag.phase1aAssignments)
            assert.equals(0, plan.diag.phase1bTopup)
            assert.equals(0, plan.diag.phase1bExtendRight)
            assert.equals(0, plan.diag.phase1bExtendLeft)
            assert.equals(0, plan.diag.phase1bFirstEmpty)
            assert.equals(0, plan.diag.phase1bUnplaced)
            assert.equals(0, plan.diag.phase2Pivots)
            assert.equals(0, plan.diag.phase3Sweeps)
            assert.equals(0, plan.diag.phase4PositionShifts)
            assert.equals(0, plan.diag.demandPinned)
        end)

        it("counts Phase 0 merges and freed slots", function()
            -- Two partials at slots 3 and 5 of overflow, summing to 160 < 200.
            -- Phase 0 emits one merge that drains slot 5 → 1 merge, 1 freed.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [3] = { itemID = 100, count = 100 },
                    [5] = { itemID = 100, count = 60 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            assert.equals(1, plan.diag.phase0Merges)
            assert.equals(1, plan.diag.phase0SlotsFreed)
        end)

        it("counts Phase 1A assignments separately from Phase 1B spills", function()
            -- Demand: tab 1 wants 1×item 100 at slot 1.
            -- Supply: tab 1 already has it at slot 1 (keep) — no Phase 1A
            -- assignment needed for the demand. Tab 1 also has an extra
            -- item 200 at slot 2 that has no demand → Phase 1B spill to overflow.
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 200, count = 5 },
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
            -- 100 is keep-reserved at slot 1, no Phase 1A op.
            assert.equals(0, plan.diag.phase1aAssignments)
            -- 200 spills to overflow as a fresh slot.
            assert.equals(1, plan.diag.phase1bFirstEmpty)
        end)

        it("counts Phase 1B topup vs extend vs first-empty modes", function()
            -- Overflow has item 100 partial at slot 1 (cap=150 left).
            -- Display tab 1 has spare item 100 (50) → topup picks slot 1.
            -- Display tab 1 also has item 200 (5) with no overflow neighbor
            -- → first-empty fallback picks the next free slot.
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 50 },
                    [2] = { itemID = 200, count = 5 },
                },
                [2] = {
                    [1] = { itemID = 100, count = 50 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200, [200] = 20 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            -- 100 from T1/S1 tops up T2/S1 (capacity 150 ≥ 50, single slot).
            assert.equals(1, plan.diag.phase1bTopup)
            -- 200 finds no same-item neighbor → first-empty.
            assert.equals(1, plan.diag.phase1bFirstEmpty)
        end)

        it("records phase1bUnplaced when overflow is full", function()
            -- Overflow tab is fully populated with unique items so neither
            -- topup nor any extension can absorb the spill.
            local overflowSlots = {}
            for s = 1, 98 do
                overflowSlots[s] = { itemID = 1000 + s, count = 1 }
            end
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 5 },
                },
                [2] = overflowSlots,
            })
            local opts = {}
            for s = 1, 98 do opts[1000 + s] = 1 end
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(),
                { maxStackByItem = opts })
            assert.is_true(plan.diag.phase1bUnplaced > 0)
        end)

        it("counts Phase 4 position shifts on a non-canonical overflow", function()
            -- Three same-item full stacks scattered; Phase 4 packs to slots 1-3.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [4] = { itemID = 100, count = 200 },
                    [6] = { itemID = 100, count = 200 },
                    [8] = { itemID = 100, count = 200 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            -- Phase 0 emits no merges (all stacks are full).
            assert.equals(0, plan.diag.phase0Merges)
            -- Phase 4 shifts 3 stacks into slots 1-3.
            assert.equals(3, plan.diag.phase4PositionShifts)
        end)

        it("counts demand origins matching the demandMap", function()
            -- Same setup as the v0.29.17 demandMap test: produces 7 demands
            -- with a known origin distribution.
            local snap = snapshot({ [1] = {}, [2] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab(
                        {
                            [100] = { slots = 1, perSlot = 20 },
                            [200] = { slots = 2, perSlot = 20 },
                            [300] = { slots = 1, perSlot = 20 },
                            [400] = { slots = 1, perSlot = 20 },
                            [500] = { slots = 2, perSlot = 20 },
                        },
                        { [1] = 100, [3] = 200, [4] = 300, [6] = 500 }
                    ),
                    [2] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            -- 4 pinned (1, 3, 4, 6), 1 ext-R (7), 1 ext-L (2), 1 first-empty (5).
            assert.equals(4, plan.diag.demandPinned)
            assert.equals(1, plan.diag.demandExtendRight)
            assert.equals(1, plan.diag.demandExtendLeft)
            assert.equals(1, plan.diag.demandFirstEmpty)
        end)

        it("items-only layout shows seed + extends, not all first-empty", function()
            -- Pass 2b adjacency relabel: with empty slotOrder, the first
            -- demand for an item is "first-empty"; subsequent same-item
            -- demands at adjacent slots become "extend-right". A single
            -- 5-slot item produces 1 first-empty + 4 extend-right (NOT
            -- 5 first-empty as before v0.30.5).
            local snap = snapshot({ [1] = {}, [2] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab(
                        { [100] = { slots = 5, perSlot = 20 } },
                        {}  -- empty slotOrder = items-only mode
                    ),
                    [2] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.equals(0, plan.diag.demandPinned)
            assert.equals(1, plan.diag.demandFirstEmpty)
            assert.equals(4, plan.diag.demandExtendRight)
            assert.equals(0, plan.diag.demandExtendLeft)
            -- demandMap origins on the slots match: slot 1 first-empty,
            -- slots 2-5 extend-right.
            assert.equals("first-empty",  plan.demandMap[1][1].origin)
            for s = 2, 5 do
                assert.equals("extend-right", plan.demandMap[1][s].origin,
                    "slot " .. s)
            end
        end)
    end)

    -- ------------------------------------------------------------------
    -- Max-stack guards in canExecute / applyOpToState (v0.30.5)
    -- ------------------------------------------------------------------
    describe("max-stack guard", function()
        local function emptyDisplayOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        it("canExecute rejects merge that would exceed maxStack", function()
            local state = {
                [2] = {
                    [1] = { itemID = 100, count = 200 },
                    [3] = { itemID = 100, count = 60 },
                },
            }
            local op = {
                srcTab = 2, srcSlot = 3,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 60,
            }
            local function getMaxStack(id) return id == 100 and 200 or nil end
            -- Without guard: same-item dst, would normally pass.
            assert.is_true(GBL._sortPlannerCanExecute(op, state))
            -- With guard: 200 + 60 = 260 > 200 → reject.
            assert.is_false(GBL._sortPlannerCanExecute(op, state, getMaxStack))
        end)

        it("canExecute allows merge that fits within maxStack", function()
            local state = {
                [2] = {
                    [1] = { itemID = 100, count = 100 },
                    [3] = { itemID = 100, count = 60 },
                },
            }
            local op = {
                srcTab = 2, srcSlot = 3,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 60,
            }
            local function getMaxStack(id) return id == 100 and 200 or nil end
            -- 100 + 60 = 160 <= 200 → allow.
            assert.is_true(GBL._sortPlannerCanExecute(op, state, getMaxStack))
        end)

        it("canExecute cold-cache (nil maxStack) preserves prior behavior", function()
            local state = {
                [2] = {
                    [1] = { itemID = 100, count = 200 },
                    [3] = { itemID = 100, count = 60 },
                },
            }
            local op = {
                srcTab = 2, srcSlot = 3,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 60,
            }
            local function getMaxStack() return nil end
            -- maxStack unknown → guard skipped → would-be-over-stack passes.
            assert.is_true(GBL._sortPlannerCanExecute(op, state, getMaxStack))
        end)

        it("applyOpToState asserts when merge would exceed maxStack", function()
            local state = {
                [2] = {
                    [1] = { itemID = 100, count = 200 },
                    [3] = { itemID = 100, count = 60 },
                },
            }
            local op = {
                srcTab = 2, srcSlot = 3,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 60,
            }
            local function getMaxStack(id) return id == 100 and 200 or nil end
            local ok, err = pcall(GBL._sortPlannerApplyOpToState,
                state, op, getMaxStack)
            assert.is_false(ok)
            assert.matches("maxStack", err)
        end)

        it("Phase 4 with same-item full collision produces a clean plan", function()
            -- Two same-item full stacks at S30, S36 in overflow with maxStack
            -- 200. Without the guard, Phase 4 would emit cascading ops that
            -- accumulate to count=400 in working state. With the guard,
            -- canExecute rejects the over-stack merge and greedyDrain
            -- reorders so each move drains into a truly-empty slot. Final
            -- bank state: no stack exceeds 200.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [30] = { itemID = 100, count = 200 },
                    [36] = { itemID = 100, count = 200 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            -- Without this the loop below passes on an empty plan: two stacks
            -- already at max stack satisfy "no slot exceeds 200" whether or
            -- not the packer emitted anything at all (#161). The ceiling
            -- argument is the other half; the simulator stacked without limit
            -- until now, so the guard under test was checked nowhere.
            assert.is_true(#plan.ops > 0, "expected Phase 4 to emit packing ops")
            local final = applyPlan(snap, plan, nil, opts.maxStackByItem)
            for s = 1, 98 do
                local sl = final[2] and final[2][s]
                if sl then
                    assert.is_true(sl.count <= 200,
                        "slot " .. s .. " count=" .. sl.count
                        .. " exceeds maxStack 200")
                end
            end
        end)
    end)

    -- ------------------------------------------------------------------
    -- Op labels (#161)
    -- ------------------------------------------------------------------
    describe("op labels (#161)", function()
        -- Reaching the Phase 3 sweep while overflow is still usable is a
        -- three-way squeeze, which is why no spec had done it before.
        --
        -- Phase 3 only sees a display slot that is occupied, undemanded and
        -- NOT flagged unplaced. Phase 1B hands every non-overflow supply
        -- either an assignment or a recordUnplaced at its own slot, and every
        -- Phase 2 abort flags its source, so the one producer left is
        -- findPivot priority 1 parking a blocker in an unclaimed display slot
        -- without flagging it. For that pivot to happen at all the blocker's
        -- own 1B spill must have failed, which means overflow was full for
        -- its item and tier 1 had no capacity. And for the label to be wrong
        -- tier 1 must have capacity again by Phase 3, and less of it than the
        -- swept stack needs.
        --
        -- rebuildOverflowSlotInfo re-reads state after Phase 2, so a slot
        -- drained during Phase 2 has its capacity back. The rest is that a
        -- demand in a DIFFERENT display tab prefers an overflow source (p=2)
        -- to a cross-tab one (p=3), so it drains the overflow partial of the
        -- very item the blocker is made of.
        --
        -- The filler is item 900 and sorts after both items under test. A
        -- filler that sorts first makes Phase 4 want to move it out of a full
        -- tab, and the abort entries then swamp the assertion.
        local function sweepSnapshot()
            local overflowTab = {
                [1] = { itemID = 700, count = 8 },   -- capacity 2
                [2] = { itemID = 800, count = 1 },
            }
            for s = 3, 98 do
                overflowTab[s] = { itemID = 900, count = 1 }
            end
            return snapshot({
                -- 9 of a max stack of 10, so isWholeStack is false and the
                -- spill walk leaves tier 1 live for it.
                [1] = { [1] = { itemID = 700, count = 9 } },
                [2] = {},
                [5] = overflowTab,
            })
        end

        local function sweepLayout()
            return {
                tabs = {
                    [1] = displayTab({ [800] = { slots = 1, perSlot = 1 } },
                                     { [1] = 800 }),
                    [2] = displayTab({ [700] = { slots = 1, perSlot = 6 } },
                                     { [1] = 700 }),
                    [5] = overflow(),
                },
            }
        end

        local function sweepOpts()
            return { maxStackByItem = { [700] = 10, [800] = 1, [900] = 1 } }
        end

        --- The ops Phase 3 emitted for the pivoted blocker at its new slot.
        local function sweptOps(plan)
            local out = {}
            for _, op in ipairs(plan.ops) do
                if op.srcTab == 1 and op.srcSlot == 2 then
                    out[#out + 1] = op
                end
            end
            return out
        end

        it("labels a Phase 3 sweep that leaves part of the stack a split", function()
            local plan = GBL:PlanSort(sweepSnapshot(), sweepLayout(), sweepOpts())

            assert.equals(1, plan.diag.phase2Pivots,
                "fixture no longer reaches Phase 3 through a pivot")
            assert.equals(2, plan.diag.phase3Sweeps,
                "fixture no longer reaches the Phase 3 tier-1 sweep")

            local swept = sweptOps(plan)
            assert.equals(2, #swept)
            assert.equals(6, swept[1].count,
                "tier 1 should be capped by the partial's capacity")
            assert.equals("split", swept[1].op,
                "a sweep that leaves 1 behind is a split, not a move")
        end)

        it("labels the sweep that does drain its source a move", function()
            local plan = GBL:PlanSort(sweepSnapshot(), sweepLayout(), sweepOpts())
            local swept = sweptOps(plan)
            assert.equals(1, swept[2].count)
            assert.equals("move", swept[2].op)
        end)

        it("labels a pivot op a move", function()
            local plan = GBL:PlanSort(sweepSnapshot(), sweepLayout(), sweepOpts())
            local pivot
            for _, op in ipairs(plan.ops) do
                if op.srcTab == 1 and op.srcSlot == 1
                   and op.dstTab == 1 and op.dstSlot == 2 then
                    pivot = op
                end
            end
            assert.is_not_nil(pivot, "fixture no longer emits a pivot")
            assert.equals(7, pivot.count, "a pivot always carries the whole stack")
            assert.equals("move", pivot.op)
        end)

        -- The invariant aimed at real planner output rather than at a
        -- hand-built plan. This is the half that would have caught the defect
        -- on its own, from any spec that applied this plan.
        it("applyPlan accepts the planner's own sweep plan", function()
            local plan = GBL:PlanSort(sweepSnapshot(), sweepLayout(), sweepOpts())
            local ok, err = pcall(applyPlan, sweepSnapshot(), plan, nil,
                                  sweepOpts().maxStackByItem)
            assert.is_true(ok, tostring(err))
        end)

        -- Hand-built plans rather than PlanSort output: the point is to prove
        -- the simulator rejects a known-bad input, not to re-assert whatever
        -- the planner happens to emit today.
        it("applyPlan rejects an op that says move but leaves its source", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = {},
            })
            local ok, err = pcall(applyPlan, snap, {
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 4 } },
            })
            assert.is_false(ok)
            assert.matches("should be split", err)
        end)

        it("applyPlan rejects an op that says split but drains its source", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = {},
            })
            local ok, err = pcall(applyPlan, snap, {
                ops = { { op = "split", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 10 } },
            })
            assert.is_false(ok)
            assert.matches("should be move", err)
        end)

        it("applyPlan rejects a merge over the item's max stack", function()
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 10 },
                    [2] = { itemID = 100, count = 15 },
                },
            })
            local ok, err = pcall(applyPlan, snap, {
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 1, dstSlot = 2, itemID = 100, count = 10 } },
            }, nil, { [100] = 20 })
            assert.is_false(ok)
            assert.matches("maxStack", err)
        end)

        it("applyPlan accepts a merge landing exactly on the max stack", function()
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 100, count = 5 },
                    [2] = { itemID = 100, count = 15 },
                },
            })
            local final = applyPlan(snap, {
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 1, dstSlot = 2, itemID = 100, count = 5 } },
            }, nil, { [100] = 20 })
            assert.equals(20, final[1][2].count)
            assert.is_nil(final[1][1])
        end)
    end)

    -- ------------------------------------------------------------------
    -- Per-op planner-state stamping (v0.30.5)
    -- ------------------------------------------------------------------
    describe("op.plannerSrcAt / plannerDstAt", function()
        local function emptyDisplayOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        it("captures src state at emit time", function()
            -- Move 20×item 100 from T1/S1 (which holds 20) to overflow T2.
            -- plannerSrcAt should be {itemID=100, count=20}; plannerDstAt
            -- nil because T2 is empty at emit.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
            })
            local layout = {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout)
            assert.is_true(#plan.ops > 0)
            local op = plan.ops[1]
            assert.is_not_nil(op.plannerSrcAt,
                "expected plannerSrcAt to be populated")
            assert.equals(100, op.plannerSrcAt.itemID)
            assert.equals(20, op.plannerSrcAt.count)
            -- dst is empty at emit so plannerDstAt is nil.
            assert.is_nil(op.plannerDstAt)
        end)

        it("captures dst state when planner expects an occupant", function()
            -- Two stacks of item 100 partial in overflow; Phase 0 merge
            -- emits a pour from the smaller into the larger. The dst
            -- (slot 1 holding 100×100) IS occupied at emit, so
            -- plannerDstAt reflects that.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 100 },
                    [3] = { itemID = 100, count = 60 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            assert.is_true(#plan.ops > 0)
            -- The Phase 0 merge op pours from S3 into S1.
            local merge = plan.ops[1]
            assert.equals(2, merge.dstTab)
            assert.equals(1, merge.dstSlot)
            assert.is_not_nil(merge.plannerDstAt)
            assert.equals(100, merge.plannerDstAt.itemID)
            assert.equals(100, merge.plannerDstAt.count)
        end)

        it("planner stamps reflect evolving state across multi-op plans", function()
            -- Three same-item full stacks scattered; Phase 4 packs them.
            -- The planner's working state evolves between ops. A later
            -- op's plannerDstAt should reflect post-prior-ops state.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [4] = { itemID = 100, count = 200 },
                    [6] = { itemID = 100, count = 200 },
                    [8] = { itemID = 100, count = 200 },
                },
            })
            local opts = { maxStackByItem = { [100] = 200 } }
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(), opts)
            -- All ops target T2/S1, T2/S2, T2/S3 from S4/S6/S8. Each dst
            -- starts EMPTY in the snapshot, so plannerDstAt is nil for
            -- each — the planner doesn't expect any occupant at the canonical
            -- positions when it emits these ops.
            for _, op in ipairs(plan.ops) do
                assert.is_nil(op.plannerDstAt,
                    "expected packing dst to be empty at emit")
            end
        end)
    end)

    ------------------------------------------------------------------
    -- #140: Phase 4 packing churn on a near-full overflow tab.
    --
    -- From a live capture: depositing 29 bag stacks took an overflow tab
    -- from 78 to 97 of 98 occupied, and sorting then cascaded for minutes,
    -- with replans coming back LARGER than the pass that had just run and
    -- successive passes shifting in opposite directions.
    --
    -- PlanSort is pure (its only outside read is the guarded GetMaxStack),
    -- so the whole thing reproduces here with no client.
    ------------------------------------------------------------------
    describe("near-full overflow packing (#140)", function()
        -- A few item types with many FULL identical stacks each, scattered so
        -- sorted order differs from slot order. This mirrors a real bank
        -- (dozens of Thalassian Phoenix Oil x20, Light's Potential x200) and
        -- it is the shape that matters: when stacks share an itemID AND a
        -- count, overflowStackOrder falls through to origSlot, so position is
        -- the only thing ordering them. A fixture of DISTINCT items never
        -- reaches that tiebreak and never reproduces the churn.
        local ITEMS = { 241289, 241301, 241309, 243733, 271883 }
        local MAXSTACK = {
            [241289] = 200, [241301] = 200, [241309] = 200,
            [243733] = 20, [271883] = 200,
        }

        local function scatteredOverflow(occupied)
            local slots, k = {}, 3
            for s = 1, occupied do
                k = (k * 7 + 13) % #ITEMS
                local id = ITEMS[k + 1]
                slots[s] = { itemID = id, count = MAXSTACK[id] }
            end
            return slots
        end

        local function layoutWithOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        local packOpts = { maxStackByItem = MAXSTACK }

        it("converges after a full pass", function()
            local snap = snapshot({ [1] = {}, [2] = scatteredOverflow(97) })
            local layout = layoutWithOverflow()

            local plan = GBL:PlanSort(snap, layout, packOpts)
            local bank = applyPlan(snap, plan)
            local plan2 = GBL:PlanSort(snapshot(redescribe(bank)), layout, packOpts)
            assert.equals(0, #plan2.ops,
                "replan after a full pass should be a no-op")
        end)

        it("does not grow the plan after a partially executed pass", function()
            -- The executor finishes when a replan is not smaller than the pass
            -- before it, so a plan that GROWS after partial progress is what
            -- makes a real sort stop early and report a residual. Live: 28 ops
            -- executed, replan came back with 124.
            local snap = snapshot({ [1] = {}, [2] = scatteredOverflow(97) })
            local layout = layoutWithOverflow()
            local plan = GBL:PlanSort(snap, layout, packOpts)

            for _, frac in ipairs({ 0.1, 0.25, 0.5, 0.75, 0.9 }) do
                local done = math.floor(#plan.ops * frac)
                local remained = #plan.ops - done
                local bank = applyPlanPartial(snap, plan, done)
                local plan2 = GBL:PlanSort(snapshot(redescribe(bank)), layout, packOpts)

                -- Progress must be real: the replan is strictly smaller than
                -- the plan it continues.
                assert.is_true(#plan2.ops < #plan.ops, string.format(
                    "after %d of %d ops the replan is %d, no smaller than the "
                    .. "plan it continues", done, #plan.ops, #plan2.ops))

                -- The only excess over the untouched tail that is legitimate
                -- is pivot overhead. A pivot parks a blocker and brings it
                -- back, so it costs two ops, and whether one is needed depends
                -- on the free-slot pattern, which partial execution genuinely
                -- changes. Anything beyond that means the plan was re-aimed
                -- rather than continued, which is the #140 defect.
                local pivots = (plan2.diag and plan2.diag.phase2Pivots) or 0
                assert.is_true(#plan2.ops <= remained + 2 * pivots, string.format(
                    "after %d of %d ops, %d remained but the replan wants %d "
                    .. "with only %d pivot(s) to account for it",
                    done, #plan.ops, remained, #plan2.ops, pivots))
            end
        end)

        it("does not repack the whole tab when one stack is added", function()
            -- Live: a packed tab planned 0 ops, one item moved in, and the
            -- next plan was 147 ops.
            local snap = snapshot({ [1] = {}, [2] = scatteredOverflow(97) })
            local layout = layoutWithOverflow()
            local packed = redescribe(applyPlan(snap, GBL:PlanSort(snap, layout, packOpts)))
            assert.equals(0, #GBL:PlanSort(snapshot(packed), layout, packOpts).ops)

            packed[2][98] = { itemID = ITEMS[1], count = MAXSTACK[ITEMS[1]] }
            local plan = GBL:PlanSort(snapshot(packed), layout, packOpts)
            -- Inserting into a sorted run costs a shift of everything after
            -- it, so this is not zero. It should not approach a full repack.
            assert.is_true(#plan.ops <= 50, string.format(
                "one added stack triggered %d ops on a 98-slot tab", #plan.ops))
        end)

        it("keeps indistinguishable stacks where they are", function()
            -- Two stacks with the same itemID and the same count are
            -- interchangeable, so any move between their positions is work
            -- with no observable result. This is the root of the churn:
            -- overflowStackOrder ranks them by origSlot, and executing the
            -- plan rewrites origSlot, which re-aims the next plan.
            local slots = {}
            for s = 1, 20 do
                slots[s] = { itemID = 243733, count = 20 }
            end
            local snap = snapshot({ [1] = {}, [2] = slots })
            local plan = GBL:PlanSort(snap, layoutWithOverflow(), packOpts)
            assert.equals(0, #plan.ops,
                "20 identical full stacks already packed from slot 1 need no moves")
        end)
    end)

    ------------------------------------------------------------------
    -- Bag sources (#139)
    --
    -- Player bags reach the planner through opts.bagSnapshot as NEGATIVE
    -- pseudo-tabs (bagID N is tab -(N+1)), never through the bank
    -- snapshot: tab classification, the perTabOccupied diagnostic and
    -- BankLayout.Validate must never see them. They are source-only, and
    -- applyPlan's dstTab assertion above is what pins that globally.
    ------------------------------------------------------------------
    describe("bag sources", function()
        --- Build an opts.bagSnapshot from { [bagID] = { [slot] = {itemID,count} } }.
        local function bagSnapshot(bags)
            local out = {}
            for bagID, slots in pairs(bags) do
                local tabIndex = -(bagID + 1)
                local tabResult = { slots = {}, itemCount = 0 }
                for slotIndex, s in pairs(slots) do
                    tabResult.slots[slotIndex] = {
                        itemLink = Helpers.makeItemLink(s.itemID, "Item" .. s.itemID, 1),
                        count = s.count,
                        slotIndex = slotIndex,
                        tabIndex = tabIndex,
                        itemID = s.itemID,
                    }
                    tabResult.itemCount = tabResult.itemCount + 1
                end
                out[tabIndex] = tabResult
            end
            return out
        end

        local function fullTab(itemID, count)
            local t = {}
            for s = 1, 98 do t[s] = { itemID = itemID, count = count } end
            return t
        end

        --- One display tab needing `perSlot` of item 100 at slot 1, plus an
        --- overflow tab. The shape most of these tests vary from.
        local function oneDemandLayout(perSlot)
            return {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = perSlot } },
                        { [1] = 100 }),
                    [2] = overflow(),
                },
            }
        end

        it("fills a display-tab deficit from a bag", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local layout = oneDemandLayout(20)

            -- Same bank, no bags: the demand is a pure deficit. Asserting
            -- this first is what stops the bag case passing vacuously.
            assert.equals(20, GBL:PlanSort(snap, layout).deficits[100])

            local bags = bagSnapshot({ [0] = { [3] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, layout, { bagSnapshot = bags })
            assert.is_nil(plan.deficits[100])
            assert.equals(1, #plan.ops)
            assert.equals(-1, plan.ops[1].srcTab)
            assert.equals(3, plan.ops[1].srcSlot)
            assert.equals(1, plan.ops[1].dstTab)
            assert.equals(1, plan.ops[1].dstSlot)
            assert.equals(20, plan.ops[1].count)
        end)

        it("prefers a bank source over a bag holding more of the item", function()
            -- T3 holds 10 as a foreign surplus; the bag holds 60. Without a
            -- dedicated bag tier both sit at priority 3, where the bag wins
            -- twice over: larger `available`, and a lower tabIndex on the
            -- tiebreak after it. Bank stock has to win, because moving inside
            -- the bank is free and a deposit is not.
            local snap = snapshot({
                [1] = {},
                [2] = {},
                [3] = { [5] = { itemID = 100, count = 10 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 10 } },
                        { [1] = 100 }),
                    [2] = overflow(),
                    [3] = displayTab({}, {}),
                },
            }
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 60 } } })
            local plan = GBL:PlanSort(snap, layout, {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 200 },
            })

            local fill
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 1 and op.dstSlot == 1 then fill = op end
            end
            assert.is_not_nil(fill)
            assert.equals(3, fill.srcTab)
        end)

        it("leaves a bag item that is in no display template alone", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local bags = bagSnapshot({ [0] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 999, count = 5 },
            } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(20), { bagSnapshot = bags })

            for _, op in ipairs(plan.ops) do
                assert.is_not.equals(999, op.itemID)
            end
            for _, u in ipairs(plan.unplaced) do
                assert.is_not.equals(999, u.itemID)
            end
            assert.is_nil(plan.deficits[999])
        end)

        it("routes bag surplus beyond the demand to overflow", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 50 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(20), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 100 },
            })

            assert.is_nil(plan.deficits[100])
            assert.equals(0, #plan.unplaced)
            local toOverflow = 0
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 2 then toOverflow = toOverflow + op.count end
            end
            assert.equals(30, toOverflow)
        end)

        it("splits one bag stack across an overflow top-up and a fresh slot", function()
            -- Demand already satisfied in-tab, so the whole bag stack is
            -- surplus: 5 tops up the partial at T2/1, the remaining 15 opens
            -- T2/2. One supply, two destinations. The bag holds exactly one
            -- stack, because a bag slot cannot hold more (#151).
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = { [1] = { itemID = 100, count = 15 } },
            })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20 },
            })

            local byDst = {}
            for _, op in ipairs(plan.ops) do
                if op.srcTab == -1 then byDst[op.dstSlot] = op.count end
            end
            assert.equals(5, byDst[1])
            assert.equals(15, byDst[2])
            -- The remainder extends the item's existing group rather than
            -- opening a first-empty: T2/1 already holds item 100, so T2/2
            -- is a right-extension of that run.
            assert.equals(1, plan.diag.phase1bTopup)
            assert.equals(1, plan.diag.phase1bExtendRight)
        end)

        it("spills bank leftovers before bag surplus", function()
            -- Supply order is bank tabs first, bags appended after. At
            -- maxStack 20 each destination seals, so the order is readable
            -- off which slot each source landed in.
            -- Both sources hold exactly one stack, because no slot holds
            -- more than one (#151): an over-stacked bag supply lands whole
            -- in a slot Phase 4 then has to swap with the bank's stack,
            -- which makes this fixture about the pivot loop rather than
            -- about spill order (#147). The demand at T1/1 is already
            -- satisfied so the bank stack is surplus in full.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = {},
                [3] = { [1] = { itemID = 100, count = 20 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 10 } },
                        { [1] = 100 }),
                    [2] = overflow(),
                    [3] = displayTab({}, {}),
                },
            }
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, layout, {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20 },
            })

            local srcOf = {}
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 2 then srcOf[op.dstSlot] = op.srcTab end
            end
            assert.equals(3, srcOf[1])
            assert.equals(-1, srcOf[2])
        end)

        it("reports unroutable bag surplus as unplaced at its bag pseudo-tab", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = fullTab(200, 200),
            })
            local bags = bagSnapshot({ [0] = { [4] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20, [200] = 200 },
            })

            assert.equals(1, #plan.unplaced)
            local u = plan.unplaced[1]
            assert.equals(GBL._sortPlannerReasons.OVERFLOW_FULL, u.reason)
            assert.equals(-1, u.tabIndex)
            assert.equals(4, u.slotIndex)
            assert.equals(20, u.count)
        end)

        it("still fills demands from bags when the layout has no overflow tab", function()
            local snap = snapshot({ [1] = {} })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 10 } },
                        { [1] = 100 }),
                },
            }
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 30 } } })
            local plan = GBL:PlanSort(snap, layout, { bagSnapshot = bags })

            assert.is_nil(plan.deficits[100])
            assert.equals(1, #plan.unplaced)
            assert.equals(GBL._sortPlannerReasons.NO_OVERFLOW_DEFINED,
                plan.unplaced[1].reason)
            assert.equals(-1, plan.unplaced[1].tabIndex)
            assert.equals(20, plan.unplaced[1].count)
        end)

        it("spills bag surplus without top-ups when maxStack is unknown", function()
            -- Cold ItemCache after a /reload. capacity reads 0, so the
            -- top-up branch is unreachable and every spill opens a slot.
            -- The plan must still be valid; a later sort merges them.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = { [1] = { itemID = 100, count = 5 } },
            })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 12 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), { bagSnapshot = bags })

            assert.equals(0, plan.diag.phase1bTopup)
            assert.equals(0, #plan.unplaced)

            -- Assert the total rather than the slots. The bag stack opens a
            -- new slot instead of merging, then Phase 4 packs the tab, so
            -- which slot holds what is packing's business; what this test
            -- owns is that nothing was dropped and nothing over-stacked.
            local final = applyPlan(snap, plan, bags)
            local inOverflow = 0
            for _, s in pairs(final[2] or {}) do
                assert.equals(100, s.itemID)
                inOverflow = inOverflow + s.count
            end
            assert.equals(17, inOverflow)
        end)

        it("is idempotent: re-planning the applied result with empty bags is a no-op", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local layout = oneDemandLayout(20)
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 50 } } })
            local opts = { bagSnapshot = bags, maxStackByItem = { [100] = 100 } }

            local plan = GBL:PlanSort(snap, layout, opts)
            local final = applyPlan(snap, plan, bags)

            -- Rebuild a scanner-shaped snapshot from the applied bank, minus
            -- the pseudo-tabs: the bags are empty once the deposits land.
            local after = {}
            for tabIndex, slots in pairs(final) do
                if tabIndex >= 1 then
                    local t = { slots = {}, itemCount = 0 }
                    for slotIndex, s in pairs(slots) do
                        t.slots[slotIndex] = {
                            itemLink = Helpers.makeItemLink(s.itemID, "Item" .. s.itemID, 1),
                            count = s.count, slotIndex = slotIndex, tabIndex = tabIndex,
                        }
                        t.itemCount = t.itemCount + 1
                    end
                    after[tabIndex] = t
                end
            end

            local second = GBL:PlanSort(after, layout,
                { bagSnapshot = {}, maxStackByItem = { [100] = 100 } })
            assert.equals(0, #second.ops)
        end)

        it("is deterministic across two identical calls", function()
            local snap = snapshot({
                [1] = {},
                [2] = {},
                [3] = { [2] = { itemID = 100, count = 7 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 2, perSlot = 10 } },
                        { [1] = 100, [2] = 100 }),
                    [2] = overflow(),
                    [3] = displayTab({}, {}),
                },
            }
            local opts = {
                bagSnapshot = bagSnapshot({ [0] = {
                    [1] = { itemID = 100, count = 9 },
                    [4] = { itemID = 100, count = 30 },
                } }),
                maxStackByItem = { [100] = 20 },
            }

            local a = GBL:PlanSort(snap, layout, opts)
            local b = GBL:PlanSort(snap, layout, opts)
            assert.equals(#a.ops, #b.ops)
            for i, op in ipairs(a.ops) do
                assert.same({ op.srcTab, op.srcSlot, op.dstTab, op.dstSlot,
                              op.itemID, op.count },
                            { b.ops[i].srcTab, b.ops[i].srcSlot, b.ops[i].dstTab,
                              b.ops[i].dstSlot, b.ops[i].itemID, b.ops[i].count })
            end
        end)

        it("never harvests a keep-slot when a bag holds the same item", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = {},
            })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 10 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20 },
            })

            for _, op in ipairs(plan.ops) do
                assert.is_false(op.srcTab == 1 and op.srcSlot == 1)
            end
        end)

        it("labels bag slots as BagN/S in the summary and never as a negative tab", function()
            local snap = snapshot({ [1] = {}, [2] = fullTab(200, 200) })
            local bags = bagSnapshot({ [0] = {
                [3] = { itemID = 100, count = 20 },
                [7] = { itemID = 100, count = 50 },
            } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(20), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20, [200] = 200 },
            })
            local lines = GBL:SummarizeSortPlan(plan)
            local blob = table.concat(lines, "\n")

            -- Both halves matter: the positive one alone passes on output
            -- that renders nothing, the negative one alone passes on empty.
            assert.is_truthy(blob:find("Bag0/3", 1, true))
            assert.is_truthy(blob:find("Bag0/7", 1, true))
            assert.is_truthy(blob:find("stays in bags", 1, true))
            assert.is_nil(blob:find("T-", 1, true))
        end)

        it("keeps pseudo-tabs out of demandMap and the tab breakdown", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(20), { bagSnapshot = bags })

            for tabIndex in pairs(plan.demandMap) do
                assert.is_true(tabIndex >= 1)
            end
            for _, line in ipairs(GBL:GetLog("sort") or {}) do
                assert.is_nil((line.message or ""):find("T-", 1, true))
            end
        end)

        it("counts bag activity in plan.diag", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local bags = bagSnapshot({ [0] = {
                [1] = { itemID = 100, count = 20 },
                [2] = { itemID = 100, count = 15 },
            } })
            local plan = GBL:PlanSort(snap, oneDemandLayout(20), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 100 },
            })

            assert.equals(2, plan.diag.bagSupplies)
            assert.equals(1, plan.diag.bagDemandFills)
            assert.equals(1, plan.diag.bagSpills)
        end)

        -- The three below all needed more than one bag, or a bank spill
        -- alongside a bag one. Mutation testing found the gap: reversing the
        -- bag walk and counting every spill as a bag spill both left the
        -- suite green, because every other fixture here uses bag 0 alone and
        -- has nothing but bag surplus to route.
        it("fills a demand from the lowest bagID when two bags tie", function()
            local snap = snapshot({ [1] = {}, [2] = {} })
            local bags = bagSnapshot({
                [0] = { [1] = { itemID = 100, count = 10 } },
                [1] = { [1] = { itemID = 100, count = 10 } },
            })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20 },
            })

            local fill
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 1 and op.dstSlot == 1 then fill = op end
            end
            assert.is_not_nil(fill)
            -- Equal counts, so this lands on the (tab, slot) tiebreak. A raw
            -- tabIndex compare picks -2 over -1, which is bag 1 beating the
            -- backpack and contradicts the spill order.
            assert.equals(-1, fill.srcTab)
        end)

        it("spills bags in bagID order", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 10 } },
                [2] = {},
            })
            local bags = bagSnapshot({
                [0] = { [1] = { itemID = 100, count = 20 } },
                [1] = { [1] = { itemID = 100, count = 20 } },
            })
            local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 20 },
            })

            -- Each stack fills a slot exactly, so the destination slot is a
            -- direct readout of which bag the walk reached first.
            local srcOf = {}
            for _, op in ipairs(plan.ops) do
                if op.dstTab == 2 and op.srcTab < 0 then srcOf[op.dstSlot] = op.srcTab end
            end
            assert.equals(-1, srcOf[1])
            assert.equals(-2, srcOf[2])
        end)

        it("counts only bag-sourced spills in diag.bagSpills", function()
            -- T3's leftover and the bag stack both spill. bagSpills has to
            -- separate them, which is invisible unless a bank spill is
            -- present to be miscounted.
            local snap = snapshot({
                [1] = {},
                [2] = {},
                [3] = { [1] = { itemID = 100, count = 30 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 10 } },
                        { [1] = 100 }),
                    [2] = overflow(),
                    [3] = displayTab({}, {}),
                },
            }
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 15 } } })
            local plan = GBL:PlanSort(snap, layout, {
                bagSnapshot = bags,
                maxStackByItem = { [100] = 100 },
            })

            assert.equals(1, plan.diag.bagSupplies)
            assert.equals(0, plan.diag.bagDemandFills)
            assert.equals(1, plan.diag.bagSpills)

            -- The same numbers on the plan line, in a fixture where fill and
            -- spill differ, so a swapped pair of format arguments shows.
            local logged
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                local m = e.message or ""
                if m:find("tabs, locked=0) bags:", 1, true) then logged = m end
            end
            assert.is_truthy(logged, "expected a plan line with a bags term")
            assert.is_truthy(logged:find(
                "tabs, locked=0) bags:1/1(stay=0,ignored=0,bound=0,locked=0,nolink=0,fillops=0,spillops=1)",
                1, true), logged)
        end)

        it("plans identically with no opts, an empty bagSnapshot, and no bags", function()
            local snap = snapshot({
                [1] = { [2] = { itemID = 100, count = 5 } },
                [2] = {},
            })
            local layout = oneDemandLayout(20)

            local a = GBL:PlanSort(snap, layout)
            local b = GBL:PlanSort(snap, layout, {})
            local c = GBL:PlanSort(snap, layout, { bagSnapshot = {} })

            assert.equals(#a.ops, #b.ops)
            assert.equals(#a.ops, #c.ops)
            assert.equals(a.deficits[100], c.deficits[100])
            assert.equals(0, c.diag.bagSupplies)
        end)

        -- The plan line's bags term is the only place a capture says what
        -- the bag scan saw. It has to render whenever bags were on, even
        -- when nothing was admitted, or "bags on, nothing to deposit" reads
        -- the same as "bags off".
        describe("plan line bags term", function()
            local function sortLines()
                local out = {}
                for _, e in ipairs(GBL:GetLog("sort") or {}) do
                    out[#out + 1] = e.message or ""
                end
                return out
            end

            local function findLine(needle)
                for _, m in ipairs(sortLines()) do
                    if m:find(needle, 1, true) then return m end
                end
                return nil
            end

            it("reports admitted over seen with the scan's skip breakdown", function()
                local snap = snapshot({ [1] = {}, [2] = {} })
                local bags = {
                    [-1] = {
                        slots = {
                            [1] = { itemID = 100, count = 20, slotIndex = 1, tabIndex = -1 },
                            [2] = { itemID = 100, count = 15, slotIndex = 2, tabIndex = -1 },
                            [3] = { itemID = 555, count = 1, slotIndex = 3, tabIndex = -1 },
                        },
                        itemCount = 3, boundSkips = 2, lockedSkips = 1, noLink = 1,
                    },
                }
                GBL:PlanSort(snap, oneDemandLayout(20), {
                    bagSnapshot = bags,
                    maxStackByItem = { [100] = 100 },
                })

                assert.is_truthy(findLine(
                    "tabs, locked=0) bags:2/7(stay=0,ignored=1,bound=2,locked=1,nolink=1,fillops=1,spillops=1)"),
                    table.concat(sortLines(), "\n"))
            end)

            it("renders a zero term when bags are on but empty, and none when off", function()
                local snap = snapshot({ [1] = {}, [2] = {} })
                GBL:PlanSort(snap, oneDemandLayout(20), { bagSnapshot = {} })
                assert.is_truthy(findLine(
                    "tabs, locked=0) bags:0/0(stay=0,ignored=0,bound=0,locked=0,nolink=0,fillops=0,spillops=0)"),
                    table.concat(sortLines(), "\n"))

                GBL:ClearLog("sort")
                GBL:PlanSort(snap, oneDemandLayout(20))
                GBL:PlanSort(snap, oneDemandLayout(20), {})
                assert.is_nil(findLine("tabs, locked=0) bags:"), table.concat(sortLines(), "\n"))
            end)

            it("counts only bag-origin unplaced entries as stay", function()
                -- Overflow is full, so the bag surplus stays in the bag and the
                -- non-layout bank stack at T1/5 has nowhere to go either. Only
                -- the first is a bag stay.
                local snap = snapshot({
                    [1] = {
                        [1] = { itemID = 100, count = 10 },
                        [5] = { itemID = 300, count = 5 },
                    },
                    [2] = fullTab(200, 200),
                })
                local bags = bagSnapshot({ [0] = { [4] = { itemID = 100, count = 50 } } })
                local plan = GBL:PlanSort(snap, oneDemandLayout(10), {
                    bagSnapshot = bags,
                    maxStackByItem = { [100] = 20, [200] = 200, [300] = 20 },
                })

                assert.equals(2, #plan.unplaced)
                assert.equals(1, plan.diag.bagStay)
                assert.is_truthy(findLine(
                    "tabs, locked=0) bags:1/1(stay=1,ignored=0,bound=0,locked=0,nolink=0,fillops=0,spillops=0)"),
                    table.concat(sortLines(), "\n"))
            end)

            -- Which admitted stacks stay behind, and why, on one indented
            -- continuation of the plan line. The count on the term says how
            -- many; this says which. Capped so a bag full of the same item
            -- cannot turn one entry into a page.
            it("names each layout stack that stays in bags with its reason", function()
                local snap = snapshot({
                    [1] = {
                        [1] = { itemID = 100, count = 10 },
                        [5] = { itemID = 300, count = 5 },
                    },
                    [2] = fullTab(200, 200),
                })
                local bags = bagSnapshot({ [0] = { [4] = { itemID = 100, count = 50 } } })
                GBL:PlanSort(snap, oneDemandLayout(10), {
                    bagSnapshot = bags,
                    maxStackByItem = { [100] = 20, [200] = 200, [300] = 20 },
                })

                local line = findLine("bags stay:")
                assert.equals("  bags stay: it:100 x50 at Bag0/4 (overflow-full)", line,
                    table.concat(sortLines(), "\n"))
                for _, m in ipairs(sortLines()) do
                    assert.is_nil(m:find("T-", 1, true), m)
                end
            end)

            it("emits no stay line when every bag stack is placed", function()
                local snap = snapshot({ [1] = {}, [2] = {} })
                local bags = bagSnapshot({ [0] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 15 },
                } })
                GBL:PlanSort(snap, oneDemandLayout(20), {
                    bagSnapshot = bags,
                    maxStackByItem = { [100] = 100 },
                })

                assert.is_nil(findLine("bags stay:"), table.concat(sortLines(), "\n"))
            end)

            it("caps the stay line at ten named stacks and counts the rest", function()
                local slots = {}
                for s = 1, 12 do slots[s] = { itemID = 100, count = 20 } end
                local snap = snapshot({ [1] = {}, [2] = fullTab(200, 200) })
                local bags = bagSnapshot({ [0] = slots })
                local plan = GBL:PlanSort(snap, oneDemandLayout(20), {
                    bagSnapshot = bags,
                    maxStackByItem = { [100] = 20, [200] = 200 },
                })

                assert.equals(11, plan.diag.bagStay)
                local line = findLine("bags stay:")
                assert.is_truthy(line, table.concat(sortLines(), "\n"))
                local _, named = line:gsub(" at Bag0/", "")
                assert.equals(10, named, line)
                assert.is_truthy(line:find(", and 1 more", 1, true), line)
            end)
        end)

        -- The bank half of the same promise (#178). The bag term says why a
        -- bag stack was not a candidate; "input: N slots" could drop by any
        -- amount with nothing beside it, because the scan's locked counter
        -- only ever printed to the SYSTEM channel and a sort gets diagnosed
        -- from the sort one.
        describe("plan line bank skip term (#178)", function()
            local function sortLines()
                local out = {}
                for _, e in ipairs(GBL:GetLog("sort") or {}) do
                    out[#out + 1] = e.message or ""
                end
                return out
            end

            local function planLine()
                for _, m in ipairs(sortLines()) do
                    if m:find("^Sort plan:") then return m end
                end
                return nil
            end

            -- snapshot() builds tab results without the scan's skip counters,
            -- because nothing read them before this. ScanTab always sets
            -- lockedSkips, so stamping it on is the production shape.
            local function withLocked(snap, byTab)
                for tabIndex, n in pairs(byTab) do
                    snap[tabIndex].lockedSkips = n
                end
                return snap
            end

            it("sums the scan's locked skips across every tab", function()
                GBL:ClearLog("sort")
                local snap = withLocked(snapshot({ [1] = {}, [2] = {} }),
                    { [1] = 2, [2] = 3 })

                local plan = GBL:PlanSort(snap, oneDemandLayout(20))

                local m = planLine()
                assert.is_not_nil(m, table.concat(sortLines(), "\n"))
                assert.is_truthy(m:find("tabs, locked=5)", 1, true), m)
                -- The structural figure and the rendered one are the same
                -- number, so a renderer reading the wrong field cannot pass.
                assert.equals(5, plan.diag.bankLocked)
            end)

            -- Present at zero, on the #139 rule the bags term follows:
            -- "checked, nothing skipped" and "not reported" are different
            -- states and a capture needs to tell them apart.
            it("renders locked=0 when the scan skipped nothing", function()
                GBL:ClearLog("sort")
                local snap = snapshot({ [1] = {}, [2] = {} })

                GBL:PlanSort(snap, oneDemandLayout(20))

                local m = planLine()
                assert.is_truthy(m:find("tabs, locked=0)", 1, true), m)
            end)

            -- Both halves in one literal: the tab that skipped something
            -- carries the suffix and the tab that did not carries none. Two
            -- separate tests would each pass against a renderer that got the
            -- other half wrong.
            it("marks only the tabs that skipped something in the breakdown", function()
                GBL:ClearLog("sort")
                local snap = withLocked(snapshot({
                    [1] = { [1] = { itemID = 100, count = 5 } },
                    [2] = {},
                }), { [1] = 2, [2] = 0 })

                GBL:PlanSort(snap, oneDemandLayout(20))

                local m = planLine()
                assert.is_truthy(m:find("[T1:1(locked=2) T2:0]", 1, true), m)
            end)

            -- Both snapshot shapes carry a field called lockedSkips and only
            -- the table it sits in tells them apart, so this is the pin that
            -- catches a walk over the wrong one. Both sides non-zero and
            -- different, or a summing bug reads as correct.
            it("leaves a bag snapshot's locked skips out of the bank total", function()
                GBL:ClearLog("sort")
                local snap = withLocked(snapshot({ [1] = {}, [2] = {} }), { [1] = 2 })
                local bags = {
                    [-1] = {
                        slots = {}, itemCount = 0,
                        boundSkips = 0, lockedSkips = 7, noLink = 0,
                    },
                }

                local plan = GBL:PlanSort(snap, oneDemandLayout(20),
                    { bagSnapshot = bags })

                local m = planLine()
                assert.is_truthy(m:find("tabs, locked=2)", 1, true), m)
                assert.is_truthy(m:find("locked=7,", 1, true),
                    "the bags bracket lost its own locked count: " .. tostring(m))
                assert.equals(2, plan.diag.bankLocked)
                assert.equals(7, plan.diag.bagLocked)
            end)

            -- An ignore tab's slots are inside "input:" today, because the
            -- walk runs over the whole snapshot and ignoreSet is not built
            -- until later. So its skips are inside the total too, or the two
            -- halves of one bracket would mean different things. Pinned
            -- because it is a decision, not an accident.
            it("counts an ignore tab's skips, as input: counts its slots", function()
                GBL:ClearLog("sort")
                local snap = withLocked(snapshot({
                    [1] = {},
                    [2] = {},
                    [3] = { [1] = { itemID = 999, count = 1 } },
                }), { [3] = 4 })
                local layout = {
                    tabs = {
                        [1] = displayTab({ [100] = { slots = 1, perSlot = 20 } },
                            { [1] = 100 }),
                        [2] = overflow(),
                        [3] = { mode = "ignore" },
                    },
                }

                GBL:PlanSort(snap, layout)

                local m = planLine()
                assert.is_truthy(m:find("input: 1 slots / 3 tabs, locked=4)", 1, true), m)
            end)
        end)

        -- One bag slot can reach plan.unplaced more than once. Phase 1B
        -- records the leftover a supply could not place, and either Phase 2
        -- abort then records one entry per REMAINING ASSIGNMENT, several of
        -- which share a source when a stack was split across destinations.
        -- Counting entries therefore reports one stack as several, names
        -- the same slot repeatedly on the continuation line, and inflates
        -- the executor's "still in bags" tail, which reads the same figure.
        -- The unit is the slot, so the helper folds by slot and sums the
        -- portions, which are disjoint takes from one stack.
        describe("_BagStays", function()
            it("folds two entries for one bag slot into one stay", function()
                local stays = GBL._BagStays({
                    { tabIndex = -1, slotIndex = 3, itemID = 100, count = 40,
                      reason = "cycle-no-pivot" },
                    { tabIndex = -1, slotIndex = 3, itemID = 100, count = 30,
                      reason = "cycle-no-pivot" },
                })

                assert.equals(1, #stays)
                assert.equals(70, stays[1].count, "the portions are disjoint and add up")
                assert.equals(-1, stays[1].tabIndex)
                assert.equals(3, stays[1].slotIndex)
            end)

            it("keeps two different bag slots apart", function()
                local stays = GBL._BagStays({
                    { tabIndex = -1, slotIndex = 3, itemID = 100, count = 40 },
                    { tabIndex = -1, slotIndex = 4, itemID = 100, count = 30 },
                })

                assert.equals(2, #stays)
            end)

            it("keeps the same slot number in two different bags apart", function()
                local stays = GBL._BagStays({
                    { tabIndex = -1, slotIndex = 3, itemID = 100, count = 40 },
                    { tabIndex = -2, slotIndex = 3, itemID = 100, count = 30 },
                })

                assert.equals(2, #stays)
            end)

            it("leaves bank entries out entirely", function()
                local stays = GBL._BagStays({
                    { tabIndex = 4, slotIndex = 3, itemID = 100, count = 40 },
                    { tabIndex = -1, slotIndex = 3, itemID = 100, count = 30 },
                })

                assert.equals(1, #stays)
                assert.equals(-1, stays[1].tabIndex)
            end)

            it("preserves the order the entries were recorded in", function()
                local stays = GBL._BagStays({
                    { tabIndex = -2, slotIndex = 9, itemID = 100, count = 1 },
                    { tabIndex = -1, slotIndex = 3, itemID = 200, count = 1 },
                })

                assert.equals(-2, stays[1].tabIndex)
                assert.equals(-1, stays[2].tabIndex)
            end)

            it("returns nothing for an empty list", function()
                assert.equals(0, #GBL._BagStays({}))
            end)
        end)

        -- The Phase 2 refused-emit debug line was the one place a bag source
        -- still rendered through a bare tab format. A bag-sourced assignment
        -- is refused on the first drain pass whenever its destination still
        -- holds the stack that has to move out first.
        describe("Phase 2 debug slot refs", function()
            it("renders a bag source as BagN/S in the refused-emit line", function()
                GBL.db.profile.sort.debugChat = true
                local snap = snapshot({
                    [1] = { [1] = { itemID = 200, count = 5 } },
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
                local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 10 } } })
                GBL:PlanSort(snap, layout, { bagSnapshot = bags })

                local refused
                for _, entry in ipairs(GBL:GetLog("sort") or {}) do
                    local m = entry.message or ""
                    if m:find("refused emit", 1, true) then refused = m end
                    assert.is_nil(m:find("T-", 1, true), m)
                end
                assert.is_truthy(refused, "expected a refused-emit debug line")
                assert.is_truthy(refused:find("refused emit Bag0/1->T1/1", 1, true), refused)
            end)
        end)
    end)

    ------------------------------------------------------------------
    -- Whole-stack top-up cascade (#146)
    --
    -- Tier 1 of pickOverflowSlotInTab tops up a same-item partial from
    -- whatever supply arrives, a whole stack included. A whole stack
    -- meeting a partial was therefore split to fill it, and its own
    -- remainder became the next partial: two ops per stack, with the
    -- remainder walking through every later stack of the item (eleven
    -- ops for six stacks in the 2026-09-07 capture). Now a whole stack
    -- takes a free slot while more whole stacks of its item are still to
    -- come, and only the last one tops up the partial, which puts the
    -- remainder at the run's tail in one split instead of one per stack.
    ------------------------------------------------------------------
    describe("whole-stack top-up cascade (#146)", function()
        --- Display tab 1 holds exactly what it wants, so every stack of
        --- item 100 anywhere else is surplus bound for overflow tab 2.
        --- Tab 3 is a display tab with no template: the bank-side source.
        local function satisfiedLayout()
            return {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 20 } }, { [1] = 100 }),
                    [2] = overflow(),
                    [3] = displayTab({}, {}),
                },
            }
        end

        local function splitCount(plan)
            local n = 0
            for _, op in ipairs(plan.ops) do
                if op.op == "split" then n = n + 1 end
            end
            return n
        end

        --- Overflow tab 2 after the plan as { [slot] = count } for item
        --- 100, failing if anything else landed there.
        local function overflowCounts(final)
            local out = {}
            for s, v in pairs(final[2] or {}) do
                assert.equals(100, v.itemID)
                out[s] = v.count
            end
            return out
        end

        it("splits only the last whole stack when the run already ends in a partial", function()
            -- Overflow holds a full stack and a x10 tail. Three whole x20
            -- stacks arrive. Two take free slots whole; the third pours 10
            -- into the tail and its own remainder becomes the new tail.
            -- Four ops, one split, and the run is already canonical so
            -- Phase 4 has nothing to do. Today every stack splits: six ops.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 10 },
                },
                [3] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { maxStackByItem = { [100] = 20 } })

            assert.equals(0, #plan.unplaced)
            assert.equals(4, #plan.ops,
                "three whole stacks and one tail should cost four ops")
            assert.equals(1, splitCount(plan))
            assert.equals(1, plan.diag.phase1bTopup)
            assert.same({ [1] = 20, [2] = 20, [3] = 20, [4] = 20, [5] = 10 },
                overflowCounts(applyPlan(snap, plan)))
        end)

        it("still fills the partial when the tab has no free slot for a whole stack", function()
            -- Overflow: item 100 x10 at slot 1 with room for 10, every
            -- other slot a full foreign stack. Two whole x20 stacks arrive
            -- and neither can take a slot whole. Deferring the first must
            -- not lose the room the tab still has: the last stack pours 10
            -- into the partial and 30 stays behind as unplaced.
            local tab2 = { [1] = { itemID = 100, count = 10 } }
            for s = 2, 98 do tab2[s] = { itemID = 200, count = 200 } end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = tab2,
                [3] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { maxStackByItem = { [100] = 20, [200] = 200 } })

            assert.equals(1, plan.diag.phase1bTopup)
            local left = 0
            for _, u in ipairs(plan.unplaced) do
                assert.equals(GBL._sortPlannerReasons.OVERFLOW_FULL, u.reason)
                left = left + u.count
            end
            assert.equals(30, left)
            assert.equals(20, applyPlan(snap, plan)[2][1].count)
        end)

        --- Same builder as "bag sources" above, which scopes it locally.
        local function bagSnapshot(bags)
            local out = {}
            for bagID, slots in pairs(bags) do
                local tabIndex = -(bagID + 1)
                local tabResult = { slots = {}, itemCount = 0 }
                for slotIndex, s in pairs(slots) do
                    tabResult.slots[slotIndex] = {
                        itemLink = Helpers.makeItemLink(s.itemID, "Item" .. s.itemID, 1),
                        count = s.count,
                        slotIndex = slotIndex,
                        tabIndex = tabIndex,
                        itemID = s.itemID,
                    }
                    tabResult.itemCount = tabResult.itemCount + 1
                end
                out[tabIndex] = tabResult
            end
            return out
        end

        --- Total count and slot count of item 100 in overflow tab 2.
        local function overflowTotal(final)
            local total, slots = 0, 0
            for _, c in pairs(overflowCounts(final)) do
                total = total + c
                slots = slots + 1
            end
            return total, slots
        end

        it("deposits five whole bag stacks whole when the odd stack sits first (the capture)", function()
            -- Bag 3 slots 4 to 9 as the 2026-09-07 run had them: x1, then
            -- five x20 of an item whose max stack is 20. Whole stacks are
            -- walked before partials within a bag, so the x1 lands last
            -- and the run comes out canonical with nothing split. Today
            -- the x1 opens the run and the last whole stack has to split
            -- around it: seven ops, or eleven before the last-stack rule.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
                [3] = {},
            })
            local bags = bagSnapshot({ [3] = {
                [4] = { itemID = 100, count = 1 },
                [5] = { itemID = 100, count = 20 },
                [6] = { itemID = 100, count = 20 },
                [7] = { itemID = 100, count = 20 },
                [8] = { itemID = 100, count = 20 },
                [9] = { itemID = 100, count = 20 },
            } })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { bagSnapshot = bags, maxStackByItem = { [100] = 20 } })

            assert.equals(0, #plan.unplaced)
            assert.equals(6, #plan.ops, "six stacks should cost six ops")
            assert.equals(0, splitCount(plan))
            assert.equals(0, plan.diag.phase1bTopup)
            local total, slots = overflowTotal(applyPlan(snap, plan, bags))
            assert.equals(101, total)
            assert.equals(6, slots)
        end)

        it("moves a display-tab surplus whole when the odd stack sits first (#144's shape)", function()
            -- The same six stacks as bank surplus in a display tab.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
                [3] = {
                    [1] = { itemID = 100, count = 1 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 100, count = 20 },
                    [4] = { itemID = 100, count = 20 },
                    [5] = { itemID = 100, count = 20 },
                    [6] = { itemID = 100, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { maxStackByItem = { [100] = 20 } })

            assert.equals(0, #plan.unplaced)
            assert.equals(6, #plan.ops)
            assert.equals(0, splitCount(plan))
            local total, slots = overflowTotal(applyPlan(snap, plan))
            assert.equals(101, total)
            assert.equals(6, slots)
        end)

        it("already costs six ops when the odd stack sits last (control)", function()
            -- Pins that the fix is about the walk, not the stacks: with
            -- the whole stacks first in slot order nothing ever split.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
                [3] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 100, count = 20 },
                    [4] = { itemID = 100, count = 20 },
                    [5] = { itemID = 100, count = 20 },
                    [6] = { itemID = 100, count = 1 },
                },
            })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { maxStackByItem = { [100] = 20 } })

            assert.equals(6, #plan.ops)
            assert.equals(0, splitCount(plan))
        end)

        it("keeps bank leftovers ahead of a whole bag stack when one slot is left", function()
            -- Whole-first ordering is within a source, never across
            -- sources: a bank leftover still claims overflow before a
            -- deposit does (#139), however small it is. One free slot, a
            -- x10 bank leftover and a x20 bag stack: the leftover opens the
            -- slot, the bag stack (the last whole stack of its item) tops
            -- it up with 10, and the other 10 stays in the bag. Walked
            -- whole-first across sources, the bag stack would take the
            -- slot whole and the bank leftover would be the one unplaced.
            local tab2 = {}
            for s = 2, 98 do tab2[s] = { itemID = 200, count = 200 } end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = tab2,
                [3] = { [1] = { itemID = 100, count = 10 } },
            })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { bagSnapshot = bags, maxStackByItem = { [100] = 20, [200] = 200 } })

            assert.equals(2, #plan.ops)
            local countFrom = {}
            for _, op in ipairs(plan.ops) do
                assert.equals(2, op.dstTab)
                assert.equals(1, op.dstSlot)
                countFrom[op.srcTab] = op.count
            end
            assert.equals(10, countFrom[3])
            assert.equals(10, countFrom[-1])
            assert.equals(1, #plan.unplaced)
            assert.equals(-1, plan.unplaced[1].tabIndex)
            assert.equals(10, plan.unplaced[1].count)
        end)

        it("keeps slot order between stacks of the same kind when only one slot is left", function()
            -- Whole-first is the only reordering. Two partials of different
            -- items in one display tab and one free overflow slot: the
            -- lower slot's stack lands, as it did before the walk was
            -- sorted, and the higher slot's is the one reported unplaced.
            -- The filler item sorts after both so Phase 4 wants nothing;
            -- a filler that sorted first would try to swap the placed
            -- stack to the end of a full tab and abort into unplaced.
            local tab2 = {}
            for s = 2, 98 do tab2[s] = { itemID = 900, count = 200 } end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = tab2,
                [3] = {
                    [1] = { itemID = 300, count = 5 },
                    [2] = { itemID = 400, count = 5 },
                },
            })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { maxStackByItem = { [900] = 200, [300] = 20, [400] = 20 } })

            assert.equals(1, #plan.ops)
            assert.equals(300, plan.ops[1].itemID)
            assert.equals(1, #plan.unplaced)
            assert.equals(400, plan.unplaced[1].itemID)
        end)

        it("uses the room in every tab's partial when no tab has a free slot", function()
            -- Two overflow tabs, each holding a x5 partial of item 100 and
            -- nothing else free. Three whole x20 stacks arrive. Deferring
            -- a whole stack must not strand the room a second tab's
            -- partial still has: once no tab can take a stack whole, a
            -- deferred stack tops up after all, and because nothing is
            -- free that top-up can never open a new partial. Both partials
            -- end full, 30 placed and 30 left behind, as before the change.
            local function fullTabWithPartial()
                local t = { [1] = { itemID = 100, count = 5 } }
                for s = 2, 98 do t[s] = { itemID = 900, count = 200 } end
                return t
            end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = fullTabWithPartial(),
                [3] = fullTabWithPartial(),
                [4] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 20 } }, { [1] = 100 }),
                    [2] = overflow(),
                    [3] = overflow(),
                    [4] = displayTab({}, {}),
                },
            }
            local plan = GBL:PlanSort(snap, layout,
                { maxStackByItem = { [100] = 20, [900] = 200 } })

            local placed, left = 0, 0
            for _, op in ipairs(plan.ops) do placed = placed + op.count end
            for _, u in ipairs(plan.unplaced) do left = left + u.count end
            assert.equals(30, placed)
            assert.equals(30, left)
            local final = applyPlan(snap, plan)
            assert.equals(20, final[2][1].count)
            assert.equals(20, final[3][1].count)
        end)

        it("lets a bank stack top up ahead of a whole bag stack when nothing is free", function()
            -- The last whole stack of an item is a bag stack whenever the
            -- bags hold one, so without the no-free-slot fallback the bank
            -- stack would be deferred straight to unplaced and the deposit
            -- would be spent on the top-up instead. Bank leftovers claim
            -- overflow before a deposit does (#139): the bank stack splits
            -- 10 into the partial and the bag stack stays in the bag whole.
            local tab2 = { [1] = { itemID = 100, count = 10 } }
            for s = 2, 98 do tab2[s] = { itemID = 900, count = 200 } end
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = tab2,
                [3] = { [1] = { itemID = 100, count = 20 } },
            })
            local bags = bagSnapshot({ [0] = { [1] = { itemID = 100, count = 20 } } })
            local plan = GBL:PlanSort(snap, satisfiedLayout(),
                { bagSnapshot = bags, maxStackByItem = { [100] = 20, [900] = 200 } })

            assert.equals(1, #plan.ops)
            assert.equals(3, plan.ops[1].srcTab)
            assert.equals(10, plan.ops[1].count)
            local leftAt = {}
            for _, u in ipairs(plan.unplaced) do leftAt[u.tabIndex] = u.count end
            assert.equals(10, leftAt[3])
            assert.equals(20, leftAt[-1])
        end)
    end)

    describe("same-item swap inside an overflow run (#147)", function()
        --- Display tab 1 carries no template, so nothing competes with the
        --- overflow tab for the stacks under test.
        local function emptyDisplayOverflow()
            return {
                tabs = {
                    [1] = displayTab({}, {}),
                    [2] = overflow(),
                },
            }
        end

        --- Overflow tab 2 after the plan as { [slot] = count }, failing if
        --- anything but item 100 landed there.
        local function runCounts(final)
            local out = {}
            for s, v in pairs(final[2] or {}) do
                assert.equals(100, v.itemID)
                out[s] = v.count
            end
            return out
        end

        it("swaps a full stack past a partial stranded in the middle of a run", function()
            -- Phase 4 wants both full stacks ahead of the partial, so slots
            -- 2 and 3 have to exchange. Each destination holds the same
            -- item and merging would make 30 against a max stack of 20, so
            -- canExecute refuses both with max-stack-overflow. Until this
            -- fix the stuck scan only recognised a FOREIGN blocker, so no
            -- pivot was tried and both stacks came back unplaced with zero
            -- ops, which repeats identically on every later pass.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 20 },
                    [2] = { itemID = 100, count = 10 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(),
                { maxStackByItem = { [100] = 20 } })

            -- Precondition: Phase 4 did ask for the swap. Without this the
            -- op and unplaced counts below would also be satisfied by a
            -- Phase 4 that wanted nothing at all.
            assert.equals(2, plan.diag.phase4PositionShifts)

            assert.equals(3, #plan.ops)
            assert.equals(1, plan.diag.phase2Pivots)
            assert.equals(0, plan.diag.phase2CycleAborts)
            assert.equals(0, #plan.unplaced)
            assert.same({ [1] = 20, [2] = 20, [3] = 10 },
                runCounts(applyPlan(snap, plan)))
        end)

        it("swaps a full stack past a partial at the head of a run", function()
            -- Same pair the other way round: the partial is where a full
            -- stack belongs. The pivot parks the partial, the full stack
            -- takes slot 1, and the partial comes back to the tail.
            local snap = snapshot({
                [1] = {},
                [2] = {
                    [1] = { itemID = 100, count = 10 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 100, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, emptyDisplayOverflow(),
                { maxStackByItem = { [100] = 20 } })

            assert.equals(2, plan.diag.phase4PositionShifts)
            assert.equals(3, #plan.ops)
            assert.equals(1, plan.diag.phase2Pivots)
            assert.equals(0, plan.diag.phase2CycleAborts)
            assert.equals(0, #plan.unplaced)
            assert.same({ [1] = 20, [2] = 20, [3] = 10 },
                runCounts(applyPlan(snap, plan)))
        end)

        it("leaves a demand refused for max stack as a zero-op residual", function()
            -- The scope pin. A demand fill is the only other assignment
            -- canExecute can refuse for max stack, and only when the layout
            -- asks for more of an item than one slot holds (perSlot 40
            -- against a max stack of 20, which Validate and the editor both
            -- accept). Pivoting there would move the stack already sitting
            -- in the demand slot out to a free slot, fill the demand, and
            -- plan the same thing again next pass, because the demand still
            -- wants more than fits. Today it is a stable residual, which is
            -- the better of the two, so the new stuck arm is scoped to
            -- Phase 4's own assignments.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 15 } },
                [2] = { [1] = { itemID = 100, count = 20 } },
            })
            local layout = {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 40 } },
                        { [1] = 100 }),
                    [2] = overflow(),
                },
            }
            local plan = GBL:PlanSort(snap, layout,
                { maxStackByItem = { [100] = 20 } })

            assert.equals(0, #plan.ops)
            assert.equals(0, plan.diag.phase2Pivots)
            assert.equals(5, plan.deficits[100])
            assert.equals(1, #plan.unplaced)
            local u = plan.unplaced[1]
            assert.equals(2, u.tabIndex)
            assert.equals(1, u.slotIndex)
            assert.equals(20, u.count)
            assert.equals(GBL._sortPlannerReasons.CYCLE_NO_PIVOT, u.reason)

            -- One abort, one assignment stranded by it. This fixture reaches
            -- the no-stuck abort path, whose counters nothing asserted until
            -- a mutation deleting the abort increment survived the suite
            -- (#165). The budget-exhaustion path had a pin; these did not,
            -- which is coverage following ease of setup.
            assert.equals(1, plan.diag.phase2CycleAborts)
            assert.equals(1, plan.diag.phase2StrandedAssignments)

            for _, op in ipairs(plan.ops) do
                assert.is_not.equals(1, op.srcTab,
                    "the stack already in the demand slot must not move")
            end
        end)
    end)

    describe("packing around an unplaced overflow slot (#143)", function()
        --- A demand asking for more of an item than one slot holds is what
        --- makes Phase 2 give up on an OVERFLOW slot while the rest of the
        --- tab is still free: the fill is refused for max stack, which is
        --- not a foreign blocker, so the loop aborts and flags the overflow
        --- source. perSlot 40 against a max stack of 20 is accepted by
        --- BankLayout.Validate and by the Layout editor, so this is an
        --- arrangement a guild can have.
        local function strandingLayout()
            return {
                tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 40 } },
                        { [1] = 100 }),
                    [2] = overflow(),
                },
            }
        end

        --- The precondition every spec here rests on: Phase 2 gave up on
        --- overflow slot 2, and on nothing else. Without this the op counts
        --- below would also be satisfied by a plan that never stranded
        --- anything, which is how this branch went unexercised.
        local function assertStranded(plan)
            assert.equals(1, #plan.unplaced)
            local u = plan.unplaced[1]
            assert.equals(2, u.tabIndex)
            assert.equals(2, u.slotIndex)
            assert.equals(20, u.count)
            assert.equals(GBL._sortPlannerReasons.CYCLE_NO_PIVOT, u.reason)
        end

        it("leaves the tab alone when only the stranded slot breaks the run", function()
            -- Slots 1 and 3 already hold what packing wants them to hold
            -- once slot 2 is out of the reckoning. Today slot 2 counts as a
            -- target anyway, so item 300 is aimed at it, the foreign blocker
            -- is pivoted out, and the plan moves the very stack Phase 2 said
            -- it could not place.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 15 } },
                [2] = {
                    [1] = { itemID = 50, count = 1 },
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 300, count = 1 },
                },
            })
            local plan = GBL:PlanSort(snap, strandingLayout(),
                { maxStackByItem = { [100] = 20 } })

            assertStranded(plan)
            assert.equals(0, plan.diag.phase4PositionShifts)
            assert.equals(0, #plan.ops)
        end)

        it("packs the other stacks around the stranded slot", function()
            -- Real packing work: item 50 belongs at slot 1 and item 300 at
            -- the slot after it, which is 3 rather than 2 because 2 is out.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 15 } },
                [2] = {
                    [1] = { itemID = 300, count = 1 },
                    [2] = { itemID = 100, count = 20 },
                    [5] = { itemID = 50, count = 1 },
                },
            })
            local plan = GBL:PlanSort(snap, strandingLayout(),
                { maxStackByItem = { [100] = 20 } })

            assertStranded(plan)
            assert.equals(2, #plan.ops)
            for _, op in ipairs(plan.ops) do
                assert.is_true(op.srcTab ~= 2 or op.srcSlot ~= 2,
                    "the stranded slot must not be a source")
                assert.is_true(op.dstTab ~= 2 or op.dstSlot ~= 2,
                    "the stranded slot must not be a destination")
            end
            local final = applyPlan(snap, plan)
            assert.equals(50, final[2][1].itemID)
            assert.equals(100, final[2][2].itemID)
            assert.equals(20, final[2][2].count)
            assert.equals(300, final[2][3].itemID)
        end)

        it("keeps identical stacks put when the stranded slot splits their run", function()
            -- Three interchangeable stacks and one target list of 1, 3, 4.
            -- The stacks at 3 and 4 are already inside that range and stay
            -- where they are (#140); only the one at 5 moves, into slot 1.
            -- A stay-put test that still compares against the rank indices
            -- 1 to 3 reads the stack at 4 as out of place and scrambles the
            -- whole run instead.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 15 } },
                [2] = {
                    [2] = { itemID = 100, count = 20 },
                    [3] = { itemID = 700, count = 20 },
                    [4] = { itemID = 700, count = 20 },
                    [5] = { itemID = 700, count = 20 },
                },
            })
            local plan = GBL:PlanSort(snap, strandingLayout(),
                { maxStackByItem = { [100] = 20, [700] = 20 } })

            assertStranded(plan)
            assert.equals(1, #plan.ops)
            local op = plan.ops[1]
            assert.equals(700, op.itemID)
            assert.equals(2, op.srcTab)
            assert.equals(5, op.srcSlot)
            assert.equals(2, op.dstTab)
            assert.equals(1, op.dstSlot)
        end)
    end)

    describe("pivot budget exhaustion (#138)", function()
        --- Two disjoint two-cycles in one display tab, each resolvable with
        --- a single pivot through the unclaimed slots from 5 up. The slot
        --- order puts item 400's demand ahead of item 300's so that if the
        --- second cycle's stacks are swept to overflow they land in itemID
        --- order and Phase 4 adds nothing, which keeps the op counts here
        --- about the budget and nothing else.
        local function twoCycleLayout()
            return {
                tabs = {
                    [1] = displayTab({
                        [100] = { slots = 1, perSlot = 10 },
                        [200] = { slots = 1, perSlot = 5 },
                        [300] = { slots = 1, perSlot = 7 },
                        [400] = { slots = 1, perSlot = 3 },
                    }, { [1] = 100, [2] = 200, [3] = 400, [4] = 300 }),
                    [2] = overflow(),
                },
            }
        end

        local function twoCycleSnapshot()
            return snapshot({
                [1] = {
                    [1] = { itemID = 200, count = 5 },
                    [2] = { itemID = 100, count = 10 },
                    [3] = { itemID = 300, count = 7 },
                    [4] = { itemID = 400, count = 3 },
                },
                [2] = {},
            })
        end

        local maxStacks = { [100] = 20, [200] = 20, [300] = 20, [400] = 20 }

        it("exports the default budget for specs to read", function()
            assert.equals(500, GBL.SORT_PIVOT_BUDGET)
        end)

        it("resolves both cycles when the budget is not reached", function()
            local snap = twoCycleSnapshot()
            local plan = GBL:PlanSort(snap, twoCycleLayout(),
                { maxStackByItem = maxStacks })

            assert.equals(6, #plan.ops)
            assert.equals(2, plan.diag.phase2Pivots)
            assert.equals(0, #plan.unplaced)
            assert.equals(0, plan.diag.phase3Sweeps)
        end)

        it("reports the assignments it dropped when the budget runs out", function()
            local snap = twoCycleSnapshot()
            local plan = GBL:PlanSort(snap, twoCycleLayout(),
                { maxStackByItem = maxStacks, pivotBudget = 1 })

            -- One pivot's worth of work: the first cycle, and nothing else.
            assert.equals(1, plan.diag.phase2Pivots)
            assert.equals(3, #plan.ops)

            -- The second cycle's two assignments are named by slot, with a
            -- reason that tells budget exhaustion from a genuine no-pivot.
            assert.equals(2, #plan.unplaced)
            -- One abort, two assignments stranded by it. The counter used to
            -- read 2 under the name "aborts", so a capture of a single cycle
            -- giving up on eight pending assignments said abort=8 (#165).
            assert.equals(1, plan.diag.phase2CycleAborts)
            assert.equals(2, plan.diag.phase2StrandedAssignments)
            local at = {}
            for _, u in ipairs(plan.unplaced) do
                assert.equals(1, u.tabIndex)
                assert.equals(GBL._sortPlannerReasons.CYCLE_BUDGET_EXHAUSTED,
                    u.reason)
                at[u.slotIndex] = u.count
            end
            assert.same({ [3] = 7, [4] = 3 }, at)

            -- Recording them also stops Phase 3 sweeping to overflow the
            -- very stacks the plan has just said it could not move.
            assert.equals(0, plan.diag.phase3Sweeps)

            -- And the phases line carries both numbers under names that mean
            -- what they say. Asserted on the rendered string rather than only
            -- the diag fields, because the string is what a capture holds.
            local phases
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                local m = e.message or ""
                if m:find("  phases:", 1, true) then phases = m end
            end
            assert.is_truthy(phases, "expected a phases line")
            assert.is_truthy(phases:find("(abort=1,stranded=2)", 1, true), phases)
        end)

        it("never moves what it reported, once Phase 4 runs the loop again", function()
            -- Same exhaustion, but the overflow tab needs packing, so the
            -- pivot loop runs a second time with its own budget. A dropped
            -- assignment left in the pending set is picked up by that run
            -- and resolved, which moves the stacks the plan has already
            -- told the player it could not place. Clearing them as they are
            -- recorded is what keeps the report and the ops agreeing.
            local snap = snapshot({
                [1] = {
                    [1] = { itemID = 200, count = 5 },
                    [2] = { itemID = 100, count = 10 },
                    [3] = { itemID = 300, count = 7 },
                    [4] = { itemID = 400, count = 3 },
                },
                [2] = {
                    [1] = { itemID = 700, count = 5 },
                    [2] = { itemID = 600, count = 5 },
                },
            })
            local plan = GBL:PlanSort(snap, twoCycleLayout(),
                { maxStackByItem = maxStacks, pivotBudget = 1 })

            assert.equals(2, #plan.unplaced)
            local reported = {}
            for _, u in ipairs(plan.unplaced) do
                reported[u.tabIndex .. "/" .. u.slotIndex] = true
            end
            for _, op in ipairs(plan.ops) do
                assert.is_nil(reported[op.srcTab .. "/" .. op.srcSlot],
                    "no op may move a stack the plan reported unplaced")
            end

            -- Phase 4 still did its own work: the overflow pair is packed.
            local final = applyPlan(snap, plan)
            assert.equals(600, final[2][1].itemID)
            assert.equals(700, final[2][2].itemID)
        end)
    end)
    -- #165 item 5: deficits were the only pairs-ordered output in an otherwise
    -- fully ordered pipeline, so two runs on identical input could print the
    -- same deficits in a different order and two people reading one capture
    -- would write different rows.
    --
    -- The itemIDs here are load-bearing and were probed, not guessed. Lua
    -- iterates small integer keys in ascending order often enough that a
    -- careless fixture makes the sorted and unsorted implementations agree,
    -- which is the 2026-09-06 recurrence of the degenerate-fixture entry: a
    -- sorted histogram whose two keys were already in sorted order pinned
    -- nothing. This set iterates 2589, 271883, 3371, 190329 under pairs and
    -- sorts to 2589, 3371, 190329, 271883, so the two differ.
    describe("deficit ordering (#165)", function()
        local DEFICITS = { [2589] = 4, [271883] = 2, [3371] = 7, [190329] = 1 }
        local SORTED = { 2589, 3371, 190329, 271883 }

        --- Guard against the fixture quietly becoming degenerate: if pairs
        --- ever hands these keys back already ascending, the tests below stop
        --- proving anything and this says so instead of passing.
        it("uses a key set whose pairs order is not already sorted", function()
            local seen = {}
            for k in pairs(DEFICITS) do seen[#seen + 1] = k end
            local ascending = true
            for i = 2, #seen do
                if seen[i] < seen[i - 1] then ascending = false end
            end
            assert.is_false(ascending,
                "fixture is degenerate: pick itemIDs whose pairs order differs")
        end)

        it("returns the deficits ascending by itemID", function()
            local got = {}
            for _, d in ipairs(GBL:OrderedDeficits({ deficits = DEFICITS })) do
                got[#got + 1] = d.itemID
            end
            assert.same(SORTED, got)
        end)

        it("carries each count with its itemID", function()
            for _, d in ipairs(GBL:OrderedDeficits({ deficits = DEFICITS })) do
                assert.equals(DEFICITS[d.itemID], d.count)
            end
        end)

        it("returns an empty list for an empty or absent deficits table", function()
            assert.same({}, GBL:OrderedDeficits({ deficits = {} }))
            assert.same({}, GBL:OrderedDeficits({}))
            assert.same({}, GBL:OrderedDeficits(nil))
        end)

        it("renders the summary's deficit lines in that order", function()
            local lines = GBL:SummarizeSortPlan({
                ops = {}, deficits = DEFICITS, unplaced = {},
            })
            local order = {}
            for _, line in ipairs(lines) do
                local id = line:match("^deficit: %d+ x item:(%d+)")
                if id then order[#order + 1] = tonumber(id) end
            end
            assert.same(SORTED, order)
        end)
    end)
    -- Overflow placement tiers 2 to 4 used to return the caller's whole
    -- remaining supply, so a supply larger than one stack landed in a single
    -- empty slot as an illegal over-stack that neither canExecute nor
    -- applyOpToState could see (both only look at merges into an occupied
    -- destination). No real bank or bag slot can hold more than a stack, so
    -- nothing reaches it today; the fixtures here are impossible inputs on
    -- purpose, which is the only way to reach the branch. Tier 1 already
    -- clamped to the destination's capacity.
    describe("overflow tier clamp (#151)", function()
        local MAX = { [100] = 20 }

        local function sortLines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                out[#out + 1] = e.message or ""
            end
            return out
        end

        local function findLine(needle)
            for _, m in ipairs(sortLines()) do
                if m:find(needle, 1, true) then return m end
            end
            return nil
        end

        local function findEntry(needle)
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                if (e.message or ""):find(needle, 1, true) then return e end
            end
            return nil
        end

        local function layout()
            return { tabs = { [1] = displayTab({}, {}), [2] = overflow() } }
        end

        --- Where the display-tab supply landed, in op order. Phase 4 packs
        --- the tab afterwards, so the applied bank cannot say which tier
        --- placed a stack; the spill ops can.
        local function spillDsts(plan)
            local out = {}
            for _, op in ipairs(plan.ops) do
                if op.srcTab == 1 then
                    out[#out + 1] = { slot = op.dstSlot, count = op.count }
                end
            end
            return out
        end

        --- Every overflow stack in the applied bank is legal and the item
        --- total is preserved.
        local function assertLegal(bank, total)
            local sum = 0
            for _, slot in pairs(bank[2] or {}) do
                assert.equals(100, slot.itemID)
                assert.is_true(slot.count <= MAX[100],
                    "overflow holds an over-stack of " .. slot.count)
                sum = sum + slot.count
            end
            assert.equals(total, sum)
            assert.is_nil(next(bank[1] or {}), "display tab was not emptied")
        end

        it("first-empty takes one stack at a time from an oversized supply", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 40 } },
                [2] = {},
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            assert.same({ { slot = 1, count = 20 }, { slot = 2, count = 20 } },
                spillDsts(plan))
            assertLegal(applyPlan(snap, plan, nil, MAX), 40)
        end)

        it("extend-right takes one stack at a time from an oversized supply", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 40 } },
                [2] = { [1] = { itemID = 100, count = 20 } },
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            assert.same({ { slot = 2, count = 20 }, { slot = 3, count = 20 } },
                spillDsts(plan))
            assert.equals(2, plan.diag.phase1bExtendRight)
            assertLegal(applyPlan(snap, plan, nil, MAX), 60)
        end)

        it("extend-left takes one stack at a time from an oversized supply", function()
            -- A full stack at slot 98 leaves no right-extension, so the
            -- walk falls to tier 3.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 40 } },
                [2] = { [98] = { itemID = 100, count = 20 } },
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            assert.same({ { slot = 97, count = 20 }, { slot = 96, count = 20 } },
                spillDsts(plan))
            assert.equals(2, plan.diag.phase1bExtendLeft)
            assertLegal(applyPlan(snap, plan, nil, MAX), 60)
        end)

        it("counts each clamped take and names the count on the plan line", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 50 } },
                [2] = {},
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            -- 50 -> 20 (clamped), 30 -> 20 (clamped), 10 (not clamped).
            assert.equals(2, plan.diag.overflowClamps)
            local entry = findEntry("  overflow clamp:")
            assert.equals("  overflow clamp: 2 take(s) held to max stack",
                entry and entry.message)
            -- The line only ever fires on an input no real bank produces,
            -- which is what WARN means on this channel.
            assert.equals("WARN", entry and entry.level)
        end)

        it("is silent when nothing was clamped", function()
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 20 } },
                [2] = {},
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            assert.equals(0, plan.diag.overflowClamps)
            -- The plan line is there, so the absence below is measured
            -- rather than an empty log.
            assert.is_not_nil(findLine("Sort plan:"))
            assert.is_nil(findLine("  overflow clamp:"),
                table.concat(sortLines(), "\n"))
        end)

        it("treats a max stack below one as unknown", function()
            -- GetItemInfo never reports 0, so only a test override reaches
            -- this; a clamp to nothing would record the stack as unplaced
            -- against an empty tab, with the wrong reason.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 5 } },
                [2] = {},
            })
            local plan = GBL:PlanSort(snap, layout(), {
                maxStackByItem = { [100] = 0 },
            })
            assert.equals(0, #plan.unplaced)
            assert.same({ { slot = 1, count = 5 } }, spillDsts(plan))
            assert.equals(0, plan.diag.overflowClamps)
        end)

        it("lets a clamped stack's remainder top up once it is a partial (#146)", function()
            -- Two whole stacks of one item, walked whole-first, with a
            -- partial already in overflow. The 50 defers its top-up while
            -- the 20 is still behind it, is clamped to 20 and 20, and its
            -- 10 remainder is then a partial: it tops up the existing 10
            -- rather than opening a slot the deferral was meant to prevent.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 50 },
                        [2] = { itemID = 100, count = 20 } },
                [2] = { [1] = { itemID = 100, count = 10 } },
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = MAX })
            assert.equals(4, #spillDsts(plan))
            assert.equals(1, plan.diag.phase1bTopup)
            local bank = applyPlan(snap, plan, nil, MAX)
            assertLegal(bank, 80)
            local stacks = 0
            for _ in pairs(bank[2]) do stacks = stacks + 1 end
            assert.equals(4, stacks)
        end)

        it("leaves an item with unknown max stack unclamped", function()
            -- Cold cache: the planner already falls back to grouping for
            -- that item, and a clamp to nothing would place nothing.
            local snap = snapshot({
                [1] = { [1] = { itemID = 100, count = 40 } },
                [2] = {},
            })
            local plan = GBL:PlanSort(snap, layout(), { maxStackByItem = {} })
            assert.equals(1, #plan.ops)
            assert.equals(40, plan.ops[1].count)
            assert.equals(0, plan.diag.overflowClamps)
        end)
    end)
    -- The two overflow continuation lines (#181): the fragmentation baseline
    -- #145 is judged against. Every assertion reads the rendered line, and
    -- plan.diag is checked against those figures rather than the reverse.
    -- Needles carry the colon: "  overflow clamp:" (#151) shares the prefix.
    describe("overflow fragmentation term (#181)", function()
        local MAX = { [100] = 20, [200] = 20, [2589] = 20, [271883] = 20,
                      [3371] = 20, [190329] = 20 }

        local function sortLines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                out[#out + 1] = e.message or ""
            end
            return out
        end

        local function findLine(needle)
            for _, m in ipairs(sortLines()) do
                if m:find(needle, 1, true) then return m end
            end
            return nil
        end

        local function lineIndex(needle)
            for i, m in ipairs(sortLines()) do
                if m:find(needle, 1, true) then return i end
            end
            return nil
        end

        --- Display tab 1 empty, T6 and T7 overflow in index order.
        local function layout()
            return { tabs = {
                [1] = displayTab({}, {}),
                [6] = overflow(),
                [7] = overflow(),
            } }
        end

        local function plan(tabs, opts)
            opts = opts or {}
            if opts.maxStackByItem == nil then opts.maxStackByItem = MAX end
            return GBL:PlanSort(snapshot(tabs), opts.layout or layout(), opts)
        end

        it("counts one item as two partials in two tabs as fragmented", function()
            plan({ [6] = { [1] = { itemID = 100, count = 5 } },
                   [7] = { [1] = { itemID = 100, count = 5 } } })
            assert.equals("  overflow: items=1 frag=1 partials=2 extra=1 unknown=0",
                findLine("  overflow:"))
            assert.equals("  overflow split: it:100 T6x1 T7x1",
                findLine("  overflow split:"))
        end)

        it("reads an empty slot between two stacks as a gap", function()
            plan({ [6] = { [1] = { itemID = 100, count = 5 },
                           [3] = { itemID = 100, count = 5 } } })
            assert.equals("  overflow: items=1 frag=1 partials=2 extra=1 unknown=0",
                findLine("  overflow:"))
        end)

        it("reads a foreign stack between two stacks as a gap", function()
            plan({ [6] = { [1] = { itemID = 100, count = 20 },
                           [2] = { itemID = 200, count = 20 },
                           [3] = { itemID = 100, count = 20 } } })
            assert.equals("  overflow: items=2 frag=1 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
            assert.equals("  overflow split: it:100 T6x2",
                findLine("  overflow split:"))
        end)

        it("reads two stacks adjacent across the tab boundary as one run", function()
            -- T6/98 and T7/1 are consecutive in virtual order: this is the
            -- definition #145 packs to, and a tab-count metric would call
            -- it fragmented forever.
            plan({ [6] = { [98] = { itemID = 100, count = 20 } },
                   [7] = { [1] = { itemID = 100, count = 20 } } })
            assert.equals("  overflow: items=1 frag=0 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
            assert.is_nil(findLine("  overflow split:"))
        end)

        it("counts partials beyond the first per item, in one tab too", function()
            -- Input state, not steady state: Phase 0 merges these in this
            -- very plan. The line describes what the planner was handed.
            plan({ [6] = { [1] = { itemID = 100, count = 5 },
                           [2] = { itemID = 100, count = 5 },
                           [3] = { itemID = 100, count = 5 } } })
            assert.equals("  overflow: items=1 frag=0 partials=3 extra=2 unknown=0",
                findLine("  overflow:"))
        end)

        it("does not count a whole stack as a partial", function()
            plan({ [6] = { [1] = { itemID = 100, count = 20 } } })
            assert.equals("  overflow: items=1 frag=0 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
        end)

        it("counts an item with no known max stack as unknown and still as present", function()
            plan({ [6] = { [1] = { itemID = 300, count = 5 },
                           [3] = { itemID = 300, count = 5 } } })
            assert.equals("  overflow: items=1 frag=1 partials=0 extra=0 unknown=1",
                findLine("  overflow:"))
        end)

        it("treats a max stack below one as unknown (#151)", function()
            plan({ [6] = { [1] = { itemID = 300, count = 5 },
                           [3] = { itemID = 300, count = 5 } } },
                 { maxStackByItem = { [300] = 0 } })
            assert.equals("  overflow: items=1 frag=1 partials=0 extra=0 unknown=1",
                findLine("  overflow:"))
        end)

        it("does not count a tab the scan could not see", function()
            plan({ [6] = { [1] = { itemID = 100, count = 5 } },
                   [7] = { [1] = { itemID = 100, count = 5 } } },
                 { coverage = { viewableTabs = { 1, 6 } } })
            assert.equals("  overflow: items=1 frag=0 partials=1 extra=0 unknown=0",
                findLine("  overflow:"))
            local planLine = findLine("Sort plan:")
            assert.is_not_nil(planLine and planLine:find(" unviewable:T7", 1, true))
        end)

        it("renders nothing when the layout declares no overflow tab", function()
            plan({ [1] = { [1] = { itemID = 100, count = 5 } } },
                 { layout = { tabs = { [1] = displayTab({}, {}) } } })
            assert.is_not_nil(findLine("Sort plan:"))
            assert.is_nil(findLine("  overflow:"))
            assert.is_nil(findLine("  overflow split:"))
        end)

        it("renders nothing when every declared overflow tab is hidden", function()
            plan({ [6] = { [1] = { itemID = 100, count = 5 } } },
                 { coverage = { viewableTabs = { 1 } } })
            assert.is_not_nil(findLine("Sort plan:"))
            assert.is_nil(findLine("  overflow:"))
        end)

        it("renders at zero when the overflow tabs are usable and empty", function()
            plan({ [6] = {}, [7] = {} })
            assert.equals("  overflow: items=0 frag=0 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
            assert.is_nil(findLine("  overflow split:"))
        end)

        it("never counts a bag pseudo-tab", function()
            -- The layout names the item so the bag stack is admitted into
            -- the working bank under tab -1; a walk over pairs(bank) would
            -- see it as a second run.
            plan({ [6] = { [1] = { itemID = 100, count = 20 } } }, {
                layout = { tabs = {
                    [1] = displayTab({ [100] = { slots = 1, perSlot = 20 } }, { 100 }),
                    [6] = overflow(),
                    [7] = overflow(),
                } },
                bagSnapshot = { [-1] = { slots = {
                    [1] = { itemID = 100, count = 20 } } } },
            })
            assert.equals("  overflow: items=1 frag=0 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
            assert.is_nil(findLine("  overflow split:"))
        end)

        describe("split line order", function()
            -- Runs per item: 2589 -> 2, 271883 -> 2, 3371 -> 3, 190329 -> 3.
            -- Sorted by runs descending then itemID ascending that is
            -- 3371, 190329, 2589, 271883. Under this Lua the key set walks
            -- 190329, 2589, 3371, 271883, so the whole differs from the
            -- sorted order and the 3371/190329 tie arrives id-descending;
            -- the self-check below says so if either ever stops being true.
            local RUNS = { [2589] = 2, [271883] = 2, [3371] = 3, [190329] = 3 }
            local SORTED = { 3371, 190329, 2589, 271883 }

            local function fragmentedTab()
                -- Every stack separated by an empty slot so each is its
                -- own run; the order of appearance is deliberately not the
                -- sorted order either.
                return { [1] = { itemID = 2589, count = 20 },
                         [3] = { itemID = 271883, count = 20 },
                         [5] = { itemID = 3371, count = 20 },
                         [7] = { itemID = 190329, count = 20 },
                         [9] = { itemID = 2589, count = 20 },
                         [11] = { itemID = 271883, count = 20 },
                         [13] = { itemID = 3371, count = 20 },
                         [15] = { itemID = 190329, count = 20 },
                         [17] = { itemID = 3371, count = 20 },
                         [19] = { itemID = 190329, count = 20 } }
            end

            --- The #165 self-check, on both sort keys: the pairs walk over
            --- this key set must not already be runs-descending, and some
            --- pair of equal-run items must come out id-descending, or the
            --- sorted and unsorted implementations agree and nothing below
            --- proves anything.
            it("uses a key set whose pairs order is not already the sorted order", function()
                local seen = {}
                for k in pairs(RUNS) do seen[#seen + 1] = k end
                local sameAsSorted = #seen == #SORTED
                for i = 1, #SORTED do
                    if seen[i] ~= SORTED[i] then sameAsSorted = false end
                end
                assert.is_false(sameAsSorted,
                    "fixture is degenerate: pairs order is already the sorted order")
                local tieDescending = false
                for i = 1, #seen do
                    for j = i + 1, #seen do
                        if RUNS[seen[i]] == RUNS[seen[j]] and seen[j] < seen[i] then
                            tieDescending = true
                        end
                    end
                end
                assert.is_true(tieDescending,
                    "fixture is degenerate: no equal-run pair arrives id-descending")
            end)

            it("names fragmented items by run count descending then itemID ascending", function()
                plan({ [6] = fragmentedTab() })
                assert.equals("  overflow: items=4 frag=4 partials=0 extra=0 unknown=0",
                    findLine("  overflow:"))
                assert.equals(
                    "  overflow split: it:3371 T6x3, it:190329 T6x3, it:2589 T6x2, it:271883 T6x2",
                    findLine("  overflow split:"))
            end)

            it("names ten items and counts the rest", function()
                local tab = {}
                local max = {}
                for i = 1, 11 do
                    local id = 1000 + i
                    tab[i] = { itemID = id, count = 20 }
                    tab[i + 40] = { itemID = id, count = 20 }
                    max[id] = 20
                end
                plan({ [6] = tab }, { maxStackByItem = max })
                local names = {}
                for i = 1, 10 do names[i] = "it:" .. (1000 + i) .. " T6x2" end
                assert.equals("  overflow split: " .. table.concat(names, ", ")
                    .. ", and 1 more", findLine("  overflow split:"))
            end)
        end)

        it("walks the overflow tabs in routing order, not tab order", function()
            -- overflowPriority puts T7 ahead of T6, so T7/98 and T6/1 are
            -- the adjacent pair and the split line lists T7 first.
            plan({ [7] = { [1] = { itemID = 200, count = 20 },
                           [98] = { itemID = 100, count = 20 } },
                   [6] = { [1] = { itemID = 100, count = 20 },
                           [5] = { itemID = 200, count = 20 } } }, {
                layout = { tabs = {
                    [1] = displayTab({}, {}),
                    [6] = { mode = "overflow", overflowPriority = 2 },
                    [7] = { mode = "overflow", overflowPriority = 1 },
                } },
            })
            assert.equals("  overflow: items=2 frag=1 partials=0 extra=0 unknown=0",
                findLine("  overflow:"))
            assert.equals("  overflow split: it:200 T7x1 T6x1",
                findLine("  overflow split:"))
        end)

        it("publishes the same figures on plan.diag", function()
            local p = plan({ [6] = { [1] = { itemID = 100, count = 5 },
                                     [3] = { itemID = 100, count = 5 },
                                     [5] = { itemID = 300, count = 5 } } })
            assert.equals("  overflow: items=2 frag=1 partials=2 extra=1 unknown=1",
                findLine("  overflow:"))
            assert.equals(2, p.diag.overflowItems)
            assert.equals(1, p.diag.overflowFragmented)
            assert.equals(2, p.diag.overflowPartials)
            assert.equals(1, p.diag.overflowExtraPartials)
            assert.equals(1, p.diag.overflowUnknownStack)
        end)

        describe("emission order", function()
            -- The audit reader's pins (spec/audit_sessions_spec.lua) record
            -- this order by hand, ahead of the producer; this is the
            -- producer-side half of that pin. GetLog is newest first, so
            -- emission order reads as descending indices here, while a
            -- saved session (what the reader parses) holds it ascending.
            it("follows demands: and precedes the clamp WARN", function()
                -- A 50-stack spilling into fresh slots at max 20 clamps
                -- (#151); T6 already fragmented so the split line renders.
                plan({ [1] = { [1] = { itemID = 100, count = 50 } },
                       [6] = { [1] = { itemID = 100, count = 20 },
                               [3] = { itemID = 100, count = 20 } } })
                local phases = lineIndex("  phases:")
                local demands = lineIndex("  demands:")
                local overflow = lineIndex("  overflow:")
                local split = lineIndex("  overflow split:")
                local clamp = lineIndex("  overflow clamp:")
                assert.is_not_nil(phases); assert.is_not_nil(demands)
                assert.is_not_nil(overflow); assert.is_not_nil(split)
                assert.is_not_nil(clamp, table.concat(sortLines(), "\n"))
                assert.is_true(phases > demands and demands > overflow
                    and overflow > split and split > clamp,
                    table.concat(sortLines(), "\n"))
            end)

            it("sits directly under the plan line when there is no phases pair", function()
                -- No display demands and nothing to move: the phases block
                -- is gated off, and this is what a converged overflow-only
                -- layout writes on its final replan.
                plan({ [6] = { [1] = { itemID = 100, count = 20 } } })
                assert.is_nil(lineIndex("  phases:"))
                assert.equals(lineIndex("Sort plan:") - 1, lineIndex("  overflow:"))
            end)
        end)
    end)
end)
