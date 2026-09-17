-- scripts/audit-sessions.lua: the offline reader for the persistent audit
-- capture (src/AuditCapture.lua). Loaded with dofile rather than require so
-- the script stays a plain file that `lua scripts/audit-sessions.lua` can
-- also run directly; the spec never goes through the CLI, only the table of
-- functions the file returns.

local FIXTURE = "spec/fixtures/audit/two-sessions.lua"

describe("audit session reader", function()
    local Reader

    before_each(function()
        Reader = dofile("scripts/audit-sessions.lua")
    end)

    describe("load", function()
        it("returns the capture table and leaves the global alone", function()
            _G.GuildBankLedgerAuditDB = nil
            local db, err = Reader.load(FIXTURE)
            assert.is_nil(err)
            assert.equals(1, db.schemaVersion)
            assert.equals(2, #db.sessions)
            -- The sandbox is the point: reading a capture must not install
            -- a multi-megabyte SavedVariable into the running process.
            assert.is_nil(_G.GuildBankLedgerAuditDB)
        end)

        it("reports a missing file rather than throwing", function()
            local db, err = Reader.load("spec/fixtures/audit/not-here.lua")
            assert.is_nil(db)
            assert.is_string(err)
        end)
    end)

    describe("list", function()
        it("returns one row per session with its header and counts", function()
            local db = Reader.load(FIXTURE)
            local rows = Reader.list(db)

            assert.equals(2, #rows)
            assert.equals(1, rows[1].index)
            assert.equals("0.39.3", rows[1].addonVersion)
            assert.equals("Tester", rows[1].player)
            assert.equals("Test Guild", rows[1].guild)
            assert.equals(2, rows[1].counts.sort)
            assert.equals(1, rows[1].counts.sync)
            assert.equals(0, rows[1].counts.system)

            assert.equals(2, rows[2].index)
            assert.equals("0.39.4", rows[2].addonVersion)
            assert.equals(16, rows[2].counts.sort)
        end)

        it("reads each session's own dropped counters", function()
            -- The fixture puts session 1's `dropped` block above its
            -- `startedAt`, which is what a real SavedVariables file does.
            -- Reading by line would attribute session 2's zeros here.
            local db = Reader.load(FIXTURE)
            local rows = Reader.list(db)

            assert.equals(692, rows[1].dropped.sort)
            assert.equals(0, rows[2].dropped.sort)
        end)
    end)

    describe("channel", function()
        it("returns one session's entries in recorded order", function()
            local db = Reader.load(FIXTURE)
            local entries = Reader.channel(db, 1, "sort")

            assert.equals(2, #entries)
            assert.is_truthy(entries[1].message:find("Sort plan:", 1, true))
            assert.equals("WARN", entries[2].level)
        end)

        it("addresses the session by index, not by position in the file", function()
            local db = Reader.load(FIXTURE)
            local entries = Reader.channel(db, 2, "system")

            assert.equals(1, #entries)
            assert.equals("Bank opened", entries[1].message)
        end)

        it("refuses a session index out of range with a message", function()
            local db = Reader.load(FIXTURE)
            local entries, err = Reader.channel(db, 9, "sort")

            assert.is_nil(entries)
            assert.is_string(err)
        end)

        it("refuses an unknown channel with a message", function()
            local db = Reader.load(FIXTURE)
            local entries, err = Reader.channel(db, 1, "restock")

            assert.is_nil(entries)
            assert.is_string(err)
        end)
    end)

    describe("runs", function()
        local function startedRuns(groups)
            local started = {}
            for _, g in ipairs(groups) do
                if g.started then started[#started + 1] = g end
            end
            return started
        end

        it("groups the sort channel into one run per execution", function()
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            assert.equals(3, #started)

            -- Each run keeps the plan line that belongs to it.
            local function planOf(g)
                for _, line in ipairs(g.lines) do
                    if line.message:find("^Sort plan:") then return line.message end
                end
            end
            assert.is_truthy(planOf(started[1]):find("12 ops", 1, true))
            assert.is_truthy(planOf(started[2]):find("unviewable:T5", 1, true))
            assert.is_truthy(planOf(started[3]):find("bags:4/9", 1, true))
        end)

        it("keeps a preview's plan line out of the following run", function()
            -- /gbl sortpreview writes a plan line with no execution behind
            -- it. Folding it into the next run would misreport what that
            -- run planned.
            local db = Reader.load(FIXTURE)
            local groups = Reader.runs(db, 2)

            assert.is_false(groups[1].started)
            assert.equals(1, #groups[1].lines)
            assert.is_truthy(groups[1].lines[1].message:find("3.0ms", 1, true))
        end)

        it("carries the terminal line so a run says how it ended", function()
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            local last = started[2].lines[#started[2].lines]
            assert.is_truthy(last.message:find("Sort: aborted", 1, true))
        end)

        it("keeps a post-run deviations plan line out of the run that ended", function()
            -- The Sort tab runs /gbl deviations after every executed sort,
            -- and that writes a plan line of its own. Attaching it to the
            -- run above would report a plan the run never executed.
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            for _, line in ipairs(started[1].lines) do
                assert.is_nil(line.message:find("4.8ms", 1, true))
            end
            for _, line in ipairs(started[2].lines) do
                assert.is_nil(line.message:find("4.8ms", 1, true))
            end
        end)

        it("drops sort lines that are not part of the run summary", function()
            -- Session 1 holds a per-op WARN. The record skeleton is a
            -- summary, so op-level noise stays out of it.
            local db = Reader.load(FIXTURE)
            local groups = Reader.runs(db, 1)

            for _, g in ipairs(groups) do
                for _, line in ipairs(g.lines) do
                    assert.is_nil(line.message:find("skipped", 1, true))
                end
            end
        end)
    end)

    describe("measures", function()
        local function measuresOf()
            local db = Reader.load(FIXTURE)
            return Reader.measures(Reader.runs(db, 2))
        end

        it("counts plan lines and how many placed everything", function()
            local m = measuresOf()
            assert.equals(5, m.planLines)
            assert.equals(3, m.planZeroUnplaced)
        end)

        it("counts phases lines and how many aborted nothing", function()
            -- The two counts differ on purpose: one of the fixture's two
            -- phases lines reads abort=1. With both at 1 a count that
            -- ignored the abort term agreed with a correct one.
            local m = measuresOf()
            assert.equals(2, m.phaseLines)
            assert.equals(1, m.phaseZeroAbort)
        end)

        it("does not read 10 unplaced as 0 unplaced", function()
            -- "0 unplaced" is a substring of "10 unplaced". Run 2 reads
            -- 10, and three of the five plan lines placed everything.
            local m = measuresOf()
            assert.equals(5, m.planLines)
            assert.equals(3, m.planZeroUnplaced)
        end)

        it("ignores the timing figure when counting distinct plans", function()
            -- Two of the five plan lines describe the same plan and differ
            -- only in milliseconds, so the count is four.
            local m = measuresOf()
            assert.equals(4, m.distinctPlans)
        end)

        it("reports the pivot counts ascending so two reads agree", function()
            local m = measuresOf()
            assert.equals(2, #m.pivots)
            assert.equals(1, m.pivots[1].value)
            assert.equals(1, m.pivots[1].count)
            assert.equals(4, m.pivots[2].value)
            assert.equals(1, m.pivots[2].count)
        end)
    end)

    describe("skeleton", function()
        local function skeletonOf()
            local db = Reader.load(FIXTURE)
            local rows = Reader.list(db)
            local groups = Reader.runs(db, 2)
            return Reader.skeleton(rows[2], groups)
        end

        it("names each run with its bags mode and how it ended", function()
            local text = skeletonOf()
            assert.is_truthy(text:find("Run 1", 1, true))
            assert.is_truthy(text:find("Run 3", 1, true))
            assert.is_truthy(text:find("bags=on", 1, true))
            assert.is_truthy(text:find("aborted", 1, true))
        end)

        it("embeds the summary lines verbatim", function()
            local text = skeletonOf()
            assert.is_truthy(text:find("unviewable:T5", 1, true))
            assert.is_truthy(text:find("bags:4/9(fill=1", 1, true))
        end)

        it("carries the counted measures", function()
            local text = skeletonOf()
            assert.is_truthy(text:find("Plan lines emitted", 1, true))
            assert.is_truthy(text:find("| 5 |", 1, true))
        end)

        it("gives the run table a header cell per column", function()
            -- The first column holds the row labels, so the header needs a
            -- leading empty cell. Without it the header is one cell short
            -- of the delimiter row, and GFM requires those to match: the
            -- whole block then renders as a paragraph of raw pipes rather
            -- than a table. Verified against GitHub's /markdown API.
            local text = skeletonOf()
            local header = text:match("\n(|[^\n]*Run 1[^\n]*)\n")
            local divider = text:match("\n|[^\n]*Run 1[^\n]*\n(|[^\n]*)\n")

            local function cells(row)
                local n = 0
                for _ in row:gmatch("|") do n = n + 1 end
                return n
            end
            assert.is_string(header)
            assert.equals(cells(divider), cells(header))
        end)

        it("names no guild, player or realm", function()
            -- Five of the six committed records name none of the three and
            -- the convention is that a record never does. A tool that leaks
            -- one into the skeleton makes that a thing to remember rather
            -- than a thing that holds.
            local text = skeletonOf()
            assert.is_nil(text:find("Tester", 1, true))
            assert.is_nil(text:find("TestRealm", 1, true))
            assert.is_nil(text:find("Test Guild", 1, true))
        end)
    end)

    describe("formatTime", function()
        it("renders UTC so two machines read one capture the same way", function()
            assert.equals("00:00:00", Reader.formatTime(0))
            assert.equals("01:01:01", Reader.formatTime(3661))
        end)
    end)
end)
