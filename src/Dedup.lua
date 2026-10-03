------------------------------------------------------------------------
-- GuildBankLedger — Dedup.lua
-- Deduplication engine (hour-bucket fuzzy matching)
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Timestamp validation
------------------------------------------------------------------------

local MIN_VALID_TIMESTAMP = 1072915200  -- 2004-01-01, before WoW launch

--- Check whether a timestamp is plausible (post-2004, before WoW existed).
-- @param ts any Value to check
-- @return boolean True if ts is a valid WoW-era timestamp
function GBL:IsValidTimestamp(ts)
    return type(ts) == "number" and ts >= MIN_VALID_TIMESTAMP
end

--- Return the record's timestamp if valid, otherwise the current server time.
-- Used wherever we need a record's effective timestamp without risking a
-- bogus epoch-0 value (see v0.27.0 epoch-0 fix). Callers include the
-- migration paths in Core.lua that rebuild seenTxHashes, and the
-- sender-wins reconciliation in Sync.lua's NormalizeRecordId.
-- @param record table Transaction record (must be a table)
-- @return number A WoW-era server-time timestamp
function GBL:SafeRecordTimestamp(record)
    return self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
end

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
    local timeSlot = math.floor((record.timestamp or GetServerTime()) / 3600)
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
    local incomingTs = record.timestamp or GetServerTime()

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
    guildData.seenTxHashes[hash] = GBL:IsValidTimestamp(timestamp) and timestamp or GetServerTime()
end

------------------------------------------------------------------------
-- Batch occurrence indexing
------------------------------------------------------------------------

--- Assign unique occurrence indices to records with identical base hashes.
-- Two withdrawals of 20 potions in the same hour get :0 and :1 suffixes,
-- making their record.id unique for dedup.
-- Counts per baseHash (prefix + timeSlot) so records in different hour slots
-- have independent counters.
-- NOTE: Dead code in production — no caller in src/, UI/ or scripts/. This
-- note used to read "only used for sync records and migrations", which was a
-- false claim about record identity, the one subject where a wrong belief is
-- expensive: since v0.37.0 peers on different versions exchange records, so two
-- buildPrefix implementations that disagree duplicate a guild's dataset instead
-- of refusing each other (#262). Retained for test coverage of the occurrence
-- suffix, like CountStoredAtSlot below. Sync intake and the migrations assign
-- ids through ComputeTxHash and NormalizeRecordId; local batch storage uses
-- count-based dedup (StoreBatchRecords), which is immune to index shift.
-- NOT idempotent: a second run reads an already-suffixed id as a base hash and
-- yields hash:0:0, which nothing can reach while nothing calls it.
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
-- NOTE: Dead code in production after v0.14.3 refactor — only called by
-- CountStoredForHash (also dead) and tests. Retained for test coverage of
-- the seenTxHashes data structure. StoreBatchRecords now uses
-- BuildStoredRecordIndex (immune to gaps) and MaxOccurrenceAtSlot.
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

--- Find the next available occurrence index at a slot in seenTxHashes.
-- Unlike CountStoredAtSlot, this scans past gaps so that new records
-- never collide with existing entries (gaps can appear after sync
-- normalization moves a record to a different slot).
-- @param baseHash string Base hash (prefix + timeSlot)
-- @param guildData table Guild data table
-- @return number Next available occurrence index
function GBL:MaxOccurrenceAtSlot(baseHash, guildData)
    if not guildData or not guildData.seenTxHashes then return 0 end
    local maxOcc = -1
    for occ = 0, 999 do
        if guildData.seenTxHashes[baseHash .. ":" .. occ] then
            maxOcc = occ
        elseif occ > maxOcc + 50 then
            break  -- safety bound: stop scanning after 50 consecutive misses
        end
    end
    return maxOcc + 1
end

--- Build an index of stored records by prefix → slot → count.
-- Scans the actual records array (ground truth), not seenTxHashes.
-- This avoids undercounting caused by gaps in seenTxHashes occurrence
-- sequences (which sync normalization can create).
-- @param guildData table Guild data from AceDB
-- @param storageKey string "transactions" or "moneyTransactions"
-- @return table Index: {[prefix] = {[slot] = count}}
function GBL:BuildStoredRecordIndex(guildData, storageKey)
    local index = {}
    for _, record in ipairs(guildData[storageKey] or {}) do
        local prefix = buildPrefix(record)
        local slot = math.floor((record.timestamp or GetServerTime()) / 3600)
        if not index[prefix] then index[prefix] = {} end
        index[prefix][slot] = (index[prefix][slot] or 0) + 1
    end
    return index
end

--- Count stored records matching a baseHash from a pre-built record index.
-- Sums counts at the exact slot AND both adjacent slots (±1).
-- Unlike the old CountStoredForHash (which returned at the first adjacent
-- match), this correctly handles records split across multiple slots by
-- sync normalization.
-- @param storedIndex table Index from BuildStoredRecordIndex
-- @param baseHash string Base hash (prefix + timeSlot)
-- @return number Count of stored records matching this prefix ±1 slot
function GBL:CountFromRecordIndex(storedIndex, baseHash)
    local prefix, slot = self:SplitBaseHash(baseHash)
    if not prefix or not slot then return 0 end
    local bySlot = storedIndex[prefix]
    if not bySlot then return 0 end
    local count = 0
    for s = slot - 1, slot + 1 do
        count = count + (bySlot[s] or 0)
    end
    return count
end

--- Count stored occurrences for a baseHash, including adjacent-slot drift.
-- Checks the exact slot first; if 0 found, probes adjacent slots with
-- timestamp proximity.
-- NOTE: Dead code in production after v0.14.3 refactor — no callers
-- outside tests. Retained for test coverage. Has a known early-return
-- limitation (returns at first adjacent match without checking the other
-- side). StoreBatchRecords now uses BuildStoredRecordIndex + CountFromRecordIndex.
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
-- Sums counts from both adjacent slots to handle records split across
-- slots (e.g. after sync normalization).
-- @param baseHash string Current baseHash
-- @param prevCounts table Previous batch counts {[baseHash] = count}
-- @return number Count from adjacent slots
function GBL:FindDriftedCount(baseHash, prevCounts)
    if not prevCounts then return 0 end
    local prefix, slot = self:SplitBaseHash(baseHash)
    if not slot then return 0 end

    local count = 0
    for _, adjSlot in ipairs({ slot - 1, slot + 1 }) do
        local adjHash = prefix .. adjSlot
        if prevCounts[adjHash] then
            count = count + prevCounts[adjHash]
        end
    end
    return count
end

--- Store a batch of records using count-based dedup.
-- Groups records by baseHash, compares counts against previously-known
-- state (session cache or actual records array), and stores only the excess.
-- Immune to occurrence index shift because it compares counts, not positions.
--
-- For initial scan (prevCounts=nil): counts from the actual records array
-- via BuildStoredRecordIndex. This is immune to gaps in seenTxHashes
-- caused by sync normalization, and sums across all ±1 adjacent slots.
--
-- For rescan (prevCounts present): compares against the session-local cache
-- which is always internally consistent.
-- @param batch table Array of records (each with .id = baseHash from ComputeTxHash)
-- @param guildData table Guild data from AceDB
-- @param storageKey string "transactions" or "moneyTransactions"
-- @param prevCounts table|nil Session-local previous batch counts (nil for initial scan)
-- @return number stored Count of newly stored records
-- @return table currentCounts The batch counts for session cache update
-- @return number refused New records the type and player check turned away,
--   which the ledger log reports (#85)
function GBL:StoreBatchRecords(batch, guildData, storageKey, prevCounts)
    if not guildData then return 0, {}, 0 end

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

    -- For initial scan: build index from actual records (ground truth).
    -- Built once and NOT updated as records are stored in the loop below.
    -- This is safe because each group has a unique baseHash (same event
    -- always maps to the same slot within a single scan), so newly stored
    -- records from one group cannot affect another group's count.
    local storedIndex
    if not prevCounts then
        storedIndex = self:BuildStoredRecordIndex(guildData, storageKey)
    end

    local stored, refused = 0, 0
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
            -- Initial scan: count from actual records array (±1 adjacent slots)
            alreadyKnown = self:CountFromRecordIndex(storedIndex, baseHash)
        end

        local newCount = math.max(0, batchCount - alreadyKnown)

        if newCount > 0 then
            -- Find next available occurrence index, scanning past gaps
            local nextOcc = self:MaxOccurrenceAtSlot(baseHash, guildData)

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
                    -- A first-time item deposit may settle a pending
                    -- restock purchase (#209). StoreTx has the same call.
                    -- Not gated on storageKey: a money record carries no
                    -- itemID and the hook ignores it (a guard here survived
                    -- its mutation for that reason).
                    if self._RestockOnRecordStored then
                        self:_RestockOnRecordStored(record, guildData)
                    end
                    stored = stored + 1
                else
                    refused = refused + 1
                end
            end
        end
    end

    -- Persist API-observed event counts (ground truth for cleanup).
    -- Uses max: never decrease, since events age out of the WoW API
    -- but the historical high-water mark is the correct count.
    if not guildData.eventCounts then guildData.eventCounts = {} end
    local now = GetServerTime()
    for _, baseHash in ipairs(order) do
        local batchCount = currentCounts[baseHash]
        local existing = guildData.eventCounts[baseHash]
        if not existing or batchCount > existing.count then
            guildData.eventCounts[baseHash] = { count = batchCount, asOf = now }
        end
    end

    return stored, currentCounts, refused
end

------------------------------------------------------------------------
-- Maintenance
------------------------------------------------------------------------

--- The 6-hour fingerprint bucket an event count entry describes.
--
-- The entry's OWN bucket, which is one member of its ride set. It was lifted
-- out for two production callers, the ride predicate and PrepareChunks, and
-- #270 moved both of them to EventCountRideBuckets, because a count on a bucket
-- edge is owed to the neighbouring bucket as well as its own. #275 then gave
-- the predicate its own reading of the own bucket, beside the records in the
-- send, since it needs the prefix from the same split.
--
-- NOTE: no production callers since #270. Retained because the specs, and the
-- chunking spec's indexByBucket helper, read it to say where a bucket's OWN
-- entries landed, which is a different question from which buckets may carry
-- them. Do not reintroduce it as the whole filter or as a packing key: that is
-- the defect #270 fixed.
-- @param baseHash string An eventCounts key (record id prefix plus time slot)
-- @return number|nil Bucket key, or nil when the key carries no readable slot
function GBL:BucketKeyForEventCount(baseHash)
    local _, slot = self:SplitBaseHash(baseHash)
    if not slot then return nil end
    return self:BucketKeyForTimeSlot(slot)
end

--- The 6-hour buckets whose records could use this event count entry.
---
--- A record at slot Y can be trimmed by a count at slot X exactly when Y is in
--- the count's side of EventCountWindow, so this entry is worth sending to a peer
--- receiving bucket B exactly when B holds one of the slots in that window.
--- That is one bucket for a slot in the middle of a bucket and two for a slot
--- on either edge of one.
---
--- The packer indexes every entry under this set, and the serve's filter may
--- only ever admit an entry for a bucket inside it (#275 narrowed the filter to
--- a subset). Admitting one outside it would reintroduce the loss #114 closed:
--- PrepareChunks files an entry under a bucket and emits it at that bucket's
--- first record, and a boundary count's own bucket has no records in the send,
--- so the entry would fall to the trailing carriers an abort discards.
---
--- Computed through BucketKeyForTimeSlot rather than by arithmetic on
--- slot % 6, so the bucket width stays in the one place that owns it. The
--- result is strictly ascending, because BucketKeyForTimeSlot does not
--- decrease as the slot rises, which is what makes comparing against the last
--- member enough to deduplicate.
--- @param baseHash string An eventCounts key (record id prefix plus time slot)
--- @return table|nil Ascending bucket keys, or nil when the key carries no slot
function GBL:EventCountRideBuckets(baseHash)
    local _, slot = self:SplitBaseHash(baseHash)
    if not slot then return nil end

    -- The span of record slots this count can trim, reflected from the
    -- record-side window (see EventCountWindow in Core.lua).
    local first, last = self:EventCountWindow()
    local buckets = {}
    for s = slot - last, slot - first do
        local bucket = self:BucketKeyForTimeSlot(s)
        if buckets[#buckets] ~= bucket then
            buckets[#buckets + 1] = bucket
        end
    end
    return buckets
end

--- Does this eventCounts entry belong with the buckets a session is sending?
--
-- The per-entry rule, on its own because its one caller, stage 6 of the sliced
-- serve (#115), crosses the table a few hundred entries at a time across
-- frames. It used to have a second caller, a synchronous walk that collected
-- the whole table in one pass; that walk lost its last production caller when
-- the serve was sliced (v0.37.17) and was deleted rather than kept agreeing
-- with a rule nothing ran.
--
-- A nil filter means send everything, which is the fallback path where there
-- are no bucket keys to compare against.
--
-- An entry rides with its own bucket, which is the rule from before #270, and
-- with a neighbouring bucket only when the send carries a record it can trim:
-- one of its prefix whose slot is inside EventCountWindow of its own. That is
-- CleanupWithEventCounts' lookup (prefix .. s across the window) run from the
-- count's side, so a count admitted through a neighbour has a record in this
-- very send that the receiver's cleanup can apply it to.
--
-- The record is read by its id, prefix and slot both, where the receiver's
-- cleanup groups by BuildTxPrefix over its fields and takes the slot from its
-- timestamp. The two agree for every record the builders produce. Where they do
-- not (the roughly 17 records with a corrupt type in docs/DATA-MODEL.md, and 0
-- records whose id slot and timestamp slot differ on the measured store), a
-- count can go out that the receiver cannot apply, or not go out through the
-- neighbour. The id is the reading on purpose, because #114's guarantee below is
-- over the packer's reading of a record, and the packer reads the id.
--
-- Both halves exist for a measured reason. #270 found 46 of 16,644 counts one
-- hour across a boundary from their records, usable locally and unsendable
-- under the own-bucket test. #270's answer, any bucket in the ride set, also
-- admitted every count on a bucket edge whose neighbour happened to be going
-- out, +25.8% entries per bucket, and #275 measured that 3,330 of those 4,328
-- admissions had no record of their prefix in the window. A slot match alone
-- (any prefix in the window) was the reading #275 was filed with and kept
-- 3,870 of them, because most hours on a bucket edge hold some record.
--
-- Everything admitted stays inside the ride set the packer files the entry
-- under: the own bucket is in it, and a record at slot s in the window sits in
-- BucketKeyForTimeSlot(s), which is in it by construction. That is what keeps
-- #114's ordering, since an entry is emitted at the first record of whichever
-- ride bucket comes up first. It holds only while sentBaseHashes is read off the
-- same id slot the packer buckets by, which is why it is built through
-- BaseHashForRecord.
-- @param baseHash string An eventCounts key (record id prefix plus time slot)
-- @param diffBuckets table|nil Set of 6-hour bucket keys; nil = everything rides
-- @param sentBaseHashes table|nil Set of BaseHashForRecord keys for the records
--   going out. Nil admits nothing through a neighbour, since nothing is known
--   to be in the send for the count to trim.
-- @return boolean True when the entry should ride along
function GBL:EventCountRidesWithBuckets(baseHash, diffBuckets, sentBaseHashes)
    if not diffBuckets then return true end
    local prefix, slot = self:SplitBaseHash(baseHash)
    if not slot then return false end
    if diffBuckets[self:BucketKeyForTimeSlot(slot)] then return true end
    if not sentBaseHashes then return false end

    local first, last = self:EventCountWindow()
    for s = slot - last, slot - first do
        -- The bucket test first, so the key is only built for a neighbour the
        -- session carries. It is a cost guard: the index holds records of
        -- carried buckets, so it changes no answer, except when a sync chunk
        -- arriving mid-preparation has rewritten a selected record's id across
        -- a bucket edge. There it withholds the count, which is as safe as
        -- admitting it, since the moved record's bucket is in the ride set.
        if diffBuckets[self:BucketKeyForTimeSlot(s)]
            and sentBaseHashes[prefix .. s] then
            return true
        end
    end
    return false
end
