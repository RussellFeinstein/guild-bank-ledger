------------------------------------------------------------------------
-- GuildBankLedger -- AuditCapture.lua
-- Persistent capture of Logger entries into the GuildBankLedgerAuditDB
-- SavedVariable, so guild members can hand over diagnostics without
-- copying chat. Phase 1 of docs/PLAN-audit-log-upload.md: local capture
-- plus manual collection; the companion uploader is a later phase.
--
-- Capture is ON by default: the data never leaves the player's machine,
-- so recording locally is not a privacy event. The opt-in moment is
-- SENDING captures to the maintainer, which is the uploader phase (not
-- built yet) and will be opt-in and off by default there. A kill switch
-- remains at db.profile.sync.auditCapture (/gbl audit off). When on,
-- INFO/WARN/ERROR entries from all three Logger channels are copied into
-- the current session. DEBUG is never captured.
--
-- SavedVariable shape:
--   GuildBankLedgerAuditDB = {
--     schemaVersion = 1,
--     sessions = {
--       { startedAt, addonVersion, protocolVersion, player, realm, guild,
--         entries = { sync = {...}, sort = {...}, system = {...} },
--         dropped = { sync = 0, sort = 0, system = 0 } },
--       ...
--     },
--   }
--
-- A session is one login/reload segment, created lazily on the first
-- captured entry so quiet sessions never consume rotation slots. Sessions
-- rotate oldest-out at MAX_AUDIT_SESSIONS; entries evict oldest-out per
-- channel at the per-channel cap, counted in dropped[channel].
--
-- Known limitation: a session created early in login may stamp the cold
-- realm sentinel "UnknownRealm" in its header; the player field still
-- identifies the source.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local AUDIT_DB_SCHEMA = 1
local MAX_AUDIT_SESSIONS = 10
-- sort gets the largest cap because one sort run emits hundreds of per-op
-- INFO lines; system stays small (login/combat/zone context only).
local ENTRY_CAPS = { sync = 1000, sort = 1500, system = 300 }

GBL.AUDIT_DB_SCHEMA = AUDIT_DB_SCHEMA
GBL.AUDIT_MAX_SESSIONS = MAX_AUDIT_SESSIONS
GBL.AUDIT_ENTRY_CAPS = ENTRY_CAPS

--- Fresh per-channel table built from the channel registry, so adding a
-- channel to ENTRY_CAPS cannot silently miss the session shape.
local function byChannel(makeValue)
    local t = {}
    for ch in pairs(ENTRY_CAPS) do
        t[ch] = makeValue()
    end
    return t
end

local function isEnabled(self)
    return (self.db and self.db.profile and self.db.profile.sync
        and self.db.profile.sync.auditCapture) == true
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

--- Initialize the SavedVariable and reset the session pointer. Called from
-- OnInitialize (SavedVariables are loaded by then; never touch the global
-- at file scope). Existing sessions persist across reloads.
function GBL:InitAuditCapture()
    GuildBankLedgerAuditDB = GuildBankLedgerAuditDB or {}
    GuildBankLedgerAuditDB.schemaVersion =
        GuildBankLedgerAuditDB.schemaVersion or AUDIT_DB_SCHEMA
    GuildBankLedgerAuditDB.sessions = GuildBankLedgerAuditDB.sessions or {}
    self._auditSession = nil
end

local function newSession(self)
    local session = {
        startedAt = (GetServerTime and GetServerTime()) or 0,
        -- self.version carries any "-dev.<id>" suffix, so capture corpora
        -- partition cleanly by build.
        addonVersion = self.version,
        protocolVersion = self.SYNC_PROTOCOL_VERSION or 0,
        player = (UnitName and UnitName("player")) or "?",
        realm = (self.GetLocalRealm and self:GetLocalRealm()) or "?",
        guild = self.GetGuildName and self:GetGuildName() or nil,
        entries = byChannel(function() return {} end),
        dropped = byChannel(function() return 0 end),
    }
    -- Self-heal a sessions-less shape (interrupted init, external write, or a
    -- future migration). A capture tap that throws would unwind emit() and
    -- break the caller it is observing, so this path must never error.
    local sessions = GuildBankLedgerAuditDB.sessions
    if type(sessions) ~= "table" then
        sessions = {}
        GuildBankLedgerAuditDB.sessions = sessions
    end
    sessions[#sessions + 1] = session
    while #sessions > MAX_AUDIT_SESSIONS do
        table.remove(sessions, 1)
    end
    return session
end

------------------------------------------------------------------------
-- Capture path (tapped from Logger's emit)
------------------------------------------------------------------------

--- Copy one Logger entry into the persistent capture. All gating lives
-- here: unknown channels, DEBUG, toggle off, and uninitialized DB are all
-- silent no-ops, so the Logger tap stays a bare call.
function GBL:CaptureAuditEntry(channel, entry)
    if not ENTRY_CAPS[channel] then return end
    if not entry or entry.level == "DEBUG" then return end
    if not isEnabled(self) then return end
    if not GuildBankLedgerAuditDB then return end

    local session = self._auditSession
    if not session then
        session = newSession(self)
        self._auditSession = session
    end

    local list = session.entries[channel]
    -- Plain copy: never hold the live Logger entry table in the SavedVariable.
    -- Ordering is chronological (oldest at index 1), the OPPOSITE of Logger's
    -- newest-first buffers, so eviction removes from the FRONT.
    list[#list + 1] = { ts = entry.ts, level = entry.level, message = entry.message }
    while #list > ENTRY_CAPS[channel] do
        table.remove(list, 1)
        session.dropped[channel] = session.dropped[channel] + 1
    end
end

------------------------------------------------------------------------
-- Status / clear
------------------------------------------------------------------------

--- Snapshot for the slash command and tests.
function GBL:GetAuditCaptureStatus()
    local status = {
        enabled = isEnabled(self),
        sessionCount = 0,
        currentEntries = byChannel(function() return 0 end),
        dropped = byChannel(function() return 0 end),
        caps = ENTRY_CAPS,
        maxSessions = MAX_AUDIT_SESSIONS,
    }
    if GuildBankLedgerAuditDB and GuildBankLedgerAuditDB.sessions then
        local sessions = GuildBankLedgerAuditDB.sessions
        status.sessionCount = #sessions
        if #sessions > 0 then
            status.oldestStartedAt = sessions[1].startedAt
            status.newestStartedAt = sessions[#sessions].startedAt
        end
    end
    local session = self._auditSession
    if session then
        for ch in pairs(ENTRY_CAPS) do
            status.currentEntries[ch] = #session.entries[ch]
            status.dropped[ch] = session.dropped[ch]
        end
    end
    return status
end

--- Wipe all captured sessions (the /gbl audit clear path). The next
-- captured entry starts a fresh session.
function GBL:ClearAuditCapture()
    if GuildBankLedgerAuditDB then
        GuildBankLedgerAuditDB.sessions = {}
    end
    self._auditSession = nil
end

------------------------------------------------------------------------
-- Slash command: /gbl audit on|off|status|clear
------------------------------------------------------------------------

function GBL:HandleAuditCommand(rest)
    local sub = (rest and rest:match("^(%S*)") or ""):lower()

    if sub == "on" then
        self.db.profile.sync.auditCapture = true
        self:Print("Log capture on (the default). Diagnostics persist to"
            .. " SavedVariables; nothing is sent anywhere. /gbl audit status"
            .. " to inspect.")
        return
    end

    if sub == "off" then
        self.db.profile.sync.auditCapture = false
        self:Print("Log capture off. Diagnostics will no longer persist"
            .. " across reloads on this character's profile.")
        return
    end

    if sub == "status" then
        local st = self:GetAuditCaptureStatus()
        self:Print(string.format("Log capture %s. %d of %d saved sessions.",
            st.enabled and "ON" or "off", st.sessionCount, st.maxSessions))
        if st.enabled then
            self:Print(string.format(
                "This session: sync %d/%d, sort %d/%d, system %d/%d"
                    .. " (evicted: %d, %d, %d).",
                st.currentEntries.sync, st.caps.sync,
                st.currentEntries.sort, st.caps.sort,
                st.currentEntries.system, st.caps.system,
                st.dropped.sync, st.dropped.sort, st.dropped.system))
        end
        return
    end

    if sub == "clear" then
        self:ClearAuditCapture()
        self:Print("Cleared ALL captured sessions on this account"
            .. " (the store is shared across your characters).")
        return
    end

    self:Print("Usage: /gbl audit on|off|status|clear")
end
