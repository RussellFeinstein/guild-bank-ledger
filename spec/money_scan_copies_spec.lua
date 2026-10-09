------------------------------------------------------------------------
-- money_scan_copies_spec.lua - the copies the views leave out (#346)
--
-- CleanupWithEventCounts trims a cluster of same-prefix records only when an
-- event count says how many events there were, and counts began on
-- 2026-04-15. So a money record that sync carried back to the client that
-- scanned it, under another occurrence index, stayed stored twice.
--
-- Such a copy can be told apart. A scan's timestamps are its scan time minus
-- whole hours, so a synced record at the exact second of a record this
-- account scanned was minted by that same scan: it is the scan's own record
-- coming back. GBL:MoneyScanCopies names those records.
--
-- It reads and never writes. The records stay stored, so the ids,
-- seenTxHashes, the bucket hashes and sync are untouched, and a copy that
-- comes back is matched by id as before. RecordsForView leaves the named
-- records out of the history tabs (spec/ui/hidden_copies_spec.lua).
-- Deleting them was built and declined: every guildmate holding the copies
-- would then differ from this store for good, and a deleted copy's next
-- arrival could fuzzy-match a real record (the #346 comment of 2026-10-08).
--
-- Money only: items were never measured, and reaching them is a decision of
-- its own (docs/DATA-MODEL.md).
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local HOUR = 3600
local SLOT = 475100
-- A second inside SLOT, so every timestamp passes IsValidTimestamp.
local T = SLOT * HOUR + 1234
local ME = "TestOfficer-TestRealm"
local PLAYER = "Katorri-TestRealm"

describe("MoneyScanCopies: a money record synced back to its own scan (#346)", function()
    local GBL, gd

    -- A money record. `scannedBy` decides whose it is; `scanTime` is the scan
    -- for a record this account scanned and the receipt for a synced one.
    local function money(opts)
        local rec = {
            type = opts.type or "deposit",
            player = opts.player or PLAYER,
            amount = opts.amount or 50000,
            timestamp = opts.timestamp or T,
            scanTime = opts.scanTime,
            scannedBy = opts.scannedBy,
        }
        rec._occurrence = opts.occ or 0
        rec.id = GBL:ComputeTxHash(rec) .. ":" .. rec._occurrence
        return rec
    end

    -- This account's scan of T, run two hours after the event.
    local function mine(opts)
        opts = opts or {}
        opts.scannedBy = opts.scannedBy or ME
        opts.scanTime = opts.scanTime or (opts.timestamp or T) + 2 * HOUR
        return money(opts)
    end

    -- The same record carried back by a peer a day later, numbered :1.
    local function echo(opts)
        opts = opts or {}
        opts.scannedBy = opts.scannedBy or "sync:Flameus-TestRealm"
        opts.scanTime = opts.scanTime or (opts.timestamp or T) + 30 * HOUR
        opts.occ = opts.occ or 1
        return money(opts)
    end

    local function store(list, ...)
        for _, rec in ipairs({ ... }) do
            table.insert(gd[list], rec)
            gd.seenTxHashes[rec.id] = rec.timestamp
        end
    end

    -- The records named, as a set, checked against the set returned.
    local function named(guildData)
        local list, isCopy = GBL:MoneyScanCopies(guildData or gd)
        local set, n = {}, 0
        for _, rec in ipairs(list) do
            set[rec] = true
            n = n + 1
        end
        local m = 0
        for rec in pairs(isCopy) do
            assert.is_true(set[rec], "the set holds a record the list does not")
            m = m + 1
        end
        assert.equals(n, m, "the list and the set name different records")
        return set, n
    end

    -- A guild table of its own, for a guild other than the logged-in one.
    local function otherGuild(playerRealms, ...)
        local other = GBL.db.global.guilds["OtherGuild"]
        other.playerRealms = playerRealms
        for _, rec in ipairs({ ... }) do
            table.insert(other.moneyTransactions, rec)
            other.seenTxHashes[rec.id] = rec.timestamp
        end
        return other
    end

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        gd = GBL:GetGuildData()
        gd.playerRealms = { TestOfficer = "TestRealm" }
        gd.eventCounts = {}
    end)

    ---------------------------------------------------------------------------
    -- What it names
    ---------------------------------------------------------------------------

    describe("names", function()
        it("a synced record at the second of this account's scan", function()
            local own, copy = mine(), echo()
            store("moneyTransactions", own, copy)

            local set, n = named()

            assert.equals(1, n)
            assert.is_true(set[copy])
            assert.is_nil(set[own])
        end)

        it("only the synced record when the scan saw the event twice", function()
            local a = mine({ occ = 0 })
            local b = mine({ occ = 1 })
            local copy = echo({ occ = 2 })
            store("moneyTransactions", a, b, copy)

            local set, n = named()

            assert.equals(1, n)
            assert.is_true(set[copy])
        end)

        it("every synced record at that second, from any sender", function()
            local own = mine()
            local c1 = echo({ occ = 1 })
            local c2 = echo({ occ = 2, scannedBy = "sync:Aeglos-TestRealm" })
            store("moneyTransactions", own, c1, c2)

            local set, n = named()

            assert.equals(2, n)
            assert.is_true(set[c1])
            assert.is_true(set[c2])
        end)

        it("the copy, and not another scan's record of the same hour", function()
            local other = money({
                timestamp = T - 600, scanTime = T + 60 * HOUR,
                scannedBy = "sync:Aeglos-TestRealm", occ = 0,
            })
            local own = mine({ occ = 1 })
            local copy = echo({ occ = 2 })
            store("moneyTransactions", other, own, copy)

            local set, n = named()

            assert.equals(1, n)
            assert.is_true(set[copy])
        end)

        it("a copy below a record that stays in its id group", function()
            -- Deleting this one would have left a gap under the later record's
            -- index for a renumber to close, so the deleting build kept it.
            -- Leaving it out of a view moves no id.
            local own, copy = mine(), echo()
            local later = money({
                timestamp = T + 600, scanTime = T + 60 * HOUR,
                scannedBy = "sync:Aeglos-TestRealm", occ = 2,
            })
            store("moneyTransactions", own, copy, later)

            local set, n = named()

            assert.equals(1, n)
            assert.is_true(set[copy])
            assert.is_nil(set[later])
        end)

        it("the copies of two hours chained into one cluster", function()
            local own1, copy1 = mine(), echo()
            local T2 = T + 2700
            local own2, copy2 = mine({ timestamp = T2 }), echo({ timestamp = T2 })
            store("moneyTransactions", own1, copy1, own2, copy2)

            local set, n = named()

            assert.equals(2, n)
            assert.is_true(set[copy1])
            assert.is_true(set[copy2])
        end)

        it("against a qualified scanner name in a guild that has no playerRealms at all", function()
            local own, copy = mine(), echo()
            local bare = {
                transactions = {}, moneyTransactions = { own, copy },
                seenTxHashes = {}, playerStats = {}, eventCounts = {},
            }

            local set, n = named(bare)

            assert.equals(1, n)
            assert.is_true(set[copy])
        end)

        it("against a bare name from before v0.13.0 that playerRealms places on this account's realm", function()
            local own = mine({ scannedBy = "TestOfficer" })
            local copy = echo()
            store("moneyTransactions", own, copy)

            local set = named()

            assert.is_true(set[copy])
        end)

        it("against an alt in the account roster", function()
            GBL.db.global.characters = { ["TestAlt-TestRealm"] = 1 }
            local own = mine({ scannedBy = "TestAlt-TestRealm" })
            local copy = echo()
            store("moneyTransactions", own, copy)

            local set = named()

            assert.is_true(set[copy])
        end)

        it("against a bare name another guild's own playerRealms places, reading that guild", function()
            GBL.db.global.characters = { ["Bob-OtherRealm"] = 1 }
            local own, copy = mine({ scannedBy = "Bob" }), echo()
            local other = otherGuild({ Bob = "OtherRealm" }, own, copy)

            local set, n = named(other)

            assert.equals(1, n)
            assert.is_true(set[copy])
        end)

        it("in a store that holds no counts at all", function()
            -- The cleanup returns before it groups anything when eventCounts is
            -- empty. This reader has no such return.
            local own, copy = mine(), echo()
            store("moneyTransactions", own, copy)
            gd.eventCounts = {}

            local set = named()

            assert.is_true(set[copy])
        end)

        it("with no eventCounts table at all", function()
            local own, copy = mine(), echo()
            store("moneyTransactions", own, copy)
            gd.eventCounts = nil

            local set = named()

            assert.is_true(set[copy])
        end)
    end)

    ---------------------------------------------------------------------------
    -- What it leaves alone
    ---------------------------------------------------------------------------

    describe("leaves alone", function()
        local function assertNone(guildData)
            local _, n = named(guildData)
            assert.equals(0, n)
        end

        it("a synced record at another second, which came from another scan", function()
            store("moneyTransactions", mine(), echo({ timestamp = T + 600 }))
            assertNone()
        end)

        it("a pair whose local record carries a time sync rewrote", function()
            -- NormalizeRecordId gives a stored record the sender's id and
            -- timestamp, so its time is no longer its own scan's.
            store("moneyTransactions", mine({ scanTime = T + 2 * HOUR + 17 }), echo())
            assertNone()
        end)

        it("a pair whose unsynced record another player scanned", function()
            -- Before v0.7.8 sync stored a record under its scanner's name.
            store("moneyTransactions", mine({ scannedBy = "Flameus-TestRealm" }),
                echo({ scannedBy = "sync:Aeglos-TestRealm" }))
            assertNone()
        end)

        it("a later record at that second that sync did not label", function()
            -- Before v0.7.8 sync stored a record under its scanner's name, so
            -- arriving later is not enough: only a record labelled sync: is
            -- read as the scan's own record coming back.
            store("moneyTransactions", mine(), money({
                scannedBy = "Flameus-TestRealm", scanTime = T + 30 * HOUR, occ = 1,
            }))
            assertNone()
        end)

        it("a pair whose bare scanner name only the logged-in guild's playerRealms places, reading another guild", function()
            -- The logged-in guild's playerRealms says nothing about who "Bob"
            -- is in another guild, so it must not make Bob's scan this account's.
            GBL.db.global.characters = { ["Bob-OtherRealm"] = 1 }
            gd.playerRealms.Bob = "OtherRealm"
            local other = otherGuild({}, mine({ scannedBy = "Bob" }), echo())
            assertNone(other)
        end)

        it("a pair whose bare scanner name the guild's playerRealms does not place", function()
            -- The Member view reads such a name on the local realm, but a
            -- guess is not a proof.
            gd.playerRealms = {}
            store("moneyTransactions", mine({ scannedBy = "TestOfficer" }), echo())
            assertNone()
        end)

        it("a pair whose bare scanner name sits in a guild that has no playerRealms at all", function()
            local bare = {
                transactions = {}, seenTxHashes = {}, playerStats = {}, eventCounts = {},
                moneyTransactions = { mine({ scannedBy = "TestOfficer" }), echo() },
            }
            assertNone(bare)
        end)

        it("a pair whose bare scanner name playerRealms marks ambiguous", function()
            gd.playerRealms.TestOfficer = false
            store("moneyTransactions", mine({ scannedBy = "TestOfficer" }), echo())
            assertNone()
        end)

        it("two synced records at one second, with no scan of this account's", function()
            -- What a peer holds: neither record is its own scan, so it cannot
            -- prove either is a copy.
            store("moneyTransactions", echo({ occ = 0 }),
                echo({ occ = 1, scannedBy = "sync:Aeglos-TestRealm" }))
            assertNone()
        end)

        it("a synced record received before the scan", function()
            store("moneyTransactions", mine(), echo({ scanTime = T + HOUR }))
            assertNone()
        end)

        it("a synced record with no receipt time", function()
            local copy = echo()
            copy.scanTime = nil
            store("moneyTransactions", mine(), copy)
            assertNone()
        end)

        it("a synced record at the second of a scan that ran on the hour", function()
            -- Intake gives a synced record that arrives with no timestamp the
            -- start of its id's hour (reconstructSyncRecord), so a record on
            -- the hour may carry a second no scan minted. A scan that ran at
            -- hh:00:00 proves nothing about what sits on the hour beside it.
            local onHour = SLOT * HOUR
            store("moneyTransactions", mine({ timestamp = onHour }),
                echo({ timestamp = onHour }))
            assertNone()
        end)

        it("a pair whose timestamp is invalid", function()
            store("moneyTransactions", mine({ timestamp = 0, scanTime = 2 * HOUR }),
                echo({ timestamp = 0, scanTime = 30 * HOUR }))
            assertNone()
        end)

        it("a cluster that has a count of its own", function()
            local own, copy = mine(), echo()
            store("moneyTransactions", own, copy)
            gd.eventCounts[GBL:BuildTxPrefix(own) .. SLOT] = { count = 2, asOf = 7 }
            assertNone()
        end)

        it("a cluster a count in the next hour reaches", function()
            -- Two scans can round one transaction's hour differently, so a
            -- count one slot away covers this cluster too, as it does for the
            -- cleanup.
            local own, copy = mine(), echo()
            store("moneyTransactions", own, copy)
            gd.eventCounts[GBL:BuildTxPrefix(own) .. (SLOT + 1)] = { count = 2, asOf = 7 }
            assertNone()
        end)

        it("the records of the hours around a copy", function()
            local own, copy = mine(), echo()
            local n1 = mine({ timestamp = T + 3700, occ = 0 })
            local n2 = mine({ timestamp = T + 3700, occ = 1 })
            local before = mine({ timestamp = T - 3700 })
            store("moneyTransactions", own, copy, n1, n2, before)

            local set, n = named()

            assert.equals(1, n)
            assert.is_true(set[copy])
        end)

        it("item records of the same shape", function()
            local function item(rec)
                rec.amount = nil
                rec.itemID, rec.count, rec.tab = 12345, 20, 1
                rec.type = "withdraw"
                rec.id = GBL:ComputeTxHash(rec) .. ":" .. rec._occurrence
                return rec
            end
            store("transactions", item(mine()), item(echo()))
            assertNone()
        end)

        it("everything while the realm APIs are cold", function()
            -- The logged-in character keys as Name-UnknownRealm, which no
            -- record carries, so with an empty roster nothing is this account's.
            GBL.db.global.characters = {}
            MockWoW.player.realm = nil
            MockWoW.player.normalizedRealm = nil
            store("moneyTransactions", mine(), echo())
            assertNone()
        end)
    end)

    ---------------------------------------------------------------------------
    -- It writes nothing
    ---------------------------------------------------------------------------

    describe("reads the store and writes nothing", function()
        local function snapshot(t)
            local copy = {}
            for k, v in pairs(t) do copy[k] = v end
            return copy
        end

        local function assertSameTable(before, after, what)
            for k, v in pairs(before) do
                assert.equals(v, after[k], what .. ": " .. tostring(k) .. " changed")
            end
            for k in pairs(after) do
                assert.is_not_nil(before[k], what .. ": " .. tostring(k) .. " appeared")
            end
        end

        it("leaves the arrays, the ids, seenTxHashes, the counts and the hash cache as they were", function()
            local own, copy = mine(), echo()
            local other = echo({ timestamp = T + 600, occ = 0 })
            store("moneyTransactions", copy, own, other)
            local itemRec = mine()
            itemRec.itemID = 9
            store("transactions", itemRec)
            local farCount = { count = 1, asOf = 1 }
            gd.eventCounts["deposit|Elsewhere-TestRealm|1|" .. (SLOT - 500)] = farCount

            local money, items = gd.moneyTransactions, gd.transactions
            local moneyOrder, itemOrder = snapshot(money), snapshot(items)
            local seen, counts = snapshot(gd.seenTxHashes), snapshot(gd.eventCounts)
            local ids = {}
            for _, rec in ipairs(money) do ids[rec] = { rec.id, rec.timestamp, rec._occurrence } end
            local generation = GBL:_HashCacheGeneration()

            local set = named()

            assert.is_true(set[copy])
            assert.equals(money, gd.moneyTransactions)
            assert.equals(items, gd.transactions)
            assertSameTable(moneyOrder, money, "moneyTransactions")
            assertSameTable(itemOrder, items, "transactions")
            assertSameTable(seen, gd.seenTxHashes, "seenTxHashes")
            assertSameTable(counts, gd.eventCounts, "eventCounts")
            assert.equals(1, farCount.count)
            for rec, was in pairs(ids) do
                assert.equals(was[1], rec.id)
                assert.equals(was[2], rec.timestamp)
                assert.equals(was[3], rec._occurrence)
            end
            assert.equals(generation, GBL:_HashCacheGeneration())
        end)
    end)

    ---------------------------------------------------------------------------
    -- What it returns
    ---------------------------------------------------------------------------

    describe("returns", function()
        it("the copies in the order the array holds them", function()
            local own1, copy1 = mine(), echo()
            local T2 = T + 5 * HOUR
            local own2, copy2 = mine({ timestamp = T2 }), echo({ timestamp = T2 })
            store("moneyTransactions", copy2, own1, own2, copy1)

            local list = GBL:MoneyScanCopies(gd)

            assert.equals(2, #list)
            assert.equals(copy2, list[1])
            assert.equals(copy1, list[2])
        end)

        it("an empty list and set for a guild with no money records", function()
            gd.moneyTransactions = nil
            local list, isCopy = GBL:MoneyScanCopies(gd)
            assert.equals(0, #list)
            assert.is_nil(next(isCopy))
        end)

        it("an empty list and set for no guild", function()
            local list, isCopy = GBL:MoneyScanCopies(nil)
            assert.equals(0, #list)
            assert.is_nil(next(isCopy))
        end)
    end)
end)
