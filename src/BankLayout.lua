------------------------------------------------------------------------
-- GuildBankLedger — BankLayout.lua
-- Per-tab layout templates: display / overflow / ignore modes.
-- Display tabs hold a curated set of items at specific slot counts and
-- per-slot stack sizes. SortPlanner consumes this to plan moves.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local MAX_TABS = MAX_GUILDBANK_TABS or 8

-- Shape history: 1 = original (mode/name/items/slotOrder, exactly one
-- overflow tab); 2 = optional overflowPriority on overflow-mode tabs.
-- Nothing reads this constant yet; it records the shape so future migration
-- or compatibility code has a correct starting point.
-- Mixed-version note: a v1-shape client's copy loops strip overflowPriority
-- on adopt while keeping the cursor, so if such a client later re-saves, the
-- stripped copy can win last-writer-wins. That only happens on layouts old
-- clients can adopt at all (single-overflow), where priority has no routing
-- effect; recovery is the GM re-saving.
local LAYOUT_SCHEMA_VERSION = 2

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function extractItemID(itemLink)
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

local function emptyTable(t)
    for k in pairs(t) do t[k] = nil end
end

--- One definition of a usable overflowPriority, shared by Validate (which
-- rejects anything else non-nil) and OrderedOverflowTabs' sort key (which
-- falls back to the tab index), so the two can never drift on edge values.
-- NaN is type "number" but breaks sort determinism, hence p == p.
local function isUsablePriority(p)
    return type(p) == "number" and p == p
end

--- Whitelist deep copy of one tab record. The single copy shared by
-- GetBankLayout, SaveBankLayout, and AdoptRemoteBankLayout: unknown fields
-- are dropped deliberately (this is storage, not the tolerant record-sync
-- intake), so a new tab field is one edit here plus its roundtrip specs.
local function copyTab(tab)
    local copy = { mode = tab.mode, name = tab.name }
    if tab.mode == "overflow" then
        copy.overflowPriority = tab.overflowPriority
    elseif tab.mode == "display" then
        copy.items = {}
        for itemID, row in pairs(tab.items or {}) do
            copy.items[itemID] = { slots = row.slots, perSlot = row.perSlot }
        end
        copy.slotOrder = {}
        for slotIndex, itemID in pairs(tab.slotOrder or {}) do
            copy.slotOrder[slotIndex] = itemID
        end
    end
    return copy
end

--- Get the guild-scoped storage table, backfilling missing layout/reserve fields.
-- Returns nil if there is no active guild yet.
local function getStore(self)
    local guild = self:GetGuildData()
    if not guild then return nil end
    if not guild.bankLayout then
        guild.bankLayout = { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    end
    if not guild.stockReserves then
        guild.stockReserves = {}
    end
    return guild
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

GBL.BankLayout = GBL.BankLayout or {}
local BankLayout = GBL.BankLayout

--- Schema version constant exposed for tests and migrations.
BankLayout.SCHEMA_VERSION = LAYOUT_SCHEMA_VERSION

--- Return the overflow tab indices in routing (fill) order.
-- Sort key is (overflowPriority or tabIndex) with ascending tabIndex as the
-- tiebreak, so priority literally defaults to the tab index: an unconfigured
-- layout fills in tab order with no setup. Lower fills first.
-- Total on any input (nil, drafts, remote payloads): malformed input yields
-- {}, and a non-number or NaN priority falls back to the tab index because
-- unvalidated editor drafts reach this before Validate runs.
-- @return array of tabIndex, possibly empty
function BankLayout.OrderedOverflowTabs(layout)
    local out = {}
    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then return out end
    for tabIndex, tab in pairs(layout.tabs) do
        if type(tabIndex) == "number" and type(tab) == "table" and tab.mode == "overflow" then
            table.insert(out, tabIndex)
        end
    end
    local function sortKey(tabIndex)
        local p = layout.tabs[tabIndex].overflowPriority
        if isUsablePriority(p) then return p end
        return tabIndex
    end
    table.sort(out, function(a, b)
        local ka, kb = sortKey(a), sortKey(b)
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    return out
end

--- Return a deep copy of the current layout (never the live reference).
-- @return table { version, updatedBy, updatedAt, tabs = { [tabIndex] = {...} } }
function GBL:GetBankLayout()
    local guild = getStore(self)
    if not guild then
        return { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    end
    -- Defensive copy so callers can't mutate storage accidentally.
    local src = guild.bankLayout
    local tabs = {}
    for tabIndex, tab in pairs(src.tabs or {}) do
        tabs[tabIndex] = copyTab(tab)
    end
    return {
        version = src.version or 0,
        updatedBy = src.updatedBy,
        updatedAt = src.updatedAt or 0,
        tabs = tabs,
    }
end

--- Return a deep copy of the stockReserves table. Keys are numeric itemIDs.
function GBL:GetStockReserves()
    local guild = getStore(self)
    if not guild then return {} end
    local copy = {}
    for itemID, reserve in pairs(guild.stockReserves or {}) do
        copy[itemID] = reserve
    end
    return copy
end

--- Validate a prospective layout. Returns ok, errorMessage.
-- @param layout table with .tabs = { [tabIndex] = tab }
function BankLayout.Validate(layout)
    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return false, "layout.tabs must be a table"
    end

    local overflowCount = 0
    local seenItems = {}

    for tabIndex, tab in pairs(layout.tabs) do
        if type(tabIndex) ~= "number" or tabIndex < 1 or tabIndex > MAX_TABS then
            return false, "invalid tabIndex: " .. tostring(tabIndex)
        end
        if type(tab) ~= "table" then
            return false, "tab " .. tabIndex .. " is not a table"
        end
        local mode = tab.mode
        if mode == "overflow" then
            overflowCount = overflowCount + 1
            local p = tab.overflowPriority
            if p ~= nil and not isUsablePriority(p) then
                return false, "tab " .. tabIndex .. " overflowPriority must be a number"
            end
        elseif mode == "display" then
            if type(tab.items) ~= "table" then
                return false, "display tab " .. tabIndex .. " missing items"
            end
            local slotsUsed = 0
            for itemID, row in pairs(tab.items) do
                if type(itemID) ~= "number" then
                    return false, "tab " .. tabIndex .. " item key must be numeric itemID"
                end
                if type(row) ~= "table" or type(row.slots) ~= "number" or type(row.perSlot) ~= "number" then
                    return false, "tab " .. tabIndex .. " item " .. itemID .. " row malformed"
                end
                if row.slots < 1 or row.perSlot < 1 then
                    return false, "tab " .. tabIndex .. " item " .. itemID .. " slots/perSlot must be >= 1"
                end
                if seenItems[itemID] then
                    return false, "item " .. itemID .. " appears in multiple display tabs ("
                        .. seenItems[itemID] .. " and " .. tabIndex .. ")"
                end
                seenItems[itemID] = tabIndex
                slotsUsed = slotsUsed + row.slots
            end
            if slotsUsed > MAX_SLOTS then
                return false, "tab " .. tabIndex .. " uses " .. slotsUsed
                    .. " slots > " .. MAX_SLOTS
            end
            if tab.slotOrder then
                for slotIndex, itemID in pairs(tab.slotOrder) do
                    if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > MAX_SLOTS then
                        return false, "tab " .. tabIndex .. " slotOrder has invalid slot " .. tostring(slotIndex)
                    end
                    if not tab.items[itemID] then
                        return false, "tab " .. tabIndex .. " slotOrder references itemID " .. tostring(itemID)
                            .. " with no matching items[] entry"
                    end
                end
            end
        elseif mode ~= "ignore" then
            return false, "tab " .. tabIndex .. " has unknown mode " .. tostring(mode)
        end
    end

    if overflowCount ~= 1 then
        return false, "exactly one tab must be mode=overflow (found " .. overflowCount .. ")"
    end

    return true, nil
end

--- Save a layout to storage. Returns ok, errorMessage.
-- @param layout table produced by GetBankLayout (or constructed fresh).
-- @param updatedBy string|nil player name of the editor (defaults to UnitName("player")).
function GBL:SaveBankLayout(layout, updatedBy)
    if not self:HasLayoutWrite() then
        return false, "you do not have layout-write access for this guild"
    end

    local ok, err = BankLayout.Validate(layout)
    if not ok then return false, err end

    local guild = getStore(self)
    if not guild then return false, "no active guild" end

    local prev = guild.bankLayout or { version = 0 }
    local nextVersion = (prev.version or 0) + 1

    local store = { version = nextVersion, tabs = {}, updatedAt = GetServerTime(),
                    updatedBy = updatedBy or (UnitName and UnitName("player")) or nil }
    for tabIndex, tab in pairs(layout.tabs) do
        store.tabs[tabIndex] = copyTab(tab)
    end
    guild.bankLayout = store

    -- Advertise the new layout promptly so officers pull it without waiting for
    -- the next gossip tick. The forced HELLO is rate-limited
    -- (FORCED_HELLO_COOLDOWN), so rapid saves coalesce. Mirrors SaveSortAccess.
    if self.BroadcastHello then self:BroadcastHello(true) end

    return true, nil
end

--- Build the wire payload for layout sync: the layout template plus stock
-- reserves, bundled under one cursor (bankLayout.updatedAt). Returns nil when
-- no layout has been saved yet (version 0), so callers can skip the send.
-- Because version > 0 only happens via SaveBankLayout (which validates first),
-- a non-nil payload is always a structurally valid layout.
-- @return table|nil { bankLayout, stockReserves }
function GBL:BuildLayoutPayload()
    local guild = getStore(self)
    if not guild then return nil end
    local bl = guild.bankLayout
    if not bl or (bl.version or 0) <= 0 then return nil end
    return {
        bankLayout = self:GetBankLayout(),       -- deep copy, severed from storage
        stockReserves = self:GetStockReserves(),  -- deep copy
    }
end

--- Adopt a layout payload arriving from a guildmate over sync. Bypasses the
-- HasLayoutWrite gate (this is sync intake, not a local edit) but validates the
-- structure and only replaces local state when the remote copy is strictly
-- newer (last-writer-wins on bankLayout.updatedAt). Preserves the remote
-- version/updatedAt/updatedBy verbatim so the cursor stays coherent guild-wide.
-- @param payload table { bankLayout, stockReserves }
-- @param _fromPeer string|nil canonical peer key (for logging by the caller)
-- @return boolean changed, string|nil err
function GBL:AdoptRemoteBankLayout(payload, _fromPeer)
    if type(payload) ~= "table" or type(payload.bankLayout) ~= "table" then
        return false, "payload.bankLayout missing"
    end
    local incoming = payload.bankLayout
    local ok, err = BankLayout.Validate(incoming)
    if not ok then return false, err end

    local guild = getStore(self)
    if not guild then return false, "no active guild" end

    local localTS = (guild.bankLayout and guild.bankLayout.updatedAt) or 0
    local remoteTS = incoming.updatedAt or 0
    if remoteTS <= localTS then
        return false, nil  -- not newer; nothing to do (not an error)
    end

    -- Deep-copy the template into storage, severing the network table ref and
    -- keeping only the fields we recognize. updatedAt/version/updatedBy are
    -- preserved from the remote so guild-wide last-writer-wins stays coherent.
    local store = {
        version = incoming.version or 0,
        updatedAt = remoteTS,
        updatedBy = incoming.updatedBy,
        tabs = {},
    }
    for tabIndex, tab in pairs(incoming.tabs or {}) do
        store.tabs[tabIndex] = copyTab(tab)
    end
    guild.bankLayout = store

    -- Stock reserves ride the same cursor; replace wholesale.
    local reserves = {}
    if type(payload.stockReserves) == "table" then
        for itemID, n in pairs(payload.stockReserves) do
            if type(itemID) == "number" and type(n) == "number" and n > 0 then
                reserves[itemID] = math.floor(n)
            end
        end
    end
    guild.stockReserves = reserves

    return true, nil
end

--- Set the reserve count for an item (beyond display-tab totals).
-- A reserve of 0 or nil removes the entry.
function GBL:SetStockReserve(itemID, reserve)
    if not self:HasLayoutWrite() then
        return false, "you do not have layout-write access for this guild"
    end
    if type(itemID) ~= "number" then return false, "itemID must be numeric" end
    local guild = getStore(self)
    if not guild then return false, "no active guild" end
    if not reserve or reserve <= 0 then
        guild.stockReserves[itemID] = nil
    else
        guild.stockReserves[itemID] = math.floor(reserve)
    end
    -- Reserves are part of the layout config and ride its sync cursor. Bump the
    -- cursor so the change re-advertises, but only when a valid layout already
    -- exists (version > 0 implies SaveBankLayout validated it). This keeps the
    -- invariant "version > 0 ⇒ structurally valid", so the advertise gate never
    -- ships an unservable layout. Reserves set before any layout is configured
    -- stay local until a layout exists.
    if guild.bankLayout and (guild.bankLayout.version or 0) > 0 then
        guild.bankLayout.version = guild.bankLayout.version + 1
        guild.bankLayout.updatedAt = GetServerTime()
    end
    return true, nil
end

--- Capture the live contents of a tab into a display-tab template.
-- Reads the most recent scan results (GetLastScanResults) for the tab and
-- emits {items, slotOrder} matching what is currently present.
-- Stacks of the same item inside the captured tab are collapsed: slots ← count
-- of distinct slots holding the item, perSlot ← the most common stack size
-- observed (ties break toward the larger number so oversize stacks don't get
-- locked in as the template target).
--
-- @param tabIndex number
-- @return table|nil template table { mode="display", items=..., slotOrder=..., name= }
-- @return string|nil error message on failure
function GBL:CaptureTabLayout(tabIndex)
    if type(tabIndex) ~= "number" then
        return nil, "tabIndex must be numeric"
    end
    local results = self.lastScanResults
    if not results or not results[tabIndex] then
        return nil, "no scan results for tab " .. tabIndex
    end
    local tabResult = results[tabIndex]

    local items = {}          -- itemID -> { slots, stackCounts = { perSlot -> occurrences } }
    local slotOrder = {}

    for slotIndex = 1, MAX_SLOTS do
        local slot = tabResult.slots and tabResult.slots[slotIndex]
        if slot then
            local itemID = extractItemID(slot.itemLink)
            if itemID then
                slotOrder[slotIndex] = itemID
                local entry = items[itemID]
                if not entry then
                    entry = { slots = 0, stackCounts = {} }
                    items[itemID] = entry
                end
                entry.slots = entry.slots + 1
                local sz = slot.count or 1
                entry.stackCounts[sz] = (entry.stackCounts[sz] or 0) + 1
            end
        end
    end

    local finalItems = {}
    for itemID, entry in pairs(items) do
        -- Pick the mode stack size; tiebreak toward larger.
        local bestSize, bestOccur = 1, -1
        for sz, occur in pairs(entry.stackCounts) do
            if occur > bestOccur or (occur == bestOccur and sz > bestSize) then
                bestSize = sz
                bestOccur = occur
            end
        end
        finalItems[itemID] = { slots = entry.slots, perSlot = bestSize }
    end

    local tabName = nil
    if GetGuildBankTabInfo then
        local name = GetGuildBankTabInfo(tabIndex)
        tabName = name
    end

    return {
        mode = "display",
        name = tabName,
        items = finalItems,
        slotOrder = slotOrder,
    }, nil
end

--- Utility: clear the layout entirely (used by tests and a future /gbl reset).
function GBL:ResetBankLayout()
    local guild = getStore(self)
    if not guild then return end
    guild.bankLayout = { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    emptyTable(guild.stockReserves)
end

--- Expose extractItemID for reuse by SortPlanner / tests.
BankLayout.ExtractItemID = extractItemID
