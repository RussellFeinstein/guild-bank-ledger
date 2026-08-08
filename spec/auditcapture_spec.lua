--- auditcapture_spec.lua — Persistent audit capture (GuildBankLedgerAuditDB)

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("AuditCapture", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        MockWoW.serverTime = 3600 * 475100  -- WoW-era timestamp
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL:ClearLog(nil)
    end)

    -- Capture defaults ON; kept as an explicit marker in tests that depend
    -- on the enabled state, and a guard if the default ever flips.
    local function enable()
        GBL.db.profile.sync.auditCapture = true
    end

    local function sessions()
        return _G.GuildBankLedgerAuditDB.sessions
    end

    describe("initialization", function()
        it("creates the SavedVariable shape on init", function()
            assert.is_table(_G.GuildBankLedgerAuditDB)
            assert.equals(GBL.AUDIT_DB_SCHEMA, _G.GuildBankLedgerAuditDB.schemaVersion)
            assert.is_table(sessions())
        end)

        it("self-heals a sessions-less SavedVariable shape without erroring", function()
            -- Regression: a capture tap that throws unwinds Logger's emit()
            -- and breaks the calling code path. A global that exists without
            -- a sessions table must be repaired in place, not crash.
            _G.GuildBankLedgerAuditDB = { schemaVersion = 1 }
            enable()
            GBL:SyncInfo("survives bad shape")
            assert.equals(1, #sessions())
            assert.equals("survives bad shape", sessions()[1].entries.sync[1].message)
        end)

        it("preserves existing sessions across re-init (relog)", function()
            enable()
            GBL:SyncInfo("before relog")
            assert.equals(1, #sessions())
            GBL:InitAuditCapture()
            assert.equals(1, #sessions())
            assert.equals("before relog", sessions()[1].entries.sync[1].message)
        end)
    end)

    describe("toggle gating", function()
        it("captures by default, with no opt-in step", function()
            assert.is_true(GBL.db.profile.sync.auditCapture)
            GBL:SyncInfo("captured without any setup")
            assert.equals(1, #sessions())
        end)

        it("the kill switch stops capture", function()
            GBL.db.profile.sync.auditCapture = false
            GBL:SyncInfo("not captured")
            assert.equals(0, #sessions())
        end)

        it("captures INFO to the sync channel when on", function()
            enable()
            GBL:SyncInfo("captured line")
            assert.equals(1, #sessions())
            local s = sessions()[1]
            assert.equals(1, #s.entries.sync)
            assert.equals("captured line", s.entries.sync[1].message)
            assert.equals("INFO", s.entries.sync[1].level)
            assert.equals(3600 * 475100, s.entries.sync[1].ts)
        end)

        it("stops capturing immediately when toggled off mid-session", function()
            enable()
            GBL:SyncInfo("kept")
            GBL.db.profile.sync.auditCapture = false
            GBL:SyncInfo("dropped")
            assert.equals(1, #sessions()[1].entries.sync)
            assert.equals("kept", sessions()[1].entries.sync[1].message)
        end)
    end)

    describe("session header", function()
        it("stamps addonVersion, protocolVersion, player, realm, guild", function()
            enable()
            GBL:SyncInfo("x")
            local s = sessions()[1]
            assert.equals(GBL.version, s.addonVersion)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, s.protocolVersion)
            assert.is_string(s.player)
            assert.is_string(s.realm)
            assert.equals(3600 * 475100, s.startedAt)
        end)

        it("stamps the dev-build suffix so capture corpora partition by build", function()
            GBL._testDevBuild = "sync"
            GBL:OnInitialize()
            enable()
            GBL:SyncInfo("dev entry")
            local s = sessions()[1]
            assert.is_truthy(s.addonVersion:find("-dev.sync", 1, true))
            GBL._testDevBuild = nil
        end)
    end)

    describe("level and channel gating", function()
        it("never captures DEBUG, even with debugChat on", function()
            enable()
            GBL.db.profile.sync.debugChat = true
            GBL:SyncDebug("debug noise")
            assert.equals(0, #sessions())
        end)

        it("captures all three channels into per-channel lists", function()
            enable()
            GBL:SyncInfo("sync line")
            GBL:SortWarn("sort line")
            GBL:SystemError("system line")
            local s = sessions()[1]
            assert.equals(1, #s.entries.sync)
            assert.equals(1, #s.entries.sort)
            assert.equals(1, #s.entries.system)
            assert.equals("WARN", s.entries.sort[1].level)
            assert.equals("ERROR", s.entries.system[1].level)
        end)

        it("stores plain copies, not the live Logger entry tables", function()
            enable()
            GBL:SyncInfo("copied")
            local captured = sessions()[1].entries.sync[1]
            local live = GBL:GetLog("sync")[1]
            assert.equals(live.message, captured.message)
            assert.is_not.equal(live, captured)
        end)
    end)

    describe("caps and rotation", function()
        it("evicts oldest entries past the per-channel cap and counts drops", function()
            enable()
            local cap = GBL.AUDIT_ENTRY_CAPS.system
            for i = 1, cap + 2 do
                GBL:SystemInfo("entry %d", i)
            end
            local s = sessions()[1]
            assert.equals(cap, #s.entries.system)
            assert.equals(2, s.dropped.system)
            assert.equals("entry 3", s.entries.system[1].message)
            -- Other channels unaffected by system-channel eviction.
            assert.equals(0, s.dropped.sync)
        end)

        it("rotates sessions oldest-out at the session cap", function()
            enable()
            local max = GBL.AUDIT_MAX_SESSIONS
            for i = 1, max + 1 do
                GBL:InitAuditCapture()  -- simulate a relog; keeps the global
                GBL:SyncInfo("session %d", i)
            end
            assert.equals(max, #sessions())
            assert.equals("session 2", sessions()[1].entries.sync[1].message)
            assert.equals("session " .. (max + 1),
                sessions()[max].entries.sync[1].message)
        end)
    end)

    describe("status and clear", function()
        it("reports enabled state, session count, and current entry counts", function()
            local st = GBL:GetAuditCaptureStatus()
            assert.is_true(st.enabled)  -- capture is on by default
            assert.equals(0, st.sessionCount)

            GBL.db.profile.sync.auditCapture = false
            st = GBL:GetAuditCaptureStatus()
            assert.is_false(st.enabled)

            enable()
            GBL:SyncInfo("one")
            GBL:SortInfo("two")
            st = GBL:GetAuditCaptureStatus()
            assert.is_true(st.enabled)
            assert.equals(1, st.sessionCount)
            assert.equals(1, st.currentEntries.sync)
            assert.equals(1, st.currentEntries.sort)
            assert.equals(0, st.currentEntries.system)
        end)

        it("clear wipes sessions and the next entry starts fresh", function()
            enable()
            GBL:SyncInfo("old")
            GBL:ClearAuditCapture()
            assert.equals(0, #sessions())
            GBL:SyncInfo("new")
            assert.equals(1, #sessions())
            assert.equals("new", sessions()[1].entries.sync[1].message)
        end)
    end)

    describe("/gbl audit slash command", function()
        before_each(function()
            Helpers.clearPrints()
        end)

        it("on re-enables capture after the kill switch", function()
            GBL.db.profile.sync.auditCapture = false
            GBL:HandleSlashCommand("audit on")
            assert.is_true(GBL.db.profile.sync.auditCapture)
            assert.is_true(Helpers.printContains("Log capture on"))
            assert.is_true(Helpers.printContains("nothing is sent anywhere"))
        end)

        it("off disables capture", function()
            GBL:HandleSlashCommand("audit off")
            assert.is_false(GBL.db.profile.sync.auditCapture)
            assert.is_true(Helpers.printContains("Log capture off"))
        end)

        it("status reports state and session counts", function()
            enable()
            GBL:SyncInfo("x")
            GBL:HandleSlashCommand("audit status")
            assert.is_true(Helpers.printContains("Log capture ON"))
            assert.is_true(Helpers.printContains("1 of "
                .. GBL.AUDIT_MAX_SESSIONS .. " saved sessions"))
            assert.is_true(Helpers.printContains("This session: sync 1/"))
        end)

        it("clear wipes sessions and says the scope is the whole account", function()
            enable()
            GBL:SyncInfo("x")
            GBL:HandleSlashCommand("audit clear")
            assert.equals(0, #sessions())
            assert.is_true(Helpers.printContains("account"))
        end)

        it("unknown subcommand prints usage", function()
            GBL:HandleSlashCommand("audit bogus")
            assert.is_true(Helpers.printContains("Usage: /gbl audit"))
        end)

        it("dispatch falls back cleanly when the module is absent", function()
            local saved = GBL.HandleAuditCommand
            GBL.HandleAuditCommand = nil
            GBL:HandleSlashCommand("audit on")
            assert.is_true(Helpers.printContains("AuditCapture module not loaded"))
            GBL.HandleAuditCommand = saved
        end)
    end)
end)
