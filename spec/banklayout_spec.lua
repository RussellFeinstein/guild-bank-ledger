------------------------------------------------------------------------
-- banklayout_spec.lua — Tests for BankLayout.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("BankLayout", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    describe("Validate", function()
        local BankLayout

        before_each(function()
            BankLayout = GBL.BankLayout
        end)

        it("rejects missing tabs table", function()
            local ok, err = BankLayout.Validate({})
            assert.is_false(ok)
            assert.truthy(err)
        end)

        it("rejects a layout with no overflow tab", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = { mode = "display", items = {} },
                },
            })
            assert.is_false(ok)
            assert.matches("overflow", err)
        end)

        it("rejects a layout with two overflow tabs", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = { mode = "overflow" },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_false(ok)
            assert.matches("overflow", err)
        end)

        it("rejects duplicate items across display tabs", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = { mode = "display", items = { [100] = { slots = 1, perSlot = 1 } } },
                    [2] = { mode = "display", items = { [100] = { slots = 1, perSlot = 1 } } },
                    [3] = { mode = "overflow" },
                },
            })
            assert.is_false(ok)
            assert.matches("multiple display tabs", err)
        end)

        it("rejects a display tab exceeding 98 slots", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = { mode = "display", items = {
                        [100] = { slots = 60, perSlot = 20 },
                        [101] = { slots = 60, perSlot = 20 },
                    } },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_false(ok)
            assert.matches("> 98", err)
        end)

        it("rejects slotOrder referencing absent itemID", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = {
                        mode = "display",
                        items = { [100] = { slots = 2, perSlot = 5 } },
                        slotOrder = { [1] = 100, [2] = 999 },  -- 999 not in items
                    },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_false(ok)
            assert.matches("slotOrder", err)
        end)

        it("accepts a minimal valid layout", function()
            local ok, err = BankLayout.Validate({
                tabs = {
                    [1] = {
                        mode = "display",
                        items = { [100] = { slots = 2, perSlot = 5 } },
                        slotOrder = { [1] = 100, [2] = 100 },
                    },
                    [2] = { mode = "overflow" },
                    [3] = { mode = "ignore" },
                },
            })
            assert.is_true(ok, err)
        end)
    end)

    describe("Save / Get roundtrip", function()
        it("persists a saved layout and returns a deep copy", function()
            local ok, err = GBL:SaveBankLayout({
                tabs = {
                    [1] = {
                        mode = "display",
                        items = { [100] = { slots = 2, perSlot = 5 } },
                        slotOrder = { [1] = 100, [2] = 100 },
                    },
                    [2] = { mode = "overflow" },
                },
            }, "TestOfficer")
            assert.is_true(ok, err)

            local got = GBL:GetBankLayout()
            assert.equals(1, got.version)
            assert.equals("TestOfficer", got.updatedBy)
            assert.equals("display", got.tabs[1].mode)
            assert.equals(5, got.tabs[1].items[100].perSlot)
            assert.equals("overflow", got.tabs[2].mode)

            -- Mutating the returned copy must NOT affect storage.
            got.tabs[1].items[100].perSlot = 999
            local second = GBL:GetBankLayout()
            assert.equals(5, second.tabs[1].items[100].perSlot)
        end)

        it("increments version on each save", function()
            local base = {
                tabs = {
                    [1] = { mode = "overflow" },
                },
            }
            GBL:SaveBankLayout(base, "A")
            GBL:SaveBankLayout(base, "B")
            GBL:SaveBankLayout(base, "C")
            assert.equals(3, GBL:GetBankLayout().version)
        end)

        it("refuses to save an invalid layout", function()
            local ok, err = GBL:SaveBankLayout({ tabs = {} }, "Officer")
            assert.is_false(ok)
            assert.truthy(err)
        end)
    end)

    describe("SetStockReserve", function()
        it("stores a reserve count", function()
            GBL:SetStockReserve(100, 400)
            assert.equals(400, GBL:GetStockReserves()[100])
        end)

        it("removes an entry when set to 0 or nil", function()
            GBL:SetStockReserve(100, 400)
            GBL:SetStockReserve(100, 0)
            assert.is_nil(GBL:GetStockReserves()[100])
            GBL:SetStockReserve(100, 50)
            GBL:SetStockReserve(100, nil)
            assert.is_nil(GBL:GetStockReserves()[100])
        end)
    end)

    describe("CaptureTabLayout", function()
        before_each(function()
            MockWoW.addTab("Potions", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Power Potion", count = 20 },
                [2] = { itemID = 100, name = "Power Potion", count = 20 },
                [3] = { itemID = 101, name = "Health Potion", count = 20 },
                [4] = { itemID = 101, name = "Health Potion", count = 20 },
                [5] = { itemID = 101, name = "Health Potion", count = 14 },
            })
            GBL.bankOpen = true
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL:StartFullScan()
            MockWoW.fireTimers()
        end)

        it("extracts items, slotCounts, and picks the mode stack size", function()
            local template, err = GBL:CaptureTabLayout(1)
            assert.is_nil(err)
            assert.equals("display", template.mode)
            assert.equals(2, template.items[100].slots)
            assert.equals(20, template.items[100].perSlot)
            -- Item 101 has counts (20, 20, 14); mode = 20
            assert.equals(3, template.items[101].slots)
            assert.equals(20, template.items[101].perSlot)
            assert.equals(100, template.slotOrder[1])
            assert.equals(101, template.slotOrder[5])
        end)

        it("returns an error when no scan exists for the tab", function()
            local template, err = GBL:CaptureTabLayout(99)
            assert.is_nil(template)
            assert.truthy(err)
        end)
    end)
end)
