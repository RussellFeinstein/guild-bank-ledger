------------------------------------------------------------------------
-- Tests for Logger.lua: per-channel sync/sort/system/ledger logging
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = require("spec.mock_wow")

describe("Logger", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()  -- materializes self.db.profile from defaults
        -- Reset all channels before each test (fresh state guarantee).
        GBL:ClearLog(nil)
        -- Defaults: chatLog and debugChat are false on every channel.
        -- Guarded per channel so a missing profile block fails the
        -- "one list of channels" pins below rather than every test here.
        for _, ch in ipairs({ "sync", "sort", "system", "ledger" }) do
            local cfg = GBL.db.profile[ch]
            if cfg then
                cfg.chatLog = false
                cfg.debugChat = false
            end
        end
    end)

    describe("channel routing", function()
        it("SyncInfo lands in sync channel only", function()
            GBL:SyncInfo("hello sync")
            assert.equal(1, #GBL:GetLog("sync"))
            assert.equal(0, #GBL:GetLog("sort"))
            assert.equal(0, #GBL:GetLog("system"))
            assert.equal("hello sync", GBL:GetLog("sync")[1].message)
            assert.equal("sync", GBL:GetLog("sync")[1].channel)
        end)

        it("SortWarn lands in sort channel only", function()
            GBL:SortWarn("phantom op")
            assert.equal(0, #GBL:GetLog("sync"))
            assert.equal(1, #GBL:GetLog("sort"))
            assert.equal(0, #GBL:GetLog("system"))
            assert.equal("WARN", GBL:GetLog("sort")[1].level)
        end)

        it("SystemError lands in system channel only", function()
            GBL:SystemError("disk on fire")
            assert.equal(1, #GBL:GetLog("system"))
            assert.equal("ERROR", GBL:GetLog("system")[1].level)
        end)

        it("entries are newest-first", function()
            MockWoW.serverTime = 1000
            GBL:SyncInfo("first")
            MockWoW.serverTime = 1001
            GBL:SyncInfo("second")
            local log = GBL:GetLog("sync")
            assert.equal("second", log[1].message)
            assert.equal("first", log[2].message)
        end)
    end)

    describe("severity recording rules", function()
        it("INFO/WARN/ERROR always record regardless of chatLog", function()
            GBL:SyncInfo("i")
            GBL:SyncWarn("w")
            GBL:SyncError("e")
            assert.equal(3, #GBL:GetLog("sync"))
        end)

        it("DEBUG drops when debugChat is false (chat-only-by-default)", function()
            GBL.db.profile.sync.debugChat = false
            GBL:SyncDebug("noisy chunk")
            assert.equal(0, #GBL:GetLog("sync"))
        end)

        it("DEBUG records when debugChat is true", function()
            GBL.db.profile.sync.debugChat = true
            GBL:SyncDebug("noisy chunk")
            assert.equal(1, #GBL:GetLog("sync"))
            assert.equal("DEBUG", GBL:GetLog("sync")[1].level)
        end)

        it("debugChat is per-channel", function()
            GBL.db.profile.sync.debugChat = true
            GBL.db.profile.sort.debugChat = false
            GBL:SyncDebug("sync chunk")
            GBL:SortDebug("sort op")
            assert.equal(1, #GBL:GetLog("sync"))
            assert.equal(0, #GBL:GetLog("sort"))
        end)
    end)

    describe("chat mirroring", function()
        local printed
        before_each(function()
            printed = {}
            GBL.Print = function(_, msg) table.insert(printed, msg) end
        end)

        it("INFO does not chat when chatLog is false", function()
            GBL:SyncInfo("quiet info")
            assert.equal(0, #printed)
        end)

        it("INFO chats when chatLog is true", function()
            GBL.db.profile.sync.chatLog = true
            GBL:SyncInfo("loud info")
            assert.equal(1, #printed)
            assert.equal("Sync: loud info", printed[1])
        end)

        it("WARN/ERROR carry a level tag in chat", function()
            GBL.db.profile.sync.chatLog = true
            GBL:SyncWarn("careful")
            GBL:SyncError("broken")
            assert.equal(2, #printed)
            assert.is_truthy(printed[1]:find("[WARN]", 1, true))
            assert.is_truthy(printed[2]:find("[ERROR]", 1, true))
        end)

        it("DEBUG chats only when debugChat is true", function()
            GBL.db.profile.sync.chatLog = false
            GBL.db.profile.sync.debugChat = true
            GBL:SyncDebug("debug line")
            assert.equal(1, #printed)
            assert.is_truthy(printed[1]:find("[DEBUG]", 1, true))
        end)

        it("each channel has its own chat prefix", function()
            GBL.db.profile.sync.chatLog = true
            GBL.db.profile.sort.chatLog = true
            GBL.db.profile.system.chatLog = true
            GBL:SyncInfo("a")
            GBL:SortInfo("b")
            GBL:SystemInfo("c")
            assert.is_truthy(printed[1]:find("Sync:", 1, true))
            assert.is_truthy(printed[2]:find("Sort:", 1, true))
            assert.is_truthy(printed[3]:find("System:", 1, true))
        end)
    end)

    describe("printf formatting", function()
        it("formats with %d / %s like string.format", function()
            GBL:SyncInfo("ack %s after %d ms", "OK", 812)
            assert.equal("ack OK after 812 ms", GBL:GetLog("sync")[1].message)
        end)

        it("falls back to format string when arg type is wrong", function()
            -- %d with a string arg crashes string.format; the wrapper
            -- catches that and falls back so a buggy producer never bricks
            -- the addon. The fallback DOES record a buffer entry.
            GBL:SyncInfo("ms=%d", "not a number")
            local log = GBL:GetLog("sync")
            assert.equal(1, #log)
            assert.equal("ms=%d", log[1].message)
        end)

        it("survives a nil format string", function()
            assert.has_no.errors(function() GBL:SyncInfo(nil) end)
            local log = GBL:GetLog("sync")
            assert.equal(1, #log)
            assert.equal("(nil)", log[1].message)
        end)

        it("works with no extra args", function()
            GBL:SyncInfo("plain literal")
            assert.equal("plain literal", GBL:GetLog("sync")[1].message)
        end)
    end)

    describe("ring buffer caps", function()
        local function setBufferLimit(channel, limit)
            -- Helper: fill near the cap and verify FIFO behavior.
            -- Caps are 2000/1000/500; we test by exceeding each by a few
            -- entries rather than allocating millions.
            for i = 1, limit + 5 do
                GBL["LogSync"](GBL, "INFO", "n%d", i)  -- placeholder; overridden below
            end
        end

        it("sync cap is 2000", function()
            -- Filling 2003 entries; expect cap at 2000, oldest dropped.
            for i = 1, 2003 do
                GBL:SyncInfo("entry %d", i)
            end
            local log = GBL:GetLog("sync")
            assert.equal(2000, #log)
            -- Newest is index 1; should be entry 2003.
            assert.equal("entry 2003", log[1].message)
            -- Oldest surviving is entry 4 (entries 1..3 dropped).
            assert.equal("entry 4", log[#log].message)
        end)

        it("sort cap is 3000", function()
            for i = 1, 3003 do
                GBL:SortInfo("op %d", i)
            end
            assert.equal(3000, #GBL:GetLog("sort"))
        end)

        it("system cap is 500", function()
            for i = 1, 503 do
                GBL:SystemInfo("evt %d", i)
            end
            assert.equal(500, #GBL:GetLog("system"))
        end)
    end)

    describe("GetMasterLog", function()
        it("k-way merges channels in strict-descending timestamp order", function()
            MockWoW.serverTime = 100
            GBL:SyncInfo("sync@100")
            MockWoW.serverTime = 110
            GBL:SortInfo("sort@110")
            MockWoW.serverTime = 105
            GBL:SystemInfo("system@105")
            MockWoW.serverTime = 120
            GBL:SyncInfo("sync@120")

            local merged = GBL:GetMasterLog()
            assert.equal(4, #merged)
            -- Strict descending by ts.
            for i = 1, #merged - 1 do
                assert.is_true(merged[i].ts >= merged[i + 1].ts,
                    string.format("non-descending at i=%d: %d before %d",
                        i, merged[i].ts, merged[i + 1].ts))
            end
            assert.equal("sync@120", merged[1].message)
            assert.equal("sort@110", merged[2].message)
            assert.equal("system@105", merged[3].message)
            assert.equal("sync@100", merged[4].message)
        end)

        it("respects opts.limit", function()
            for i = 1, 10 do
                MockWoW.serverTime = 1000 + i
                GBL:SyncInfo("e%d", i)
            end
            local merged = GBL:GetMasterLog({ limit = 3 })
            assert.equal(3, #merged)
        end)

        it("respects opts.channels filter", function()
            GBL:SyncInfo("s")
            GBL:SortInfo("o")
            GBL:SystemInfo("y")
            local merged = GBL:GetMasterLog({ channels = { "sync", "sort" } })
            assert.equal(2, #merged)
            for _, e in ipairs(merged) do
                assert.is_true(e.channel == "sync" or e.channel == "sort")
            end
        end)
    end)

    describe("ClearLog", function()
        it("ClearLog(channel) empties only that channel", function()
            GBL:SyncInfo("a")
            GBL:SortInfo("b")
            GBL:SystemInfo("c")
            GBL:ClearLog("sync")
            assert.equal(0, #GBL:GetLog("sync"))
            assert.equal(1, #GBL:GetLog("sort"))
            assert.equal(1, #GBL:GetLog("system"))
        end)

        it("ClearLog(nil) empties every channel", function()
            GBL:SyncInfo("a")
            GBL:SortInfo("b")
            GBL:SystemInfo("c")
            GBL:ClearLog(nil)
            assert.equal(0, #GBL:GetLog("sync"))
            assert.equal(0, #GBL:GetLog("sort"))
            assert.equal(0, #GBL:GetLog("system"))
        end)

        it("ClearLog with unknown channel name is a no-op", function()
            GBL:SyncInfo("a")
            GBL:ClearLog("bogus")
            assert.equal(1, #GBL:GetLog("sync"))
        end)
    end)

    describe("AddAuditEntry shim (compat)", function()
        it("plain call routes to sync INFO", function()
            GBL:AddAuditEntry("legacy info")
            local log = GBL:GetLog("sync")
            assert.equal(1, #log)
            assert.equal("legacy info", log[1].message)
            assert.equal("INFO", log[1].level)
        end)

        it("chatOnly=true routes to sync DEBUG (drops without debugChat)", function()
            GBL.db.profile.sync.debugChat = false
            GBL:AddAuditEntry("legacy chat-only", true)
            assert.equal(0, #GBL:GetLog("sync"))
        end)

        it("chatOnly=true with debugChat on records as DEBUG", function()
            GBL.db.profile.sync.debugChat = true
            GBL:AddAuditEntry("legacy chat-only", true)
            local log = GBL:GetLog("sync")
            assert.equal(1, #log)
            assert.equal("DEBUG", log[1].level)
        end)
    end)

    -- #85: transaction recording gets a channel of its own. Russell's
    -- call (2026-10-02) over putting it on system: a bank log read that
    -- stores something writes one line, 1 to 157 of them a day, and the
    -- system capture's 300 lines are the budget #199 kept a restock run
    -- inside.
    describe("ledger channel (#85)", function()
        it("LedgerInfo lands in the ledger channel only", function()
            GBL:LedgerInfo("read %d", 3)
            assert.equal(1, #GBL:GetLog("ledger"))
            assert.equal(0, #GBL:GetLog("sync"))
            assert.equal(0, #GBL:GetLog("system"))
            local entry = GBL:GetLog("ledger")[1]
            assert.equal("read 3", entry.message)
            assert.equal("ledger", entry.channel)
            assert.equal("INFO", entry.level)
        end)

        it("LogLedger takes a runtime level", function()
            GBL:LogLedger("WARN", "skipped %d", 2)
            assert.equal("WARN", GBL:GetLog("ledger")[1].level)
        end)

        it("LedgerWarn and LedgerError record their levels", function()
            GBL:LedgerWarn("w")
            GBL:LedgerError("e")
            local log = GBL:GetLog("ledger")
            assert.equal("ERROR", log[1].level)
            assert.equal("WARN", log[2].level)
        end)

        it("LedgerDebug drops unless the ledger channel's debugChat is on", function()
            GBL:LedgerDebug("quiet rescan")
            assert.equal(0, #GBL:GetLog("ledger"))
            GBL.db.profile.ledger.debugChat = true
            GBL:LedgerDebug("quiet rescan")
            assert.equal(1, #GBL:GetLog("ledger"))
        end)

        it("chats with its own prefix", function()
            local printed = {}
            GBL.Print = function(_, msg) table.insert(printed, msg) end
            GBL.db.profile.ledger.chatLog = true
            GBL:LedgerInfo("read")
            assert.equal("Ledger: read", printed[1])
        end)

        it("ledger cap is 500", function()
            for i = 1, 503 do
                GBL:LedgerInfo("read %d", i)
            end
            local log = GBL:GetLog("ledger")
            assert.equal(500, #log)
            assert.equal("read 503", log[1].message)
        end)

        it("ClearLog(nil) empties the ledger channel too", function()
            GBL:LedgerInfo("a")
            GBL:ClearLog(nil)
            assert.equal(0, #GBL:GetLog("ledger"))
        end)
    end)

    -- Four places name the channels: Logger, the capture's caps, the
    -- profile defaults and the offline reader. Each reads Logger's list
    -- or is pinned against it here, so a channel added in one place and
    -- missed in another fails the suite rather than going quiet.
    describe("one list of channels (#85)", function()
        local function asSet(list)
            local set = {}
            for _, v in ipairs(list) do set[v] = true end
            return set
        end

        local function keySet(t)
            local set = {}
            for k in pairs(t) do set[k] = true end
            return set
        end

        it("Logger exports its channels in order", function()
            assert.same({ "sync", "sort", "system", "ledger" }, GBL.LOG_CHANNELS)
        end)

        it("the capture has a cap for every channel and no other", function()
            assert.same(asSet(GBL.LOG_CHANNELS), keySet(GBL.AUDIT_ENTRY_CAPS))
        end)

        it("every channel has profile defaults with chat and debug off", function()
            for _, ch in ipairs(GBL.LOG_CHANNELS) do
                local cfg = GBL.db.profile[ch]
                assert.is_table(cfg, "no profile block for " .. ch)
                assert.is_false(cfg.chatLog, ch .. ".chatLog")
                assert.is_false(cfg.debugChat, ch .. ".debugChat")
            end
        end)

        it("the offline reader knows every channel and no other", function()
            local Reader = dofile("scripts/audit-sessions.lua")
            -- Both tables first: two nils compare the same.
            assert.is_table(GBL.LOG_CHANNELS)
            assert.is_table(Reader.CHANNELS)
            assert.same(GBL.LOG_CHANNELS, Reader.CHANNELS)
        end)

        it("the master log merges every channel by default", function()
            GBL:SyncInfo("s")
            GBL:SortInfo("o")
            GBL:SystemInfo("y")
            GBL:LedgerInfo("l")
            local seen = {}
            for _, e in ipairs(GBL:GetMasterLog()) do seen[e.channel] = true end
            assert.same(asSet(GBL.LOG_CHANNELS), seen)
        end)
    end)

    describe("log commands for the ledger and system channels (#85)", function()
        before_each(function()
            Helpers.clearPrints()
        end)

        it("/gbl ledgerlog opens the ledger channel's window", function()
            GBL:HandleSlashCommand("ledgerlog")
            assert.is_true(Helpers.printContains("GBL Ledger Log: no entries yet."))
        end)

        it("/gbl systemlog opens the system channel's window", function()
            GBL:HandleSlashCommand("systemlog")
            assert.is_true(Helpers.printContains("GBL System Log: no entries yet."))
        end)

        it("/gbl logs clear ledger empties only the ledger channel", function()
            GBL:LedgerInfo("l")
            GBL:SyncInfo("s")
            GBL:HandleSlashCommand("logs clear ledger")
            assert.equal(0, #GBL:GetLog("ledger"))
            assert.equal(1, #GBL:GetLog("sync"))
            assert.is_true(Helpers.printContains("Cleared ledger log."))
        end)

        it("/gbl logs clear all empties the ledger channel too", function()
            GBL:LedgerInfo("l")
            GBL:HandleSlashCommand("logs clear all")
            assert.equal(0, #GBL:GetLog("ledger"))
        end)

        it("/gbl logs debug ledger on turns on the ledger channel's debug", function()
            GBL:HandleSlashCommand("logs debug ledger on")
            assert.is_true(GBL.db.profile.ledger.debugChat)
            assert.is_true(Helpers.printContains("ledger debug-to-chat enabled."))
        end)

        it("the usage line names the ledger channel", function()
            GBL:HandleSlashCommand("logs clear bogus")
            assert.is_true(Helpers.printContains("sync||sort||system||ledger||all"))
        end)
    end)

    describe("GetAuditTrail alias", function()
        it("returns the sync channel snapshot with legacy timestamp field", function()
            MockWoW.serverTime = 12345
            GBL:SyncInfo("legacy reader")
            local trail = GBL:GetAuditTrail()
            assert.equal(1, #trail)
            assert.equal("legacy reader", trail[1].message)
            -- Legacy callers asserted on `entry.timestamp`; preserve.
            assert.equal(12345, trail[1].timestamp)
        end)
    end)
end)
