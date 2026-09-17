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
            assert.equals(14, rows[2].counts.sort)
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
        it("groups the sort channel into one run per execution", function()
            local db = Reader.load(FIXTURE)
            local groups = Reader.runs(db, 2)

            local started = {}
            for _, g in ipairs(groups) do
                if g.started then started[#started + 1] = g end
            end
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
            local groups = Reader.runs(db, 2)

            local last = groups[3].lines[#groups[3].lines]
            assert.is_truthy(last.message:find("Sort: aborted", 1, true))
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

    describe("formatTime", function()
        it("renders UTC so two machines read one capture the same way", function()
            assert.equals("00:00:00", Reader.formatTime(0))
            assert.equals("01:01:01", Reader.formatTime(3661))
        end)
    end)
end)
