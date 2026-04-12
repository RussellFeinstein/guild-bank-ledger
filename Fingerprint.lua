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
    return math.floor((tx.timestamp or 0) / BUCKET_SECONDS)
end

--- Exposed for use by Sync.lua bucket filtering.
function GBL:BucketKeyForRecord(tx)
    return bucketKeyForRecord(tx)
end

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

--- Reset the hash cache. Exposed for testing.
function GBL:ResetHashCache()
    hashCache.dataHash = 0
    hashCache.txCount = -1
end
