------------------------------------------------------------------------
-- GuildBankLedger — Dedup.lua
-- Deduplication engine (hour-bucket fuzzy matching with occurrence counting)
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
-- Seen hash helpers (count-aware)
------------------------------------------------------------------------

--- Read the stored count for a hash entry, handling old format migration.
-- Old format: seenTxHashes[hash] = timestamp (number)
-- New format: seenTxHashes[hash] = { count = N, timestamp = T }
-- @param entry any The value from seenTxHashes
-- @return number count, number timestamp
local function readEntry(entry)
    if type(entry) == "table" then
        return entry.count or 1, entry.timestamp or 0
    elseif type(entry) == "number" then
        return 1, entry
    end
    return 0, 0
end

--- Get the stored count for a hash, checking adjacent hour slots.
-- @param record table Transaction record
-- @param guildData table Guild data
-- @return number Total stored count across matching slots
function GBL:GetSeenCount(record, guildData)
    if not guildData or not guildData.seenTxHashes then
        return 0
    end

    local _, timeSlot = self:ComputeTxHash(record)
    local prefix = buildPrefix(record)
    local total = 0

    for slot = timeSlot - 1, timeSlot + 1 do
        local entry = guildData.seenTxHashes[prefix .. slot]
        if entry then
            local count = readEntry(entry)
            total = total + count
        end
    end

    return total
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

    local _, timeSlot = self:ComputeTxHash(record)
    local prefix = buildPrefix(record)

    -- Check 3 adjacent hour slots for drift tolerance
    for slot = timeSlot - 1, timeSlot + 1 do
        if guildData.seenTxHashes[prefix .. slot] then
            return true
        end
    end

    return false
end

--- Mark a transaction hash as seen, incrementing the occurrence count.
-- @param hash string Hash key from ComputeTxHash
-- @param timestamp number Transaction timestamp (for pruning)
-- @param guildData table Guild data table
function GBL:MarkSeen(hash, timestamp, guildData)
    if not guildData then return end

    local entry = guildData.seenTxHashes[hash]
    if type(entry) == "table" then
        entry.count = (entry.count or 1) + 1
        if timestamp > (entry.timestamp or 0) then
            entry.timestamp = timestamp
        end
    elseif type(entry) == "number" then
        -- Migrate old format: number (timestamp) → table
        guildData.seenTxHashes[hash] = {
            count = 2,
            timestamp = math.max(entry, timestamp),
        }
    else
        guildData.seenTxHashes[hash] = { count = 1, timestamp = timestamp }
    end
end

------------------------------------------------------------------------
-- Batch dedup (for ReadTabTransactions / ReadMoneyTransactions)
------------------------------------------------------------------------

--- Given a batch of records from the WoW log, determine which are new.
-- Counts occurrences of each hash in the batch and compares against
-- stored counts. Returns only the records that exceed the stored count.
-- @param records table Array of transaction records (each must have .id set)
-- @param guildData table Guild data
-- @return table Array of records to store (new occurrences only)
function GBL:FilterNewRecords(records, guildData)
    if not guildData then return {} end

    -- Count occurrences per hash in this batch
    local batchCounts = {}
    local batchOrder = {}  -- preserve order for deterministic results
    for _, record in ipairs(records) do
        local hash = record.id
        if not batchCounts[hash] then
            batchCounts[hash] = 0
            table.insert(batchOrder, hash)
        end
        batchCounts[hash] = batchCounts[hash] + 1
    end

    -- Determine how many of each hash to store
    local toStore = {}
    for _, hash in ipairs(batchOrder) do
        local storedCount = self:GetSeenCount(records[1], guildData)
        -- Find a record with this hash to pass to GetSeenCount
        for _, r in ipairs(records) do
            if r.id == hash then
                storedCount = self:GetSeenCount(r, guildData)
                break
            end
        end
        local deficit = batchCounts[hash] - storedCount
        if deficit > 0 then
            toStore[hash] = deficit
        end
    end

    -- Collect the new records (pick the right number per hash)
    local result = {}
    for _, record in ipairs(records) do
        local remaining = toStore[record.id]
        if remaining and remaining > 0 then
            table.insert(result, record)
            toStore[record.id] = remaining - 1
        end
    end

    return result
end

------------------------------------------------------------------------
-- Maintenance
------------------------------------------------------------------------

--- Remove seen hashes older than maxAge days.
-- Handles both old format (number) and new format (table).
-- @param maxAgeDays number Maximum age in days (default 90)
-- @param guildData table Guild data table
function GBL:PruneSeenHashes(maxAgeDays, guildData)
    if not guildData or not guildData.seenTxHashes then return end

    maxAgeDays = maxAgeDays or 90
    local cutoff = GetServerTime() - (maxAgeDays * 86400)

    for hash, entry in pairs(guildData.seenTxHashes) do
        local _, timestamp = readEntry(entry)
        if timestamp < cutoff then
            guildData.seenTxHashes[hash] = nil
        end
    end
end
