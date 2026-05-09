------------------------------------------------------------------------
-- GuildBankLedger -- Logger.lua
-- Per-channel session log: sync / sort / system
--
-- Public API on GBL:
--   GBL:LogSync(level, fmt, ...)    -- channel "sync"
--   GBL:LogSort(level, fmt, ...)
--   GBL:LogSystem(level, fmt, ...)
--
--   GBL:SyncDebug / SyncInfo / SyncWarn / SyncError(fmt, ...)
--   GBL:SortDebug / SortInfo / SortWarn / SortError(fmt, ...)
--   GBL:SystemDebug / SystemInfo / SystemWarn / SystemError(fmt, ...)
--
--   GBL:GetLog(channel)              snapshot, newest first
--   GBL:GetMasterLog(opts)           k-way merge, opts = { channels?, limit? }
--   GBL:ClearLog(channel)            nil = clear all
--
-- Levels: DEBUG | INFO | WARN | ERROR.
--
-- Persistence: in-memory only, session-scoped, reset on /reload. Chat mirror
-- gates live in db.profile.<channel>.chatLog (INFO/WARN/ERROR) and
-- db.profile.<channel>.debugChat (DEBUG). DEBUG entries are dropped entirely
-- when debugChat is false so the noisy per-chunk DEBUG path cannot push
-- INFO/WARN out of the FIFO tail; this preserves the prior chatOnly=true
-- "don't pollute the buffer" semantics from AddAuditEntry.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local CHANNELS = { sync = true, sort = true, system = true }
local CAPS     = { sync = 2000, sort = 1000, system = 500 }
local LEVELS   = { DEBUG = true, INFO = true, WARN = true, ERROR = true }

local CHAT_PREFIXES = { sync = "Sync: ", sort = "Sort: ", system = "System: " }

local entries = { sync = {}, sort = {}, system = {} }

local function formatMessage(fmt, ...)
    if fmt == nil then return "(nil)" end
    if select("#", ...) == 0 then return tostring(fmt) end
    local ok, result = pcall(string.format, fmt, ...)
    if ok then return result end
    return tostring(fmt)
end

local function shouldChat(self, channel, level)
    if not (self.db and self.db.profile and self.db.profile[channel]) then
        return false
    end
    local cfg = self.db.profile[channel]
    if level == "DEBUG" then return cfg.debugChat == true end
    return cfg.chatLog == true
end

local function shouldRecordDebug(self, channel)
    if not (self.db and self.db.profile and self.db.profile[channel]) then
        return false
    end
    return self.db.profile[channel].debugChat == true
end

------------------------------------------------------------------------
-- Core write path
------------------------------------------------------------------------

local function record(self, channel, level, message)
    local entry = {
        ts      = (GetServerTime and GetServerTime()) or 0,
        level   = level,
        channel = channel,
        message = message,
    }
    local buf = entries[channel]
    table.insert(buf, 1, entry)
    local cap = CAPS[channel]
    while #buf > cap do
        table.remove(buf)
    end
    return entry
end

local function emit(self, channel, level, fmt, ...)
    if not CHANNELS[channel] then return end
    if not LEVELS[level] then level = "INFO" end

    -- DEBUG drop-when-quiet rule: skip both buffer and chat unless debugChat on.
    if level == "DEBUG" and not shouldRecordDebug(self, channel) then
        return
    end

    local message = formatMessage(fmt, ...)
    record(self, channel, level, message)

    if shouldChat(self, channel, level) then
        local prefix = CHAT_PREFIXES[channel] or ""
        if level == "DEBUG" or level == "WARN" or level == "ERROR" then
            self:Print(prefix .. "[" .. level .. "] " .. message)
        else
            self:Print(prefix .. message)
        end
    end
end

------------------------------------------------------------------------
-- Public API: lower-level entry points
------------------------------------------------------------------------

function GBL:LogSync(level, fmt, ...)   emit(self, "sync",   level, fmt, ...) end
function GBL:LogSort(level, fmt, ...)   emit(self, "sort",   level, fmt, ...) end
function GBL:LogSystem(level, fmt, ...) emit(self, "system", level, fmt, ...) end

------------------------------------------------------------------------
-- Public API: convenience wrappers
------------------------------------------------------------------------

function GBL:SyncDebug(fmt, ...) emit(self, "sync", "DEBUG", fmt, ...) end
function GBL:SyncInfo (fmt, ...) emit(self, "sync", "INFO",  fmt, ...) end
function GBL:SyncWarn (fmt, ...) emit(self, "sync", "WARN",  fmt, ...) end
function GBL:SyncError(fmt, ...) emit(self, "sync", "ERROR", fmt, ...) end

function GBL:SortDebug(fmt, ...) emit(self, "sort", "DEBUG", fmt, ...) end
function GBL:SortInfo (fmt, ...) emit(self, "sort", "INFO",  fmt, ...) end
function GBL:SortWarn (fmt, ...) emit(self, "sort", "WARN",  fmt, ...) end
function GBL:SortError(fmt, ...) emit(self, "sort", "ERROR", fmt, ...) end

function GBL:SystemDebug(fmt, ...) emit(self, "system", "DEBUG", fmt, ...) end
function GBL:SystemInfo (fmt, ...) emit(self, "system", "INFO",  fmt, ...) end
function GBL:SystemWarn (fmt, ...) emit(self, "system", "WARN",  fmt, ...) end
function GBL:SystemError(fmt, ...) emit(self, "system", "ERROR", fmt, ...) end

------------------------------------------------------------------------
-- Public API: read / clear
------------------------------------------------------------------------

--- Snapshot of one channel, newest first.
function GBL:GetLog(channel)
    if not CHANNELS[channel] then return {} end
    return entries[channel]
end

--- K-way merge across channels (each is already newest-first), returning a
-- single timestamp-descending array. opts.channels optional list (default all
-- three). opts.limit caps output length.
function GBL:GetMasterLog(opts)
    opts = opts or {}
    local channels = opts.channels or { "sync", "sort", "system" }
    local limit = opts.limit

    local cursors = {}
    for _, ch in ipairs(channels) do
        if CHANNELS[ch] then cursors[ch] = 1 end
    end

    local merged = {}
    while true do
        local bestCh, bestEntry = nil, nil
        for ch, idx in pairs(cursors) do
            local e = entries[ch][idx]
            if e then
                if not bestEntry or e.ts > bestEntry.ts then
                    bestCh, bestEntry = ch, e
                end
            end
        end
        if not bestEntry then break end
        merged[#merged + 1] = bestEntry
        cursors[bestCh] = cursors[bestCh] + 1
        if limit and #merged >= limit then break end
    end
    return merged
end

--- Truncate a single channel, or all when channel is nil.
function GBL:ClearLog(channel)
    if channel == nil then
        for ch in pairs(CHANNELS) do
            entries[ch] = {}
        end
        return
    end
    if CHANNELS[channel] then
        entries[channel] = {}
    end
end
