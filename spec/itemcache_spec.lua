--- itemcache_spec.lua — Tests for ItemCache.lua, focused on GetMaxStack.
-- Existing GetCachedItemInfo coverage lives in spec/data_integrity_spec.lua.

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("ItemCache GetMaxStack", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL:ClearItemCache()
    end)

    it("returns the cached stackCount once GetItemInfo populates the entry", function()
        MockWoW.itemNames[12345] = {
            name = "Healing Potion",
            link = "|cff0070dd|Hitem:12345|h[Healing Potion]|h|r",
            stackCount = 200,
        }
        -- First call warms the cache via the synchronous GetItemInfo path.
        local stack = GBL:GetMaxStack(12345)
        assert.equals(200, stack)
        -- Subsequent calls hit the cache directly.
        assert.equals(200, GBL:GetMaxStack(12345))
    end)

    it("returns nil for an unknown itemID and triggers an async load", function()
        MockWoW.itemInfoRequested = {}
        local stack = GBL:GetMaxStack(99999)
        assert.is_nil(stack)
        assert.is_true(MockWoW.itemInfoRequested[99999])
    end)

    it("returns nil for a nil itemID without crashing", function()
        assert.is_nil(GBL:GetMaxStack(nil))
    end)

    it("returns the value once OnItemInfoReceived fires for a cold entry", function()
        -- Cold call: cache entry created with loaded=false.
        assert.is_nil(GBL:GetMaxStack(54321))

        -- Item data arrives.
        MockWoW.itemNames[54321] = {
            name = "Embersilk Cloth",
            link = "|cffffffff|Hitem:54321|h[Embersilk Cloth]|h|r",
            stackCount = 1000,
        }
        GBL:OnItemInfoReceived("GET_ITEM_INFO_RECEIVED", 54321)

        assert.equals(1000, GBL:GetMaxStack(54321))
    end)

    it("returns nil when the item has no stackCount in the mock (legacy fallback)", function()
        MockWoW.itemNames[42] = {
            name = "Mystery Item",
            link = "|cffffffff|Hitem:42|h[Mystery Item]|h|r",
            -- stackCount intentionally absent.
        }
        local stack = GBL:GetMaxStack(42)
        assert.is_nil(stack)
    end)
end)
