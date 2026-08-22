------------------------------------------------------------------------
-- GuildBankLedger — Fingerprint.lua
-- Dataset fingerprinting for efficient sync (skip redundant transfers)
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Hash primitives
------------------------------------------------------------------------

--- djb2 string hash, pure Lua 5.1.
-- Produces a 32-bit unsigned integer from any string.
-- Not cryptographic — designed for fast, well-distributed fingerprinting.
-- @param str string Input string
-- @return number Hash value (0 to 2^32-1)
function GBL:HashString(str)
    if not str then return 0 end
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + string.byte(str, i)) % 4294967296
    end
    return h
end

--- 32-bit XOR.
-- Uses WoW's bit library when available, pure Lua fallback for tests.
-- @param a number First operand (0 to 2^32-1)
-- @param b number Second operand (0 to 2^32-1)
-- @return number XOR result
local xor32
if bit and bit.bxor then
    xor32 = bit.bxor
else
    xor32 = function(a, b)
        local r, v = 0, 1
        for _ = 1, 32 do
            if a % 2 ~= b % 2 then r = r + v end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            v = v * 2
        end
        return r
    end
end

function GBL:XOR32(a, b)
    return xor32(a, b)
end

------------------------------------------------------------------------
-- Dataset fingerprints
------------------------------------------------------------------------

-- Session cache for ComputeDataHash (invalidated when txCount changes)
local hashCache = {
    dataHash = 0,
    txCount = -1,
}

--- Compute the global dataHash for a guild's entire dataset.
-- XORs the djb2 hash of every record.id across both transaction arrays.
-- Order-independent (XOR is commutative and associative).
-- @param guildData table Guild data from AceDB
-- @return number Combined fingerprint (0 if empty)
function GBL:ComputeDataHash(guildData)
    if not guildData then return 0 end
    local h = 0
    for _, tx in ipairs(guildData.transactions) do
        if tx.id then h = xor32(h, self:HashString(tx.id)) end
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        if tx.id then h = xor32(h, self:HashString(tx.id)) end
    end
    return h
end

--- Get the cached dataHash, recomputing only when txCount changes.
-- @param guildData table Guild data from AceDB
-- @return number Cached or freshly computed dataHash
function GBL:GetDataHash(guildData)
    if not guildData then return 0 end
    local count = #guildData.transactions + #guildData.moneyTransactions
    if count ~= hashCache.txCount then
        hashCache.dataHash = self:ComputeDataHash(guildData)
        hashCache.txCount = count
    end
    return hashCache.dataHash
end

------------------------------------------------------------------------
-- Bucket fingerprints (6-hour windows)
------------------------------------------------------------------------

local BUCKET_SECONDS = 21600  -- 6 hours
local BUCKET_HOURS = 6        -- hours per bucket (21600 / 3600)
GBL.BUCKET_SECONDS = BUCKET_SECONDS

--- Extract the 6-hour bucket key from a record's ID.
-- Uses the timeSlot embedded in the ID (format: prefix|timeSlot:occ) so
-- that bucket placement is consistent across peers after ID normalization.
-- Falls back to tx.timestamp when the ID can't be parsed (legacy records).
-- @param tx table Transaction record with .id and .timestamp
-- @return number Bucket key
local function bucketKeyForRecord(tx)
    if tx.id then
        -- ID format: "type|player|...|timeSlot:occurrence"
        local timeSlot = tx.id:match("|(%d+):%d+$")
        if timeSlot then
            return math.floor(tonumber(timeSlot) / BUCKET_HOURS)
        end
    end
    -- Fallback for records without parseable IDs
    return math.floor((tx.timestamp or GetServerTime()) / BUCKET_SECONDS)
end

--- Exposed for use by Sync.lua bucket filtering.
function GBL:BucketKeyForRecord(tx)
    return bucketKeyForRecord(tx)
end

--- Convert an hourly time slot to the 6-hour bucket that contains it.
--
-- The same arithmetic bucketKeyForRecord applies once it has parsed a slot out
-- of a record id, exposed for callers that already hold the slot. Dedup.lua
-- gets there from a base hash rather than from a record, and had been spelling
-- the six out as a literal, so the bucket width lived in two places.
-- @param slot number Hours since epoch, as embedded in a record id
-- @return number Bucket key
function GBL:BucketKeyForTimeSlot(slot)
    return math.floor(slot / BUCKET_HOURS)
end

-- Session cache for ComputeBucketHashes.
--
-- Keyed by the guildData table itself as well as the record count. GetDataHash
-- keys on the count alone, which is survivable for a whole-dataset hash, but
-- this map decides which buckets a sync offers: handing one guild's map to
-- another whose record count happened to match would offer the wrong records.
-- Comparing the table identity costs nothing and removes the question.
local bucketCache = {
    source = nil,
    txCount = -1,
    buckets = nil,
}

--- Compute per-bucket fingerprints for delta sync.
-- Groups records by 6-hour window derived from the timeSlot in their ID
-- (not tx.timestamp) so that bucket placement is consistent across peers
-- even when timestamps differ for the same normalized record.
-- @param guildData table Guild data from AceDB
-- @return table Map of bucketKey (number) → bucket hash (number)
function GBL:ComputeBucketHashes(guildData)
    if not guildData then return {} end
    local buckets = {}
    for _, tx in ipairs(guildData.transactions) do
        if tx.id then
            local key = bucketKeyForRecord(tx)
            buckets[key] = xor32(buckets[key] or 0, self:HashString(tx.id))
        end
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        if tx.id then
            local key = bucketKeyForRecord(tx)
            buckets[key] = xor32(buckets[key] or 0, self:HashString(tx.id))
        end
    end
    return buckets
end

--- Get per-bucket fingerprints, recomputing only when the dataset changes.
--
-- ComputeBucketHashes walks every record and hashes each id, and serving one
-- SYNC_REQUEST asked for that map three times over (the bucket diff, the
-- request builder, and the HELLO diagnostic), on a history that grows without
-- bound. Those repeated passes are part of what trips the script watchdog on a
-- large history (#115).
--
-- Same invalidation contract as GetDataHash, and it shares ResetHashCache, so
-- every caller that already invalidates one invalidates both. That contract
-- holds because only `record.id` feeds a bucket hash: changing any other field
-- on a record cannot strand this cache, while rewriting an id in place without
-- changing the record count can, which is exactly what the migrations and
-- CleanupWithEventCounts call ResetHashCache for.
--
-- Returns the cached table itself rather than a copy. Treat it as read-only:
-- mutating it corrupts every bucket diff that follows, until something
-- invalidates the cache. Every caller today only reads.
-- @param guildData table Guild data from AceDB
-- @return table Map of bucketKey (number) to bucket hash (number)
function GBL:GetBucketHashes(guildData)
    if not guildData then return {} end
    local count = #guildData.transactions + #guildData.moneyTransactions
    if bucketCache.source ~= guildData or bucketCache.txCount ~= count then
        bucketCache.buckets = self:ComputeBucketHashes(guildData)
        bucketCache.source = guildData
        bucketCache.txCount = count
    end
    return bucketCache.buckets
end

--- Return the cached bucket map if one is already built, otherwise nil.
--
-- The read-only companion to GetBucketHashes, for a caller that wants the map
-- only if getting it is free. The case it exists for is HandleHello's bucket
-- count: printing that number is worth nothing to a peer and cost a full walk
-- over every record on every inbound HELLO, worst exactly during a receive,
-- where the record count moves with each stored chunk so the cache misses
-- every time and the walk lands on the busiest client in the guild.
--
-- Deliberately does NOT validate the record count. A bucket count is a slowly
-- changing number and a few records out of date does not change what a reader
-- learns from it, whereas going cold whenever the count moved would return nil
-- for the whole of a receive, which is when the diagnostic is most wanted. The
-- guildData identity IS checked: a stale count misreports by a few, but
-- another guild's map is a different number about data we are not looking at.
--
-- Anything that needs the correct answer calls GetBucketHashes. Read-only, same
-- as GetBucketHashes: this is the cached table itself, not a copy.
-- @param guildData table Guild data the map must belong to
-- @return table|nil Cached bucket map, or nil when cold or built elsewhere
function GBL:PeekBucketHashes(guildData)
    if not guildData or bucketCache.source ~= guildData then return nil end
    return bucketCache.buckets
end

--- Return the cached bucket map only when it is current, otherwise nil.
--
-- The difference from PeekBucketHashes is the record-count check: this one
-- answers "can I use this as the truth" rather than "is there something to
-- print". The sliced serving pipeline asks it first, and only builds a scan
-- when the answer is nil, so a warm cache still costs one comparison.
-- Read-only, same as the other two accessors.
-- @param guildData table Guild data the map must belong to
-- @return table|nil The cached map when it is current, otherwise nil
function GBL:_FreshBucketHashes(guildData)
    if not guildData then return nil end
    local count = #guildData.transactions + #guildData.moneyTransactions
    if bucketCache.source == guildData and bucketCache.txCount == count then
        return bucketCache.buckets
    end
    return nil
end

--- Begin a bucket-hash computation that can be advanced a slice at a time.
--
-- ComputeBucketHashes does the whole walk in one execution slice, which is one
-- of the passes that trips the script watchdog when a large-history client
-- serves a SYNC_REQUEST (#115). This is the same computation, resumable.
--
-- The array lengths are captured here and never re-read, so a record appended
-- while the scan is in flight is simply not walked. That is what keeps the
-- cursor's meaning stable: re-reading #transactions mid-scan would shift the
-- boundary between the two arrays and make one cursor value point at a
-- different record than it did on the previous step.
-- @param guildData table Guild data from AceDB
-- @return table Scan state to hand back to StepBucketHashScan
function GBL:StartBucketHashScan(guildData)
    local nTx, nMoney = 0, 0
    if guildData then
        nTx = #guildData.transactions
        nMoney = #guildData.moneyTransactions
    end
    return { buckets = {}, cursor = 0, nTx = nTx, total = nTx + nMoney }
end

--- Advance a bucket-hash scan by at most `budget` records.
--
-- On the step that finishes the walk, the completed map is stamped into the
-- same cache GetBucketHashes uses, so the work is not thrown away.
--
-- The stamp carries the count captured at scan start rather than the count
-- now. Anything appended mid-scan is missing from the map, and a stamp
-- claiming the current count would hand the next reader a map quietly short of
-- records; reporting the starting count makes the next read see a mismatch and
-- recompute instead. Wrong in the direction that costs a walk, not the
-- direction that loses records.
-- @param guildData table Guild data from AceDB
-- @param scan table State from StartBucketHashScan
-- @param budget number Maximum records to walk on this step
-- @return number How many records were walked
-- @return boolean True when the scan is complete and the cache is stamped
function GBL:StepBucketHashScan(guildData, scan, budget)
    if not guildData or not scan then return 0, true end

    local tx = guildData.transactions
    local money = guildData.moneyTransactions
    local spent = 0

    while spent < budget and scan.cursor < scan.total do
        scan.cursor = scan.cursor + 1
        local rec
        if scan.cursor <= scan.nTx then
            rec = tx[scan.cursor]
        else
            rec = money[scan.cursor - scan.nTx]
        end
        -- A record can be missing if something removed one mid-scan; skipping
        -- it is correct, and the stale stamp already forces a recompute.
        if rec and rec.id then
            local key = bucketKeyForRecord(rec)
            scan.buckets[key] = xor32(scan.buckets[key] or 0, self:HashString(rec.id))
        end
        spent = spent + 1
    end

    if scan.cursor >= scan.total then
        bucketCache.buckets = scan.buckets
        bucketCache.source = guildData
        bucketCache.txCount = scan.total
        return spent, true
    end
    return spent, false
end

------------------------------------------------------------------------
-- Request manifest (bounded SYNC_REQUEST payload)
------------------------------------------------------------------------

-- A SYNC_REQUEST used to carry one entry per 6-hour bucket over the guild's
-- whole history, so it grew forever and crossed AceComm's whisper reliability
-- ceiling at around 230 buckets. The manifest keeps full detail for the recent
-- window, where essentially all divergence lives, and summarizes everything
-- older as a handful of coarse span fingerprints. Size is then fixed no matter
-- how far back the history runs.
local SYNC_REQUEST_DETAIL_BUCKETS = 50
local SYNC_REQUEST_SPAN_COUNT = 8
GBL.SYNC_REQUEST_DETAIL_BUCKETS = SYNC_REQUEST_DETAIL_BUCKETS
GBL.SYNC_REQUEST_SPAN_COUNT = SYNC_REQUEST_SPAN_COUNT

--- Fold every bucket hash in [s, e] into one 32-bit span fingerprint.
-- Order-dependent djb2 over (key, hash) pairs in ascending key order.
--
-- Deliberately NOT XOR. Bucket hashes are themselves XOR aggregates, so an
-- XOR of them flattens to a single XOR over every record in the span: two
-- peers each missing records whose hashes cancel would compute the same span
-- fingerprint over genuinely different data, and because both sides recompute
-- it deterministically every session the divergence would never be seen again.
-- Record IDs are highly structured, which makes that cancellation reachable
-- rather than astronomically unlikely. Weighting each entry by a distinct power
-- of 33 removes the algebraic escape and leaves only honest hash collisions.
-- @param bucketHashes table Map of bucketKey (number) -> hash (number)
-- @param s number First bucket key in the range (inclusive)
-- @param e number Last bucket key in the range (inclusive)
-- @return number Fold value (0 to 2^32-1); the djb2 seed for an empty range
function GBL:FoldBucketRange(bucketHashes, s, e)
    if not bucketHashes then return 5381 end

    local keys = {}
    for key in pairs(bucketHashes) do
        if type(key) == "number" and key >= s and key <= e then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local h = 5381
    for i = 1, #keys do
        local key = keys[i]
        h = (h * 33 + key) % 4294967296
        h = (h * 33 + (bucketHashes[key] or 0)) % 4294967296
    end
    return h
end

--- Split a bucket-hash table into the bounded shape a SYNC_REQUEST carries.
-- The newest SYNC_REQUEST_DETAIL_BUCKETS buckets ride verbatim; everything
-- older is covered by up to SYNC_REQUEST_SPAN_COUNT coarse spans that tile
-- [oldest key .. detailStart-1] with no gaps. Tiling matters: a serving peer
-- holding a bucket this requester has never seen must still fall inside a
-- declared span, or its fold would not change and the bucket would never be
-- offered.
-- @param bucketHashes table|nil Map of bucketKey -> hash, or nil
-- @return table|nil detail Newest buckets, same shape as the input (nil in, nil out)
-- @return table|nil spans Array of { s, e, h }, or nil when nothing is older
function GBL:BuildRequestManifest(bucketHashes)
    if not bucketHashes then return nil, nil end

    local keys = {}
    for key in pairs(bucketHashes) do
        if type(key) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)

    local total = #keys
    local detailCount = math.min(total, SYNC_REQUEST_DETAIL_BUCKETS)
    local olderCount = total - detailCount

    local detail = {}
    for i = olderCount + 1, total do
        detail[keys[i]] = bucketHashes[keys[i]]
    end

    if olderCount == 0 then return detail, nil end

    local detailStart = keys[olderCount + 1]
    local spanCount = math.min(SYNC_REQUEST_SPAN_COUNT, olderCount)
    local base = math.floor(olderCount / spanCount)
    local remainder = olderCount % spanCount

    local spans = {}
    local idx = 1
    for i = 1, spanCount do
        local size = base
        if i <= remainder then size = size + 1 end

        local s = keys[idx]
        idx = idx + size
        -- Each span ends where the next one begins, so the ranges tile rather
        -- than hugging the keys this peer happens to hold.
        local e = (i == spanCount) and (detailStart - 1) or (keys[idx] - 1)

        spans[i] = { s = s, e = e, h = self:FoldBucketRange(bucketHashes, s, e) }
    end

    return detail, spans
end

--- Reset the hash caches. Exposed for testing.
-- Both the dataset hash and the bucket map are invalidated together: they are
-- computed from the same record ids, so anything that strands one strands the
-- other, and every existing caller already fires at exactly those moments.
function GBL:ResetHashCache()
    hashCache.dataHash = 0
    hashCache.txCount = -1
    bucketCache.source = nil
    bucketCache.txCount = -1
    bucketCache.buckets = nil
end
