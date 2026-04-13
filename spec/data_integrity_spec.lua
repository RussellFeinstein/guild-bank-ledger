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
end)
