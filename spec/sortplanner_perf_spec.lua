------------------------------------------------------------------------
-- sortplanner_perf_spec.lua
-- Benchmark: verify PlanSort runs within the performance budget on a
-- worst-case snapshot. The upper bound is deliberately generous (250 ms)
-- so the test does not flake on slow CI while still catching an
-- accidental O(n^3) regression.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("SortPlanner performance", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        Helpers.MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    it("plans a worst-case bank within the 250 ms budget", function()
        -- Snapshot: 8 tabs, each fully occupied (98 distinct slots).
        -- Each slot holds one of ~100 rotating itemIDs so there is substantial
        -- overlap between display-tab claims, overflow supply, and stragglers
        -- — realistic content for a "just captured layout, now sort" run.
        local snap = {}
        for t = 1, 8 do
            snap[t] = { slots = {}, itemCount = 0 }
            for s = 1, 98 do
                local itemID = 100 + ((t - 1) * 98 + s) % 120
                snap[t].slots[s] = {
                    itemLink = Helpers.makeItemLink(itemID, "I" .. itemID, 1),
                    count = 10,
                    slotIndex = s, tabIndex = t,
                }
                snap[t].itemCount = snap[t].itemCount + 1
            end
        end

        -- Layout: 3 display tabs claiming 30 items each (90 demands total),
        --         1 overflow tab, 4 ignore tabs.
        local layout = { tabs = {} }
        for t = 1, 3 do
            local items, slotOrder = {}, {}
            for s = 1, 30 do
                local itemID = 100 + (t - 1) * 30 + s - 1
                items[itemID] = { slots = 1, perSlot = 10 }
                slotOrder[s] = itemID
            end
            layout.tabs[t] = {
                mode = "display", items = items, slotOrder = slotOrder,
            }
        end
        layout.tabs[4] = { mode = "overflow" }
        for t = 5, 8 do
            layout.tabs[t] = { mode = "ignore" }
        end

        local start = os.clock()
        local plan = GBL:PlanSort(snap, layout)
        local elapsed = os.clock() - start

        assert.is_not_nil(plan)
        assert.is_table(plan.ops)
        assert.is_true(elapsed < 0.250,
            string.format("PlanSort took %.3fs, expected < 0.250s", elapsed))
    end)
end)
