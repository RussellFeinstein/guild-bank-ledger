#!/usr/bin/env lua
-- Offline reader for GuildBankLedger's persistent audit capture.
--
-- src/AuditCapture.lua writes per-login sessions into the
-- GuildBankLedgerAuditDB global, which WoW saves inside
--   <WoW>/_retail_/WTF/Account/<accountID>/SavedVariables/GuildBankLedger.lua
-- alongside the much larger GuildBankLedgerDB ledger. Nothing in the addon
-- renders a SAVED session: /gbl sortlog and /gbl logs both read the live
-- Logger ring, so a past session can only be read from disk. That is what
-- this script is for, and the capture cadence in docs/sort-logs/README.md
-- depends on it being a two-minute job.
--
-- Two rules are load-bearing.
--
-- Sessions are addressed BY INDEX, never by bracketing lines around a key.
-- WoW serialises a table in pairs() order, so a session's `dropped` block
-- can sit above its own `startedAt`, and the line below a session's entries
-- belongs to the next session's header. Reading by line attributed one
-- session's dropped counters to another on 2026-09-08 and produced a wrong
-- conclusion; spec/fixtures/audit/two-sessions.lua pins the shape.
--
-- The file is loaded into an isolated environment. A real capture carries
-- the whole ledger beside it, and installing that into _G to read a dozen
-- log lines is needless.
--
-- Usage:
--   lua scripts/audit-sessions.lua <path>                  list the sessions
--   lua scripts/audit-sessions.lua <path> --session N      one session, sort
--   lua scripts/audit-sessions.lua <path> --session N --channel sync
--   lua scripts/audit-sessions.lua <path> --session N --md  record skeleton

local M = {}

local CHANNEL_ORDER = { "sync", "sort", "system" }
local CHANNELS = { sync = true, sort = true, system = true }

------------------------------------------------------------------------
-- Loading
------------------------------------------------------------------------

--- Load a SavedVariables file without touching the caller's globals.
-- @param path string path to GuildBankLedger.lua
-- @return table|nil the GuildBankLedgerAuditDB table, or nil plus a message
function M.load(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end

    local env = {}
    setfenv(chunk, env)
    local ok, runErr = pcall(chunk)
    if not ok then return nil, runErr end

    local db = env.GuildBankLedgerAuditDB
    if type(db) ~= "table" then
        return nil, path .. ": no GuildBankLedgerAuditDB table (is log capture on?)"
    end
    db.sessions = db.sessions or {}
    return db
end

------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------

--- One row per saved session, in save order.
function M.list(db)
    local rows = {}
    for i, session in ipairs((db and db.sessions) or {}) do
        local counts, dropped = {}, {}
        for _, channel in ipairs(CHANNEL_ORDER) do
            counts[channel] = #((session.entries and session.entries[channel]) or {})
            dropped[channel] = (session.dropped and session.dropped[channel]) or 0
        end
        rows[i] = {
            index = i,
            startedAt = session.startedAt or 0,
            addonVersion = session.addonVersion or "?",
            protocolVersion = session.protocolVersion or 0,
            player = session.player or "?",
            realm = session.realm or "?",
            guild = session.guild,
            counts = counts,
            dropped = dropped,
        }
    end
    return rows
end

--- One session's entries on one channel, oldest first (capture order).
function M.channel(db, index, channel)
    if not CHANNELS[channel] then
        return nil, "unknown channel '" .. tostring(channel) .. "' (sync, sort, system)"
    end
    local sessions = (db and db.sessions) or {}
    local session = sessions[index]
    if not session then
        return nil, "no session " .. tostring(index) .. " (" .. #sessions .. " saved)"
    end
    return (session.entries and session.entries[channel]) or {}
end

------------------------------------------------------------------------
-- Grouping the sort channel into runs
------------------------------------------------------------------------

-- The lines a capture record is built from. Per-op INFO and WARN lines are
-- deliberately absent: a record is a summary, and a full run emits hundreds
-- of them.
local SUMMARY_PATTERNS = {
    "^Sort: starting",
    "^Sort plan:",
    "^%s+phases:",
    "^Sort: pass %d+ left",
    "^Sort bags:",
    "^%s+bags stay:",
    "^Sort: complete",
    "^Sort: aborted",
}

local function isSummaryLine(message)
    for _, pattern in ipairs(SUMMARY_PATTERNS) do
        if message:find(pattern) then return true end
    end
    return false
end

local function isRunStart(message)
    return message:find("^Sort: starting") ~= nil
end

local function isTerminal(message)
    return message:find("^Sort: complete") ~= nil
        or message:find("^Sort: aborted") ~= nil
end

--- Group a session's sort channel into runs.
--
-- A run opens on `Sort: starting` and closes on `Sort: complete` or
-- `Sort: aborted`. Summary lines with no execution behind them (a plan line
-- from /gbl sortpreview, or from the /gbl deviations the Sort tab runs after
-- a sort) are kept in their own group with `started = false` rather than
-- folded into the next run, which would misreport what that run planned.
function M.runs(db, index)
    local entries, err = M.channel(db, index, "sort")
    if not entries then return nil, err end

    local groups, current = {}, nil
    for _, entry in ipairs(entries) do
        local message = entry.message or ""
        if isSummaryLine(message) then
            if isRunStart(message) then
                current = { started = true, lines = {} }
                groups[#groups + 1] = current
            elseif not current then
                current = { started = false, lines = {} }
                groups[#groups + 1] = current
            end
            current.lines[#current.lines + 1] = entry
            if isTerminal(message) then current = nil end
        end
    end
    return groups
end

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------

--- Render a capture timestamp as UTC.
-- GetServerTime() is server time and the machine reading a capture is rarely
-- in that zone, so rendering in local time would make two people describe
-- one capture differently. UTC is arbitrary but shared.
function M.formatTime(ts)
    return os.date("!%H:%M:%S", ts or 0)
end

function M.formatDate(ts)
    return os.date("!%Y-%m-%d %H:%M:%S", ts or 0)
end

return M
