------------------------------------------------------------------------
-- GuildBankLedger — Dedup.lua
-- Deduplication engine (hour-bucket fuzzy matching)
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Hash computation
------------------------------------------------------------------------

--- Build the hash prefix for a record (everything before the time slot).
-- Extracted to avoid duplication between ComputeTxHash and IsDuplicate.
local function buildPrefix(record)
    if record.itemID then
        return (record.type or "") .. "|"
            .. (record.player or "") .. "|"
            .. (record.itemID or 0) .. "|"
            .. (record.count or 0) .. "|"
            .. (record.tab or 0) .. "|"
    else
        return (record.type or "") .. "|"
            .. (record.player or "") .. "|"
            .. (record.amount or 0) .. "|"
    end
end

--- Compute a dedup hash key for a transaction record.
-- Item tx key: type|player|itemID|count|tab|hourSlot
-- Money tx key: type|player|amount|hourSlot
-- @param record table Transaction record
-- @return string Hash key, number Time slot
function GBL:ComputeTxHash(record)
    local timeSlot = math.floor((record.timestamp or 0) / 3600)
    local prefix = buildPrefix(record)
    return prefix .. timeSlot, timeSlot
end

------------------------------------------------------------------------
-- Duplicate detection
------------------------------------------------------------------------

--- Check if a transaction is a duplicate by probing 3 adjacent hour slots.
-- @param record table Transaction record
-- @param guildData table Guild data table containing seenTxHashes
-- @return boolean True if duplicate
function GBL:IsDuplicate(record, guildData)
    if not guildData or not guildData.seenTxHashes then
        return false
    end

    local hash = record.id
    if hash and guildData.seenTxHashes[hash] then
        return true
    end

    -- Also check adjacent hour slots for drift tolerance (cross-officer sync)
    local _, timeSlot = self:ComputeTxHash(record)
    local prefix = buildPrefix(record)
    local occ = record._occurrence or 0

    for slot = timeSlot - 1, timeSlot + 1 do
        local key = prefix .. slot .. ":" .. occ
        if guildData.seenTxHashes[key] then
            return true
        end
    end

    return false
end

--- Mark a transaction hash as seen.
-- @param hash string Hash key (record.id)
-- @param timestamp number Transaction timestamp (for pruning)
-- @param guildData table Guild data table
function GBL:MarkSeen(hash, timestamp, guildData)
    if not guildData then return end
    guildData.seenTxHashes[hash] = timestamp
end

------------------------------------------------------------------------
-- Batch occurrence indexing
------------------------------------------------------------------------

--- Assign unique occurrence indices to records with identical base hashes.
-- Two withdrawals of 20 potions in the same hour get :0 and :1 suffixes,
-- making their record.id unique for dedup.
-- @param records table Array of records (each must have .id from ComputeTxHash)
function GBL:AssignOccurrenceIndices(records)
    local counts = {}
    for _, record in ipairs(records) do
        local baseHash = record.id
        local occ = counts[baseHash] or 0
        counts[baseHash] = occ + 1
        record._occurrence = occ
        record.id = baseHash .. ":" .. occ
    end
end

------------------------------------------------------------------------
-- Maintenance
------------------------------------------------------------------------

--- Remove seen hashes older than maxAge days.
-- Handles both old format (number) and new format with occurrence suffix.
-- @param maxAgeDays number Maximum age in days (default 90)
-- @param guildData table Guild data table
function GBL:PruneSeenHashes(maxAgeDays, guildData)
    if not guildData or not guildData.seenTxHashes then return end

    maxAgeDays = maxAgeDays or 90
    local cutoff = GetServerTime() - (maxAgeDays * 86400)

    for hash, entry in pairs(guildData.seenTxHashes) do
        local timestamp = type(entry) == "table" and (entry.timestamp or 0) or entry
        if timestamp < cutoff then
            guildData.seenTxHashes[hash] = nil
        end
    end
end
