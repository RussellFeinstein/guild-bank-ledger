------------------------------------------------------------------------
-- GuildBankLedger — Categories.lua
-- Item classification via WoW classID/subclassID
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Category map: classID -> subclassID -> category string
-- ["*"] is a wildcard fallback for unknown subclassIDs
------------------------------------------------------------------------

local CATEGORY_MAP = {
    [0] = { -- Consumable
        [0] = "consumable",
        [1] = "consumable",
        [2] = "elixir",
        [3] = "flask",
        [5] = "food",
        [7] = "bandage",
        [8] = "consumable",
        [9] = "vantus_rune",
        ["*"] = "consumable",
    },
    [1] = { ["*"] = "container" },
    [2] = { ["*"] = "weapon" },
    [3] = { -- Gem
        [0] = "gem_red",
        [1] = "gem_blue",
        [2] = "gem_yellow",
        [3] = "gem_purple",
        [4] = "gem_green",
        [5] = "gem_orange",
        [6] = "gem_meta",
        [7] = "gem_simple",
        [8] = "gem_prismatic",
        [9] = "gem_hydraulic",
        [10] = "gem_cogwheel",
        [11] = "gem_tinker",
        ["*"] = "gem",
    },
    [4] = { ["*"] = "armor" },
    [5] = { ["*"] = "reagent" },
    [7] = { -- Tradeskill
        [1] = "parts",
        [4] = "jewelcrafting",
        [5] = "cloth",
        [6] = "leather",
        [7] = "metal_stone",
        [8] = "cooking",
        [9] = "herb",
        [10] = "elemental",
        [11] = "ore",
        [12] = "enchanting",
        [16] = "inscription",
        ["*"] = "tradeskill",
    },
    [8] = { ["*"] = "item_enhancement" },
    [9] = { ["*"] = "recipe" },
    [12] = { ["*"] = "quest" },
    [15] = { ["*"] = "miscellaneous" },
    [16] = { ["*"] = "glyph" },
    [17] = { ["*"] = "battlepet" },
    [18] = { ["*"] = "profession" },
    [19] = { ["*"] = "profession" },
}

------------------------------------------------------------------------
-- Display names: category string -> human-readable label
------------------------------------------------------------------------

local DISPLAY_NAMES = {
    consumable = "Consumable",
    elixir = "Elixir",
    flask = "Flask",
    food = "Food & Drink",
    bandage = "Bandage",
    vantus_rune = "Vantus Rune",
    container = "Container",
    weapon = "Weapon",
    gem = "Gem",
    gem_red = "Gem (Red)",
    gem_blue = "Gem (Blue)",
    gem_yellow = "Gem (Yellow)",
    gem_purple = "Gem (Purple)",
    gem_green = "Gem (Green)",
    gem_orange = "Gem (Orange)",
    gem_meta = "Gem (Meta)",
    gem_simple = "Gem (Simple)",
    gem_prismatic = "Gem (Prismatic)",
    gem_hydraulic = "Gem (Hydraulic)",
    gem_cogwheel = "Gem (Cogwheel)",
    gem_tinker = "Gem (Tinker)",
    armor = "Armor",
    reagent = "Reagent",
    tradeskill = "Tradeskill",
    parts = "Parts",
    jewelcrafting = "Jewelcrafting",
    cloth = "Cloth",
    leather = "Leather",
    metal_stone = "Metal & Stone",
    cooking = "Cooking",
    herb = "Herb",
    elemental = "Elemental",
    ore = "Ore",
    enchanting = "Enchanting",
    inscription = "Inscription",
    item_enhancement = "Item Enhancement",
    recipe = "Recipe",
    quest = "Quest",
    miscellaneous = "Miscellaneous",
    glyph = "Glyph",
    battlepet = "Battle Pet",
    profession = "Profession",
    unknown = "Unknown",
}

-- Cached sorted list of all categories
local allCategories = nil

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Classify an item by its classID and subclassID.
-- @param classID number WoW item class ID
-- @param subclassID number WoW item subclass ID
-- @return string Category key (e.g. "flask", "herb", "unknown")
function GBL:CategorizeItem(classID, subclassID)
    local classEntry = CATEGORY_MAP[classID]
    if not classEntry then
        return "unknown"
    end
    return classEntry[subclassID] or classEntry["*"] or "unknown"
end

--- Get category for an item by itemID (uses C_Item.GetItemInfoInstant).
-- @param itemID number
-- @return string Category key
function GBL:GetItemCategory(itemID)
    if not itemID then return "unknown" end
    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    if not classID then return "unknown" end
    return self:CategorizeItem(classID, subclassID)
end

--- Get human-readable display name for a category.
-- @param category string Category key
-- @return string Display name
function GBL:GetCategoryDisplayName(category)
    if not category then return "Unknown" end
    if DISPLAY_NAMES[category] then
        return DISPLAY_NAMES[category]
    end
    -- Capitalize first letter as fallback
    return category:sub(1, 1):upper() .. category:sub(2)
end

--- Get a sorted list of all known category keys.
-- @return table Array of category strings
function GBL:GetAllCategories()
    if allCategories then return allCategories end

    local seen = {}
    local list = {}
    for _, subMap in pairs(CATEGORY_MAP) do
        for _, cat in pairs(subMap) do
            if not seen[cat] then
                seen[cat] = true
                table.insert(list, cat)
            end
        end
    end
    table.sort(list)
    allCategories = list
    return allCategories
end
