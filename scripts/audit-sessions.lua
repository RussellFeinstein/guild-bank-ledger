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
    "^%s+demands:",
    "^Sort: pass %d+ left",
    "^Sort: lift guard disabled",
    "^Sort bags:",
    "^%s+bags stay:",
    "^Sort: complete",
    "^Sort: aborted",
    "^Sort lift probe:",
    "^Sort hitch summary:",
}

-- The lines `finish` writes AFTER the terminal line. A run's summary does not
-- end where the run does: src/SortExecutor.lua emits the complete/aborted line
-- first and then up to three more. Closing a run on its terminal line and
-- stopping there files all of them under a group the skeleton labels as a
-- preview, which is where `Sort bags:` went for every real capture until this
-- existed.
--
-- `Sort plan:` is deliberately absent. The Sort tab runs /gbl deviations after
-- every executed sort and that writes a plan line, so admitting it here would
-- report a plan the run never executed, which is the case the grouping comment
-- below was written to protect. Nothing can interleave into the tail, because
-- finish() emits the whole of it synchronously in one frame.
local TAIL_PATTERNS = {
    "^Sort bags:",
    "^Sort lift probe:",
    "^Sort hitch summary:",
}

local function isTailLine(message)
    for _, pattern in ipairs(TAIL_PATTERNS) do
        if message:find(pattern) then return true end
    end
    return false
end

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

    local groups, current, closed = {}, nil, nil
    for _, entry in ipairs(entries) do
        local message = entry.message or ""
        if isSummaryLine(message) then
            local handled = false
            if isRunStart(message) then
                current = { started = true, lines = {} }
                groups[#groups + 1] = current
                closed = nil
            elseif not current and closed and isTailLine(message) then
                -- Files against the run that just closed without reopening
                -- it, so the next `Sort: starting` cannot inherit the tail.
                closed.lines[#closed.lines + 1] = entry
                handled = true
            elseif not current then
                current = { started = false, lines = {} }
                groups[#groups + 1] = current
                -- Any other summary line ends the tail: a preview or a
                -- deviations plan line means finish() is done writing.
                closed = nil
            end

            if not handled then
                current.lines[#current.lines + 1] = entry
                if isTerminal(message) then
                    closed = current
                    current = nil
                end
            end
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

------------------------------------------------------------------------
-- Counted measures
------------------------------------------------------------------------

--- Count the things a record's figures table reports.
--
-- Counted rather than eyeballed: the first pass at the 2026-09-12 record
-- undercounted its own evidence six times over, and a tally settled it.
--
-- `distinctPlans` ignores the timing figure, because two plan lines
-- describing one plan differ in milliseconds every time and counting those
-- as two says the planner changed its mind when it did not.
function M.measures(groups)
    local planLines, planZeroUnplaced, phaseLines, phaseZeroAbort = 0, 0, 0, 0
    local seen, distinctPlans, pivotCounts = {}, 0, {}

    for _, group in ipairs(groups or {}) do
        for _, line in ipairs(group.lines or {}) do
            local message = line.message or ""
            if message:find("^Sort plan:") then
                planLines = planLines + 1
                -- The leading comma is load-bearing: "0 unplaced" is a
                -- substring of "10 unplaced" and ", 0 unplaced " is not.
                if message:find(", 0 unplaced ", 1, true) then
                    planZeroUnplaced = planZeroUnplaced + 1
                end
                local signature = (message:gsub("%d+%.%d+ms", "<ms>"))
                if not seen[signature] then
                    seen[signature] = true
                    distinctPlans = distinctPlans + 1
                end
            elseif message:find("^%s+phases:") then
                phaseLines = phaseLines + 1
                local pivot, abort = message:match("P2 pivot=(%d+)%(abort=(%d+)%)")
                if abort == "0" then phaseZeroAbort = phaseZeroAbort + 1 end
                if pivot then
                    local value = tonumber(pivot)
                    pivotCounts[value] = (pivotCounts[value] or 0) + 1
                end
            end
        end
    end

    -- Ascending, so two people reading one capture write the same row.
    local pivots = {}
    for value, count in pairs(pivotCounts) do
        pivots[#pivots + 1] = { value = value, count = count }
    end
    table.sort(pivots, function(a, b) return a.value < b.value end)

    return {
        planLines = planLines,
        planZeroUnplaced = planZeroUnplaced,
        phaseLines = phaseLines,
        phaseZeroAbort = phaseZeroAbort,
        distinctPlans = distinctPlans,
        pivots = pivots,
    }
end

------------------------------------------------------------------------
-- Record skeleton
------------------------------------------------------------------------

local function firstMatch(group, pattern)
    for _, line in ipairs(group.lines or {}) do
        local message = line.message or ""
        if message:find(pattern) then return message, line end
    end
end

local function bagsModeOf(group)
    local message = firstMatch(group, "^Sort: starting")
    return message and message:match("bags=(%a+)") or "?"
end

local function plannedOf(group)
    local message = firstMatch(group, "^Sort: starting")
    local ops = message and message:match("execution of (%d+) ops")
    return ops and (ops .. " ops") or "?"
end

--- What the cursor probe answered for a run, for the record's header table.
-- #171 made this the tripwire for the whole sort: a client where
-- GetCursorInfo has gone quiet looks exactly like a bank full of failed lifts
-- until a capture says which it was. A run from before v0.39.6, or one that
-- lifted nothing from the bank, has no probe line and reads "-".
local function probeOf(group)
    local message = firstMatch(group, "^Sort lift probe:")
    if not message then return "-" end
    local kinds = message:match("GetCursorInfo %[([^%]]*)%]") or "?"
    local guard = message:find("guard=disabled", 1, true) and " (guard off)" or ""
    return "GetCursorInfo [" .. kinds .. "]" .. guard
end

local function endedOf(group)
    local message = firstMatch(group, "^Sort: aborted")
    if message then
        return "aborted " .. (message:match("^Sort: aborted (%b())") or "")
    end
    message = firstMatch(group, "^Sort: complete")
    if not message then return "no terminal line" end
    local passes, remaining = message:match("(%d+) passes, %d+ ops issued, (%d+) remaining")
    if not passes then return "complete" end
    return string.format("complete, %s passes, %s remaining", passes, remaining)
end

--- Build a capture record skeleton for one session.
--
-- The prose headings are left empty on purpose: the figures are mechanical
-- and the reasoning is not. Shape follows docs/sort-logs/README.md.
--
-- Deliberately omits the session header's player, realm and guild. A record
-- names none of the three, and a tool that leaks one turns the convention
-- into something a person has to remember on every capture.
function M.skeleton(row, groups)
    groups = groups or {}
    local measures = M.measures(groups)
    local out = {}
    local function add(line) out[#out + 1] = line end

    -- Number the runs once, so the figures section and the table above it
    -- cannot disagree about which run is Run 2.
    local runNumber, runs = {}, {}
    for i, group in ipairs(groups) do
        if group.started then
            runs[#runs + 1] = group
            runNumber[i] = #runs
        end
    end

    add(string.format("# %s: <what this capture shows>",
        os.date("!%Y-%m-%d", row.startedAt or 0)))
    add("")
    add("<One or two sentences on what was run and why it is worth keeping.>")
    add("")
    add("## What was run")
    add("")

    if #runs == 0 then
        add("No executed run in this session: the lines below are plans only.")
    else
        -- The leading empty cell is the row-label column. Without it the
        -- header has one cell fewer than the delimiter row, and GFM then
        -- declines to make a table at all: GitHub renders the whole block
        -- as a paragraph of raw pipes. Checked against the /markdown API,
        -- not assumed.
        local header, divider = { "| |" }, { "|---|" }
        local started, bags = { "| Started |" }, { "| Bags |" }
        local planned, ended = { "| Planned |" }, { "| Ended |" }
        local probe = { "| Probe |" }
        for i, run in ipairs(runs) do
            header[#header + 1] = string.format(" Run %d |", i)
            divider[#divider + 1] = "---|"
            local _, first = firstMatch(run, "^Sort: starting")
            started[#started + 1] = string.format(" %s |", M.formatTime(first and first.ts))
            bags[#bags + 1] = string.format(" %s |", bagsModeOf(run))
            planned[#planned + 1] = string.format(" %s |", plannedOf(run))
            ended[#ended + 1] = string.format(" %s |", endedOf(run))
            probe[#probe + 1] = string.format(" %s |", probeOf(run))
        end
        add(table.concat(header))
        add(table.concat(divider))
        add(table.concat(started))
        add(table.concat(bags))
        add(table.concat(planned))
        add(table.concat(ended))
        add(table.concat(probe))
    end

    add("")
    add(string.format("Addon version %s, session %d of the capture.",
        row.addonVersion or "?", row.index or 0))
    add("")
    add("## The figures")
    add("")

    for i, group in ipairs(groups) do
        if runNumber[i] then
            add(string.format("### Run %d", runNumber[i]))
        else
            add("### A plan with no run behind it")
            add("")
            add("A preview, or the deviations the Sort tab prints after a sort.")
        end
        add("")
        add("```")
        for _, line in ipairs(group.lines or {}) do
            add(string.format("[%s] %s", M.formatTime(line.ts), line.message or ""))
        end
        add("```")
        add("")
    end

    add("| Measure | Value |")
    add("|---|---|")
    add(string.format("| Plan lines emitted | %d |", measures.planLines))
    add(string.format("| Of those reading `0 unplaced` | %d |", measures.planZeroUnplaced))
    add(string.format("| `phases` lines emitted | %d |", measures.phaseLines))
    add(string.format("| Of those reading `abort=0` | %d |", measures.phaseZeroAbort))
    add(string.format("| Distinct plan signatures | %d |", measures.distinctPlans))
    local pivotParts = {}
    for _, entry in ipairs(measures.pivots) do
        pivotParts[#pivotParts + 1] = string.format("%d (x%d)", entry.value, entry.count)
    end
    add(string.format("| `P2 pivot` values seen | %s |",
        #pivotParts > 0 and table.concat(pivotParts, ", ") or "none"))
    add("")
    add("## What this accounts for")
    add("")
    add("## The limit worth stating")
    add("")
    add("## For the reader of the next capture")
    add("")

    return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- Command line
------------------------------------------------------------------------

local USAGE = [[
Read a saved GuildBankLedger audit session.

  lua scripts/audit-sessions.lua <path>                    list the sessions
  lua scripts/audit-sessions.lua <path> --session N        one session, sort channel
  lua scripts/audit-sessions.lua <path> --session N --channel sync
  lua scripts/audit-sessions.lua <path> --session N --md   capture record skeleton

<path> is the SavedVariables file itself, which holds the whole ledger too:
  <WoW>/_retail_/WTF/Account/<accountID>/SavedVariables/GuildBankLedger.lua

Sessions are numbered oldest first. The store keeps ten and a /reload that
logs anything consumes one, so a capture is about nine loads from eviction.
]]

local function parseArgs(argv)
    local opts = { channel = "sort" }
    local i = 1
    while argv[i] do
        local a = argv[i]
        if a == "--session" then
            i = i + 1
            opts.session = tonumber(argv[i])
            if not opts.session then return nil, "--session needs a number" end
        elseif a == "--channel" then
            i = i + 1
            opts.channel = argv[i]
            if not opts.channel then return nil, "--channel needs a name" end
        elseif a == "--md" then
            opts.md = true
        elseif a == "-h" or a == "--help" then
            return nil, USAGE
        elseif a:find("^%-") then
            return nil, "unknown option " .. a
        elseif not opts.path then
            opts.path = a
        else
            return nil, "unexpected argument " .. a
        end
        i = i + 1
    end
    if not opts.path then return nil, USAGE end
    return opts
end

local function printSessions(db)
    local rows = M.list(db)
    if #rows == 0 then
        print("No sessions saved.")
        return
    end
    print(string.format("%3s  %-21s %-9s %6s %6s %7s  %s",
        "#", "started (UTC)", "version", "sync", "sort", "system", "dropped"))
    for _, row in ipairs(rows) do
        local dropped = {}
        for _, channel in ipairs(CHANNEL_ORDER) do
            if row.dropped[channel] > 0 then
                dropped[#dropped + 1] = channel .. ":" .. row.dropped[channel]
            end
        end
        print(string.format("%3d  %-21s %-9s %6d %6d %7d  %s",
            row.index, M.formatDate(row.startedAt), row.addonVersion,
            row.counts.sync, row.counts.sort, row.counts.system,
            #dropped > 0 and table.concat(dropped, " ") or "-"))
    end
end

--- Entry point. Returns a process exit code.
function M.main(argv)
    local opts, err = parseArgs(argv or {})
    if not opts then
        io.stderr:write(err .. "\n")
        return 2
    end

    local db, loadErr = M.load(opts.path)
    if not db then
        io.stderr:write(tostring(loadErr) .. "\n")
        return 1
    end

    if not opts.session then
        printSessions(db)
        return 0
    end

    if opts.md then
        local rows = M.list(db)
        local row = rows[opts.session]
        if not row then
            io.stderr:write("no session " .. opts.session .. " (" .. #rows .. " saved)\n")
            return 1
        end
        print(M.skeleton(row, M.runs(db, opts.session)))
        return 0
    end

    local entries, channelErr = M.channel(db, opts.session, opts.channel)
    if not entries then
        io.stderr:write(tostring(channelErr) .. "\n")
        return 1
    end
    for _, entry in ipairs(entries) do
        -- Level is shown only when it is not INFO, matching how the in-game
        -- log frame renders the same entries.
        local level = (entry.level and entry.level ~= "INFO")
            and ("[" .. entry.level .. "] ") or ""
        print(string.format("[%s] %s%s", M.formatTime(entry.ts), level, entry.message or ""))
    end
    return 0
end

-- Run only when invoked as a script. Under busted the spec loads this file
-- with dofile and arg[0] is the test runner, so the CLI stays asleep.
if arg and arg[0] and arg[0]:lower():find("audit%-sessions%.lua$") then
    os.exit(M.main(arg))
end

return M
