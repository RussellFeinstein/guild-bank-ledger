------------------------------------------------------------------------
-- spec/wire_contract_spec.lua — pins the sync wire format against the REAL
-- AceSerializer, not the pass-through mock every other spec uses.
--
-- Background: docs/DATA-MODEL.md section 9. spec/mock_ace.lua stubs Serialize to
-- stash a table and hand the same object back, so nothing in this suite has ever
-- encoded a byte. Numeric key survival, escaping, payload size and the
-- cross-version decode contract were all in-game-only claims until this file.
--
-- These are characterization tests, so green on first run is the expected
-- result rather than a smell. What keeps them honest is that every expectation
-- in spec/fixtures/wire/ is hand-written from DATA-MODEL.md instead of pasted
-- from program output, and that each family has a documented mutation that must
-- turn it red.
--
-- Serialization only, no compression. LibDeflate is a pure byte-exact codec this
-- addon neither configures nor extends, so testing it would test LibDeflate
-- rather than GuildBankLedger, and it would mean vendoring 3,600 more lines for
-- the privilege. estimateRecordBytes is documented against AceSerializer output,
-- and the compressed size that matters at runtime is measured live as
-- syncState.lastChunkBytes. See spec/vendor/README.md.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local Wire = require("spec.wire_helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

local RECORD_CASES = dofile("spec/fixtures/wire/records.lua")
local ENVELOPE_CASES = dofile("spec/fixtures/wire/envelopes.lua")

-- The seven fields stripForSync removes, per src/Sync.lua and DATA-MODEL.md
-- section 4. Hand-written: if the production list changes, this must disagree.
local STRIPPED_FIELDS = {
    "itemLink", "category", "tabName", "destTabName", "scanTime", "scannedBy", "_occurrence",
}

-- Plausible values for the stripped fields, used to build a stored record from a
-- wire record. Values are irrelevant; presence is the point.
local STRIPPED_VALUES = {
    itemLink = "|cffa335ee|Hitem:191318::::::::70:::::|h[Phial of Tepid Versatility]|h|r",
    category = "flask",
    tabName = "Consumables",
    destTabName = "Overflow",
    scanTime = 1775587507,
    scannedBy = "Rexxybear-Tichondrius",
    _occurrence = 3,
}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function keySet(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

--- Walk a path of keys into a table, e.g. {"bankLayout", "tabs", 1, "items"}.
local function descend(t, path)
    local node = t
    for _, key in ipairs(path) do
        node = node[key]
        if node == nil then return nil end
    end
    return node
end

--- Collect every table handed to Serialize while fn runs.
-- The serializer mock already records them, so nothing needs stubbing.
local function capturePayloads(fn)
    local first = MockAce._serializedCounter + 1
    fn()
    local out = {}
    for i = first, MockAce._serializedCounter do
        local args = MockAce._serialized[i]
        if args and type(args[1]) == "table" then out[#out + 1] = args[1] end
    end
    return out
end

local function firstOfType(payloads, messageType)
    for _, payload in ipairs(payloads) do
        if payload.type == messageType then return payload end
    end
    return nil
end

describe("Wire contract", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "Test Guild"
        MockWoW.player.name = "OfficerA"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    --------------------------------------------------------------------
    -- Decode direction: frozen bytes in, stored record out.
    --
    -- This is the contract the MIN_SYNC_VERSION floor (#74) rests on. The
    -- strings are what a v0.36.x peer sends and they never change, so a later
    -- release that stops reading them fails here.
    --------------------------------------------------------------------
    describe("decoding frozen records", function()
        for _, case in ipairs(RECORD_CASES) do
            it("deserializes: " .. case.name, function()
                local ok, decoded = Wire.deserialize(case.serialized)
                assert.is_true(ok)
                assert.same(case.stripped, decoded)
            end)

            it("re-serializes to the same shape: " .. case.name, function()
                local ok, decoded = Wire.deserialize(Wire.serialize(case.stripped))
                assert.is_true(ok)
                assert.same(case.stripped, decoded)
            end)

            it("reconstructs: " .. case.name, function()
                local record = copy(Wire.roundTrip(case.stripped))
                local accepted = GBL:_ReconstructSyncRecord(record, "Peer")

                assert.equals(case.accepted, accepted)
                if not case.accepted then return end

                -- Fields the sender supplied must survive untouched. timestamp and
                -- player are excluded because reconstruct legitimately rewrites them.
                for key, value in pairs(case.stripped) do
                    if key ~= "timestamp" and key ~= "player" then
                        assert.equals(value, record[key],
                            ("field %q was not preserved"):format(key))
                    end
                end

                for key, value in pairs(case.reconstructed or {}) do
                    assert.equals(value, record[key],
                        ("reconstructed field %q"):format(key))
                end

                if case.expectNowTimestamp then
                    assert.equals(MockWoW.serverTime, record.timestamp)
                end

                -- Guarantees the docstring makes unconditionally.
                assert.equals(MockWoW.serverTime, record.scanTime)
                assert.equals("sync:Peer-TestRealm", record.scannedBy)
                assert.is_not_nil(record.id)
                assert.is_not_nil(record.timestamp)
            end)
        end

        it("leaves tabName and destTabName nil for BackfillTabNames", function()
            local case = RECORD_CASES[2]  -- the move, the only shape with tab fields
            local record = copy(case.stripped)
            GBL:_ReconstructSyncRecord(record, "Peer")
            assert.is_nil(record.tabName)
            assert.is_nil(record.destTabName)
        end)
    end)

    --------------------------------------------------------------------
    -- Encode direction: stored record in, wire record out.
    --------------------------------------------------------------------
    describe("stripping for the wire", function()
        for _, case in ipairs(RECORD_CASES) do
            it("removes exactly the seven derivable fields: " .. case.name, function()
                local stored = copy(case.stripped)
                for _, field in ipairs(STRIPPED_FIELDS) do
                    stored[field] = STRIPPED_VALUES[field]
                end

                assert.same(case.stripped, GBL:_StripForSync(stored))
            end)
        end

        it("does not mutate the record it was handed", function()
            local stored = copy(RECORD_CASES[1].stripped)
            stored.itemLink = STRIPPED_VALUES.itemLink
            stored.category = "flask"
            local before = copy(stored)

            GBL:_StripForSync(stored)

            assert.same(before, stored)
        end)

        it("round-trips a stripped record through the real codec", function()
            for _, case in ipairs(RECORD_CASES) do
                local ok, back = Wire.deserialize(Wire.serialize(case.stripped))
                assert.is_true(ok)
                assert.same(case.stripped, back)
            end
        end)
    end)

    --------------------------------------------------------------------
    -- Byte accounting.
    --
    -- estimateRecordBytes calls itself "a conservative upper bound matching
    -- AceSerializer output" and nothing has ever checked it. An under-count
    -- pushes chunks past CHUNK_BYTE_BUDGET and raises the fragment count, which
    -- is the failure mode the whole v0.28.x reliability arc was spent on.
    --
    -- The bound holds only because record fields cannot contain the characters
    -- AceSerializer doubles (space, control codes, ^ and ~). Pipes and colons,
    -- which ids are full of, pass through unescaped. If this ever goes red it is
    -- a real chunk-sizing finding, not a fixture to loosen.
    --------------------------------------------------------------------
    describe("byte estimation", function()
        for _, case in ipairs(RECORD_CASES) do
            it("is an upper bound on real serialized size: " .. case.name, function()
                local estimated = GBL:_EstimateRecordBytes(case.stripped)
                local actual = #Wire.serialize(case.stripped)
                assert.is_true(estimated >= actual,
                    ("estimate %d is below the real %d bytes"):format(estimated, actual))
            end)
        end
    end)

    --------------------------------------------------------------------
    -- Message envelopes, golden decode.
    --------------------------------------------------------------------
    describe("decoding frozen envelopes", function()
        for _, case in ipairs(ENVELOPE_CASES) do
            it("deserializes: " .. case.name, function()
                local ok, decoded = Wire.deserialize(case.serialized)
                assert.is_true(ok)
                assert.same(case.decoded, decoded)
            end)

            it("re-serializes to the same shape: " .. case.name, function()
                local ok, decoded = Wire.deserialize(Wire.serialize(case.decoded))
                assert.is_true(ok)
                assert.same(case.decoded, decoded)
            end)
        end
    end)

    --------------------------------------------------------------------
    -- String escaping.
    --
    -- AceSerializer doubles space, control codes, ^ and ~. Guild names contain
    -- spaces and ride every envelope, so this path runs constantly in the field.
    -- Writing an envelope string by hand with a raw space is silently lossy:
    -- "Test Guild" comes back "TestGuild", the space simply gone. Nothing in
    -- production does that, because production always serializes properly, but
    -- the fixtures would have if this were not pinned.
    --------------------------------------------------------------------
    describe("string escaping", function()
        it("round-trips a guild name containing a space", function()
            local ok, decoded = Wire.deserialize(Wire.serialize({ guild = "Test Guild" }))
            assert.is_true(ok)
            assert.equals("Test Guild", decoded.guild)
        end)

        it("round-trips the characters AceSerializer escapes", function()
            local hostile = { s = "a b^c~d\1e" }
            local ok, decoded = Wire.deserialize(Wire.serialize(hostile))
            assert.is_true(ok)
            assert.same(hostile, decoded)
        end)

        it("round-trips the pipes and colons record ids are built from", function()
            local id = "withdraw|Speaknglide-Area52|10000000|493216:0"
            local ok, decoded = Wire.deserialize(Wire.serialize({ id = id }))
            assert.is_true(ok)
            assert.equals(id, decoded.id)
        end)
    end)

    --------------------------------------------------------------------
    -- Numeric keys.
    --
    -- docs/DATA-MODEL.md section 9 flagged this as untested and named only
    -- stockReserves and bankLayout.tabs[].items. The bucket tables are the
    -- larger exposure: bucketKeyForRecord returns math.floor(), so bucketHashes
    -- and buckets are numeric-keyed and ride SYNC_REQUEST and MANIFEST on every
    -- sync. String-keyed arrival would make every bucket comparison miss, so
    -- every sync would resend everything while reporting a high duplicate rate,
    -- which is the one number project notes already warn cannot be trusted.
    --------------------------------------------------------------------
    describe("numeric keys", function()
        for _, case in ipairs(ENVELOPE_CASES) do
            if case.numericKeyPaths then
                it("keeps numeric keys numeric: " .. case.name, function()
                    local decoded = Wire.roundTrip(case.decoded)
                    for _, path in ipairs(case.numericKeyPaths) do
                        local node = descend(decoded, path)
                        assert.is_table(node, ("path %s missing"):format(table.concat(path, ".")))
                        local count = 0
                        for key in pairs(node) do
                            assert.equals("number", type(key),
                                ("key %s arrived as %s"):format(tostring(key), type(key)))
                            assert.is_nil(rawget(node, tostring(key)),
                                "a string-keyed twin arrived alongside the numeric key")
                            count = count + 1
                        end
                        assert.is_true(count > 0)
                    end
                end)
            end

            if case.validatesAsLayout then
                it("still passes BankLayout.Validate after a round trip: " .. case.name, function()
                    local decoded = Wire.roundTrip(case.decoded)
                    local ok, err = GBL.BankLayout.Validate(decoded.bankLayout)
                    assert.is_true(ok, tostring(err))
                end)
            end
        end

        -- The literal fixtures above prove the codec preserves numeric keys. This
        -- proves the keys production actually generates are numeric in the first
        -- place, so the family is coupled to bucketKeyForRecord rather than to a
        -- hand-written table that happens to agree with it.
        it("preserves bucket hashes built by ComputeBucketHashes", function()
            local guildData = GBL:GetGuildData()
            for _, case in ipairs(RECORD_CASES) do
                if case.accepted and case.stripped.id and case.stripped.timestamp then
                    local record = copy(case.stripped)
                    record._occurrence = 0
                    local target = record.amount and guildData.moneyTransactions
                        or guildData.transactions
                    table.insert(target, record)
                end
            end

            local buckets = GBL:ComputeBucketHashes(guildData)
            local bucketCount = 0
            for key in pairs(buckets) do
                assert.equals("number", type(key))
                bucketCount = bucketCount + 1
            end
            assert.is_true(bucketCount > 0, "fixture records produced no buckets")

            local decoded = Wire.roundTrip({ bucketHashes = buckets })
            assert.same(buckets, decoded.bucketHashes)

            -- The property that actually matters: a lookup still lands.
            for key, hash in pairs(buckets) do
                assert.equals(hash, decoded.bucketHashes[key],
                    "bucket lookup missed after a round trip")
            end
        end)
    end)

    --------------------------------------------------------------------
    -- Duplicated builder parity.
    --
    -- HELLO, SYNC_DATA and BUSY are each built in two places (#70 names the
    -- latter two; HELLO is a third pair the issue misses). The floor release
    -- adds minSyncVersion to the HELLO payload, and adding it to only one
    -- builder fails silently: a peer that only ever receives the reply would
    -- fall back to exact-version matching and refuse to sync.
    --
    -- Strict key-set equality would be wrong even today, because sortAccess,
    -- layoutUpdatedAt and eventCounts use the `X and Y or nil` idiom and vanish
    -- rather than arriving nil. So the assertion is parity under identical
    -- state, with the one documented difference named.
    --
    -- Written against the emitted message rather than the builder site, so it
    -- survives #70: a single builder taking an isReply argument still has to
    -- produce exactly this difference.
    --------------------------------------------------------------------
    describe("duplicated builders agree", function()
        local function configureGuild()
            local gd = GBL:GetGuildData()
            gd.sortAccess = {
                write = { rankThreshold = 1, delegates = {} },
                sort = { rankThreshold = 4, delegates = {} },
                updatedBy = "GuildMaster-Stormrage",
                updatedAt = 1775100000,
            }
            gd.bankLayout = {
                version = 3,
                updatedBy = "GuildMaster-Stormrage",
                updatedAt = 1775200000,
                tabs = { [1] = { mode = "overflow" } },
            }
            return gd
        end

        it("both HELLO builders differ only by isReply", function()
            configureGuild()
            GBL.db.profile.sync.enabled = true

            local broadcast = firstOfType(capturePayloads(function()
                GBL:BroadcastHello(true)
            end), "HELLO")
            local reply = firstOfType(capturePayloads(function()
                GBL:SendHelloReply("PeerA")
            end), "HELLO")

            assert.is_table(broadcast)
            assert.is_table(reply)

            local replyOnly = {}
            for key in pairs(reply) do
                if broadcast[key] == nil then replyOnly[#replyOnly + 1] = key end
            end
            local broadcastOnly = {}
            for key in pairs(broadcast) do
                if reply[key] == nil then broadcastOnly[#broadcastOnly + 1] = key end
            end

            assert.same({ "isReply" }, replyOnly)
            assert.same({}, broadcastOnly)
        end)

        --- Seed a record and an eventCounts entry so the populated send path runs.
        local function seedSendableRecord(gd)
            local record = copy(RECORD_CASES[1].stripped)
            record._occurrence = 0
            record.scanTime = record.timestamp
            record.scannedBy = "OfficerA-TestRealm"
            table.insert(gd.transactions, record)
            gd.seenTxHashes[record.id] = record.timestamp
            gd.eventCounts = gd.eventCounts or {}
            gd.eventCounts[record.id:gsub(":%d+$", "")] = { count = 1, asOf = record.timestamp }
            return record
        end

        it("both SYNC_DATA builders agree on keys, apart from eventCounts", function()
            local gd = configureGuild()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- The empty-chunk builder: a peer asks and we hold nothing.
            local empty = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerA", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "SYNC_DATA")
            assert.is_table(empty, "no empty SYNC_DATA was built")

            seedSendableRecord(gd)

            local real = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerB", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "SYNC_DATA")
            assert.is_table(real, "no populated SYNC_DATA was built")

            -- eventCounts is the documented delta. It is optional on the wire and
            -- cannot appear on the empty branch at all (see the test below), so
            -- comparing it directly would assert a difference rather than parity.
            local function keysExceptEventCounts(payload)
                local trimmed = copy(payload)
                trimmed.eventCounts = nil
                return keySet(trimmed)
            end

            assert.same(keysExceptEventCounts(empty), keysExceptEventCounts(real))
        end)

        it("the populated SYNC_DATA builder carries eventCounts", function()
            local gd = configureGuild()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            seedSendableRecord(gd)

            local real = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerA", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "SYNC_DATA")

            assert.is_table(real)
            assert.is_table(real.eventCounts)
        end)

        -- The empty-chunk builder reads `eventCounts = batches[1]`, and that
        -- expression can never be non-nil at that site. The loop above it extends
        -- the chunk list until #chunks >= #batches, so reaching the
        -- `#chunks == 0` branch already implies #batches == 0. Anything with
        -- event counts to send routes to the other builder instead, emitting an
        -- empty chunk from there. So the key is dead where it is written, and the
        -- parity assertion above has to allow for it rather than read it as drift
        -- between the two builders.
        it("routes an eventCounts-only send through the populated builder", function()
            local gd = configureGuild()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- No records, but event counts to share. If the empty branch were
            -- reachable here it would be taken, and eventCounts would come back nil.
            gd.eventCounts = {
                ["deposit|Alice-Stormrage|191318|20|0|493216"] = { count = 1, asOf = 1775580307 },
            }

            local sent = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerA", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "SYNC_DATA")

            assert.is_table(sent)
            assert.equals(0, #sent.transactions)
            assert.is_table(sent.eventCounts)
        end)

        it("takes the empty branch, with no eventCounts, when there is nothing at all", function()
            configureGuild()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local sent = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerA", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "SYNC_DATA")

            assert.is_table(sent)
            assert.equals(0, #sent.transactions)
            assert.equals(1, sent.totalChunks)
            assert.is_nil(sent.eventCounts)
        end)

        it("both BUSY builders agree on keys", function()
            local gd = configureGuild()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local record = copy(RECORD_CASES[1].stripped)
            record._occurrence = 0
            record.scanTime = record.timestamp
            record.scannedBy = "OfficerA-TestRealm"
            table.insert(gd.transactions, record)
            gd.seenTxHashes[record.id] = record.timestamp

            -- First request puts us into sending state.
            GBL:HandleSyncRequest("PeerA", {
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Second request is declined with BUSY.
            local declined = firstOfType(capturePayloads(function()
                GBL:HandleSyncRequest("PeerB", {
                    sinceTimestamp = 0,
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                })
            end), "BUSY")
            assert.is_table(declined, "HandleSyncRequest built no BUSY")

            -- Combat aborts the same send and notifies the partner.
            local aborted = firstOfType(capturePayloads(function()
                GBL:OnCombatStart()
            end), "BUSY")
            assert.is_table(aborted, "OnCombatStart built no BUSY")

            assert.same(keySet(declined), keySet(aborted))
        end)
    end)
end)
