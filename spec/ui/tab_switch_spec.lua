------------------------------------------------------------------------
-- tab_switch_spec.lua - the tab-switch paths (#121)
--
-- Five production sites hand a tab value to the AceGUI TabGroup and
-- expect its OnGroupSelected to come back and build that tab:
-- RebuildTabs selecting the default tab (UI/UI.lua), RefreshUI's
-- "not built yet" branch, the Consumption player link switching to
-- Transactions, OpenRestockTab (UI/RestockView.lua), and the Layout
-- tab's inner TabGroup building its own content (UI/LayoutEditor.lua).
-- None of them had ever run in a spec, because the mock's SelectTab
-- recorded the value and fanned out to nothing.
--
-- Every case here asserts on something the build rendered rather than
-- on a flag the switch set, so a mock that records without building
-- cannot satisfy them.
--
-- The tab list matters: real SelectTab fires only when the value
-- matches a tab the group currently holds (AceGUI-3.0 TabGroup,
-- "if found then"), which is why the last case uses a member whose bar
-- never had a Layout tab rather than a user demoted out of one.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Tab switching through the TabGroup", function()
    local GBL

    -- Every widget in the tree, depth first.
    local function walk(node, visit)
        for _, child in ipairs(node._children or {}) do
            visit(child)
            walk(child, visit)
        end
    end

    -- True when any widget's text carries the needle (plain find).
    local function rendersText(container, needle)
        local found = false
        walk(container, function(w)
            if not found and type(w._text) == "string"
                and w._text:find(needle, 1, true) then
                found = true
            end
        end)
        return found
    end

    local function widgetWithText(container, wtype, text)
        local hit
        walk(container, function(w)
            if not hit and w._type == wtype and w._text == text then hit = w end
        end)
        return hit
    end

    local function widgetWithLabel(container, wtype, label)
        local hit
        walk(container, function(w)
            if not hit and w._type == wtype and w._label == label then hit = w end
        end)
        return hit
    end

    -- The Transactions tab is the one every access tier opens on, so its
    -- search box is what "the default tab got built" means below.
    local function transactionsRendered()
        return widgetWithLabel(GBL.tabGroup, "EditBox", "Search") ~= nil
    end

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: every tab in the bar
        GBL:OnEnable()
    end)

    it("builds the default tab when the window is created", function()
        GBL:CreateMainFrame()

        assert.equals("transactions", GBL.activeTab)
        assert.is_true(transactionsRendered(),
            "RebuildTabs selects the default tab and nothing built it")
    end)

    it("builds the Layout tab when the group selects it", function()
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("layout")

        assert.equals("layout", GBL.activeTab)
        assert.is_true(rendersText(GBL.tabGroup, "Layout-write access:"),
            "the Layout tab's access banner is not on screen")
    end)

    it("builds the inner Layout tab's own content", function()
        -- UI/LayoutEditor.lua ends BuildLayoutTab with innerTG:SelectTab,
        -- and the inner OnGroupSelected is the only thing that renders a
        -- bank tab's editor. Two fan-outs deep, which is the shape the
        -- smoke-test gap was named for.
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("layout")

        local heading
        walk(GBL.tabGroup, function(w)
            if not heading and w._type == "Heading"
                and type(w._text) == "string" and w._text:find("Tab 1", 1, true) then
                heading = w
            end
        end)
        assert.is_not_nil(heading, "the inner tab's per-tab heading never rendered")
    end)

    it("builds the Sort tab when the group selects it", function()
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("sort")

        assert.equals("sort", GBL.activeTab)
        assert.is_not_nil(widgetWithText(GBL.tabGroup, "Button", "Preview"),
            "the Sort tab's Preview button is not on screen")
    end)

    it("builds the Restock tab from OpenRestockTab", function()
        GBL:OpenRestockTab()

        assert.equals("restock", GBL.activeTab)
        assert.is_true(rendersText(GBL.tabGroup, "Gold:"),
            "the Restock tab's gold line is not on screen")
    end)

    it("switches to Transactions when a consumption row's player is clicked", function()
        local gd = GBL:GetGuildData()
        gd.transactions = {
            {
                id = "Fluphie:1",
                timestamp = MockWoW.serverTime - 3600,
                player = "Fluphie-TestRealm",
                type = "withdraw",
                itemID = 111,
                itemLink = "[Test Item]",
                count = 2,
                tab = 1,
            },
        }

        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("consumption")

        local link = widgetWithText(GBL.tabGroup, "InteractiveLabel", "Fluphie-TestRealm")
        assert.is_not_nil(link, "the consumption player cell never rendered")

        link:Fire("OnClick")

        assert.equals("transactions", GBL.activeTab)
        assert.equals("Fluphie-TestRealm", GBL._pendingSearchText)
        assert.is_true(transactionsRendered(),
            "the player link switched tabs without building Transactions")
    end)

    it("builds nothing for a value the tab bar does not hold", function()
        -- A member has no Layout tab, so the value matches nothing and
        -- real AceGUI fires no callback at all. The window stays where
        -- it was rather than rendering a tab this rank cannot have.
        MockWoW.player.name = "Member"
        MockWoW.guild.rankIndex = 5
        GBL:CreateMainFrame()
        assert.is_nil(widgetWithText(GBL.tabGroup, "Button", "Preview"),
            "precondition: this rank has no Sort or Layout tab")

        GBL.tabGroup:SelectTab("layout")

        assert.equals("transactions", GBL.activeTab)
        assert.is_false(rendersText(GBL.tabGroup, "Layout-write access:"))
        assert.is_true(transactionsRendered(), "the tab that was showing went away")
    end)
end)
