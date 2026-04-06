--- helpers.lua — Shared test utilities for GuildBankLedger busted tests
-- Loaded automatically via .busted config.

local MockWoW = require("spec.mock_wow")
local MockAce = require("spec.mock_ace")

local Helpers = {}

--- Quality color codes (WoW item quality)
local QUALITY_COLORS = {
    [0] = "ff9d9d9d", -- Poor (grey)
    [1] = "ffffffff", -- Common (white)
    [2] = "ff1eff00", -- Uncommon (green)
    [3] = "ff0070dd", -- Rare (blue)
    [4] = "ffa335ee", -- Epic (purple)
    [5] = "ffff8000", -- Legendary (orange)
}

--- Create a mock item link.
-- @param itemID number
-- @param name string
-- @param quality number (0-5, default 1)
-- @return string WoW-style item link
function Helpers.makeItemLink(itemID, name, quality)
    quality = quality or 1
    local color = QUALITY_COLORS[quality] or QUALITY_COLORS[1]
    return "|c" .. color .. "|Hitem:" .. itemID .. "::::::::70:::::|h[" .. name .. "]|h|r"
end

--- Populate a mock guild bank tab with items.
-- @param tabIndex number Tab index (1-based)
-- @param items table Array of { itemID, name, count, quality, locked } (sparse OK, nil = empty slot)
function Helpers.populateTab(tabIndex, items)
    local tab = MockWoW.guildBank.tabs[tabIndex]
    if not tab then
        error("Tab " .. tabIndex .. " does not exist. Call MockWoW.addTab() first.")
    end

    tab.slots = {}
    for slotIndex, item in pairs(items) do
        if item then
            local link = Helpers.makeItemLink(item.itemID or 12345, item.name or "Test Item", item.quality or 1)
            tab.slots[slotIndex] = {
                itemLink = link,
                texture = "Interface\\Icons\\INV_Misc_QuestionMark",
                count = item.count or 1,
                quality = item.quality or 1,
                locked = item.locked or false,
                isFiltered = false,
                itemID = item.itemID or 12345,
            }
        end
    end
end

--- Full reset: clear all mock state and reload the addon.
function Helpers.resetAll()
    MockWoW.reset()
    MockAce.reset()

    -- Clear any previously loaded addon modules
    package.loaded["Core"] = nil
    package.loaded["Scanner"] = nil
end

--- Initialize mocks (call in before_each).
function Helpers.setupMocks()
    Helpers.resetAll()
    MockWoW.install()
    MockAce.install()
end

--- Load the addon Core module after mocks are installed.
-- @return table The addon object
function Helpers.loadAddon()
    package.loaded["Core"] = nil
    package.loaded["Scanner"] = nil
    dofile("Core.lua")
    dofile("Scanner.lua")
    return MockAce.addon
end

--- Get captured print lines.
-- @return table Array of print output strings
function Helpers.getPrints()
    return MockWoW.getPrints()
end

--- Clear captured prints.
function Helpers.clearPrints()
    MockWoW.clearPrints()
end

--- Check if any captured print contains the given substring.
-- @param substring string
-- @return boolean
function Helpers.printContains(substring)
    for _, line in ipairs(MockWoW.prints) do
        if line:find(substring, 1, true) then
            return true
        end
    end
    return false
end

-- Export mocks for direct access in tests
Helpers.MockWoW = MockWoW
Helpers.MockAce = MockAce

return Helpers
