------------------------------------------------------------------------
-- spec/wire_contract_spec.lua — pins the sync wire format against the REAL
-- AceSerializer and LibDeflate, not the pass-through mock every other spec uses.
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
-- turn it red (see the plan's mutation table).
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local Wire = require("spec.wire_helpers")
local MockWoW = Helpers.MockWoW

local RECORD_CASES = dofile("spec/fixtures/wire/records.lua")

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

            it("survives the full compress and encode path: " .. case.name, function()
                local ok, decoded = Wire.fromWire(Wire.toWire(case.stripped))
                assert.is_true(ok)
                assert.same(case.stripped, decoded)
            end)

            it("reconstructs: " .. case.name, function()
                local record = copy(Wire.fromWireOrDie(Wire.toWire(case.stripped)))
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
end)
