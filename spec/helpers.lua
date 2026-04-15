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
    package.loaded["Categories"] = nil
    package.loaded["Dedup"] = nil
    package.loaded["Ledger"] = nil
    package.loaded["Storage"] = nil
    package.loaded["Fingerprint"] = nil
    package.loaded["Sync"] = nil
    package.loaded["UI.Accessibility"] = nil
    package.loaded["UI.FilterBar"] = nil
    package.loaded["UI.ConsumptionView"] = nil
    package.loaded["UI.LedgerView"] = nil
    package.loaded["UI.UI"] = nil
end

--- Initialize mocks (call in before_each).
function Helpers.setupMocks()
    Helpers.resetAll()
    MockWoW.install()
    MockAce.install()
end

--- Safely load a Lua file (no error if file does not exist).
local function safeDofile(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        dofile(path)
    end
end

--- Load the addon modules after mocks are installed.
-- Core and Scanner are required; M2+ modules are loaded if present.
-- @return table The addon object
function Helpers.loadAddon()
    package.loaded["Core"] = nil
    package.loaded["Scanner"] = nil
    package.loaded["Categories"] = nil
    package.loaded["Dedup"] = nil
    package.loaded["Ledger"] = nil
    package.loaded["Storage"] = nil
    package.loaded["Sync"] = nil
    dofile("Core.lua")
    dofile("Scanner.lua")
    safeDofile("Categories.lua")
    safeDofile("Dedup.lua")
    safeDofile("Ledger.lua")
    safeDofile("Storage.lua")
    safeDofile("Fingerprint.lua")
    safeDofile("ItemCache.lua")
    safeDofile("Sync.lua")
    -- UI modules (M3+)
    safeDofile("UI/Accessibility.lua")
    safeDofile("UI/FilterBar.lua")
    safeDofile("UI/ConsumptionView.lua")
    safeDofile("UI/LedgerView.lua")
    safeDofile("UI/SyncStatus.lua")
    safeDofile("UI/ChangelogView.lua")
    safeDofile("UI/AboutView.lua")
    safeDofile("UI/UI.lua")
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

---------------------------------------------------------------------------
-- M2 transaction helpers
---------------------------------------------------------------------------

--- Create a mock item transaction log entry.
-- @param txType string "deposit"|"withdraw"|"move"
-- @param name string Player name
-- @param itemLink string Item link (use makeItemLink)
-- @param count number Stack count
-- @param tab number Source tab index
-- @param destTab number|nil Destination tab (for moves)
-- @param hoursAgo number Hours ago the transaction occurred
-- @return table Transaction entry for mock log
function Helpers.makeTransaction(txType, name, itemLink, count, tab, destTab, hoursAgo)
    hoursAgo = hoursAgo or 0
    return {
        type = txType,
        name = name,
        itemLink = itemLink,
        count = count or 1,
        tab1 = tab or 1,
        tab2 = destTab,
        year = 0,
        month = 0,
        day = math.floor(hoursAgo / 24),
        hour = hoursAgo % 24,
    }
end

--- Create a mock money transaction log entry.
-- @param txType string "deposit"|"withdraw"|"repair"|"buyTab"|"depositSummary"
-- @param name string Player name
-- @param amount number Copper amount
-- @param hoursAgo number Hours ago the transaction occurred
-- @return table Money transaction entry for mock log
function Helpers.makeMoneyTransaction(txType, name, amount, hoursAgo)
    hoursAgo = hoursAgo or 0
    return {
        type = txType,
        name = name,
        amount = amount or 0,
        year = 0,
        month = 0,
        day = math.floor(hoursAgo / 24),
        hour = hoursAgo % 24,
    }
end

--- Configure C_Item.GetItemInfoInstant return values for a specific itemID.
-- @param itemID number
-- @param classID number
-- @param subclassID number
function Helpers.setItemInfo(itemID, classID, subclassID)
    MockWoW.itemInfo[itemID] = { classID = classID, subclassID = subclassID }
end

--- Populate a tab's transaction log.
-- @param tab number Tab index
-- @param transactions table Array of transaction entries (from makeTransaction)
function Helpers.addTabTransactions(tab, transactions)
    MockWoW.guildBank.transactionLogs[tab] = transactions
end

--- Populate the money transaction log.
-- @param transactions table Array of money transaction entries (from makeMoneyTransaction)
function Helpers.addMoneyTransactions(transactions)
    MockWoW.guildBank.moneyTransactions = transactions
end

-- Export mocks for direct access in tests
Helpers.MockWoW = MockWoW
Helpers.MockAce = MockAce

return Helpers
