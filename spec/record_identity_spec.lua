------------------------------------------------------------------------
-- record_identity_spec.lua — a record id must agree with the record.
--
-- Fifteen sites in src/ assign a record id and nothing anywhere checked that
-- the result still describes the record it sits on. That is precisely the
-- defect class already on disk (#75: 223 corrupted records, found by
-- docs/DATA-MODEL.md section 8), and it is the invariant a repair migration
-- will have to assert against.
--
-- These cases pin behaviour that already ships, so they are a regression net
-- rather than a red/green cycle, and a failure here is a defect to report.
--
-- Two shapes, which is the thing to know before reading any of it. The record
-- builders assign a BARE hash; GBL:AssignOccurrenceIndices is the transition to
-- the suffixed `hash:occurrence` form that everything else produces. The
-- invariant belongs to a stored record, not to every id-touching function's
-- output.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- IsValidTimestamp rejects anything before the WoW era, so a spec timestamp has
-- to be a real one.
local HOUR = 3600
local BASE_TS = HOUR * 475200

describe("record identity", function()
    local GBL, guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        guildData = GBL:GetGuildData()
    end)

    -- ComputeTxHash returns the hash and its time slot; only the hash is wanted.
    local function hashOf(record)
        local hash = GBL:ComputeTxHash(record)
        return hash
    end

    local function itemRecord(overrides)
        local record = {
            type = "deposit",
            player = "Alice-TestRealm",
            itemID = 12345,
            count = 5,
            tab = 1,
            itemLink = "link",
            tabName = "Consumables",
            classID = 0,
            subclassID = 0,
            category = "Other",
            timestamp = BASE_TS,
            scanTime = BASE_TS,
            scannedBy = "Alice-TestRealm",
        }
        for k, v in pairs(overrides or {}) do record[k] = v end
        return record
    end

    local function moneyRecord(overrides)
        local record = {
            type = "deposit",
            player = "Alice-TestRealm",
            amount = 10000,
            timestamp = BASE_TS,
            scanTime = BASE_TS,
            scannedBy = "Alice-TestRealm",
        }
        for k, v in pairs(overrides or {}) do record[k] = v end
        return record
    end

    ---------------------------------------------------------------------------
    -- The tripwire: which fields the id is made of
    --
    -- This is what tells a reviewer instantly whether a proposed record field is
    -- identity-affecting, and it makes "changing the prefix is expensive" fire
    -- the moment someone tries rather than sitting in a document. The record-id
    -- format is load-bearing across the sync floor: from v0.37.0 peers on
    -- different versions exchange records, so two buildPrefix implementations
    -- that disagree duplicate the guild's dataset silently.
    ---------------------------------------------------------------------------

    describe("the tripwire", function()
        -- The six fields buildPrefix reads (src/Dedup.lua:39-51). tab belongs to
        -- the item shape and amount to the money shape.
        local IDENTITY_ITEM = {
            type = "withdraw",
            player = "Bob-OtherRealm",
            itemID = 99999,
            count = 7,
            tab = 4,
        }

        -- Everything else a record carries. destTab is the interesting one: a
        -- move's DESTINATION is not part of its identity, only its source is.
        local INERT_ITEM = {
            itemLink = "a different link",
            tabName = "Renamed In The Bank",
            destTab = 3,
            destTabName = "Elsewhere",
            classID = 9,
            subclassID = 9,
            category = "Something Else",
            scanTime = BASE_TS + 900,
            scannedBy = "Someone-Else",
        }

        for field, value in pairs(IDENTITY_ITEM) do
            it("changes the hash when " .. field .. " changes", function()
                local before = hashOf(itemRecord())
                local after = hashOf(itemRecord({ [field] = value }))
                assert.are_not.equals(before, after)
            end)
        end

        for field, value in pairs(INERT_ITEM) do
            it("leaves the hash alone when " .. field .. " changes", function()
                local before = hashOf(itemRecord())
                local after = hashOf(itemRecord({ [field] = value }))
                assert.equals(before, after)
            end)
        end

        for field, value in pairs({ type = "withdraw", player = "Bob-Other", amount = 55 }) do
            it("changes a money hash when " .. field .. " changes", function()
                local before = hashOf(moneyRecord())
                local after = hashOf(moneyRecord({ [field] = value }))
                assert.are_not.equals(before, after)
            end)
        end

        it("leaves a money hash alone when scanTime changes", function()
            assert.equals(
                hashOf(moneyRecord()),
                hashOf(moneyRecord({ scanTime = BASE_TS + 900 }))
            )
        end)

        it("switches a money record to the item key shape when it gains an itemID", function()
            -- buildPrefix branches on the presence of itemID, so this is not a
            -- field change, it is a change of key shape. #68 fixed the sync-side
            -- version of exactly this.
            assert.are_not.equals(
                hashOf(moneyRecord()),
                hashOf(moneyRecord({ itemID = 12345 }))
            )
        end)

        it("changes the hash when the timestamp crosses an hour boundary", function()
            -- The time slot is part of the hash even though buildPrefix does not
            -- read the timestamp, so identity is hour-coarse by design.
            assert.are_not.equals(
                hashOf(itemRecord()),
                hashOf(itemRecord({ timestamp = BASE_TS + HOUR }))
            )
        end)

        it("leaves the hash alone within one hour", function()
            assert.equals(
                hashOf(itemRecord()),
                hashOf(itemRecord({ timestamp = BASE_TS + HOUR - 1 }))
            )
        end)
    end)

    ---------------------------------------------------------------------------
    -- The two id shapes
    ---------------------------------------------------------------------------

    describe("the two id shapes", function()
        it("CreateTxRecord assigns a bare hash with no occurrence suffix", function()
            local link = Helpers.makeItemLink(12345, "Test Item")
            local record = GBL:CreateTxRecord("deposit", "Alice", link, 5, 1, nil, 0, 0, 0, 1)

            assert.equals(hashOf(record), record.id)
            assert.is_nil(record.id:match(":%d+$"))
            assert.is_nil(record._occurrence)
        end)

        it("CreateMoneyTxRecord assigns a bare hash with no occurrence suffix", function()
            local record = GBL:CreateMoneyTxRecord("deposit", "Alice", 10000, 0, 0, 0, 1)

            assert.equals(hashOf(record), record.id)
            assert.is_nil(record.id:match(":%d+$"))
            assert.is_nil(record._occurrence)
        end)

        it("AssignOccurrenceIndices is the transition to the suffixed form", function()
            local record = itemRecord()
            record.id = hashOf(record)

            GBL:AssignOccurrenceIndices({ record })

            assert.equals(0, record._occurrence)
            assert.equals(hashOf(record) .. ":0", record.id)
        end)

        it("numbers repeat records inside one hour slot", function()
            local first, second = itemRecord(), itemRecord()
            first.id = hashOf(first)
            second.id = hashOf(second)

            GBL:AssignOccurrenceIndices({ first, second })

            assert.equals(hashOf(first) .. ":0", first.id)
            assert.equals(hashOf(second) .. ":1", second.id)
            assert.are_not.equals(first.id, second.id)
        end)

        it("counts hour slots independently", function()
            local first = itemRecord()
            local later = itemRecord({ timestamp = BASE_TS + HOUR })
            first.id = hashOf(first)
            later.id = hashOf(later)

            GBL:AssignOccurrenceIndices({ first, later })

            assert.equals(0, first._occurrence)
            assert.equals(0, later._occurrence)
        end)

        it("is not idempotent, and no production code calls it at all", function()
            -- Characterization, not approval. A second run reads the already
            -- suffixed id as a base hash and appends again, so the id stops
            -- agreeing with the record. Nothing in src/ or UI/ calls this
            -- function, despite its own comment claiming sync records and
            -- migrations use it, so no production path can reach the second run
            -- today. Pinned so that a future caller finds this written down
            -- rather than discovering it on live data.
            local record = itemRecord()
            record.id = hashOf(record)

            GBL:AssignOccurrenceIndices({ record })
            GBL:AssignOccurrenceIndices({ record })

            assert.equals(hashOf(record) .. ":0:0", record.id)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Conformance: an id that survives the migration chain still describes its
    -- own record
    ---------------------------------------------------------------------------

    describe("conformance through the migration chain", function()
        local function assertIdAgrees(record, where)
            local expected = hashOf(record) .. ":" .. (record._occurrence or 0)
            assert.equals(expected, record.id,
                where .. ": id disagrees with its own fields")
        end

        it("leaves every surviving record with an id that agrees with its fields",
        function()
            -- Schema 2 shaped: bare player names, ids built before the realm was
            -- resolved, so the chain has real work to do and every record it
            -- keeps has to come out the far side conformant.
            guildData.schemaVersion = 2
            guildData.transactions = {
                {
                    type = "deposit", player = "Alice", itemID = 12345, count = 5,
                    tab = 1, timestamp = BASE_TS, id = "deposit|Alice|12345|5|1|475200:0",
                },
                {
                    type = "withdraw", player = "Bob", itemID = 777, count = 2,
                    tab = 2, timestamp = BASE_TS + HOUR,
                    id = "withdraw|Bob|777|2|2|475201:0",
                },
            }
            guildData.moneyTransactions = {
                {
                    type = "deposit", player = "Alice", amount = 10000,
                    timestamp = BASE_TS, id = "deposit|Alice|10000|475200:0",
                },
            }

            GBL:MigrateAllGuilds()

            local seen = 0
            for i, record in ipairs(guildData.transactions) do
                assertIdAgrees(record, "transactions[" .. i .. "]")
                seen = seen + 1
            end
            for i, record in ipairs(guildData.moneyTransactions) do
                assertIdAgrees(record, "moneyTransactions[" .. i .. "]")
                seen = seen + 1
            end

            -- A chain that dropped every record would satisfy the loops above
            -- without proving anything.
            assert.is_true(seen > 0, "the migration chain kept no records")
        end)

        it("keeps every id unique across the records it kept", function()
            guildData.schemaVersion = 2
            guildData.transactions = {
                {
                    type = "deposit", player = "Alice", itemID = 12345, count = 5,
                    tab = 1, timestamp = BASE_TS, id = "deposit|Alice|12345|5|1|475200:0",
                },
                {
                    type = "deposit", player = "Alice", itemID = 12345, count = 5,
                    tab = 1, timestamp = BASE_TS + 60,
                    id = "deposit|Alice|12345|5|1|475200:1",
                },
            }

            GBL:MigrateAllGuilds()

            local ids = {}
            for _, record in ipairs(guildData.transactions) do
                assert.is_nil(ids[record.id], "duplicate id survived: " .. tostring(record.id))
                ids[record.id] = true
            end
        end)
    end)
end)
