------------------------------------------------------------------------
-- restockview_spec.lua — Tests for UI/RestockView.lua
--
-- Covers the pure status-display helper and the render scaffold. The render
-- path runs in the mock (per the changelog_spec precedent); these tests assert
-- structure (ScrollFrame + rows), the focus-order registration, the
-- Auctionator-absent notice, and the Add-to-catalog coverage affordance.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- Recursive widget search by AceGUI type.
local function findChild(container, widgetType)
    for _, c in ipairs(container._children or {}) do
        if c._type == widgetType then return c end
        local nested = findChild(c, widgetType)
        if nested then return nested end
    end
    return nil
end

-- Recursive: first Button whose text matches.
local function findButton(container, text)
    for _, c in ipairs(container._children or {}) do
        if c._type == "Button" and c._text == text then return c end
        local nested = findButton(c, text)
        if nested then return nested end
    end
    return nil
end

describe("RestockView", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: passes HasLayoutWrite for SetStockReserve
        GBL:OnEnable()
    end)

    describe("GetRestockStatusDisplay", function()
        it("distinguishes buy / stocked / over by color, icon and text", function()
            local buy = GBL:GetRestockStatusDisplay({ target = 60, stock = 20, toBuy = 40 })
            local stocked = GBL:GetRestockStatusDisplay({ target = 60, stock = 60, toBuy = 0 })
            local over = GBL:GetRestockStatusDisplay({ target = 60, stock = 80, toBuy = 0 })

            assert.equals("buy", buy.status)
            assert.equals("stocked", stocked.status)
            assert.equals("over", over.status)

            assert.equals("Buy 40", buy.text)
            assert.equals("Stocked", stocked.text)
            assert.equals("Over 20", over.text)

            -- shape channel: distinct icons
            assert.is_true(buy.icon ~= stocked.icon)
            assert.is_true(stocked.icon ~= over.icon)
            -- color channel: distinct palette entries
            assert.is_true(buy.color ~= stocked.color)
            assert.is_true(stocked.color ~= over.color)
        end)

        it("treats a nil or empty row as stocked", function()
            assert.equals("stocked", GBL:GetRestockStatusDisplay(nil).status)
            assert.equals("stocked", GBL:GetRestockStatusDisplay({}).status)
        end)
    end)

    describe("BuildRestockTab", function()
        local function build()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildRestockTab(container)
            return container
        end

        it("renders a ScrollFrame with catalog rows", function()
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
            assert.is_true(#scroll._children > 0)
        end)

        it("registers interactive widgets in the focus order", function()
            build()
            assert.is_true(#GBL.A11Y.focusOrder > 0)
        end)

        it("shows an Auctionator-required notice when Auctionator is absent", function()
            local container = build()
            local banner = findChild(container, "Label")
            assert.is_not_nil(banner)
            assert.truthy(banner._text:find("Auctionator", 1, true))
        end)

        it("renders Add-to-catalog for a bank-target item and adds it on click", function()
            GBL:SetStockReserve(88888, 10)  -- reserve-only, not in the catalog
            local container = build()
            local addBtn = findButton(container, "Add to catalog")
            assert.is_not_nil(addBtn)
            addBtn:Fire("OnClick")
            assert.is_true(GBL:GetRestockData().added[88888])
        end)

        it("exposes the view functions (rename guard)", function()
            assert.is_function(GBL.BuildRestockTab)
            assert.is_function(GBL.RefreshRestockTab)
            assert.is_function(GBL.GetRestockStatusDisplay)
        end)
    end)

    describe("keyboard navigation", function()
        local b1, b2

        before_each(function()
            local AceGUI = LibStub("AceGUI-3.0")
            b1 = AceGUI:Create("Button")
            b2 = AceGUI:Create("Button")
            GBL:ClearFocusOrder()
            GBL:RegisterFocusable(b1, 1)
            GBL:RegisterFocusable(b2, 2)
            GBL.A11Y.focusIndex = 0
        end)

        it("TAB advances focus and wraps", function()
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(2, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("TAB", false)  -- wraps to first
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("Shift-TAB reverses and wraps", function()
            GBL.A11Y.focusIndex = 1
            GBL:_RestockView_NavKey("TAB", true)  -- wraps backward to last
            assert.equals(2, GBL.A11Y.focusIndex)
        end)

        it("DOWN and UP move focus", function()
            GBL:_RestockView_NavKey("DOWN", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("DOWN", false)
            assert.equals(2, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("UP", false)
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("ENTER activates the focused widget's OnClick", function()
            local clicked = false
            b1:SetCallback("OnClick", function() clicked = true end)
            GBL.A11Y.focusIndex = 1
            local handled = GBL:_RestockView_NavKey("ENTER", false)
            assert.is_true(handled)
            assert.is_true(clicked)
        end)

        it("ENTER with no focus returns false", function()
            GBL.A11Y.focusIndex = 0
            assert.is_false(GBL:_RestockView_NavKey("ENTER", false))
        end)

        it("returns false for an unhandled key", function()
            assert.is_false(GBL:_RestockView_NavKey("X", false))
        end)
    end)
end)
