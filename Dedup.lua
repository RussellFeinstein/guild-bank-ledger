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

--- Expose the prefix builder for external use (e.g. migration).
-- @param record table Transaction record
-- @return string Prefix string (everything before the time slot)
function GBL:BuildTxPrefix(record)
    return buildPrefix(record)
end

------------------------------------------------------------------------
-- Duplicate detection
------------------------------------------------------------------------

--- Check if a transaction is a duplicate by probing 3 adjacent hour slots.
-- Uses timestamp proximity (< 3600s) to avoid false positives: genuinely
-- different events with the same prefix in adjacent hours (e.g. same player
-- repairs for the same amount two hours in a row) are NOT treated as dups.
-- Same event scanned by different clients always has |diff| <= 3599 due to
-- WoW API's hour-level granularity; different events from the same scan
-- always have |diff| == 3600. Strict < 3600 cleanly separates them.
-- @param record table Transaction record
-- @param guildData table Guild data table containing seenTxHashes
-- @return boolean True if duplicate
-- @return string|nil Matched seenTxHashes key on fuzzy match (nil on exact or no match)
function GBL:IsDuplicate(record, guildData)
    if not guildData or not guildData.seenTxHashes then
        return false, nil
    end

    local hash = record.id
    if hash and guildData.seenTxHashes[hash] then
        return true, nil  -- exact match, IDs already converged
    end

    -- Also check adjacent hour slots for drift tolerance (cross-member sync)
    local _, timeSlot = self:ComputeTxHash(record)
    local prefix = buildPrefix(record)
    local occ = record._occurrence or 0
    local incomingTs = record.timestamp or 0

    for slot = timeSlot - 1, timeSlot + 1 do
        local key = prefix .. slot .. ":" .. occ
        local storedEntry = guildData.seenTxHashes[key]
        if storedEntry then
            -- Extract stored timestamp (handles number and legacy table formats)
            local storedTs = type(storedEntry) == "table"
                and (storedEntry.timestamp or 0) or storedEntry
            -- Legacy entries (storedTs == 0) or non-numeric: fall back to match
            if type(storedTs) ~= "number" or storedTs == 0 then
                return true, key
            end
            -- Same event: |diff| <= 3599; different event same-scan: |diff| == 3600
            if math.abs(incomingTs - storedTs) < 3600 then
                return true, key
            end
        end
    end

    return false, nil
end

--- Mark a transaction hash as seen.
-- @param hash string Hash key (record.id)
-- @param timestamp number Transaction timestamp (for pruning)
-- @param guildData table Guild data table
function GBL:MarkSeen(hash, timestamp, guildData)
    if not guildData or not hash then return end
    guildData.seenTxHashes[hash] = timestamp or 0
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
