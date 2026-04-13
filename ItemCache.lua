------------------------------------------------------------------------
-- GuildBankLedger — ItemCache.lua
-- Lazy async item info cache for resolving item names from IDs
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- In-memory cache: itemID → { name, link, loaded }
local cache = {}

--- Get item name and link for an itemID.
-- Returns immediately if cached. If not cached, requests from server
-- and returns nil (caller should use fallback and retry on next render).
-- @param itemID number
-- @return string|nil itemName
-- @return string|nil itemLink
function GBL:GetCachedItemInfo(itemID)
    if not itemID then return nil, nil end

    local entry = cache[itemID]
    if entry and entry.loaded then
        return entry.name, entry.link
    end

    -- Already requested, waiting for callback
    if entry and not entry.loaded then
        return nil, nil
    end

    -- First request — try synchronous lookup
    local name, link = GetItemInfo(itemID)
    if name then
        cache[itemID] = { name = name, link = link, loaded = true }
        return name, link
    end

    -- Not cached by WoW client — request async load
    cache[itemID] = { loaded = false }
    C_Item.RequestLoadItemData(itemID)
    return nil, nil
end

--- Handle GET_ITEM_INFO_RECEIVED event.
-- Called when WoW finishes loading item data we requested.
-- @param itemID number The item that was loaded
function GBL:OnItemInfoReceived(_event, itemID)
    if not itemID or not cache[itemID] then return end

    local name, link = GetItemInfo(itemID)
    if name then
        cache[itemID] = { name = name, link = link, loaded = true }
    end
end

--- Clear the item cache (for testing).
function GBL:ClearItemCache()
    cache = {}
end
