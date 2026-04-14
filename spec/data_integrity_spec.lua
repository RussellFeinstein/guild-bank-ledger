--- data_integrity_spec.lua — Tests for data integrity fixes (v0.13.0)
-- Covers: ResolvePlayerName, StripRealm, BuildRosterCache,
-- schema migration v2→v3, StoreTx/StoreMoneyTx validation

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Data integrity", function()
    local GBL, guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        guildData = GBL:GetGuildData()
    end)

    ---------------------------------------------------------------------------
    -- ResolvePlayerName
    ---------------------------------------------------------------------------

    describe("ResolvePlayerName", function()
        it("passes through already-qualified names", function()
            assert.equals("Alice-Wyrmrest", GBL:ResolvePlayerName("Alice-Wyrmrest"))
        end)

        it("appends local realm when roster cache is empty", function()
            assert.equals("Alice-TestRealm", GBL:ResolvePlayerName("Alice"))
        end)

        it("uses roster cache when available", function()
            guildData.playerRealms = { Alice = "Wyrmrest" }
            assert.equals("Alice-Wyrmrest", GBL:ResolvePlayerName("Alice"))
        end)

        it("returns nil/empty unchanged", function()
            assert.equals(nil, GBL:ResolvePlayerName(nil))
            assert.equals("", GBL:ResolvePlayerName(""))
        end)
    end)

    ---------------------------------------------------------------------------
    -- StripRealm
    ---------------------------------------------------------------------------

    describe("StripRealm", function()
        it("strips realm suffix", function()
            assert.equals("Alice", GBL:StripRealm("Alice-Wyrmrest"))
        end)

        it("returns bare name unchanged", function()
            assert.equals("Alice", GBL:StripRealm("Alice"))
        end)

        it("returns empty string for nil", function()
            assert.equals("", GBL:StripRealm(nil))
        end)

        it("returns empty string for empty input", function()
            assert.equals("", GBL:StripRealm(""))
        end)
    end)

    ---------------------------------------------------------------------------
    -- BuildRosterCache
    ---------------------------------------------------------------------------

    describe("BuildRosterCache", function()
        it("populates playerRealms from guild roster", function()
            MockWoW.guildRoster = {
                { name = "Alice-Wyrmrest" },
                { name = "Bob-Tichondrius" },
            }
            GBL:BuildRosterCache()
            assert.equals("Wyrmrest", guildData.playerRealms["Alice"])
            assert.equals("Tichondrius", guildData.playerRealms["Bob"])
        end)

        it("handles same-realm members without hyphen", function()
            MockWoW.guildRoster = {
                { name = "Charlie" },  -- same realm, no hyphen
            }
            GBL:BuildRosterCache()
            assert.equals("TestRealm", guildData.playerRealms["Charlie"])
        end)

        it("does nothing with empty roster", function()
            MockWoW.guildRoster = {}
            GBL:BuildRosterCache()
            -- Should not error, playerRealms remains empty
            assert.same({}, guildData.playerRealms)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Schema migration v2 → v3
    ---------------------------------------------------------------------------

    describe("MigrateSchemaV2ToV3", function()
        before_each(function()
            guildData.schemaVersion = 2
        end)

        it("removes corrupted records", function()
            table.insert(guildData.transactions, {
                type = "", player = "Alice", timestamp = 1000, id = "bad1:0",
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "", timestamp = 1001, id = "bad2:0",
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "Bob", timestamp = 1002, id = "good1:0",
            })

            GBL:MigrateSchemaV2ToV3(guildData)

            assert.equals(1, #guildData.transactions)
            assert.equals("Bob-TestRealm", guildData.transactions[1].player)
        end)

        it("resolves bare player names to Name-Realm", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "Alice",
                timestamp = 1000, id = "deposit|Alice|12345|5|1|0:0",
                itemID = 12345, count = 5, tab = 1,
            })

            GBL:MigrateSchemaV2ToV3(guildData)

            assert.equals("Alice-TestRealm", guildData.transactions[1].player)
        end)

        it("harvests realm from existing realm-qualified records", function()
            guildData.playerRealms = {}
            table.insert(guildData.transactions, {
                type = "deposit", player = "Alice-Wyrmrest",
                timestamp = 1000, id = "old:0",
                itemID = 12345, count = 5, tab = 1,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Alice",
                timestamp = 1001, id = "old2:0",
                itemID = 12345, count = 3, tab = 1,
            })

            GBL:MigrateSchemaV2ToV3(guildData)

            -- Both should resolve to Alice-Wyrmrest (harvested from first record)
            assert.equals("Alice-Wyrmrest", guildData.transactions[1].player)
            assert.equals("Alice-Wyrmrest", guildData.transactions[2].player)
        end)

        it("normalizes daily summary player sets", function()
            guildData.dailySummaries = {
                ["2024-01-01"] = {
                    players = { Alice = true, Bob = true },
                    totalWithdrawn = 10,
                },
            }

            GBL:MigrateSchemaV2ToV3(guildData)

            local summary = guildData.dailySummaries["2024-01-01"]
            assert.is_true(summary.players["Alice-TestRealm"])
            assert.is_true(summary.players["Bob-TestRealm"])
            assert.is_nil(summary.players["Alice"])
        end)

        it("normalizes weekly summary player sets", function()
            guildData.weeklySummaries = {
                ["2024-W01"] = {
                    players = { Charlie = true },
                    totalWithdrawn = 5,
                },
            }

            GBL:MigrateSchemaV2ToV3(guildData)

            local summary = guildData.weeklySummaries["2024-W01"]
            assert.is_true(summary.players["Charlie-TestRealm"])
        end)

        it("rebuilds seenTxHashes", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "Alice",
                timestamp = 1000, id = "deposit|Alice|12345|5|1|0:0",
                itemID = 12345, count = 5, tab = 1,
            })
            guildData.seenTxHashes["deposit|Alice|12345|5|1|0:0"] = 1000

            GBL:MigrateSchemaV2ToV3(guildData)

            -- Old hash should be gone
            assert.is_nil(guildData.seenTxHashes["deposit|Alice|12345|5|1|0:0"])
            -- New hash with realm should exist
            local newId = guildData.transactions[1].id
            assert.is_not_nil(guildData.seenTxHashes[newId])
        end)

        it("merges playerStats on collision", function()
            -- Simulate bare + realm-qualified entries for same player
            guildData.playerStats["Alice"] = {
                withdrawals = { flask = 3 },
                deposits = {},
                totalWithdrawCount = 3,
                totalDepositCount = 0,
                moneyWithdrawn = 0,
                moneyDeposited = 0,
                firstSeen = 1000,
                lastSeen = 2000,
            }
            guildData.playerStats["Alice-TestRealm"] = {
                withdrawals = { flask = 2, gem = 1 },
                deposits = { ore = 5 },
                totalWithdrawCount = 3,
                totalDepositCount = 5,
                moneyWithdrawn = 100,
                moneyDeposited = 0,
                firstSeen = 500,
                lastSeen = 3000,
            }

            GBL:MigrateSchemaV2ToV3(guildData)

            local merged = guildData.playerStats["Alice-TestRealm"]
            assert.is_not_nil(merged)
            assert.equals(6, merged.totalWithdrawCount)
            assert.equals(5, merged.totalDepositCount)
            assert.equals(100, merged.moneyWithdrawn)
            assert.equals(500, merged.firstSeen)
            assert.equals(3000, merged.lastSeen)
            assert.equals(5, merged.withdrawals.flask)
            assert.equals(1, merged.withdrawals.gem)
            assert.equals(5, merged.deposits.ore)
            -- Bare key should be cleared (AceDB wildcard returns default with all zeros)
            local bare = guildData.playerStats["Alice"]
            assert.equals(0, bare.totalWithdrawCount)
            assert.equals(0, bare.totalDepositCount)
        end)

        it("sets schemaVersion to 3", function()
            GBL:MigrateSchemaV2ToV3(guildData)
            assert.equals(3, guildData.schemaVersion)
        end)

        it("skips if already at schema version 3", function()
            guildData.schemaVersion = 3
            table.insert(guildData.transactions, {
                type = "deposit", player = "BareNameShouldStay",
                timestamp = 1000, id = "test:0",
            })

            GBL:MigrateSchemaV2ToV3(guildData)

            -- Should not have been modified
            assert.equals("BareNameShouldStay", guildData.transactions[1].player)
        end)

        it("normalizes scannedBy fields", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "Alice",
                timestamp = 1000, id = "old:0",
                scannedBy = "sync:Bob-Wyrmrest",
                itemID = 12345, count = 5, tab = 1,
            })

            GBL:MigrateSchemaV2ToV3(guildData)

            -- sync: prefix preserved, realm kept
            assert.equals("sync:Bob-Wyrmrest", guildData.transactions[1].scannedBy)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Schema migration v3 → v4 (per-slot occurrence counting)
    ---------------------------------------------------------------------------

    describe("MigrateOccurrenceToPerSlot", function()
        before_each(function()
            guildData.schemaVersion = 3
        end)

        it("reindexes cross-slot occurrences to per-slot", function()
            -- Old cross-slot counting: two records with same prefix but different
            -- slots got sequential :0, :1 from a shared counter.
            -- After migration they should each get :0 (independent per-slot).
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Katorri-TestRealm",
                itemID = 99999, count = 1, tab = 1,
                timestamp = 3600 * 100, id = "withdraw|Katorri-TestRealm|99999|1|1|100:0",
                _occurrence = 0,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Katorri-TestRealm",
                itemID = 99999, count = 1, tab = 1,
                timestamp = 3600 * 102, id = "withdraw|Katorri-TestRealm|99999|1|1|102:1",
                _occurrence = 1,
            })
            guildData.seenTxHashes["withdraw|Katorri-TestRealm|99999|1|1|100:0"] = 3600 * 100
            guildData.seenTxHashes["withdraw|Katorri-TestRealm|99999|1|1|102:1"] = 3600 * 102

            GBL:MigrateOccurrenceToPerSlot(guildData)

            -- Both should now be :0 in their respective slots
            assert.equals("withdraw|Katorri-TestRealm|99999|1|1|100:0", guildData.transactions[1].id)
            assert.equals(0, guildData.transactions[1]._occurrence)
            assert.equals("withdraw|Katorri-TestRealm|99999|1|1|102:0", guildData.transactions[2].id)
            assert.equals(0, guildData.transactions[2]._occurrence)
        end)

        it("rebuilds seenTxHashes with per-slot keys", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall-TestRealm",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 100, id = "withdraw|Thrall-TestRealm|12345|5|1|100:0",
                _occurrence = 0,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall-TestRealm",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 102, id = "withdraw|Thrall-TestRealm|12345|5|1|102:1",
                _occurrence = 1,
            })
            guildData.seenTxHashes["withdraw|Thrall-TestRealm|12345|5|1|100:0"] = 3600 * 100
            guildData.seenTxHashes["withdraw|Thrall-TestRealm|12345|5|1|102:1"] = 3600 * 102

            GBL:MigrateOccurrenceToPerSlot(guildData)

            -- Old :1 key gone, new :0 key present
            assert.is_nil(guildData.seenTxHashes["withdraw|Thrall-TestRealm|12345|5|1|102:1"])
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall-TestRealm|12345|5|1|102:0"])
            -- Slot 100 key unchanged
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall-TestRealm|12345|5|1|100:0"])
        end)

        it("preserves genuinely different same-hour events", function()
            -- Two real withdrawals in the same hour slot (different timestamps
            -- within the hour would be rounded to same value by WoW API)
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Alice-TestRealm",
                itemID = 55555, count = 1, tab = 1,
                timestamp = 3600 * 100, id = "withdraw|Alice-TestRealm|55555|1|1|100:0",
                _occurrence = 0,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Alice-TestRealm",
                itemID = 55555, count = 1, tab = 1,
                timestamp = 3600 * 100, id = "withdraw|Alice-TestRealm|55555|1|1|100:1",
                _occurrence = 1,
            })
            guildData.seenTxHashes["withdraw|Alice-TestRealm|55555|1|1|100:0"] = 3600 * 100
            guildData.seenTxHashes["withdraw|Alice-TestRealm|55555|1|1|100:1"] = 3600 * 100

            GBL:MigrateOccurrenceToPerSlot(guildData)

            -- Both preserved with :0 and :1 (same baseHash, two records)
            assert.equals(2, #guildData.transactions)
            assert.is_truthy(guildData.transactions[1].id:find(":0$"))
            assert.is_truthy(guildData.transactions[2].id:find(":1$"))
        end)

        it("sets schemaVersion to 4", function()
            GBL:MigrateOccurrenceToPerSlot(guildData)
            assert.equals(4, guildData.schemaVersion)
        end)

        it("skips if already at schema version 4", function()
            guildData.schemaVersion = 4
            table.insert(guildData.transactions, {
                type = "deposit", player = "Bob-TestRealm",
                timestamp = 1000, id = "deposit|Bob-TestRealm|12345|5|1|0:0",
                _occurrence = 0, itemID = 12345, count = 5, tab = 1,
            })

            GBL:MigrateOccurrenceToPerSlot(guildData)

            -- Should not have been modified
            assert.equals("deposit|Bob-TestRealm|12345|5|1|0:0", guildData.transactions[1].id)
        end)

        it("handles empty data gracefully", function()
            GBL:MigrateOccurrenceToPerSlot(guildData)

            assert.equals(4, guildData.schemaVersion)
            assert.equals(0, #guildData.transactions)
        end)

        it("handles money transactions", function()
            table.insert(guildData.moneyTransactions, {
                type = "repair", player = "Tank-TestRealm",
                amount = 50000,
                timestamp = 3600 * 100, id = "repair|Tank-TestRealm|50000|100:0",
                _occurrence = 0,
            })
            table.insert(guildData.moneyTransactions, {
                type = "repair", player = "Tank-TestRealm",
                amount = 50000,
                timestamp = 3600 * 102, id = "repair|Tank-TestRealm|50000|102:1",
                _occurrence = 1,
            })
            guildData.seenTxHashes["repair|Tank-TestRealm|50000|100:0"] = 3600 * 100
            guildData.seenTxHashes["repair|Tank-TestRealm|50000|102:1"] = 3600 * 102

            GBL:MigrateOccurrenceToPerSlot(guildData)

            -- Second record reindexed from :1 to :0 (independent slot counter)
            assert.equals("repair|Tank-TestRealm|50000|102:0", guildData.moneyTransactions[2].id)
            assert.equals(0, guildData.moneyTransactions[2]._occurrence)
        end)
    end)

    ---------------------------------------------------------------------------
    -- StoreTx / StoreMoneyTx validation
    ---------------------------------------------------------------------------

    describe("StoreTx validation", function()
        it("rejects records with empty type", function()
            local record = {
                type = "", player = "Alice-TestRealm",
                timestamp = 1000, id = "test:0",
            }
            assert.is_false(GBL:StoreTx(record, guildData))
        end)

        it("rejects records with empty player", function()
            local record = {
                type = "deposit", player = "",
                timestamp = 1000, id = "test:0",
            }
            assert.is_false(GBL:StoreTx(record, guildData))
        end)

        it("rejects records with nil type", function()
            local record = {
                player = "Alice-TestRealm",
                timestamp = 1000, id = "test:0",
            }
            assert.is_false(GBL:StoreTx(record, guildData))
        end)

        it("accepts valid records", function()
            local record = {
                type = "deposit", player = "Alice-TestRealm",
                timestamp = 1000, id = "deposit|Alice-TestRealm|12345|5|1|0:0",
                itemID = 12345, count = 5, tab = 1,
            }
            assert.is_true(GBL:StoreTx(record, guildData))
        end)
    end)

    describe("StoreMoneyTx validation", function()
        it("rejects records with empty type", function()
            local record = {
                type = "", player = "Alice-TestRealm",
                timestamp = 1000, id = "test:0",
                amount = 100,
            }
            assert.is_false(GBL:StoreMoneyTx(record, guildData))
        end)

        it("rejects records with nil player", function()
            local record = {
                type = "deposit",
                timestamp = 1000, id = "test:0",
                amount = 100,
            }
            assert.is_false(GBL:StoreMoneyTx(record, guildData))
        end)
    end)

    ---------------------------------------------------------------------------
    -- ItemCache
    ---------------------------------------------------------------------------

    describe("ItemCache", function()
        before_each(function()
            GBL:ClearItemCache()
        end)

        it("returns name/link for cached items", function()
            MockWoW.itemNames[12345] = {
                name = "Flask of Power",
                link = "|cff0070dd|Hitem:12345|h[Flask of Power]|h|r",
            }
            local name, link = GBL:GetCachedItemInfo(12345)
            assert.equals("Flask of Power", name)
            assert.truthy(link)
        end)

        it("returns nil for uncached items and requests load", function()
            MockWoW.itemInfoRequested = {}
            local name, link = GBL:GetCachedItemInfo(99999)
            assert.is_nil(name)
            assert.is_nil(link)
            assert.is_true(MockWoW.itemInfoRequested[99999])
        end)

        it("OnItemInfoReceived populates cache", function()
            -- First call triggers request
            GBL:GetCachedItemInfo(12345)
            assert.is_nil(GBL:GetCachedItemInfo(12345))

            -- Simulate item data arriving
            MockWoW.itemNames[12345] = {
                name = "Flask of Power",
                link = "|cff0070dd|Hitem:12345|h[Flask of Power]|h|r",
            }
            GBL:OnItemInfoReceived("GET_ITEM_INFO_RECEIVED", 12345)

            -- Now should return cached data
            local name = GBL:GetCachedItemInfo(12345)
            assert.equals("Flask of Power", name)
        end)

        it("returns nil for nil itemID", function()
            local name, link = GBL:GetCachedItemInfo(nil)
            assert.is_nil(name)
            assert.is_nil(link)
        end)
    end)

    ---------------------------------------------------------------------------
    -- ExtractItemName with cache
    ---------------------------------------------------------------------------

    describe("ExtractItemName with cache", function()
        before_each(function()
            GBL:ClearItemCache()
        end)

        it("prefers itemLink when present", function()
            local link = "|cff0070dd|Hitem:12345|h[Flask of Power]|h|r"
            assert.equals("Flask of Power", GBL:ExtractItemName(link, 12345))
        end)

        it("uses cache when itemLink is nil", function()
            MockWoW.itemNames[12345] = {
                name = "Flask of Power",
                link = "|cff0070dd|Hitem:12345|h[Flask of Power]|h|r",
            }
            assert.equals("Flask of Power", GBL:ExtractItemName(nil, 12345))
        end)

        it("falls back to Item # when cache miss", function()
            assert.equals("Item #99999", GBL:ExtractItemName(nil, 99999))
        end)

        it("returns Unknown Item when no itemID or link", function()
            assert.equals("Unknown Item", GBL:ExtractItemName(nil, nil))
        end)
    end)

    ---------------------------------------------------------------------------
    -- MigrateDeduplicateRecords (schema v4→v5)
    ---------------------------------------------------------------------------

    describe("MigrateDeduplicateRecords", function()
        -- Helper: create a record with explicit fields for dedup testing
        local function makeRecord(opts)
            local rec = {
                type = opts.type or "withdraw",
                player = opts.player or "Katorri-TestRealm",
                itemID = opts.itemID or 99999,
                count = opts.count or 1,
                tab = opts.tab or 1,
                timestamp = opts.timestamp or (3600 * 100),
                scanTime = opts.scanTime or MockWoW.serverTime,
                scannedBy = opts.scannedBy or "Katorri-TestRealm",
            }
            rec.id = GBL:ComputeTxHash(rec)
            return rec
        end

        local function makeMoneyRecord(opts)
            local rec = {
                type = opts.type or "deposit",
                player = opts.player or "Katorri-TestRealm",
                amount = opts.amount or 50000,
                timestamp = opts.timestamp or (3600 * 100),
                scanTime = opts.scanTime or MockWoW.serverTime,
                scannedBy = opts.scannedBy or "Katorri-TestRealm",
            }
            rec.id = GBL:ComputeTxHash(rec)
            return rec
        end

        -- Assign occurrence indices to a set of records (simulates what the buggy code stored)
        local function assignAndStore(records, gd, storageKey)
            GBL:AssignOccurrenceIndices(records)
            for _, rec in ipairs(records) do
                table.insert(gd[storageKey], rec)
                gd.seenTxHashes[rec.id] = rec.timestamp
            end
        end

        it("removes bug duplicates with different scanTimes", function()
            guildData.schemaVersion = 4
            -- Original record from first scan
            local r1 = makeRecord({ scanTime = 1000 })
            -- Bug duplicates from later rescans
            local r2 = makeRecord({ scanTime = 1003, timestamp = 3600 * 100 + 3 })
            local r3 = makeRecord({ scanTime = 1006, timestamp = 3600 * 100 + 6 })
            assignAndStore({ r1, r2, r3 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(2, removed)
            assert.equals(1, #guildData.transactions)
            assert.equals(1000, guildData.transactions[1].scanTime)
        end)

        it("keeps genuine identical events from same scan", function()
            guildData.schemaVersion = 4
            -- Two genuine withdrawals in the same scan (same scanTime)
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 1000 })
            -- One bug duplicate from a rescan
            local r3 = makeRecord({ scanTime = 1003 })
            assignAndStore({ r1, r2, r3 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(1, removed)
            assert.equals(2, #guildData.transactions)
        end)

        it("handles all-synced records using smallest sub-group", function()
            guildData.schemaVersion = 4
            local r1 = makeRecord({ scanTime = 2000, scannedBy = "sync:PeerA-TestRealm" })
            local r2 = makeRecord({ scanTime = 2001, scannedBy = "sync:PeerA-TestRealm" })
            local r3 = makeRecord({ scanTime = 2002, scannedBy = "sync:PeerA-TestRealm" })
            assignAndStore({ r1, r2, r3 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            -- Each sub-group has 1 record; smallest = 1; keep 1
            assert.equals(2, removed)
            assert.equals(1, #guildData.transactions)
        end)

        it("prefers local anchor over synced records", function()
            guildData.schemaVersion = 4
            -- Synced records arrived first (earlier scanTime = receipt time)
            local s1 = makeRecord({ scanTime = 500, scannedBy = "sync:PeerA-TestRealm" })
            local s2 = makeRecord({ scanTime = 501, scannedBy = "sync:PeerA-TestRealm" })
            -- Local scan later
            local l1 = makeRecord({ scanTime = 1000 })
            assignAndStore({ s1, s2, l1 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            -- Local anchor has 1 record → keep 1
            assert.equals(2, removed)
            assert.equals(1, #guildData.transactions)
            assert.equals(1000, guildData.transactions[1].scanTime)
        end)

        it("preserves records with different baseHashes", function()
            guildData.schemaVersion = 4
            -- Two different items
            local a1 = makeRecord({ itemID = 111, scanTime = 1000 })
            local a2 = makeRecord({ itemID = 111, scanTime = 1003 })  -- dup of a1
            local b1 = makeRecord({ itemID = 222, scanTime = 1000 })

            assignAndStore({ a1 }, guildData, "transactions")
            -- Manually add a2 and b1 with correct IDs
            local a2base = GBL:ComputeTxHash(a2)
            a2._occurrence = 1
            a2.id = a2base .. ":1"
            table.insert(guildData.transactions, a2)
            guildData.seenTxHashes[a2.id] = a2.timestamp

            assignAndStore({ b1 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(1, removed)  -- only a2 removed
            assert.equals(2, #guildData.transactions)  -- a1 + b1 survive
        end)

        it("no-ops when no duplicates exist", function()
            guildData.schemaVersion = 4
            local r1 = makeRecord({ scanTime = 1000 })
            assignAndStore({ r1 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(0, removed)
            assert.equals(1, #guildData.transactions)
            assert.equals(5, guildData.schemaVersion)
        end)

        it("rebuilds seenTxHashes with correct indices", function()
            guildData.schemaVersion = 4
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 1003 })
            local r3 = makeRecord({ scanTime = 1006 })
            assignAndStore({ r1, r2, r3 }, guildData, "transactions")

            GBL:MigrateDeduplicateRecords(guildData)

            -- Only 1 record survives with :0 suffix
            local count = 0
            for _ in pairs(guildData.seenTxHashes) do count = count + 1 end
            assert.equals(1, count)
            assert.is_truthy(guildData.transactions[1].id:find(":0$"))
            assert.is_not_nil(guildData.seenTxHashes[guildData.transactions[1].id])
        end)

        it("rebuilds playerStats from surviving records", function()
            guildData.schemaVersion = 4
            -- 3 records: 1 genuine, 2 bug duplicates
            local r1 = makeRecord({ type = "withdraw", scanTime = 1000, count = 5 })
            local r2 = makeRecord({ type = "withdraw", scanTime = 1003, count = 5 })
            local r3 = makeRecord({ type = "withdraw", scanTime = 1006, count = 5 })
            assignAndStore({ r1, r2, r3 }, guildData, "transactions")

            GBL:MigrateDeduplicateRecords(guildData)

            local stats = guildData.playerStats["Katorri-TestRealm"]
            -- Only 1 record survives → totalWithdrawCount = 5 (not 15)
            assert.equals(5, stats.totalWithdrawCount)
        end)

        it("handles empty transactions gracefully", function()
            guildData.schemaVersion = 4
            local removed = GBL:MigrateDeduplicateRecords(guildData)
            assert.equals(0, removed)
            assert.equals(5, guildData.schemaVersion)
        end)

        it("deduplicates money transactions", function()
            guildData.schemaVersion = 4
            local m1 = makeMoneyRecord({ scanTime = 1000 })
            local m2 = makeMoneyRecord({ scanTime = 1003 })
            assignAndStore({ m1, m2 }, guildData, "moneyTransactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.moneyTransactions)
        end)

        it("skips already-migrated data (schemaVersion >= 5)", function()
            guildData.schemaVersion = 5
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 1003 })
            assignAndStore({ r1, r2 }, guildData, "transactions")

            local removed = GBL:MigrateDeduplicateRecords(guildData)

            assert.equals(0, removed)
            assert.equals(2, #guildData.transactions)  -- unchanged
        end)
    end)

    ---------------------------------------------------------------------------
    -- MigrateCrossSlotDedup (schema v5→v6)
    ---------------------------------------------------------------------------

    describe("MigrateCrossSlotDedup", function()
        -- Helper: create a record with explicit fields for dedup testing
        local function makeRecord(opts)
            local rec = {
                type = opts.type or "withdraw",
                player = opts.player or "Katorri-TestRealm",
                itemID = opts.itemID or 99999,
                count = opts.count or 1,
                tab = opts.tab or 1,
                timestamp = opts.timestamp or (3600 * 100),
                scanTime = opts.scanTime or MockWoW.serverTime,
                scannedBy = opts.scannedBy or "Katorri-TestRealm",
            }
            rec.id = GBL:ComputeTxHash(rec)
            return rec
        end

        local function assignAndStore(records, gd, storageKey)
            GBL:AssignOccurrenceIndices(records)
            for _, rec in ipairs(records) do
                table.insert(gd[storageKey], rec)
                gd.seenTxHashes[rec.id] = rec.timestamp
            end
        end

        it("removes cross-slot duplicates missed by v4→v5 migration", function()
            guildData.schemaVersion = 5
            -- Original record at slot 100
            local r1 = makeRecord({ timestamp = 3600 * 100, scanTime = 1000 })
            r1.id = GBL:ComputeTxHash(r1)
            r1._occurrence = 0
            r1.id = r1.id .. ":0"
            table.insert(guildData.transactions, r1)
            guildData.seenTxHashes[r1.id] = r1.timestamp

            -- Cross-slot duplicate at slot 101 (created by counting bug).
            -- ID and occurrence set manually (not via AssignOccurrenceIndices)
            -- because cross-slot duplicates have different baseHashes — they
            -- were independently scanned at different times, each getting :0.
            local r2 = makeRecord({ timestamp = 3600 * 100 + 200, scanTime = 1005 })
            r2.id = "withdraw|Katorri-TestRealm|99999|1|1|101:0"
            r2._occurrence = 0
            table.insert(guildData.transactions, r2)
            guildData.seenTxHashes[r2.id] = r2.timestamp

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.transactions)
            assert.equals(1000, guildData.transactions[1].scanTime)
        end)

        it("preserves genuinely different events in non-adjacent hours", function()
            guildData.schemaVersion = 5
            -- Event A at hour 100
            local r1 = makeRecord({ timestamp = 3600 * 100, scanTime = 1000 })
            assignAndStore({ r1 }, guildData, "transactions")
            -- Event B at hour 105 (well separated, genuinely different)
            local r2 = makeRecord({ timestamp = 3600 * 105, scanTime = 1000 })
            assignAndStore({ r2 }, guildData, "transactions")

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(0, removed)
            assert.equals(2, #guildData.transactions)
        end)

        it("handles multiple clusters within same prefix", function()
            guildData.schemaVersion = 5
            -- Cluster A: hour 100 (1 genuine + 1 dup)
            local a1 = makeRecord({ timestamp = 3600 * 100, scanTime = 1000 })
            local a2 = makeRecord({ timestamp = 3600 * 100 + 100, scanTime = 1005 })
            -- Cluster B: hour 200 (1 genuine, no dup)
            local b1 = makeRecord({ timestamp = 3600 * 200, scanTime = 1000 })

            assignAndStore({ a1, a2, b1 }, guildData, "transactions")

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(1, removed)  -- only a2 removed
            assert.equals(2, #guildData.transactions)
        end)

        it("rebuilds seenTxHashes and playerStats", function()
            guildData.schemaVersion = 5
            local r1 = makeRecord({ timestamp = 3600 * 100, scanTime = 1000, count = 5 })
            local r2 = makeRecord({ timestamp = 3600 * 100 + 50, scanTime = 1003, count = 5 })
            assignAndStore({ r1, r2 }, guildData, "transactions")

            GBL:MigrateCrossSlotDedup(guildData)

            -- Only 1 survives
            local hashCount = 0
            for _ in pairs(guildData.seenTxHashes) do hashCount = hashCount + 1 end
            assert.equals(1, hashCount)

            local stats = guildData.playerStats["Katorri-TestRealm"]
            assert.equals(5, stats.totalWithdrawCount)  -- not 10
        end)

        it("sets schemaVersion to 6", function()
            guildData.schemaVersion = 5
            GBL:MigrateCrossSlotDedup(guildData)
            assert.equals(6, guildData.schemaVersion)
        end)

        it("skips already-migrated data (schemaVersion >= 6)", function()
            guildData.schemaVersion = 6
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 1003 })
            assignAndStore({ r1, r2 }, guildData, "transactions")

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(0, removed)
            assert.equals(2, #guildData.transactions)
        end)

        it("handles empty data gracefully", function()
            guildData.schemaVersion = 5
            local removed = GBL:MigrateCrossSlotDedup(guildData)
            assert.equals(0, removed)
            assert.equals(6, guildData.schemaVersion)
        end)

        it("removes cross-slot money duplicates", function()
            guildData.schemaVersion = 5
            local function makeMoneyRec(opts)
                local rec = {
                    type = opts.type or "deposit",
                    player = opts.player or "Katorri-TestRealm",
                    amount = opts.amount or 50000,
                    timestamp = opts.timestamp or (3600 * 100),
                    scanTime = opts.scanTime or MockWoW.serverTime,
                    scannedBy = opts.scannedBy or "Katorri-TestRealm",
                }
                rec.id = GBL:ComputeTxHash(rec)
                return rec
            end

            -- Original at slot 100
            local m1 = makeMoneyRec({ scanTime = 1000 })
            m1._occurrence = 0
            m1.id = m1.id .. ":0"
            table.insert(guildData.moneyTransactions, m1)
            guildData.seenTxHashes[m1.id] = m1.timestamp

            -- Cross-slot duplicate at slot 101
            local m2 = makeMoneyRec({ timestamp = 3600 * 100 + 200, scanTime = 1005 })
            m2.id = "deposit|Katorri-TestRealm|50000|101:0"
            m2._occurrence = 0
            table.insert(guildData.moneyTransactions, m2)
            guildData.seenTxHashes[m2.id] = m2.timestamp

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.moneyTransactions)
            assert.equals(1000, guildData.moneyTransactions[1].scanTime)
        end)

        it("handles mixed item and money cross-slot duplicates", function()
            guildData.schemaVersion = 5

            -- Item: original + cross-slot dup
            local i1 = makeRecord({ scanTime = 1000 })
            i1._occurrence = 0
            i1.id = GBL:ComputeTxHash(i1) .. ":0"
            table.insert(guildData.transactions, i1)
            guildData.seenTxHashes[i1.id] = i1.timestamp

            local i2 = makeRecord({ timestamp = 3600 * 100 + 100, scanTime = 1005 })
            i2.id = "withdraw|Katorri-TestRealm|99999|1|1|101:0"
            i2._occurrence = 0
            table.insert(guildData.transactions, i2)
            guildData.seenTxHashes[i2.id] = i2.timestamp

            -- Money: original + cross-slot dup
            local m1 = {
                type = "deposit", player = "Katorri-TestRealm",
                amount = 50000, timestamp = 3600 * 200,
                scanTime = 1000, scannedBy = "Katorri-TestRealm",
            }
            m1.id = GBL:ComputeTxHash(m1) .. ":0"
            m1._occurrence = 0
            table.insert(guildData.moneyTransactions, m1)
            guildData.seenTxHashes[m1.id] = m1.timestamp

            local m2 = {
                type = "deposit", player = "Katorri-TestRealm",
                amount = 50000, timestamp = 3600 * 200 + 100,
                scanTime = 1005, scannedBy = "Katorri-TestRealm",
            }
            m2.id = "deposit|Katorri-TestRealm|50000|201:0"
            m2._occurrence = 0
            table.insert(guildData.moneyTransactions, m2)
            guildData.seenTxHashes[m2.id] = m2.timestamp

            local removed = GBL:MigrateCrossSlotDedup(guildData)

            assert.equals(2, removed)  -- 1 item + 1 money
            assert.equals(1, #guildData.transactions)
            assert.equals(1, #guildData.moneyTransactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- DeduplicateRecords (schema-independent cleanup)
    ---------------------------------------------------------------------------

    describe("DeduplicateRecords", function()
        local function makeRecord(opts)
            local rec = {
                type = opts.type or "withdraw",
                player = opts.player or "Katorri-TestRealm",
                itemID = opts.itemID or 99999,
                count = opts.count or 1,
                tab = opts.tab or 1,
                timestamp = opts.timestamp or (3600 * 100),
                scanTime = opts.scanTime or MockWoW.serverTime,
                scannedBy = opts.scannedBy or "Katorri-TestRealm",
            }
            rec.id = GBL:ComputeTxHash(rec)
            return rec
        end

        local function assignAndStore(records, gd, storageKey)
            GBL:AssignOccurrenceIndices(records)
            for _, rec in ipairs(records) do
                table.insert(gd[storageKey], rec)
                gd.seenTxHashes[rec.id] = rec.timestamp
            end
        end

        it("runs without schema guard regardless of schemaVersion", function()
            guildData.schemaVersion = 99
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 1003 })
            assignAndStore({ r1, r2 }, guildData, "transactions")

            local removed = GBL:DeduplicateRecords(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.transactions)
            -- Schema should be restored to original (99 > 6)
            assert.equals(99, guildData.schemaVersion)
        end)

        it("removes duplicates from diverged sync occurrence indices", function()
            guildData.schemaVersion = 6
            -- Local: 1 genuine event, cleaned to :0
            local local1 = makeRecord({ scanTime = 1000 })
            local1._occurrence = 0
            local1.id = GBL:ComputeTxHash(local1) .. ":0"
            table.insert(guildData.transactions, local1)
            guildData.seenTxHashes[local1.id] = local1.timestamp

            -- Sync brought in: same event but peer had it as :1
            -- (IsDuplicate didn't catch it because :1 != :0)
            local synced = makeRecord({
                timestamp = 3600 * 100 + 50,  -- same event, slight ts diff
                scanTime = 2000,
                scannedBy = "sync:Voxle-TestRealm",
            })
            synced._occurrence = 1
            synced.id = GBL:ComputeTxHash(synced) .. ":1"
            table.insert(guildData.transactions, synced)
            guildData.seenTxHashes[synced.id] = synced.timestamp

            local removed = GBL:DeduplicateRecords(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.transactions)
            -- Earliest local scan (scanTime=1000) survives
            assert.equals(1000, guildData.transactions[1].scanTime)
        end)

        it("preserves schema version when already >= 6", function()
            guildData.schemaVersion = 7
            local removed = GBL:DeduplicateRecords(guildData)
            assert.equals(0, removed)
            assert.equals(7, guildData.schemaVersion)
        end)

        -- CRITICAL: genuine synced records must survive cleanup
        it("preserves genuine synced second event in same hour", function()
            guildData.schemaVersion = 6
            -- Local: 1 event scanned locally
            local local1 = makeRecord({ scanTime = 1000 })
            local1._occurrence = 0
            local1.id = GBL:ComputeTxHash(local1) .. ":0"
            table.insert(guildData.transactions, local1)
            guildData.seenTxHashes[local1.id] = local1.timestamp

            -- Sync: GENUINE second event from peer (different withdrawal
            -- in same hour that local client hadn't scanned yet)
            local synced = makeRecord({
                timestamp = 3600 * 100 + 50,
                scanTime = 2000,
                scannedBy = "sync:Voxle-TestRealm",
            })
            synced._occurrence = 1
            synced.id = GBL:ComputeTxHash(synced) .. ":1"
            table.insert(guildData.transactions, synced)
            guildData.seenTxHashes[synced.id] = synced.timestamp

            local removed = GBL:DeduplicateRecords(guildData)

            -- Both records must survive — the synced one is genuine
            assert.equals(0, removed)
            assert.equals(2, #guildData.transactions)
        end)
    end)
end)
