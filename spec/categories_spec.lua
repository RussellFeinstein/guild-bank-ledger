--- categories_spec.lua — Tests for Categories module

local Helpers = require("spec.helpers")

describe("Categories", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        Helpers.MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("CategorizeItem", function()
        it("classifies consumable potions", function()
            assert.equals("consumable", GBL:CategorizeItem(0, 1))
        end)

        it("classifies flasks", function()
            assert.equals("flask", GBL:CategorizeItem(0, 3))
        end)

        it("classifies food and drink", function()
            assert.equals("food", GBL:CategorizeItem(0, 5))
        end)

        it("classifies herbs", function()
            assert.equals("herb", GBL:CategorizeItem(7, 9))
        end)

        it("classifies ore", function()
            assert.equals("ore", GBL:CategorizeItem(7, 11))
        end)

        it("classifies gems by subclass", function()
            assert.equals("gem_red", GBL:CategorizeItem(3, 0))
            assert.equals("gem_blue", GBL:CategorizeItem(3, 1))
            assert.equals("gem_yellow", GBL:CategorizeItem(3, 2))
            assert.equals("gem_prismatic", GBL:CategorizeItem(3, 8))
        end)

        it("classifies weapons", function()
            assert.equals("weapon", GBL:CategorizeItem(2, 0))
            assert.equals("weapon", GBL:CategorizeItem(2, 7))
        end)

        it("classifies armor", function()
            assert.equals("armor", GBL:CategorizeItem(4, 0))
            assert.equals("armor", GBL:CategorizeItem(4, 3))
        end)

        it("returns unknown for unrecognized classID", function()
            assert.equals("unknown", GBL:CategorizeItem(99, 0))
            assert.equals("unknown", GBL:CategorizeItem(255, 5))
        end)

        it("falls back to wildcard for unrecognized subclassID", function()
            -- classID 0 (Consumable) has wildcard, subclassID 99 not explicitly mapped
            assert.equals("consumable", GBL:CategorizeItem(0, 99))
            -- classID 7 (Tradeskill) wildcard
            assert.equals("tradeskill", GBL:CategorizeItem(7, 99))
            -- classID 3 (Gem) wildcard
            assert.equals("gem", GBL:CategorizeItem(3, 99))
        end)
    end)

    describe("GetItemCategory", function()
        it("uses C_Item.GetItemInfoInstant to categorize", function()
            Helpers.setItemInfo(12345, 0, 3)  -- classID=0 (Consumable), subclassID=3 (Flask)
            assert.equals("flask", GBL:GetItemCategory(12345))
        end)

        it("returns unknown for nil itemID", function()
            assert.equals("unknown", GBL:GetItemCategory(nil))
        end)
    end)

    describe("GetAllCategories", function()
        it("returns a sorted list of all categories", function()
            local cats = GBL:GetAllCategories()
            assert.is_table(cats)
            assert.is_true(#cats > 10)
            -- Verify sorted order
            for i = 2, #cats do
                assert.is_true(cats[i - 1] <= cats[i],
                    "Expected sorted: " .. cats[i - 1] .. " <= " .. cats[i])
            end
        end)
    end)

    describe("GetCategoryDisplayName", function()
        it("returns human-readable name for known categories", function()
            assert.equals("Flask", GBL:GetCategoryDisplayName("flask"))
            assert.equals("Herb", GBL:GetCategoryDisplayName("herb"))
            assert.equals("Food & Drink", GBL:GetCategoryDisplayName("food"))
            assert.equals("Unknown", GBL:GetCategoryDisplayName("unknown"))
        end)

        it("capitalizes unknown category strings as fallback", function()
            assert.equals("Newthing", GBL:GetCategoryDisplayName("newthing"))
        end)
    end)
end)
