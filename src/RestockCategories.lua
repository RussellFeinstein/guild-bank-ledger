------------------------------------------------------------------------
-- GuildBankLedger — RestockCategories.lua
-- Restock catalog: item lists ported from GuildBankRestock's Categories/.
-- Pure constant data, no UI and no Auctionator. GetRestockCatalog returns
-- the live module table, which is READ-ONLY by contract: callers that
-- decorate rows (e.g. the Restock universe builder) must copy them first.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Ordered array of groups. A group is { name, items = { row, ... } }.
-- A row is either an item { id, rank?, qty, enabled } or a header { header }.
-- Ranks are crafted-quality tiers (R1/R2); Runes has none. Food is empty.
local CATALOG = {
    {
        name = "Gems",
        items = {
            { id = 240968, rank = 1, qty = 1, enabled = true }, -- Telluric Eversong Diamond R1
            { id = 240969, rank = 2, qty = 1, enabled = true }, -- Telluric Eversong Diamond R2
            { id = 240966, rank = 1, qty = 1, enabled = true }, -- Powerful Eversong Diamond R1
            { id = 240967, rank = 2, qty = 1, enabled = true }, -- Powerful Eversong Diamond R2
            { id = 240982, rank = 1, qty = 1, enabled = true }, -- Indecipherable Eversong Diamond R1
            { id = 240983, rank = 2, qty = 1, enabled = true }, -- Indecipherable Eversong Diamond R2
            { id = 240970, rank = 1, qty = 1, enabled = true }, -- Stoic Eversong Diamond R1
            { id = 240971, rank = 2, qty = 1, enabled = true }, -- Stoic Eversong Diamond R2
            { id = 240911, rank = 1, qty = 1, enabled = true }, -- Versatile Lapis R1
            { id = 240912, rank = 2, qty = 1, enabled = true }, -- Flawless Versatile Lapis R2
            { id = 240913, rank = 1, qty = 1, enabled = true }, -- Deadly Lapis R1
            { id = 240914, rank = 2, qty = 1, enabled = true }, -- Flawless Deadly Lapis R2
            { id = 240917, rank = 1, qty = 1, enabled = true }, -- Masterful Lapis R1
            { id = 240918, rank = 2, qty = 1, enabled = true }, -- Flawless Masterful Lapis R2
            { id = 240901, rank = 1, qty = 1, enabled = true }, -- Versatile Amethyst R1
            { id = 240902, rank = 2, qty = 1, enabled = true }, -- Flawless Versatile Amethyst R2
            { id = 240893, rank = 1, qty = 1, enabled = true }, -- Versatile Peridot R1
            { id = 240894, rank = 2, qty = 1, enabled = true }, -- Flawless Versatile Peridot R2
            { id = 240889, rank = 1, qty = 1, enabled = true }, -- Deadly Peridot R1
            { id = 240890, rank = 2, qty = 1, enabled = true }, -- Flawless Deadly Peridot R2
            { id = 240903, rank = 1, qty = 1, enabled = true }, -- Deadly Garnet R1
            { id = 240904, rank = 2, qty = 1, enabled = true }, -- Flawless Deadly Garnet R2
            { id = 240895, rank = 1, qty = 1, enabled = true }, -- Masterful Amethyst R1
            { id = 240896, rank = 2, qty = 1, enabled = true }, -- Flawless Masterful Amethyst R2
            { id = 240915, rank = 1, qty = 1, enabled = true }, -- Quick Lapis R1
            { id = 240916, rank = 2, qty = 1, enabled = true }, -- Flawless Quick Lapis R2
            { id = 240909, rank = 1, qty = 1, enabled = true }, -- Versatile Garnet R1
            { id = 240910, rank = 2, qty = 1, enabled = true }, -- Flawless Versatile Garnet R2
            { id = 240887, rank = 1, qty = 1, enabled = true }, -- Quick Peridot R1
            { id = 240888, rank = 2, qty = 1, enabled = true }, -- Flawless Quick Peridot R2
            { id = 240907, rank = 1, qty = 1, enabled = true }, -- Masterful Garnet R1
            { id = 240908, rank = 2, qty = 1, enabled = true }, -- Flawless Masterful Garnet R2
            { id = 240905, rank = 1, qty = 1, enabled = true }, -- Quick Garnet R1
            { id = 240906, rank = 2, qty = 1, enabled = true }, -- Flawless Quick Garnet R2
            { id = 240891, rank = 1, qty = 1, enabled = true }, -- Masterful Peridot R1
            { id = 240892, rank = 2, qty = 1, enabled = true }, -- Flawless Masterful Peridot R2
            { id = 240899, rank = 1, qty = 1, enabled = true }, -- Quick Amethyst R1
            { id = 240900, rank = 2, qty = 1, enabled = true }, -- Flawless Quick Amethyst R2
            { id = 240897, rank = 1, qty = 1, enabled = true }, -- Deadly Amethyst R1
            { id = 240898, rank = 2, qty = 1, enabled = true }, -- Flawless Deadly Amethyst R2
        },
    },
    {
        name = "Enchants",
        items = {
            -- Rings
            { header = "Rings" },
            { id = 243956, rank = 1, qty = 1, enabled = true }, -- Enchant Ring - Eyes of the Eagle R1
            { id = 243957, rank = 2, qty = 1, enabled = true }, -- Enchant Ring - Eyes of the Eagle R2
            { id = 243986, rank = 1, qty = 1, enabled = true }, -- Enchant Ring - Nature's Fury R1
            { id = 243987, rank = 2, qty = 1, enabled = true }, -- Enchant Ring - Nature's Fury R2
            { id = 244014, rank = 1, qty = 1, enabled = true }, -- Enchant Ring - Silvermoon's Alacrity R1
            { id = 244015, rank = 2, qty = 1, enabled = true }, -- Enchant Ring - Silvermoon's Alacrity R2
            { id = 244016, rank = 1, qty = 1, enabled = true }, -- Enchant Ring - Silvermoon's Tenacity R1
            { id = 244017, rank = 2, qty = 1, enabled = true }, -- Enchant Ring - Silvermoon's Tenacity R2
            { id = 243958, rank = 1, qty = 1, enabled = true }, -- Enchant Ring - Zul'jin's Mastery R1
            { id = 243959, rank = 2, qty = 1, enabled = true }, -- Enchant Ring - Zul'jin's Mastery R2

            -- Chest
            { header = "Chest" },
            { id = 243976, rank = 1, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Worldsoul R1
            { id = 243977, rank = 2, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Worldsoul R2
            { id = 244002, rank = 1, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Magister R1
            { id = 244003, rank = 2, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Magister R2
            { id = 243946, rank = 1, qty = 1, enabled = true }, -- Enchant Chest - Mark of Nalorakk R1
            { id = 243947, rank = 2, qty = 1, enabled = true }, -- Enchant Chest - Mark of Nalorakk R2
            { id = 243974, rank = 1, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Rootwarden R1
            { id = 243975, rank = 2, qty = 1, enabled = true }, -- Enchant Chest - Mark of the Rootwarden R2

            -- Leg
            { header = "Leg" },
            { id = 240094, rank = 1, qty = 1, enabled = true }, -- Sunfire Silk Spellthread R1
            { id = 240133, rank = 2, qty = 1, enabled = true }, -- Sunfire Silk Spellthread R2
            { id = 240154, rank = 1, qty = 1, enabled = true }, -- Arcanoweave Spellthread R1
            { id = 240155, rank = 2, qty = 1, enabled = true }, -- Arcanoweave Spellthread R2
            { id = 244640, rank = 1, qty = 1, enabled = true }, -- Forest Hunter's Armor Kit R1
            { id = 244641, rank = 2, qty = 1, enabled = true }, -- Forest Hunter's Armor Kit R2
            { id = 244642, rank = 1, qty = 1, enabled = true }, -- Blood Knight's Armor Kit R1
            { id = 244643, rank = 2, qty = 1, enabled = true }, -- Blood Knight's Armor Kit R2

            -- Head
            { header = "Head" },
            { id = 243950, rank = 1, qty = 1, enabled = true }, -- Enchant Helm - Empowered Hex of Leeching R1
            { id = 243951, rank = 2, qty = 1, enabled = true }, -- Enchant Helm - Empowered Hex of Leeching R2
            { id = 244006, rank = 1, qty = 1, enabled = true }, -- Enchant Helm - Empowered Rune of Avoidance R1
            { id = 244007, rank = 2, qty = 1, enabled = true }, -- Enchant Helm - Empowered Rune of Avoidance R2
            { id = 243980, rank = 1, qty = 1, enabled = true }, -- Enchant Helm - Empowered Blessing of Speed R1
            { id = 243981, rank = 2, qty = 1, enabled = true }, -- Enchant Helm - Empowered Blessing of Speed R2

            -- Shoulder
            { header = "Shoulder" },
            { id = 243990, rank = 1, qty = 1, enabled = true }, -- Enchant Shoulder - Amirdrassil's Grace R1
            { id = 243991, rank = 2, qty = 1, enabled = true }, -- Enchant Shoulder - Amirdrassil's Grace R2
            { id = 243962, rank = 1, qty = 1, enabled = true }, -- Enchant Shoulder - Akil'zon's Swiftness R1
            { id = 243963, rank = 2, qty = 1, enabled = true }, -- Enchant Shoulder - Akil'zon's Swiftness R2
            { id = 244020, rank = 1, qty = 1, enabled = true }, -- Enchant Shoulder - Silvermoon's Mending R1
            { id = 244021, rank = 2, qty = 1, enabled = true }, -- Enchant Shoulder - Silvermoon's Mending R2

            -- Boots
            { header = "Boots" },
            { id = 243982, rank = 1, qty = 1, enabled = true }, -- Enchant Boots - Shaladrassil's Roots R1
            { id = 243983, rank = 2, qty = 1, enabled = true }, -- Enchant Boots - Shaladrassil's Roots R2
            { id = 244008, rank = 1, qty = 1, enabled = true }, -- Enchant Boots - Farstrider's Hunt R1
            { id = 244009, rank = 2, qty = 1, enabled = true }, -- Enchant Boots - Farstrider's Hunt R2
            { id = 243952, rank = 1, qty = 1, enabled = true }, -- Enchant Boots - Lynx's Dexterity R1
            { id = 243953, rank = 2, qty = 1, enabled = true }, -- Enchant Boots - Lynx's Dexterity R2

            -- Weapon
            { header = "Weapon" },
            { id = 243970, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Jan'alai's Precision R1
            { id = 243971, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Jan'alai's Precision R2
            { id = 243972, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Berserker's Rage R1
            { id = 243973, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Berserker's Rage R2
            { id = 243998, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Worldsoul Aegis R1
            { id = 243999, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Worldsoul Aegis R2
            { id = 244026, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Flames of the Sin'dorei R1
            { id = 244027, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Flames of the Sin'dorei R2
            { id = 244028, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Acuity of the Ren'dorei R1
            { id = 244029, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Acuity of the Ren'dorei R2
            { id = 244030, rank = 1, qty = 1, enabled = true }, -- Enchant Weapon - Arcane Mastery R1
            { id = 244031, rank = 2, qty = 1, enabled = true }, -- Enchant Weapon - Arcane Mastery R2
        },
    },
    {
        name = "Potions",
        items = {
            { id = 241309, rank = 1, qty = 1, enabled = true }, -- Light's Potential R1
            { id = 241308, rank = 2, qty = 1, enabled = true }, -- Light's Potential R2
            { id = 241289, rank = 1, qty = 1, enabled = true }, -- Potion of Recklessness R1
            { id = 241288, rank = 2, qty = 1, enabled = true }, -- Potion of Recklessness R2
            { id = 241293, rank = 1, qty = 1, enabled = true }, -- Draught of Rampant Abandon R1
            { id = 241292, rank = 2, qty = 1, enabled = true }, -- Draught of Rampant Abandon R2
            { id = 241297, rank = 1, qty = 1, enabled = true }, -- Potion of Zealotry R1
            { id = 241296, rank = 2, qty = 1, enabled = true }, -- Potion of Zealotry R2
            { id = 241305, rank = 1, qty = 1, enabled = true }, -- Silvermoon Health Potion R1
            { id = 241304, rank = 2, qty = 1, enabled = true }, -- Silvermoon Health Potion R2
            { id = 241301, rank = 1, qty = 1, enabled = true }, -- Lightfused Mana Potion R1
            { id = 241300, rank = 2, qty = 1, enabled = true }, -- Lightfused Mana Potion R2
            { id = 241295, rank = 1, qty = 1, enabled = true }, -- Potion of Devoured Dreams R1
            { id = 241294, rank = 2, qty = 1, enabled = true }, -- Potion of Devoured Dreams R2
            { id = 241303, rank = 1, qty = 1, enabled = true }, -- Void-Shrouded Tincture R1
            { id = 241302, rank = 2, qty = 1, enabled = true }, -- Void-Shrouded Tincture R2
        },
    },
    {
        name = "Flasks",
        items = {
            { id = 241325, rank = 1, qty = 1, enabled = true }, -- Flask of the Blood Knights R1
            { id = 241324, rank = 2, qty = 1, enabled = true }, -- Flask of the Blood Knights R2
            { id = 241323, rank = 1, qty = 1, enabled = true }, -- Flask of the Magisters R1
            { id = 241322, rank = 2, qty = 1, enabled = true }, -- Flask of the Magisters R2
            { id = 241327, rank = 1, qty = 1, enabled = true }, -- Flask of the Shattered Sun R1
            { id = 241326, rank = 2, qty = 1, enabled = true }, -- Flask of the Shattered Sun R2
            { id = 241321, rank = 1, qty = 1, enabled = true }, -- Flask of Thalassian Resistance R1
            { id = 241320, rank = 2, qty = 1, enabled = true }, -- Flask of Thalassian Resistance R2
        },
    },
    {
        name = "Oils",
        items = {
            { id = 243733, rank = 1, qty = 1, enabled = true }, -- Thalassian Phoenix Oil R1
            { id = 243734, rank = 2, qty = 1, enabled = true }, -- Thalassian Phoenix Oil R2
        },
    },
    {
        name = "Food",
        items = {},
    },
    {
        name = "Runes",
        items = {
            { id = 259085, qty = 1, enabled = true }, -- Void-Touched Augment Rune (no rank)
        },
    },
}

--- Return the restock catalog: an ordered array of groups.
-- Each group is { name = string, items = { row, ... } }, where a row is either
-- an item { id, rank?, qty, enabled } or a section header { header = string }.
-- Returns the live module table; treat it as READ-ONLY. Callers that decorate
-- rows must copy them first (see the Restock universe builder).
-- @return table groups
function GBL:GetRestockCatalog()
    return CATALOG
end

--- Return a flattened itemID -> row lookup across all groups.
-- Header rows (no id) are excluded; duplicate ids collapse to a single entry.
-- A fresh table is built each call, so the caller may freely mutate the map
-- (the row values are still the live, read-only catalog rows).
-- @return table map of [itemID] = catalog row
function GBL:GetRestockCatalogItemIDs()
    local map = {}
    for _, group in ipairs(CATALOG) do
        for _, row in ipairs(group.items) do
            if row.id then
                map[row.id] = row
            end
        end
    end
    return map
end
