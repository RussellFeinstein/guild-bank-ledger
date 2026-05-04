------------------------------------------------------------------------
-- core_spec.lua — Tests for Core.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

describe("Core", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    describe("initialization", function()
        it("creates the addon without error", function()
            assert.is_not_nil(GBL)
            assert.equals("GuildBankLedger", GBL._name)
        end)

        it("creates AceDB with correct SavedVariables name", function()
            GBL:OnInitialize()
            assert.is_not_nil(MockAce.dbInstance)
            assert.equals("GuildBankLedgerDB", MockAce.dbInstance._svName)
        end)

        it("registers slash commands", function()
            GBL:OnInitialize()
            assert.is_not_nil(MockAce.registeredSlashCommands["gbl"])
            assert.is_not_nil(MockAce.registeredSlashCommands["guildbankledger"])
        end)
    end)

    describe("bank open/close detection", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
        end)

        it("detects guild bank open via correct event", function()
            assert.is_not_nil(MockAce.registeredEvents["PLAYER_INTERACTION_MANAGER_FRAME_SHOW"])
        end)

        it("sets bankOpen on GuildBanker interaction", function()
            assert.is_false(GBL:IsBankOpen())
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_true(GBL:IsBankOpen())
        end)

        it("ignores non-GuildBanker interaction types", function()
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 99)
            assert.is_false(GBL:IsBankOpen())
        end)

        it("sets bankOpen false on bank close", function()
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_true(GBL:IsBankOpen())

            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_false(GBL:IsBankOpen())
        end)

        it("marks bank open but does not scan when not in a guild", function()
            MockWoW.guild.name = nil
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            -- Bank frame is physically open
            assert.is_true(GBL:IsBankOpen())
            -- But no scan starts because guild name is nil
            assert.is_false(GBL.scanInProgress)
        end)
    end)

    describe("IsBankOpen", function()
        it("returns correct state", function()
            GBL:OnInitialize()
            assert.is_false(GBL:IsBankOpen())

            GBL.bankOpen = true
            assert.is_true(GBL:IsBankOpen())

            GBL.bankOpen = false
            assert.is_false(GBL:IsBankOpen())
        end)
    end)

    describe("GetGuildName", function()
        before_each(function()
            GBL:OnInitialize()
        end)

        it("returns nil when not in a guild", function()
            MockWoW.guild.name = nil
            assert.is_nil(GBL:GetGuildName())
        end)

        it("returns guild name when in a guild", function()
            MockWoW.guild.name = "Test Guild"
            assert.equals("Test Guild", GBL:GetGuildName())
        end)
    end)

    describe("slash commands", function()
        before_each(function()
            GBL:OnInitialize()
            Helpers.clearPrints()
        end)

        it("status prints version and guild info", function()
            MockWoW.guild.name = "Test Guild"
            GBL:HandleSlashCommand("status")
            assert.is_true(Helpers.printContains("0.30.5"))
            assert.is_true(Helpers.printContains("Test Guild"))
        end)

        it("help prints available commands", function()
            GBL:HandleSlashCommand("help")
            assert.is_true(Helpers.printContains("/gbl status"))
            assert.is_true(Helpers.printContains("/gbl scan"))
            assert.is_true(Helpers.printContains("/gbl help"))
        end)

        it("empty command calls ToggleMainFrame", function()
            local called = false
            local origToggle = GBL.ToggleMainFrame
            GBL.ToggleMainFrame = function() called = true end
            GBL:HandleSlashCommand("")
            GBL.ToggleMainFrame = origToggle
            assert.is_true(called)
        end)

        it("'show' command calls ToggleMainFrame", function()
            local called = false
            local origToggle = GBL.ToggleMainFrame
            GBL.ToggleMainFrame = function() called = true end
            GBL:HandleSlashCommand("show")
            GBL.ToggleMainFrame = origToggle
            assert.is_true(called)
        end)
    end)

    ---------------------------------------------------------------------------
    -- MigrateOccurrenceScheme (v0.12.0)
    ---------------------------------------------------------------------------

    describe("MigrateOccurrenceScheme", function()
        local guildData

        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            guildData = GBL:GetGuildData()
        end)

        it("reassigns occurrences by prefix across hour slots", function()
            -- Two records with same prefix, different hours — old scheme both :0
            guildData.schemaVersion = 1
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|475100:0", _occurrence = 0,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "withdraw|Thrall|12345|5|1|475101:0", _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 3600 * 475100
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            GBL:MigrateOccurrenceScheme(guildData)

            -- First record (earlier timestamp) keeps :0, second gets :1
            assert.equals("withdraw|Thrall|12345|5|1|475100:0", guildData.transactions[1].id)
            assert.equals(0, guildData.transactions[1]._occurrence)
            assert.equals("withdraw|Thrall|12345|5|1|475101:1", guildData.transactions[2].id)
            assert.equals(1, guildData.transactions[2]._occurrence)
            assert.equals(2, guildData.schemaVersion)
        end)

        it("rebuilds seenTxHashes with new keys", function()
            guildData.schemaVersion = 1
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|475100:0", _occurrence = 0,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "withdraw|Thrall|12345|5|1|475101:0", _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 3600 * 475100
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            GBL:MigrateOccurrenceScheme(guildData)

            -- Old :0 key for second record is gone, new :1 key present
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"])
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:1"])
            assert.is_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:0"])

            -- Timestamps preserved
            assert.equals(3600 * 475100, guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"])
            assert.equals(3600 * 475101, guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:1"])
        end)

        it("is idempotent — skips on schemaVersion 2", function()
            guildData.schemaVersion = 2
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|475100:0", _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 3600 * 475100

            GBL:MigrateOccurrenceScheme(guildData)

            -- Nothing changed
            assert.equals("withdraw|Thrall|12345|5|1|475100:0", guildData.transactions[1].id)
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"])
        end)

        it("handles records without occurrence suffix", function()
            guildData.schemaVersion = 1
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|100", _occurrence = nil,  -- no :N suffix
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|100"] = 3600 * 475100

            GBL:MigrateOccurrenceScheme(guildData)

            assert.equals("withdraw|Thrall|12345|5|1|100:0", guildData.transactions[1].id)
            assert.equals(0, guildData.transactions[1]._occurrence)
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|100:0"])
            assert.is_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|100"])
        end)

        it("preserves non-ID fields", function()
            guildData.schemaVersion = 1
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|475100:0", _occurrence = 0,
                classID = 2, subclassID = 3, category = "Consumable",
                scanTime = 9999, scannedBy = "OfficerA",
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "withdraw|Thrall|12345|5|1|475101:0", _occurrence = 0,
                classID = 2, subclassID = 3, category = "Consumable",
                scanTime = 10000, scannedBy = "OfficerA",
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 3600 * 475100
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            GBL:MigrateOccurrenceScheme(guildData)

            -- ID changed for second record, but all other fields preserved
            local rec = guildData.transactions[2]
            assert.equals("withdraw|Thrall|12345|5|1|475101:1", rec.id)
            assert.equals("withdraw", rec.type)
            assert.equals("Thrall", rec.player)
            assert.equals(12345, rec.itemID)
            assert.equals(5, rec.count)
            assert.equals(1, rec.tab)
            assert.equals(3600 * 475101, rec.timestamp)
            assert.equals(2, rec.classID)
            assert.equals(3, rec.subclassID)
            assert.equals("Consumable", rec.category)
            assert.equals(10000, rec.scanTime)
            assert.equals("OfficerA", rec.scannedBy)
        end)

        it("removes corrupted records during migration", function()
            guildData.schemaVersion = 1

            -- Valid record
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "withdraw|Thrall|12345|5|1|475100:0", _occurrence = 0,
            })
            -- Corrupted: "typyer" key (type+player merged)
            table.insert(guildData.transactions, {
                typyer = "Yoshpet", itemID = 244018,
                scannedBy = "sync:Deemle", subclassID = 2,
                timestamp = 3600 * 475200, _occurrence = 0,
                id = "||244018|0|0|475200:0",
            })
            -- Corrupted: "typelassID" key
            table.insert(guildData.transactions, {
                typelassID = 8, player = "Someone",
                itemID = 243987, scannedBy = "sync:Aeglos",
                timestamp = 3600 * 475300, _occurrence = 0,
                id = "|Someone|243987|0|0|475300:0",
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 3600 * 475100
            guildData.seenTxHashes["||244018|0|0|475200:0"] = 3600 * 475200
            guildData.seenTxHashes["|Someone|243987|0|0|475300:0"] = 3600 * 475300

            GBL:MigrateOccurrenceScheme(guildData)

            -- Only the valid record survives
            assert.equals(1, #guildData.transactions)
            assert.equals("Thrall", guildData.transactions[1].player)
            assert.equals(2, guildData.schemaVersion)
            -- Corrupted keys cleaned from seenTxHashes (rebuilt from surviving records)
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"])
            assert.is_nil(guildData.seenTxHashes["||244018|0|0|475200:0"])
            assert.is_nil(guildData.seenTxHashes["|Someone|243987|0|0|475300:0"])
        end)
    end)

    describe("minimap button", function()
        it("registers LibDataBroker data object on init", function()
            GBL:OnInitialize()
            local ldb = MockAce.ldb
            assert.is_not_nil(ldb._objects["GuildBankLedger"])
        end)

        it("registers with LibDBIcon on init", function()
            GBL:OnInitialize()
            local icon = MockAce.ldbIcon
            assert.is_not_nil(icon._registered["GuildBankLedger"])
        end)

        it("toggle hides minimap icon but keeps LDB object", function()
            GBL:OnInitialize()
            local icon = MockAce.ldbIcon
            local ldb = MockAce.ldb

            -- Simulate unchecking "Show minimap button"
            local hideCalled, showCalled = false, false
            icon.Hide = function() hideCalled = true end
            icon.Show = function() showCalled = true end

            GBL.db.profile.minimap.hide = true
            icon.Hide()
            assert.is_true(hideCalled)
            assert.is_true(GBL.db.profile.minimap.hide)
            -- LDB data object still registered
            assert.is_not_nil(ldb._objects["GuildBankLedger"])

            -- Simulate re-checking "Show minimap button"
            GBL.db.profile.minimap.hide = false
            icon.Show()
            assert.is_true(showCalled)
            assert.is_false(GBL.db.profile.minimap.hide)
            assert.is_not_nil(ldb._objects["GuildBankLedger"])
        end)
    end)

    describe("post-scan duplicate cleanup", function()
        local guildData

        local function makeRecord(opts)
            local rec = {
                type = opts.type or "withdraw",
                player = opts.player or "Thrall-TestRealm",
                itemID = opts.itemID or 12345,
                count = opts.count or 5,
                tab = opts.tab or 1,
                timestamp = opts.timestamp or (3600 * 475100),
                scanTime = opts.scanTime or MockWoW.serverTime,
                scannedBy = opts.scannedBy or "Thrall-TestRealm",
            }
            rec.id = GBL:ComputeTxHash(rec)
            return rec
        end

        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
            guildData.schemaVersion = 7
        end)

        it("removes duplicates after bank scan refreshes eventCounts", function()
            -- Two records for the same event (e.g., from sync divergence)
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 2000, timestamp = 3600 * 475100 + 50 })
            GBL:AssignOccurrenceIndices({ r1, r2 })
            table.insert(guildData.transactions, r1)
            table.insert(guildData.transactions, r2)
            guildData.seenTxHashes[r1.id] = r1.timestamp
            guildData.seenTxHashes[r2.id] = r2.timestamp

            -- eventCounts says only 1 event exists (fresh from API scan)
            local baseHash = GBL:ComputeTxHash(r1)
            guildData.eventCounts = {
                [baseHash] = { count = 1, asOf = MockWoW.serverTime },
            }

            -- Simulate post-scan callback: bankOpen + fire deferred timers
            GBL.bankOpen = true
            -- Directly call the post-scan cleanup path
            local removed = GBL:DeduplicateRecords(guildData)

            assert.equals(1, removed)
            assert.equals(1, #guildData.transactions)
        end)

        it("skips cleanup when no duplicates exist", function()
            local r1 = makeRecord({})
            GBL:AssignOccurrenceIndices({ r1 })
            table.insert(guildData.transactions, r1)
            guildData.seenTxHashes[r1.id] = r1.timestamp

            local baseHash = GBL:ComputeTxHash(r1)
            guildData.eventCounts = {
                [baseHash] = { count = 1, asOf = MockWoW.serverTime },
            }

            local removed = GBL:DeduplicateRecords(guildData)

            assert.equals(0, removed)
            assert.equals(1, #guildData.transactions)
        end)

        it("skips cleanup when eventCounts is empty", function()
            -- Stale eventCounts (the scenario that caused the original bug)
            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 2000, timestamp = 3600 * 475100 + 50 })
            GBL:AssignOccurrenceIndices({ r1, r2 })
            table.insert(guildData.transactions, r1)
            table.insert(guildData.transactions, r2)
            guildData.seenTxHashes[r1.id] = r1.timestamp
            guildData.seenTxHashes[r2.id] = r2.timestamp

            -- No eventCounts — conservative: keep all
            guildData.eventCounts = {}

            local removed = GBL:DeduplicateRecords(guildData)

            assert.equals(0, removed)
            assert.equals(2, #guildData.transactions)
        end)

        it("OnEnable early dedup catches duplicates with existing eventCounts", function()
            -- Pre-populate guild data before OnEnable
            local testGuildData = GBL.db.global.guilds["Early Guild"]
            testGuildData.schemaVersion = 7
            testGuildData.transactions = {}
            testGuildData.moneyTransactions = {}
            testGuildData.seenTxHashes = {}

            local r1 = makeRecord({ scanTime = 1000 })
            local r2 = makeRecord({ scanTime = 2000, timestamp = 3600 * 475100 + 50 })
            GBL:AssignOccurrenceIndices({ r1, r2 })
            table.insert(testGuildData.transactions, r1)
            table.insert(testGuildData.transactions, r2)
            testGuildData.seenTxHashes[r1.id] = r1.timestamp
            testGuildData.seenTxHashes[r2.id] = r2.timestamp

            local baseHash = GBL:ComputeTxHash(r1)
            testGuildData.eventCounts = {
                [baseHash] = { count = 1, asOf = MockWoW.serverTime },
            }

            -- Re-run OnEnable (which includes the early dedup pass)
            GBL:OnEnable()

            -- The early pass should have caught the duplicate
            assert.equals(1, #testGuildData.transactions)
        end)
    end)

    describe("realm normalization (NormalizeRealm / GetLocalRealm)", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
        end)

        it("NormalizeRealm strips internal whitespace", function()
            assert.equals("AeriePeak", GBL:NormalizeRealm("Aerie Peak"))
            assert.equals("Area52", GBL:NormalizeRealm("Area 52"))
        end)

        it("NormalizeRealm passes through already-normalized realms", function()
            assert.equals("Tichondrius", GBL:NormalizeRealm("Tichondrius"))
            assert.equals("MalGanis", GBL:NormalizeRealm("MalGanis"))
        end)

        it("NormalizeRealm handles nil and empty input", function()
            assert.is_nil(GBL:NormalizeRealm(nil))
            assert.equals("", GBL:NormalizeRealm(""))
        end)

        it("GetLocalRealm prefers GetNormalizedRealmName output", function()
            MockWoW.player.realm = "Aerie Peak"
            -- Mock derives normalized form by stripping whitespace
            assert.equals("AeriePeak", GBL:GetLocalRealm())
        end)

        it("GetLocalRealm falls back to UnknownRealm when both APIs are nil", function()
            local origN = _G.GetNormalizedRealmName
            local origR = _G.GetRealmName
            _G.GetNormalizedRealmName = function() return nil end
            _G.GetRealmName = function() return nil end
            local result = GBL:GetLocalRealm()
            _G.GetNormalizedRealmName = origN
            _G.GetRealmName = origR
            assert.equals("UnknownRealm", result)
        end)

        it("ResolvePlayerName fallback returns Name-NormalizedRealm for spaced realms", function()
            MockWoW.player.realm = "Aerie Peak"
            -- No playerRealms entry for Charlie, so ResolvePlayerName falls back
            local guildData = GBL:GetGuildData()
            guildData.playerRealms = {}
            assert.equals("Charlie-AeriePeak", GBL:ResolvePlayerName("Charlie"))
        end)

        it("BuildRosterCache stores normalized realm for cross-realm members", function()
            MockWoW.player.realm = "Tichondrius"
            MockWoW.guildRoster = {
                { name = "Alice-Aerie Peak", isOnline = true },
                { name = "Bob", isOnline = true },
            }
            GBL:BuildRosterCache()

            local guildData = GBL:GetGuildData()
            assert.equals("AeriePeak", guildData.playerRealms["Alice"])
            -- Same-realm member ("Bob" with no hyphen) gets the normalized local realm
            assert.equals("Tichondrius", guildData.playerRealms["Bob"])
        end)

        it("BuildRosterCache normalizes spaced local realms for bare-name members", function()
            MockWoW.player.realm = "Aerie Peak"
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },
            }
            GBL:BuildRosterCache()

            local guildData = GBL:GetGuildData()
            -- The local-realm fallback path also runs through GetLocalRealm
            assert.equals("AeriePeak", guildData.playerRealms["Alice"])
        end)

        it("GetGuildRosterInfo mock returns 14 values including lastLogoff", function()
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true, lastLogoff = 0 },
                { name = "Bob", isOnline = false, lastLogoff = 86400 },
            }
            local _, _, _, _, _, _, _, _, _, _, _, _, _, aliceLastLogoff = GetGuildRosterInfo(1)
            local _, _, _, _, _, _, _, _, _, _, _, _, _, bobLastLogoff = GetGuildRosterInfo(2)
            assert.equals(0, aliceLastLogoff)
            assert.equals(86400, bobLastLogoff)
        end)
    end)

    describe("MigrateNormalizeStoredRealms (schema 9 -> 10)", function()
        local guildData
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
        end)

        it("normalizes spaced realm strings in playerRealms", function()
            guildData.schemaVersion = 9
            guildData.playerRealms = {
                ["Alice"] = "Aerie Peak",
                ["Bob"] = "Area 52",
                ["Charlie"] = "Tichondrius",
            }

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(2, rewrites)
            assert.equals(10, guildData.schemaVersion)
            assert.equals("AeriePeak", guildData.playerRealms["Alice"])
            assert.equals("Area52", guildData.playerRealms["Bob"])
            assert.equals("Tichondrius", guildData.playerRealms["Charlie"])
        end)

        it("normalizes record.player realm portion", function()
            guildData.schemaVersion = 9
            guildData.transactions = {
                { player = "Alice-Aerie Peak", type = "deposit", timestamp = 1000 },
                { player = "Bob-Tichondrius", type = "deposit", timestamp = 1001 },
            }
            guildData.moneyTransactions = {
                { player = "Charlie-Area 52", type = "deposit", timestamp = 1002 },
            }

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(2, rewrites)
            assert.equals("Alice-AeriePeak", guildData.transactions[1].player)
            assert.equals("Bob-Tichondrius", guildData.transactions[2].player)
            assert.equals("Charlie-Area52", guildData.moneyTransactions[1].player)
        end)

        it("normalizes scannedBy sender realm portion", function()
            guildData.schemaVersion = 9
            guildData.transactions = {
                {
                    player = "Alice-AeriePeak",
                    scannedBy = "sync:Bob-Aerie Peak",
                    type = "deposit",
                    timestamp = 1000,
                },
            }

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(1, rewrites)
            assert.equals("sync:Bob-AeriePeak", guildData.transactions[1].scannedBy)
        end)

        it("is idempotent", function()
            guildData.schemaVersion = 9
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }

            local first = GBL:MigrateNormalizeStoredRealms(guildData)
            local second = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(1, first)
            assert.equals(0, second)
            assert.equals(10, guildData.schemaVersion)
        end)

        it("skips already-migrated guilds (schemaVersion >= 10)", function()
            guildData.schemaVersion = 10
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }

            GBL:MigrateNormalizeStoredRealms(guildData)

            -- Already at schema 10 so the function returns without rewriting
            assert.equals("Aerie Peak", guildData.playerRealms["Alice"])
        end)

        it("handles missing playerRealms / transactions gracefully", function()
            guildData.schemaVersion = 9
            guildData.playerRealms = nil
            guildData.transactions = nil
            guildData.moneyTransactions = nil

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(10, guildData.schemaVersion)
        end)

        it("refuses to bump from schema 8 (strict prerequisite)", function()
            -- If MigrateNormalizePeerNames short-circuits on cold realm APIs,
            -- schemaVersion stays at 8. This migration must NOT advance schema
            -- past 9 in that case, otherwise schema 8 -> 9 is permanently
            -- skipped on the next session.
            guildData.schemaVersion = 8
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(8, guildData.schemaVersion)
            -- Spaced realm untouched (will be normalized once schema 9 is reached)
            assert.equals("Aerie Peak", guildData.playerRealms["Alice"])
        end)

        it("recomputes record.id after rewriting record.player", function()
            guildData.schemaVersion = 9
            local hashOld = GBL:ComputeTxHash({
                type = "deposit", player = "Alice-Aerie Peak",
                itemID = 100, count = 5, timestamp = 1000,
            })
            local hashNew = GBL:ComputeTxHash({
                type = "deposit", player = "Alice-AeriePeak",
                itemID = 100, count = 5, timestamp = 1000,
            })
            -- Sanity check: the two hashes really differ (player participates)
            assert.not_equals(hashOld, hashNew)

            guildData.transactions = {
                {
                    type = "deposit", player = "Alice-Aerie Peak",
                    itemID = 100, count = 5, timestamp = 1000,
                    _occurrence = 0,
                    id = hashOld .. ":0",
                },
            }
            guildData.seenTxHashes = { [hashOld .. ":0"] = 1000 }

            GBL:MigrateNormalizeStoredRealms(guildData)

            -- Player normalized
            assert.equals("Alice-AeriePeak", guildData.transactions[1].player)
            -- Id recomputed from new player string
            assert.equals(hashNew .. ":0", guildData.transactions[1].id)
            -- seenTxHashes reseeded under the new id; old id evicted
            assert.is_nil(guildData.seenTxHashes[hashOld .. ":0"])
            assert.is_not_nil(guildData.seenTxHashes[hashNew .. ":0"])
        end)

        it("does not rebuild seenTxHashes when no record.player changed", function()
            guildData.schemaVersion = 9
            -- playerRealms has spaces (will be rewritten) but records do not
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }
            guildData.transactions = {
                {
                    type = "deposit", player = "Bob-AeriePeak",
                    itemID = 100, count = 5, timestamp = 1000,
                    _occurrence = 0, id = "h1:0",
                },
            }
            local sentinel = 9999
            guildData.seenTxHashes = { ["h1:0"] = sentinel }

            GBL:MigrateNormalizeStoredRealms(guildData)

            -- Record id untouched, seenTxHashes preserved with original sentinel
            assert.equals("h1:0", guildData.transactions[1].id)
            assert.equals(sentinel, guildData.seenTxHashes["h1:0"])
        end)
    end)

    describe("CanonicalPeerKey", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
        end)

        it("strips realm when it matches the local realm", function()
            MockWoW.player.realm = "TestRealm"
            assert.equals("Alice", GBL:CanonicalPeerKey("Alice-TestRealm"))
        end)

        it("preserves cross-realm suffix", function()
            MockWoW.player.realm = "TestRealm"
            assert.equals("Alice-OtherRealm", GBL:CanonicalPeerKey("Alice-OtherRealm"))
        end)

        it("passes bare names through unchanged", function()
            assert.equals("Alice", GBL:CanonicalPeerKey("Alice"))
        end)

        it("returns nil and empty input as-is without invoking Ambiguate", function()
            assert.is_nil(GBL:CanonicalPeerKey(nil))
            assert.equals("", GBL:CanonicalPeerKey(""))
        end)

        it("strips spaced same-realm via mock normalization fallback", function()
            MockWoW.player.realm = "Aerie Peak"
            -- Sender carries normalized form; mock compares both raw and normalized
            assert.equals("Alice", GBL:CanonicalPeerKey("Alice-AeriePeak"))
        end)
    end)

    describe("CanonicalPeerKey roster fallback (bare-name re-realming)", function()
        local guildData
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
            MockWoW.player.realm = "TestRealm"
        end)

        it("re-realms a bare name with a cross-realm playerRealms entry", function()
            guildData.playerRealms = { ["Katorriwl"] = "Stormrage" }
            assert.equals("Katorriwl-Stormrage", GBL:CanonicalPeerKey("Katorriwl"))
        end)

        it("collapses a bare name with a same-realm playerRealms entry", function()
            guildData.playerRealms = { ["Bob"] = "TestRealm" }
            -- Roster says Bob is local-realm; helper re-realms then Ambiguate("guild")
            -- collapses back to bare. Net: bare in, bare out (canonical for same-realm).
            assert.equals("Bob", GBL:CanonicalPeerKey("Bob"))
        end)

        it("returns bare unchanged when playerRealms has no entry", function()
            guildData.playerRealms = {}
            assert.equals("Ghost", GBL:CanonicalPeerKey("Ghost"))
        end)

        it("returns bare unchanged when playerRealms is absent on guildData", function()
            guildData.playerRealms = nil
            assert.equals("Loner", GBL:CanonicalPeerKey("Loner"))
        end)

        it("qualified name path is unaffected by playerRealms", function()
            guildData.playerRealms = { ["Katorriwl"] = "Stormrage" }
            -- Cross-realm qualified arrival: Ambiguate("guild") preserves
            assert.equals("Katorriwl-Stormrage", GBL:CanonicalPeerKey("Katorriwl-Stormrage"))
            -- Same-realm qualified arrival: Ambiguate("guild") strips
            assert.equals("Alice", GBL:CanonicalPeerKey("Alice-TestRealm"))
        end)
    end)

    describe("MigrateNormalizePeerNames (schema 8 -> 9, realm-aware)", function()
        local guildData
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
            MockWoW.player.realm = "TestRealm"
        end)

        it("collapses same-realm key to bare and merges by recency", function()
            guildData.schemaVersion = 8
            guildData.knownPeers = {
                ["Rexxybear"] = { version = "0.30.4", txCount = 5, lastSeen = 99000 },
                ["Rexxybear-TestRealm"] = { version = "0.30.4", txCount = 8, lastSeen = 99500 },
            }

            local merged = GBL:MigrateNormalizePeerNames(guildData)

            assert.equals(1, merged)
            assert.equals(9, guildData.schemaVersion)
            assert.is_nil(guildData.knownPeers["Rexxybear-TestRealm"])
            assert.equals(99500, guildData.knownPeers["Rexxybear"].lastSeen)
            assert.equals(8, guildData.knownPeers["Rexxybear"].txCount)
        end)

        it("preserves cross-realm key untouched", function()
            guildData.schemaVersion = 8
            guildData.knownPeers = {
                ["Otherguy-OtherRealm"] = { version = "0.30.4", txCount = 3, lastSeen = 98000 },
            }

            local merged = GBL:MigrateNormalizePeerNames(guildData)

            assert.equals(0, merged)
            assert.equals(9, guildData.schemaVersion)
            assert.is_not_nil(guildData.knownPeers["Otherguy-OtherRealm"])
            assert.is_nil(guildData.knownPeers["Otherguy"])
        end)

        it("mixed: same-realm collapses, cross-realm preserved", function()
            guildData.schemaVersion = 8
            guildData.knownPeers = {
                ["Bob-TestRealm"] = { version = "0.30.4", txCount = 7, lastSeen = 99000 },
                ["Bob-OtherRealm"] = { version = "0.30.4", txCount = 4, lastSeen = 99000 },
            }

            GBL:MigrateNormalizePeerNames(guildData)

            assert.is_nil(guildData.knownPeers["Bob-TestRealm"])
            assert.is_not_nil(guildData.knownPeers["Bob"])
            assert.is_not_nil(guildData.knownPeers["Bob-OtherRealm"])
        end)

        it("normalizes guildData.syncState.peers in the same pass", function()
            guildData.schemaVersion = 8
            guildData.syncState.peers = {
                ["Rexxybear-TestRealm"] = { lastSync = 99500, stored = 100 },
            }

            GBL:MigrateNormalizePeerNames(guildData)

            assert.is_nil(guildData.syncState.peers["Rexxybear-TestRealm"])
            assert.equals(99500, guildData.syncState.peers["Rexxybear"].lastSync)
        end)

        it("is idempotent", function()
            guildData.schemaVersion = 8
            guildData.knownPeers = {
                ["Rexxybear-TestRealm"] = { version = "0.30.4", txCount = 8, lastSeen = 99500 },
            }

            local first = GBL:MigrateNormalizePeerNames(guildData)
            local second = GBL:MigrateNormalizePeerNames(guildData)

            assert.equals(1, first)
            assert.equals(0, second)
            assert.equals(9, guildData.schemaVersion)
        end)

        it("skips already-migrated guilds (schemaVersion >= 9)", function()
            guildData.schemaVersion = 9
            guildData.knownPeers = {
                ["Stale-TestRealm"] = { version = "0.20.0", txCount = 1, lastSeen = 1 },
            }

            GBL:MigrateNormalizePeerNames(guildData)

            assert.is_not_nil(guildData.knownPeers["Stale-TestRealm"])
        end)

        it("returns early when local realm is unknown (cold APIs)", function()
            guildData.schemaVersion = 8
            guildData.knownPeers = {
                ["Rexxybear-TestRealm"] = { version = "0.30.4", txCount = 8, lastSeen = 99500 },
            }
            local origN, origR = _G.GetNormalizedRealmName, _G.GetRealmName
            _G.GetNormalizedRealmName = function() return nil end
            _G.GetRealmName = function() return nil end

            local merged = GBL:MigrateNormalizePeerNames(guildData)

            _G.GetNormalizedRealmName, _G.GetRealmName = origN, origR

            assert.equals(0, merged)
            assert.equals(8, guildData.schemaVersion)
            -- Realm-qualified key untouched; next session (warm APIs) retries
            assert.is_not_nil(guildData.knownPeers["Rexxybear-TestRealm"])
        end)
    end)

    describe("MigrateRecoverPeerRealms (schema 10 -> 11)", function()
        local guildData
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
            MockWoW.player.realm = "TestRealm"
        end)

        it("bare key matching one same-realm roster entry stays bare", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },  -- bare = same-realm
            }

            GBL:MigrateRecoverPeerRealms(guildData)

            assert.is_not_nil(guildData.knownPeers["Alice"])
            assert.is_nil(guildData.knownPeers["Alice-TestRealm"])
            assert.equals(11, guildData.schemaVersion)
        end)

        it("bare key matching one cross-realm roster entry gets re-realmed", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }

            GBL:MigrateRecoverPeerRealms(guildData)

            assert.is_nil(guildData.knownPeers["Alice"])
            assert.is_not_nil(guildData.knownPeers["Alice-OtherRealm"])
            assert.equals(11, guildData.schemaVersion)
        end)

        it("bare key matching multiple roster entries (different realms) stays bare", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },           -- local realm
                { name = "Alice-OtherRealm", isOnline = true }, -- cross-realm
            }

            GBL:MigrateRecoverPeerRealms(guildData)

            -- Ambiguous: stays bare, no rewrite
            assert.is_not_nil(guildData.knownPeers["Alice"])
            assert.is_nil(guildData.knownPeers["Alice-OtherRealm"])
            assert.equals(11, guildData.schemaVersion)
        end)

        it("bare key with no roster match stays bare (offline / departed)", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Ghost"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },
            }

            GBL:MigrateRecoverPeerRealms(guildData)

            assert.is_not_nil(guildData.knownPeers["Ghost"])
            assert.equals(11, guildData.schemaVersion)
        end)

        it("returns early when local realm is unknown (cold APIs)", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }
            local origN, origR = _G.GetNormalizedRealmName, _G.GetRealmName
            _G.GetNormalizedRealmName = function() return nil end
            _G.GetRealmName = function() return nil end

            local rewrites = GBL:MigrateRecoverPeerRealms(guildData)

            _G.GetNormalizedRealmName, _G.GetRealmName = origN, origR

            assert.equals(0, rewrites)
            assert.equals(10, guildData.schemaVersion)
            assert.is_not_nil(guildData.knownPeers["Alice"])
        end)

        it("is idempotent (second run produces no rewrites)", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }

            local first = GBL:MigrateRecoverPeerRealms(guildData)
            -- Reset schemaVersion so the migration's guard doesn't short-circuit
            -- the second invocation; we want to verify the migration logic
            -- itself doesn't double-rewrite.
            guildData.schemaVersion = 10
            local second = GBL:MigrateRecoverPeerRealms(guildData)

            assert.equals(1, first)
            assert.equals(0, second)
            assert.is_not_nil(guildData.knownPeers["Alice-OtherRealm"])
        end)

        it("recovers entries in guildData.syncState.peers too", function()
            guildData.schemaVersion = 10
            guildData.syncState.peers = { ["Alice"] = { lastSync = 99000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }

            GBL:MigrateRecoverPeerRealms(guildData)

            assert.is_nil(guildData.syncState.peers["Alice"])
            assert.is_not_nil(guildData.syncState.peers["Alice-OtherRealm"])
        end)

        it("refuses to bump from schema 8 (strict prerequisite)", function()
            -- Skip-chain prevention: if earlier migrations (8 -> 9, 9 -> 10)
            -- short-circuited, this one must not jump straight to 11.
            guildData.schemaVersion = 8
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }

            local rewrites = GBL:MigrateRecoverPeerRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(8, guildData.schemaVersion)
            -- Bare key untouched (will be recovered once schema 10 is reached)
            assert.is_not_nil(guildData.knownPeers["Alice"])
            assert.is_nil(guildData.knownPeers["Alice-OtherRealm"])
        end)

        it("refuses to bump from schema 9 (strict prerequisite)", function()
            guildData.schemaVersion = 9
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Alice-OtherRealm", isOnline = true },
            }

            local rewrites = GBL:MigrateRecoverPeerRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(9, guildData.schemaVersion)
            assert.is_not_nil(guildData.knownPeers["Alice"])
        end)

        it("returns early without bumping when roster is cold (numMembers == 0)", function()
            -- Reproduces the v0.30.5 premature-bump bug: when the realm API is
            -- valid but the roster API is still cold at OnEnable time, the
            -- migration walked an empty roster, recovered nothing, and still
            -- bumped to 11. Fix: return 0 without bumping so the migration
            -- retries on a later session or via the GUILD_ROSTER_UPDATE retrigger.
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Alice"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {}  -- numMembers will be 0

            local rewrites = GBL:MigrateRecoverPeerRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(10, guildData.schemaVersion)  -- NOT bumped
            assert.is_not_nil(guildData.knownPeers["Alice"])
        end)
    end)

    describe("GUILD_ROSTER_UPDATE migration retrigger", function()
        local guildData
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
            guildData = GBL:GetGuildData()
            MockWoW.player.realm = "TestRealm"
            -- Reset retrigger flags so each test starts from cold state
            GBL._migrationsRetried = nil
            GBL._playerNamesRepaired = nil
            GBL._sentPostLoginHello = nil
        end)

        it("does not retrigger MigrateAllGuilds when roster is still cold", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Katorriwl"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {}  -- cold

            GBL:GUILD_ROSTER_UPDATE()

            -- Migration didn't get a chance, schema unchanged
            assert.equals(10, guildData.schemaVersion)
            assert.is_nil(GBL._migrationsRetried)
        end)

        it("retriggers MigrateAllGuilds once when roster warms up", function()
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Katorriwl"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Katorriwl-Stormrage", isOnline = true },
            }

            GBL:GUILD_ROSTER_UPDATE()

            -- Migration ran on the warm roster, schema reached 11, bare key recovered
            assert.equals(11, guildData.schemaVersion)
            assert.is_true(GBL._migrationsRetried)
            assert.is_nil(guildData.knownPeers["Katorriwl"])
            assert.is_not_nil(guildData.knownPeers["Katorriwl-Stormrage"])
        end)

        it("does not retrigger again after the first warm GUILD_ROSTER_UPDATE", function()
            guildData.schemaVersion = 10
            MockWoW.guildRoster = {
                { name = "Katorriwl-Stormrage", isOnline = true },
            }

            GBL:GUILD_ROSTER_UPDATE()  -- first fire: retriggers
            assert.is_true(GBL._migrationsRetried)
            assert.equals(11, guildData.schemaVersion)

            -- Mutate guildData to detect a second migration run if it happens
            guildData.schemaVersion = 10
            guildData.knownPeers = { ["Loner"] = { lastSeen = 1000 } }
            MockWoW.guildRoster = {
                { name = "Loner-OtherRealm", isOnline = true },
            }

            GBL:GUILD_ROSTER_UPDATE()  -- second fire: should NOT re-run

            -- Schema stays at 10 because the retrigger is one-shot
            assert.equals(10, guildData.schemaVersion)
            assert.is_not_nil(guildData.knownPeers["Loner"])
        end)
    end)
end)
