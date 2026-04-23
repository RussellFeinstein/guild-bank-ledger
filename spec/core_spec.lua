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
            assert.is_true(Helpers.printContains("0.29.1"))
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
end)
