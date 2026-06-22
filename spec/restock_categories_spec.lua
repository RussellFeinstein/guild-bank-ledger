------------------------------------------------------------------------
-- restock_categories_spec.lua — Tests for RestockCategories.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("RestockCategories", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    -- Item counts per group (items only, headers excluded), verified against
    -- GuildBankRestock v0.9.13 source.
    local EXPECTED_COUNTS = {
        Gems = 40, Enchants = 56, Potions = 16,
        Flasks = 8, Oils = 2, Food = 0, Runes = 1,
    }
    local EXPECTED_ORDER = { "Gems", "Enchants", "Potions", "Flasks", "Oils", "Food", "Runes" }
    local TOTAL_ITEMS = 123

    -- Count item rows and header rows in a group.
    local function countItems(group)
        local items, headers = 0, 0
        for _, row in ipairs(group.items) do
            if row.id then
                items = items + 1
            elseif row.header then
                headers = headers + 1
            end
        end
        return items, headers
    end

    local function lookupSize(map)
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        return n
    end

    describe("GetRestockCatalog", function()
        it("returns seven groups in load order", function()
            local catalog = GBL:GetRestockCatalog()
            assert.equals(7, #catalog)
            local order = {}
            for i, group in ipairs(catalog) do order[i] = group.name end
            assert.same(EXPECTED_ORDER, order)
        end)

        it("has the expected item count per group (headers excluded)", function()
            local actual = {}
            for _, group in ipairs(GBL:GetRestockCatalog()) do
                actual[group.name] = (countItems(group))
            end
            assert.same(EXPECTED_COUNTS, actual)
        end)

        it("has seven header rows in Enchants and none elsewhere", function()
            local headers = {}
            for _, group in ipairs(GBL:GetRestockCatalog()) do
                local _, h = countItems(group)
                headers[group.name] = h
            end
            assert.same({
                Gems = 0, Enchants = 7, Potions = 0,
                Flasks = 0, Oils = 0, Food = 0, Runes = 0,
            }, headers)
        end)

        it("tolerates an empty group (Food)", function()
            local food
            for _, group in ipairs(GBL:GetRestockCatalog()) do
                if group.name == "Food" then food = group end
            end
            assert.is_table(food)
            assert.equals(0, #food.items)
        end)

        it("treats rank as optional", function()
            local map = GBL:GetRestockCatalogItemIDs()
            assert.is_nil(map[259085].rank)    -- Void-Touched Augment Rune (Runes)
            assert.equals(1, map[240968].rank) -- Telluric Eversong Diamond R1 (Gems)
        end)
    end)

    describe("GetRestockCatalogItemIDs", function()
        it("flattens to the total item count", function()
            assert.equals(TOTAL_ITEMS, lookupSize(GBL:GetRestockCatalogItemIDs()))
        end)

        it("equals the summed non-header rows (no duplicate ids)", function()
            local summed = 0
            for _, group in ipairs(GBL:GetRestockCatalog()) do
                summed = summed + (countItems(group))
            end
            assert.equals(summed, lookupSize(GBL:GetRestockCatalogItemIDs()))
        end)

        it("excludes header rows and keys by id", function()
            for id, row in pairs(GBL:GetRestockCatalogItemIDs()) do
                assert.is_nil(row.header)
                assert.equals(id, row.id)
            end
        end)

        it("maps known ids to their rows", function()
            local map = GBL:GetRestockCatalogItemIDs()
            assert.is_table(map[240968])
            assert.equals(240968, map[240968].id)
            assert.is_table(map[259085])
        end)
    end)
end)
