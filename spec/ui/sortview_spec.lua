------------------------------------------------------------------------
-- sortview_spec.lua — Tests for UI/SortView.lua banner integration.
--
-- The AceGUI rendering path itself is not unit-tested (mock coverage
-- is thin for ScrollFrame/Label interactions). These tests confirm
-- that the crafted-quality detection helper exported by SortExecutor
-- is reachable from the SortView seam — if the export is renamed or
-- removed, the banner silently stops appearing in-game; this test
-- catches that.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local function craftedQualityLink(itemID, name)
    return "|cff0070dd|Hitem:" .. itemID
        .. "::::::::70:::::|h[" .. name
        .. " |A:Professions-ChatIcon-Quality-12-Tier2:17:15::1|a]|h|r"
end

describe("SortView crafted-quality detection", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL:OnEnable()
        MockWoW.addTab("Tab 1", nil, true)
        MockWoW.addTab("Tab 2", nil, true)
    end)

    it("exports the helper as GBL._sortExecutor_PlanHasCraftedQualityItems",
        function()
            assert.is_function(GBL._sortExecutor_PlanHasCraftedQualityItems,
                "SortView relies on this exported helper to render the "
                .. "warning banner — do not rename without updating "
                .. "UI/SortView.lua")
        end)

    it("returns true for a plan op whose src link has the atlas marker",
        function()
            MockWoW.guildBank.tabs[1].slots = {
                [1] = {
                    itemLink = craftedQualityLink(240904, "Flawless Deadly Garnet"),
                    texture = "Interface\\Icons\\INV_Misc_QuestionMark",
                    count = 3, quality = 3,
                    locked = false, isFiltered = false,
                    itemID = 240904,
                },
            }
            local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
            assert.is_true(helper({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 240904, count = 3 },
                },
            }))
        end)

    it("returns false for plain-quality items", function()
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Flask", count = 20 },
        })
        local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
        assert.is_false(helper({
            ops = {
                { op = "move", srcTab = 1, srcSlot = 1,
                  dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
            },
        }))
    end)

    it("returns false for empty / nil / missing-ops plans", function()
        local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
        assert.is_false(helper(nil))
        assert.is_false(helper({}))
        assert.is_false(helper({ ops = {} }))
    end)

    it("returns true when ANY op (not just the first) touches a "
        .. "crafted-quality slot", function()
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Flask", count = 20 },
        })
        MockWoW.guildBank.tabs[1].slots[2] = {
            itemLink = craftedQualityLink(240900, "Flawless Quick Amethyst"),
            texture = "Interface\\Icons\\INV_Misc_QuestionMark",
            count = 3, quality = 3,
            locked = false, isFiltered = false,
            itemID = 240900,
        }
        local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
        assert.is_true(helper({
            ops = {
                { op = "move", srcTab = 1, srcSlot = 1,
                  dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                { op = "move", srcTab = 1, srcSlot = 2,
                  dstTab = 2, dstSlot = 2, itemID = 240900, count = 3 },
            },
        }))
    end)
end)
