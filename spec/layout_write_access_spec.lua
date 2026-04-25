------------------------------------------------------------------------
-- layout_write_access_spec.lua — Regression tests asserting that the
-- BankLayout storage API enforces HasLayoutWrite(), and that the
-- sort-tier does not leak layout-write permission.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local VALID_LAYOUT = {
    tabs = {
        [1] = {
            mode = "display",
            items = { [100] = { slots = 2, perSlot = 5 } },
            slotOrder = { [1] = 100, [2] = 100 },
        },
        [2] = { mode = "overflow" },
    },
}

describe("Layout storage access gates", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- start as GM so we can configure policy
        GBL:OnEnable()
    end)

    local function setPlayer(name, realm, rankIndex)
        MockWoW.player.name = name
        MockWoW.player.realm = realm or "TestRealm"
        MockWoW.guild.rankIndex = rankIndex or 5
    end

    local function emptyTier()
        return { rankThreshold = nil, delegates = {} }
    end

    describe("SaveBankLayout", function()
        it("GM can save", function()
            setPlayer("Gm", "TestRealm", 0)
            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Gm")
            assert.is_true(ok, err)
            assert.equals(1, GBL:GetBankLayout().version)
        end)

        it("write-tier delegate can save", function()
            -- Configure policy as GM, then switch to delegate
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                write = { delegates = { ["Editor-TestRealm"] = true } },
                sort  = emptyTier(),
            }))

            setPlayer("Editor", "TestRealm", 5)
            assert.is_true(GBL:HasLayoutWrite())
            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Editor")
            assert.is_true(ok, err)
        end)

        it("write-tier rank can save", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                write = { rankThreshold = 2 },
                sort  = emptyTier(),
            }))

            setPlayer("Officer", "TestRealm", 2)
            assert.is_true(GBL:HasLayoutWrite())
            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Officer")
            assert.is_true(ok, err)
        end)

        it("sort-tier delegate cannot save, but can sort", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                write = emptyTier(),
                sort  = { delegates = { ["Sorter-TestRealm"] = true } },
            }))

            setPlayer("Sorter", "TestRealm", 5)
            assert.is_false(GBL:HasLayoutWrite())
            assert.is_true(GBL:HasSortAccess())
            local versionBefore = GBL:GetBankLayout().version

            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Sorter")
            assert.is_false(ok)
            assert.matches("layout%-write", err)
            assert.equals(versionBefore, GBL:GetBankLayout().version)
        end)

        it("sort-tier rank cannot save", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                write = emptyTier(),
                sort  = { rankThreshold = 3 },
            }))

            setPlayer("Member", "TestRealm", 3)
            assert.is_false(GBL:HasLayoutWrite())
            assert.is_true(GBL:HasSortAccess())
            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Member")
            assert.is_false(ok)
            assert.matches("layout%-write", err)
        end)

        it("outsider cannot save", function()
            setPlayer("Nobody", "TestRealm", 9)
            local ok, err = GBL:SaveBankLayout(VALID_LAYOUT, "Nobody")
            assert.is_false(ok)
            assert.matches("layout%-write", err)
        end)
    end)

    describe("SetStockReserve", function()
        it("GM can set reserve", function()
            setPlayer("Gm", "TestRealm", 0)
            local ok, err = GBL:SetStockReserve(100, 250)
            assert.is_true(ok, err)
            assert.equals(250, GBL:GetStockReserves()[100])
        end)

        it("sort-tier delegate cannot set reserve", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                write = emptyTier(),
                sort  = { delegates = { ["Sorter-TestRealm"] = true } },
            }))

            setPlayer("Sorter", "TestRealm", 5)
            local ok, err = GBL:SetStockReserve(100, 250)
            assert.is_false(ok)
            assert.matches("layout%-write", err)
            assert.is_nil(GBL:GetStockReserves()[100])
        end)
    end)
end)
