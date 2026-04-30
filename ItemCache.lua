------------------------------------------------------------------------
-- GuildBankLedger — ItemCache.lua
-- Lazy async item info cache for resolving item names from IDs
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- In-memory cache: itemID → { name, link, stackCount, loaded }
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
    local name, link, _, _, _, _, _, stackCount = GetItemInfo(itemID)
    if name then
        cache[itemID] = {
            name = name, link = link,
            stackCount = stackCount, loaded = true,
        }
        return name, link
    end

    -- Not cached by WoW client — request async load
    cache[itemID] = { loaded = false }
    C_Item.RequestLoadItemDataByID(itemID)
    return nil, nil
end

--- Get the maximum stack size for an itemID.
-- Returns the cached stackCount when known. Triggers a warm/load via
-- GetCachedItemInfo when the cache is cold; if the synchronous lookup
-- populated the entry, the value is returned in this same call.
-- Otherwise returns nil and a subsequent call after
-- GET_ITEM_INFO_RECEIVED fires will return the value.
-- @param itemID number
-- @return number|nil stackCount
function GBL:GetMaxStack(itemID)
    if not itemID then return nil end

    local entry = cache[itemID]
    if entry and entry.loaded then
        return entry.stackCount
    end

    -- Cold cache — warm it. Re-read in case the synchronous GetItemInfo
    -- path populated the entry.
    self:GetCachedItemInfo(itemID)
    entry = cache[itemID]
    if entry and entry.loaded then
        return entry.stackCount
    end
    return nil
end

--- Handle GET_ITEM_INFO_RECEIVED event.
-- Called when WoW finishes loading item data we requested.
-- @param itemID number The item that was loaded
function GBL:OnItemInfoReceived(_event, itemID)
    if not itemID or not cache[itemID] then return end

    local name, link, _, _, _, _, _, stackCount = GetItemInfo(itemID)
    if name then
        cache[itemID] = {
            name = name, link = link,
            stackCount = stackCount, loaded = true,
        }
    end
end

--- Format an itemID for human-readable audit/diagnostic lines.
-- Returns "<name> (it:NNN)" when the cache has loaded the name, or
-- "it:NNN" as a fallback. Never warms the cache (audit emission paths
-- shouldn't trigger async loads). nil itemID renders as "it:?" so the
-- output is always something printable.
-- @param itemID number|nil
-- @return string
function GBL:DescribeItem(itemID)
    if not itemID then return "it:?" end
    local entry = cache[itemID]
    if entry and entry.loaded and entry.name then
        return entry.name .. " (it:" .. itemID .. ")"
    end
    return "it:" .. itemID
end

--- Clear the item cache (for testing).
function GBL:ClearItemCache()
    cache = {}
end
