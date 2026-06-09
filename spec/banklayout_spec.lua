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
        MockWoW.guild.rankIndex = 0   -- GM: bypass HasLayoutWrite gate for these tests
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

    describe("Layout sync intake (BuildLayoutPayload / AdoptRemoteBankLayout)", function()
        local validLayout = {
            tabs = {
                [1] = {
                    mode = "display",
                    items = { [100] = { slots = 2, perSlot = 5 } },
                    slotOrder = { [1] = 100, [2] = 100 },
                },
                [2] = { mode = "overflow" },
            },
        }

        local function remotePayload(updatedAt, perSlot)
            return {
                bankLayout = {
                    version = 7,
                    updatedAt = updatedAt,
                    updatedBy = "RemoteGM-Realm",
                    tabs = {
                        [1] = {
                            mode = "display",
                            items = { [100] = { slots = 2, perSlot = perSlot or 5 } },
                            slotOrder = { [1] = 100, [2] = 100 },
                        },
                        [2] = { mode = "overflow" },
                    },
                },
                stockReserves = { [100] = 250 },
            }
        end

        describe("BuildLayoutPayload", function()
            it("returns nil when no layout is configured (version 0)", function()
                assert.is_nil(GBL:BuildLayoutPayload())
            end)

            it("returns the layout plus stock reserves once configured", function()
                GBL:SaveBankLayout(validLayout, "GM")
                GBL:SetStockReserve(100, 400)
                local payload = GBL:BuildLayoutPayload()
                assert.truthy(payload)
                assert.equals("display", payload.bankLayout.tabs[1].mode)
                assert.equals(400, payload.stockReserves[100])
            end)

            it("returns deep copies severed from storage", function()
                GBL:SaveBankLayout(validLayout, "GM")
                local payload = GBL:BuildLayoutPayload()
                payload.bankLayout.tabs[1].items[100].perSlot = 999
                assert.equals(5, GBL:GetBankLayout().tabs[1].items[100].perSlot)
            end)
        end)

        describe("AdoptRemoteBankLayout", function()
            it("rejects a non-table payload", function()
                local changed, err = GBL:AdoptRemoteBankLayout(nil)
                assert.is_false(changed)
                assert.truthy(err)
            end)

            it("rejects a structurally invalid layout", function()
                local bad = remotePayload(MockWoW.serverTime + 100)
                bad.bankLayout.tabs[2] = nil  -- remove the sole overflow tab
                local changed, err = GBL:AdoptRemoteBankLayout(bad)
                assert.is_false(changed)
                assert.matches("overflow", err)
            end)

            it("adopts a newer layout and reserves, preserving the remote cursor", function()
                local ts = MockWoW.serverTime + 500
                local changed = GBL:AdoptRemoteBankLayout(remotePayload(ts, 9))
                assert.is_true(changed)
                local got = GBL:GetBankLayout()
                assert.equals(ts, got.updatedAt)
                assert.equals(7, got.version)
                assert.equals("RemoteGM-Realm", got.updatedBy)
                assert.equals(9, got.tabs[1].items[100].perSlot)
                assert.equals(250, GBL:GetStockReserves()[100])
            end)

            it("ignores an older-or-equal layout (last-writer-wins)", function()
                local ts = MockWoW.serverTime + 500
                GBL:AdoptRemoteBankLayout(remotePayload(ts, 9))
                -- Equal cursor: no overwrite.
                assert.is_false(GBL:AdoptRemoteBankLayout(remotePayload(ts, 1)))
                assert.equals(9, GBL:GetBankLayout().tabs[1].items[100].perSlot)
                -- Older cursor: no overwrite.
                assert.is_false(GBL:AdoptRemoteBankLayout(remotePayload(ts - 100, 2)))
                assert.equals(9, GBL:GetBankLayout().tabs[1].items[100].perSlot)
            end)

            it("adopts without local write access (sync intake bypasses the gate)", function()
                MockWoW.guild.rankIndex = 5  -- not GM, no write access
                assert.is_false(GBL:HasLayoutWrite())
                local changed = GBL:AdoptRemoteBankLayout(remotePayload(MockWoW.serverTime + 500))
                assert.is_true(changed)
                assert.equals(5, GBL:GetBankLayout().tabs[1].items[100].perSlot)
            end)
        end)

        describe("SetStockReserve sync cursor", function()
            it("bumps the layout cursor when a layout exists so the change re-advertises", function()
                GBL:SaveBankLayout(validLayout, "GM")
                local before = GBL:GetBankLayout()
                MockWoW.serverTime = MockWoW.serverTime + 10
                GBL:SetStockReserve(100, 400)
                local after = GBL:GetBankLayout()
                assert.is_true(after.version > before.version)
                assert.is_true(after.updatedAt > before.updatedAt)
            end)

            it("does not bump the cursor when no layout exists (reserves stay local)", function()
                GBL:SetStockReserve(100, 400)
                assert.equals(0, GBL:GetBankLayout().version)
            end)
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
