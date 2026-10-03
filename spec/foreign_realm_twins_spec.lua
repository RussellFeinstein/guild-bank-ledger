------------------------------------------------------------------------
-- foreign_realm_twins_spec.lua - the #332 repair
--
-- Before v0.13.0 one client resolved bare names against a cold roster cache
-- and stamped its own realm, Nesingwary, onto members of five other realms.
-- Sync carried those records to every peer, and correctly named records of
-- most of the same events arrived from other clients, so each such event is
-- stored twice under two players and every total counts it twice.
--
-- The check drops a copy that has a twin under the roster realm and leaves
-- everything else alone. It runs once as a migration rung and again after
-- every sync receive, because peers whose stores differ at the update decide
-- differently, and a kept copy would otherwise come back to peers that dropped
-- it. Measured on the live store: 561 dropped, 2 left with no twin, and 34
-- records on two other realms left as possible real history.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local Sync = require("spec.sync_helpers")
local MockWoW = Helpers.MockWoW

-- A WoW-era hour slot, so every timestamp passes IsValidTimestamp.
local H = 475100
local function at(hour, sec) return (H + hour) * 3600 + sec end

describe("MigrateForeignRealmTwins (#332)", function()
    local GBL, gd

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        gd = GBL:GetGuildData()
        gd.schemaVersion = 11
        gd.playerRealms = {
            Alice = "Stormrage", Bob = "Tichondrius", Cara = "Stormrage", Dan = false,
        }
    end)

    local function item(player, ts, fields)
        fields = fields or {}
        return {
            type = fields.type or "deposit", player = player,
            itemID = fields.itemID or 2589, count = fields.count or 20, tab = fields.tab or 1,
            timestamp = ts, scanTime = ts + 60,
        }
    end

    local function money(player, ts, amount)
        return {
            type = "repair", player = player, amount = amount or 5000,
            timestamp = ts, scanTime = ts + 60,
        }
    end

    -- Stores records the way the scan path leaves them: the next free
    -- occurrence index in the record's hour, the id in seenTxHashes, and the
    -- player's stats counted.
    local function store(guildData, ...)
        for _, r in ipairs({ ... }) do
            local base = GBL:ComputeTxHash(r)
            local occ = GBL:MaxOccurrenceAtSlot(base, guildData)
            r.id = base .. ":" .. occ
            r._occurrence = occ
            local list = r.itemID and guildData.transactions or guildData.moneyTransactions
            list[#list + 1] = r
            guildData.seenTxHashes[r.id] = r.timestamp
            GBL:UpdatePlayerStats(r, guildData)
        end
    end

    local function players(list)
        local out = {}
        for i, r in ipairs(list) do out[i] = r.player end
        return out
    end

    local function run(name)
        return GBL:MigrateForeignRealmTwins(gd, name)
    end

    ---------------------------------------------------------------------------
    -- Twins
    ---------------------------------------------------------------------------

    describe("a copy with a twin", function()
        it("is dropped when the twin is in the same hour", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local copyId = gd.transactions[2].id

            local dropped = run()

            assert.equals(1, dropped)
            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
            assert.is_nil(gd.seenTxHashes[copyId])
            assert.equals(12, gd.schemaVersion)
        end)

        it("is dropped when the twin is in the next hour but under 3600s away", function()
            store(gd, item("Alice-Stormrage", at(0, 3500)), item("Alice-Nesingwary", at(1, 100)))
            -- Non-degenerate: the two really sit in different hour slots.
            assert.are_not.equals(math.floor(gd.transactions[1].timestamp / 3600),
                math.floor(gd.transactions[2].timestamp / 3600))

            run()

            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
        end)

        it("is kept when the nearest twin is 3600s or more away", function()
            -- IsDuplicate's boundary: an hour apart is two events.
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(1, 600)))

            local dropped = run()

            assert.equals(0, dropped)
            assert.same({ "Alice-Stormrage", "Alice-Nesingwary" }, players(gd.transactions))
        end)

        it("needs the same item, count and tab", function()
            store(gd, item("Alice-Stormrage", at(0, 600), { count = 19 }),
                item("Alice-Nesingwary", at(0, 630)))

            run()

            assert.same({ "Alice-Stormrage", "Alice-Nesingwary" }, players(gd.transactions))
        end)

        it("is dropped from the money log the same way", function()
            store(gd, money("Bob-Tichondrius", at(0, 600)), money("Bob-Nesingwary", at(0, 640)))

            local dropped = run()

            assert.equals(1, dropped)
            assert.same({ "Bob-Tichondrius" }, players(gd.moneyTransactions))
        end)

        it("is absorbed one per twin, and a second copy is kept", function()
            store(gd, item("Alice-Stormrage", at(0, 600)),
                item("Alice-Nesingwary", at(0, 610)), item("Alice-Nesingwary", at(0, 900)))

            local dropped = run()

            assert.equals(1, dropped)
            assert.same({ "Alice-Stormrage", "Alice-Nesingwary" }, players(gd.transactions))
            assert.equals(900, gd.transactions[2].timestamp - at(0, 0))
        end)

        it("pairs as many copies as any assignment could", function()
            -- Nearest-first fails here: the first copy takes the later twin,
            -- 1500s away, and leaves the second copy only the earlier one,
            -- 4000s away. Walking both sides in time order pairs both.
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Stormrage", at(1, 1500)),
                item("Alice-Nesingwary", at(1, 0)), item("Alice-Nesingwary", at(1, 1000)))

            local dropped = run()

            assert.equals(2, dropped)
            assert.same({ "Alice-Stormrage", "Alice-Stormrage" }, players(gd.transactions))
        end)
    end)

    ---------------------------------------------------------------------------
    -- A copy with no twin is left alone
    ---------------------------------------------------------------------------

    describe("a copy with no twin", function()
        it("is left alone even when other copies of its name and realm had twins", function()
            -- The 2 such records on the live store sit 60 and 63 minutes from a
            -- match. Renaming would mint an id another peer could hold for a
            -- different event, and the label is all that is wrong (Russell,
            -- 2026-10-03).
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)),
                item("Alice-Nesingwary", at(5, 600), { itemID = 2592 }))
            local id = gd.transactions[3].id

            run()

            assert.same({ "Alice-Stormrage", "Alice-Nesingwary" }, players(gd.transactions))
            assert.equals(id, gd.transactions[2].id)
        end)

        it("is left alone when its name and realm have no twin anywhere", function()
            -- The Thrall shape: a realm the roster contradicts, with nothing to
            -- show it was stamped. It may be a real realm transfer.
            store(gd, item("Cara-Thrall", at(0, 600)))
            local id = gd.transactions[1].id

            local dropped = run()

            assert.equals(0, dropped)
            assert.equals("Cara-Thrall", gd.transactions[1].player)
            assert.equals(id, gd.transactions[1].id)
        end)
    end)

    ---------------------------------------------------------------------------
    -- What the roster cache can and cannot say
    ---------------------------------------------------------------------------

    describe("the roster cache", function()
        it("leaves a name it marks ambiguous", function()
            store(gd, item("Dan-Stormrage", at(0, 600)), item("Dan-Nesingwary", at(0, 630)))

            run()

            assert.same({ "Dan-Stormrage", "Dan-Nesingwary" }, players(gd.transactions))
        end)

        it("leaves a name it does not hold", function()
            store(gd, item("Eve-Stormrage", at(0, 600)), item("Eve-Nesingwary", at(0, 630)))

            run()

            assert.same({ "Eve-Stormrage", "Eve-Nesingwary" }, players(gd.transactions))
        end)

        it("is compared in the normalized form on both sides", function()
            -- Stored records carry the no-space form (rung 10). A raw compare
            -- would take the right record for a copy, remove it from the twins,
            -- and keep both.
            gd.playerRealms.Alice = "Aerie Peak"
            store(gd, item("Alice-AeriePeak", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))

            run()

            assert.same({ "Alice-AeriePeak" }, players(gd.transactions))
        end)

        it("bumps a guild whose cache is empty, with nothing to compare", function()
            -- The check runs again after every receive, so a cache that warms
            -- later still gets its turn.
            gd.playerRealms = {}
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))

            run()

            assert.equals(12, gd.schemaVersion)
            assert.equals(2, #gd.transactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Invalid timestamps
    ---------------------------------------------------------------------------

    describe("a record whose timestamp is not valid", function()
        it("is never dropped", function()
            store(gd, item("Bob-Tichondrius", 1000), item("Bob-Nesingwary", 1030))

            run()

            assert.same({ "Bob-Tichondrius", "Bob-Nesingwary" }, players(gd.transactions))
        end)
    end)

    ---------------------------------------------------------------------------
    -- eventCounts follow the records (the #332 rider)
    ---------------------------------------------------------------------------

    describe("eventCounts", function()
        it("move a dropped copy's count onto the roster key and delete the old key", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local twinKey = GBL:ComputeTxHash(gd.transactions[1])
            local copyKey = GBL:ComputeTxHash(gd.transactions[2])
            gd.eventCounts[twinKey] = { count = 1, asOf = 1 }
            gd.eventCounts[copyKey] = { count = 2, asOf = 2 }

            local _, moved = run()

            assert.equals(1, moved)
            assert.is_nil(gd.eventCounts[copyKey])
            assert.equals(2, gd.eventCounts[twinKey].count)
        end)

        it("keep the higher count when the roster key already holds more", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local twinKey = GBL:ComputeTxHash(gd.transactions[1])
            local copyKey = GBL:ComputeTxHash(gd.transactions[2])
            gd.eventCounts[twinKey] = { count = 3, asOf = 1 }
            gd.eventCounts[copyKey] = { count = 2, asOf = 2 }

            run()

            assert.is_nil(gd.eventCounts[copyKey])
            assert.equals(3, gd.eventCounts[twinKey].count)
        end)

        it("move in every hour of a prefix whose records all went", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local copyPrefix = GBL:BuildTxPrefix(gd.transactions[2])
            local twinPrefix = GBL:BuildTxPrefix(gd.transactions[1])
            gd.eventCounts[copyPrefix .. (H + 9)] = { count = 4, asOf = 1 }

            run()

            assert.is_nil(gd.eventCounts[copyPrefix .. (H + 9)])
            assert.equals(4, gd.eventCounts[twinPrefix .. (H + 9)].count)
        end)

        it("stay under a prefix that still holds a record", function()
            -- The copy goes, the record two hours later stays, and its count
            -- still describes it.
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)),
                item("Alice-Nesingwary", at(2, 600)))
            local keptKey = GBL:ComputeTxHash(gd.transactions[3])
            gd.eventCounts[keptKey] = { count = 1, asOf = 1 }

            local dropped, moved = run()

            assert.equals(1, dropped)
            assert.equals(0, moved)
            assert.equals(1, gd.eventCounts[keptKey].count)
        end)

        it("stay where they are under a prefix whose records were left alone", function()
            store(gd, item("Cara-Thrall", at(0, 600)))
            local key = GBL:ComputeTxHash(gd.transactions[1])
            gd.eventCounts[key] = { count = 1, asOf = 1 }

            local _, moved = run()

            assert.equals(0, moved)
            assert.equals(1, gd.eventCounts[key].count)
        end)

        it("skip a key that is not a string rather than raising", function()
            -- Sync intake merges a peer's keys without checking their type.
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            gd.eventCounts[12345] = { count = 1, asOf = 1 }

            local ok, err = pcall(run)

            assert.is_true(ok, tostring(err))
            assert.equals(12, gd.schemaVersion)
            assert.equals(1, gd.eventCounts[12345].count)
        end)
    end)

    ---------------------------------------------------------------------------
    -- The rest of the store
    ---------------------------------------------------------------------------

    describe("the rest of the store", function()
        it("rebuilds playerStats so the roster name counts each event once", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            -- Non-degenerate: before the repair the copy has stats of its own.
            assert.equals(20, rawget(gd.playerStats, "Alice-Nesingwary").totalDepositCount)

            run()

            assert.is_nil(rawget(gd.playerStats, "Alice-Nesingwary"))
            assert.equals(20, gd.playerStats["Alice-Stormrage"].totalDepositCount)
        end)

        it("keeps the saved arrays and the order of what survives", function()
            local tx = gd.transactions
            store(gd, item("Cara-Stormrage", at(0, 100), { itemID = 1 }),
                item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)),
                item("Cara-Stormrage", at(2, 100), { itemID = 3 }))

            run()

            assert.is_true(tx == gd.transactions, "the AceDB array was replaced")
            assert.equals(3, #gd.transactions)
            assert.is_nil(gd.transactions[4])
            assert.same({ 1, 2589, 3 }, {
                gd.transactions[1].itemID, gd.transactions[2].itemID, gd.transactions[3].itemID,
            })
        end)

        it("moves the data hash after a repair", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local before = GBL:GetDataHash(gd)

            run()

            assert.are_not.equals(before, GBL:GetDataHash(gd))
        end)

        it("leaves a warm cache alone, and still bumps, when there is nothing to repair", function()
            store(gd, item("Alice-Stormrage", at(0, 600)))
            local warm = GBL:GetBucketHashes(gd)

            run()

            assert.equals(12, gd.schemaVersion)
            assert.is_true(warm == GBL:GetBucketHashes(gd),
                "the cache was cleared for a guild with nothing to repair")
        end)
    end)

    ---------------------------------------------------------------------------
    -- The gate
    ---------------------------------------------------------------------------

    describe("the gate", function()
        it("does not run a guild below its rung", function()
            gd.schemaVersion = 10
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))

            local dropped = run()

            assert.equals(0, dropped)
            assert.equals(10, gd.schemaVersion)
            assert.equals(2, #gd.transactions)
        end)

        it("does not re-run a guild above it", function()
            gd.schemaVersion = 12
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))

            run()

            assert.equals(12, gd.schemaVersion)
            assert.equals(2, #gd.transactions)
        end)

        it("changes nothing on a second run", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)),
                item("Alice-Nesingwary", at(5, 600), { itemID = 2592 }))
            run()
            local ids = {}
            for i, r in ipairs(gd.transactions) do ids[i] = r.id end

            gd.schemaVersion = 11
            local dropped, moved = run()

            assert.same({ 0, 0 }, { dropped, moved })
            local after = {}
            for i, r in ipairs(gd.transactions) do after[i] = r.id end
            assert.same(ids, after)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Every peer must decide the same way
    ---------------------------------------------------------------------------

    describe("determinism", function()
        it("gives the same result whatever order the records are stored in", function()
            store(gd, item("Alice-Stormrage", at(0, 600)),
                item("Alice-Nesingwary", at(0, 610)), item("Alice-Nesingwary", at(0, 900)),
                item("Alice-Nesingwary", at(5, 600), { itemID = 2592 }),
                money("Bob-Tichondrius", at(1, 100)), money("Bob-Nesingwary", at(1, 200)))

            -- The same records and ids, stored in the reverse order in a second
            -- guild, so only the walk order differs.
            local other = GBL.db.global.guilds["Other Guild"]
            other.schemaVersion = 11
            other.playerRealms = { Alice = "Stormrage", Bob = "Tichondrius" }
            for _, key in ipairs({ "transactions", "moneyTransactions" }) do
                local src = gd[key]
                for i = #src, 1, -1 do
                    local copy = {}
                    for k, v in pairs(src[i]) do copy[k] = v end
                    other[key][#other[key] + 1] = copy
                    other.seenTxHashes[copy.id] = copy.timestamp
                end
            end

            GBL:MigrateForeignRealmTwins(gd)
            GBL:MigrateForeignRealmTwins(other)

            local function outcome(g)
                local out = {}
                for _, key in ipairs({ "transactions", "moneyTransactions" }) do
                    for _, r in ipairs(g[key]) do out[#out + 1] = r.player .. "@" .. r.id end
                end
                table.sort(out)
                return out
            end
            assert.same(outcome(gd), outcome(other))
            -- Non-degenerate: an item copy and the money copy went in both, and
            -- the item copy that went is the earlier one in both, though the
            -- two guilds walked their records in opposite orders.
            assert.equals(4, #outcome(gd))
            for _, g in ipairs({ gd, other }) do
                local kept
                for _, r in ipairs(g.transactions) do
                    if r.player == "Alice-Nesingwary" and r.itemID == 2589 then kept = r end
                end
                assert.equals(at(0, 900), kept.timestamp)
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- The log line
    ---------------------------------------------------------------------------

    describe("the system log", function()
        local function lines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Foreign-realm twins", 1, true) then out[#out + 1] = e end
            end
            return out
        end

        it("names the guild and the two counts", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local copyKey = GBL:ComputeTxHash(gd.transactions[2])
            gd.eventCounts[copyKey] = { count = 1, asOf = 1 }

            run("TestGuild")

            local found = lines()
            assert.equals(1, #found)
            assert.equals("INFO", found[1].level)
            assert.is_truthy(found[1].message:find(
                "Foreign-realm twins for TestGuild: dropped 1, counts moved 1", 1, true),
                found[1].message)
        end)

        it("writes nothing for a guild with nothing to repair", function()
            store(gd, item("Alice-Stormrage", at(0, 600)))

            run("TestGuild")

            assert.equals(0, #lines())
        end)

        it("is reached from the ladder with the guild's name", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))

            GBL:MigrateAllGuilds()

            assert.equals(12, gd.schemaVersion)
            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
            local found = lines()
            assert.equals(1, #found)
            assert.is_truthy(found[1].message:find("for TestGuild:", 1, true), found[1].message)
        end)
    end)

    ---------------------------------------------------------------------------
    -- After every sync receive, not only at the update
    ---------------------------------------------------------------------------

    describe("after a sync receive", function()
        before_each(function()
            GBL, gd = Sync.setup()
            gd.schemaVersion = 12
            gd.playerRealms = { Alice = "Stormrage" }
        end)

        it("drops a kept copy once its twin arrives", function()
            -- A peer that held the copy without its twin at the update keeps it,
            -- and must drop it when the twin comes in.
            store(gd, item("Alice-Nesingwary", at(0, 630)))
            assert.equals(0, (GBL:DropForeignRealmTwins(gd)))

            store(gd, item("Alice-Stormrage", at(0, 600)))
            local dropped = GBL:DropForeignRealmTwins(gd)

            assert.equals(1, dropped)
            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
        end)

        it("drops a copy handed back after the repair", function()
            local copy = item("Alice-Nesingwary", at(0, 630))
            store(gd, item("Alice-Stormrage", at(0, 600)), copy)
            GBL:DropForeignRealmTwins(gd)
            assert.equals(1, #gd.transactions)

            -- A peer that kept it sends it back under its old id.
            local back = {}
            for k, v in pairs(copy) do back[k] = v end
            gd.transactions[#gd.transactions + 1] = back
            gd.seenTxHashes[back.id] = back.timestamp

            assert.equals(1, (GBL:DropForeignRealmTwins(gd)))
            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
        end)

        it("runs when a receive finishes", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            GBL:FinishReceiving("OfficerB")

            assert.same({ "Alice-Stormrage" }, players(gd.transactions))
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("finishes the receive and resets the hash cache when the check raises", function()
            store(gd, item("Alice-Stormrage", at(0, 600)), item("Alice-Nesingwary", at(0, 630)))
            local original, originalReset = GBL.DropForeignRealmTwins, GBL.ResetHashCache
            local resets = 0
            GBL.DropForeignRealmTwins = function() error("twin check exploded", 0) end
            GBL.ResetHashCache = function(self, ...)
                resets = resets + 1
                return originalReset(self, ...)
            end
            GBL:RequestSync("OfficerB", 0)

            local ok, err = pcall(GBL.FinishReceiving, GBL, "OfficerB")

            GBL.DropForeignRealmTwins, GBL.ResetHashCache = original, originalReset
            assert.is_true(ok, tostring(err))
            assert.is_false(GBL:GetSyncStatus().receiving)
            assert.is_true(resets > 0, "the failure branch did not reset the hash cache")
            local errors = {}
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.level == "ERROR" then errors[#errors + 1] = e.message end
            end
            assert.equals(1, #errors)
            assert.is_truthy(errors[1]:find("twin check exploded", 1, true), errors[1])
        end)

        it("names a failing check once per session", function()
            local original = GBL.DropForeignRealmTwins
            GBL.DropForeignRealmTwins = function() error("twin check exploded", 0) end
            GBL:RequestSync("OfficerB", 0)
            GBL:FinishReceiving("OfficerB")
            GBL:RequestSync("OfficerB", 0)
            GBL:FinishReceiving("OfficerB")
            GBL.DropForeignRealmTwins = original

            local n = 0
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.level == "ERROR" and e.message:find("twin check", 1, true) then n = n + 1 end
            end
            assert.equals(1, n)
        end)
    end)
end)
