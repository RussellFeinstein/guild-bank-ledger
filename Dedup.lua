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
-- Counts per baseHash (prefix + timeSlot) so records in different hour slots
-- have independent counters.
-- NOTE: Only used for sync records and migrations. Local batch storage uses
-- count-based dedup (StoreBatchRecords) which is immune to index shift.
-- @param records table Array of records (each must have .id from ComputeTxHash)
function GBL:AssignOccurrenceIndices(records)
    local counts = {}
    for _, record in ipairs(records) do
        local baseHash = record.id  -- prefix .. timeSlot (from ComputeTxHash)
        local occ = counts[baseHash] or 0
        counts[baseHash] = occ + 1
        record._occurrence = occ
        record.id = baseHash .. ":" .. occ
    end
end

------------------------------------------------------------------------
-- Count-based batch dedup
------------------------------------------------------------------------

--- Split a baseHash into its prefix and time slot number.
-- baseHash format: "type|player|...|timeSlot"
-- The prefix always ends with "|", followed by the numeric slot.
-- @param baseHash string Base hash from ComputeTxHash
-- @return string prefix, number slot
function GBL:SplitBaseHash(baseHash)
    if not baseHash then return nil, nil end
    local prefix, slotStr = baseHash:match("^(.-)(%d+)$")
    return prefix, tonumber(slotStr)
end

--- Count sequential occurrence entries at an exact slot in seenTxHashes.
-- Scans :0, :1, :2, ... and stops at the first gap.
-- @param baseHash string Base hash (prefix + timeSlot)
-- @param guildData table Guild data table
-- @return number Count of stored occurrences
function GBL:CountStoredAtSlot(baseHash, guildData)
    if not guildData or not guildData.seenTxHashes then return 0 end
    local count = 0
    for occ = 0, 999 do
        if guildData.seenTxHashes[baseHash .. ":" .. occ] then
            count = count + 1
        else
            break
        end
    end
    return count
end

--- Count stored occurrences for a baseHash, including adjacent-slot drift.
-- Used for initial scan dedup (no session cache). Checks the exact slot
-- first; if 0 found, probes adjacent slots with timestamp proximity.
-- @param baseHash string Base hash (prefix + timeSlot)
-- @param batchTimestamp number Timestamp of the batch records
-- @param guildData table Guild data with seenTxHashes
-- @return number Count of stored records matching this hash
function GBL:CountStoredForHash(baseHash, batchTimestamp, guildData)
    if not guildData or not guildData.seenTxHashes then return 0 end

    -- Try exact slot first
    local exactCount = self:CountStoredAtSlot(baseHash, guildData)
    if exactCount > 0 then return exactCount end

    -- Check adjacent slots for hour-boundary drift
    local prefix, slot = self:SplitBaseHash(baseHash)
    if not slot then return 0 end

    for _, adjSlot in ipairs({ slot - 1, slot + 1 }) do
        local adjHash = prefix .. adjSlot
        local adjCount = 0
        for occ = 0, 999 do
            local key = adjHash .. ":" .. occ
            local storedEntry = guildData.seenTxHashes[key]
            if storedEntry then
                local storedTs = type(storedEntry) == "table"
                    and (storedEntry.timestamp or 0) or storedEntry
                if type(storedTs) ~= "number" or storedTs == 0
                    or math.abs(batchTimestamp - storedTs) < 3600 then
                    adjCount = adjCount + 1
                end
            else
                break
            end
        end
        if adjCount > 0 then return adjCount end
    end

    return 0
end

--- Check adjacent slots in a session-local prevCounts table for drift.
-- Used during rescan when hour boundary shifts all baseHashes.
-- @param baseHash string Current baseHash
-- @param prevCounts table Previous batch counts {[baseHash] = count}
-- @return number Count from adjacent slot, or 0
function GBL:FindDriftedCount(baseHash, prevCounts)
    if not prevCounts then return 0 end
    local prefix, slot = self:SplitBaseHash(baseHash)
    if not slot then return 0 end

    for _, adjSlot in ipairs({ slot - 1, slot + 1 }) do
        local adjHash = prefix .. adjSlot
        if prevCounts[adjHash] then
            return prevCounts[adjHash]
        end
    end
    return 0
end

--- Store a batch of records using count-based dedup.
-- Groups records by baseHash, compares counts against previously-known
-- state (session cache or seenTxHashes), and stores only the excess.
-- Immune to occurrence index shift because it compares counts, not positions.
-- @param batch table Array of records (each with .id = baseHash from ComputeTxHash)
-- @param guildData table Guild data from AceDB
-- @param storageKey string "transactions" or "moneyTransactions"
-- @param prevCounts table|nil Session-local previous batch counts (nil for initial scan)
-- @return number stored Count of newly stored records
-- @return table currentCounts The batch counts for session cache update
function GBL:StoreBatchRecords(batch, guildData, storageKey, prevCounts)
    if not guildData then return 0, {} end

    -- Group by baseHash (preserve first-seen order for deterministic storage)
    local groups = {}
    local order = {}
    local currentCounts = {}
    for _, record in ipairs(batch) do
        local baseHash = record.id
        if not groups[baseHash] then
            groups[baseHash] = {}
            order[#order + 1] = baseHash
        end
        groups[baseHash][#groups[baseHash] + 1] = record
        currentCounts[baseHash] = (currentCounts[baseHash] or 0) + 1
    end

    local stored = 0
    for _, baseHash in ipairs(order) do
        local group = groups[baseHash]
        local batchCount = #group
        local alreadyKnown

        if prevCounts then
            -- Rescan: compare with previous batch (immune to seenTxHashes inflation)
            alreadyKnown = prevCounts[baseHash] or 0
            if alreadyKnown == 0 then
                alreadyKnown = self:FindDriftedCount(baseHash, prevCounts)
            end
        else
            -- Initial scan: count from seenTxHashes (with adjacent-slot drift)
            alreadyKnown = self:CountStoredForHash(
                baseHash, group[1].timestamp or 0, guildData)
        end

        local newCount = math.max(0, batchCount - alreadyKnown)

        if newCount > 0 then
            -- Find next available occurrence index at this slot
            local nextOcc = self:CountStoredAtSlot(baseHash, guildData)

            -- Validate records and store
            for i = 1, newCount do
                local record = group[i]
                if record.type and record.type ~= ""
                    and record.player and record.player ~= "" then
                    record._occurrence = nextOcc
                    record.id = baseHash .. ":" .. nextOcc
                    nextOcc = nextOcc + 1

                    self:MarkSeen(record.id, record.timestamp, guildData)
                    guildData[storageKey][#guildData[storageKey] + 1] = record
                    self:UpdatePlayerStats(record, guildData)
                    stored = stored + 1
                end
            end
        end
    end

    return stored, currentCounts
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
