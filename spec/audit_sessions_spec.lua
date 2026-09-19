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
            assert.equals("0.39.7", rows[2].addonVersion)
            assert.equals(23, rows[2].counts.sort)
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
            -- This used to read the run's LAST line, which worked only while
            -- the reader dropped everything finish() writes after the terminal
            -- line. The terminal line is not last any more and never was in a
            -- real capture, so the position it sits at is what gets asserted.
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            local terminal
            for i, line in ipairs(started[2].lines) do
                if line.message:find("Sort: aborted", 1, true) then terminal = i end
            end
            assert.is_not_nil(terminal, "a run has to say how it ended")
            assert.is_true(terminal < #started[2].lines,
                "the tail finish() writes comes after the terminal line")
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

        -- THE TAIL. `finish` writes the terminal line FIRST and then up to
        -- three more summary lines after it (src/SortExecutor.lua: the
        -- complete/aborted line, then `Sort bags:`, `Sort lift probe:`,
        -- `Sort hitch summary:`). Closing a run on the terminal line and
        -- stopping there drops all of them into an orphan group that the
        -- skeleton labels as a preview, which is where `Sort bags:` landed
        -- for every real capture until this was pinned. The fixture used to
        -- put the bags line ABOVE the terminal line, an order no client
        -- produces, which is why 24 green specs never saw it.
        it("keeps the tail a run emits after its terminal line inside that run", function()
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            local function has(g, needle)
                for _, line in ipairs(g.lines) do
                    if line.message:find(needle, 1, true) then return true end
                end
                return false
            end

            assert.is_true(has(started[3], "Sort bags: 3 deposit(s)"),
                "the bags line belongs to the run it reports on")
            assert.is_true(has(started[3], "Sort lift probe:"),
                "the probe line is the tripwire for the guard; it belongs to its run")
            assert.is_true(has(started[3], "Sort hitch summary:"))
            assert.is_true(has(started[1], "GetCursorInfo [item:14]"),
                "a bags=off run still emits a probe and a hitch summary")
        end)

        it("keeps both continuations of a plan line, not just the phases one", function()
            -- `demands:` is the sibling of `phases:` under the same plan line
            -- and was simply missing from the pattern list. Every committed
            -- capture doc quotes it, so a skeleton without it sends the writer
            -- back to the raw log, which is what the reader exists to avoid.
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            local phases, demands = false, false
            for _, g in ipairs(started) do
                for _, line in ipairs(g.lines) do
                    if line.message:find("^%s+phases:") then phases = true end
                    if line.message:find("^%s+demands:") then demands = true end
                end
            end
            assert.is_true(phases)
            assert.is_true(demands, "the demands continuation belongs to its run too")
        end)

        it("does not attach one run's tail to the run that follows it", function()
            -- Run 2 ends on an abort and run 3 starts straight after, with no
            -- preview line between them.
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            for _, line in ipairs(started[3].lines) do
                assert.is_nil(line.message:find("0 hitches", 1, true),
                    "run 2's hitch summary must not read as run 3's")
            end
        end)

        it("still keeps a post-run deviations plan line out, now that a tail exists", function()
            -- The tail must not be an open door: `Sort plan:` is excluded from
            -- it, or the plan line /gbl deviations writes after every sort gets
            -- folded into the run above.
            local db = Reader.load(FIXTURE)
            local groups = Reader.runs(db, 2)

            local deviations
            for _, g in ipairs(groups) do
                for _, line in ipairs(g.lines) do
                    if line.message:find("4.8ms", 1, true) then deviations = g end
                end
            end
            assert.is_not_nil(deviations, "the deviations plan line should still be grouped")
            assert.is_false(deviations.started)
        end)

        it("carries a mid-run guard WARN like any other summary line", function()
            local db = Reader.load(FIXTURE)
            local started = startedRuns(Reader.runs(db, 2))

            local found = false
            for _, line in ipairs(started[3].lines) do
                if line.message:find("lift guard disabled", 1, true) then
                    found = true
                    assert.equals("WARN", line.level)
                end
            end
            assert.is_true(found, "a run that disabled its guard has to say so in the record")
        end)

        it("keeps the overflow clamp continuation with its plan line (#151)", function()
            -- Hand-built rather than added to the recorded fixture: the line
            -- only ever fires on an input no real bank produces, so no
            -- capture will ever carry it, and the recording stays a
            -- recording. The order is the one the client emits.
            local function entry(message)
                return { message = message, level = "INFO", t = 1 }
            end
            local db = { sessions = { { entries = { sort = {
                entry("Sort: starting 2 ops, bags=off"),
                entry("Sort plan: 1.0ms, 2 ops, 0 deficits, 0 unplaced (input: 1 slots / 2 tabs) [T1:1]"),
                entry("  phases: P0 merge=0(free=0) P1a assign=0 P1b spill=2(top=0,r=1,l=0,fe=1,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=0"),
                entry("  demands: 0 total (pinned=0, ext-R=0, ext-L=0, first-empty=0)"),
                entry("  overflow clamp: 1 take(s) held to max stack"),
                entry("Sort: complete, 2 ops issued"),
            } } } } }
            local started = startedRuns(Reader.runs(db, 1))
            assert.equals(1, #started)
            local found = false
            for _, line in ipairs(started[1].lines) do
                if line.message:find("overflow clamp:", 1, true) then found = true end
            end
            assert.is_true(found, "the clamp continuation belongs to its run")
        end)

        -- #181 adds two more continuations under the plan line, the
        -- fragmentation term and the list of split items. Hand-built like
        -- the #151 pin above, because the recorded fixture predates them
        -- and stays a recording. Each case asserts the whole kept sequence
        -- rather than the presence of one line, so a pattern that swallows
        -- a neighbour or drops one reads as a different sequence.
        local function line(message)
            return { message = message, level = "INFO", t = 1 }
        end

        local function keptMessages(group)
            local out = {}
            for _, entry in ipairs(group.lines) do
                out[#out + 1] = entry.message
            end
            return out
        end

        it("keeps both overflow continuations with their plan line, in emitted order (#181)", function()
            -- The order is the one src/SortPlanner.lua emits: the pair,
            -- then the two overflow lines, then the clamp WARN.
            local messages = {
                "Sort: starting 2 ops, bags=off",
                "Sort plan: 1.0ms, 2 ops, 0 deficits, 0 unplaced (input: 4 slots / 3 tabs, locked=0) [T1:1 T6:2 T7:1]",
                "  phases: P0 merge=0(free=0) P1a assign=0 P1b spill=2(top=0,r=1,l=0,fe=1,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=0",
                "  demands: 0 total (pinned=0, ext-R=0, ext-L=0, first-empty=0)",
                "  overflow: items=42 frag=7 partials=9 extra=4 unknown=0",
                "  overflow split: it:12345 T6x2 T7x1",
                "  overflow clamp: 1 take(s) held to max stack",
                "Sort: complete, 2 ops issued",
            }
            local sort = {}
            for _, m in ipairs(messages) do sort[#sort + 1] = line(m) end
            local db = { sessions = { { entries = { sort = sort } } } }

            local started = startedRuns(Reader.runs(db, 1))
            assert.equals(1, #started)
            assert.same(messages, keptMessages(started[1]))
        end)

        it("keeps a zero-op replan's overflow line with its plan line when no phases pair follows (#181)", function()
            -- The planner skips the phases/demands pair on a plan with no
            -- ops and no demands, and the overflow line renders anyway (it
            -- is gated on the layout, not on activity). The final replan
            -- of a run is exactly that shape, and it is the reading #145 is
            -- judged against, so the line must land inside the run beside
            -- the plan line it continues. The per-op WARN between them is
            -- the noise the reader exists to drop.
            local kept = {
                "Sort: starting execution of 12 ops, cadence 1.0s (ping 40ms) bags=off",
                "Sort plan: 5.1ms, 12 ops, 0 deficits, 0 unplaced (input: 600 slots / 7 tabs, locked=0) [T1:59 T6:93 T7:68]",
                "  phases: P0 merge=0(free=0) P1a assign=12 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0,stranded=0) P3 sweep=0 P4 pack=0",
                "  demands: 214 total (pinned=12, ext-R=180, ext-L=0, first-empty=22)",
                "  overflow: items=42 frag=7 partials=9 extra=4 unknown=0",
                "  overflow split: it:12345 T6x7 T7x6",
                "Sort plan: 4.8ms, 0 ops, 0 deficits, 0 unplaced (input: 600 slots / 7 tabs, locked=0) [T1:59 T6:93 T7:68]",
                "  overflow: items=42 frag=7 partials=9 extra=4 unknown=0",
                "Sort: complete in 40.0s - 1 passes, 12 ops issued, 0 remaining, avg 1.10s/op (cursorStuck=0 stalls=0 flushes=0)",
            }
            local sort = {}
            for i, m in ipairs(kept) do
                sort[#sort + 1] = line(m)
                if i == 6 then
                    sort[#sort + 1] = { message = "Sort op 3/12 skipped: T1/5 empty, wanted 20 x it:100",
                                        level = "WARN", t = 1 }
                end
            end
            local db = { sessions = { { entries = { sort = sort } } } }

            local started = startedRuns(Reader.runs(db, 1))
            assert.equals(1, #started)
            local got = keptMessages(started[1])
            assert.same(kept, got)
            assert.is_truthy(got[7]:find("^Sort plan: 4.8ms, 0 ops"))
            assert.is_truthy(got[8]:find("^  overflow:"),
                "the replan's overflow line follows its plan line directly")
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

        -- #165 split the phases line's abort term into an abort count and a
        -- stranded-assignment count. The reader has to keep parsing both, and
        -- the committed fixture cannot prove it: that file is a frozen
        -- recording of a real pre-#165 capture, on the same principle as
        -- spec/fixtures/wire, so it carries the old form forever and would
        -- stay green while the live format stopped parsing. These two cases
        -- sit beside it rather than replacing it.
        local function measuresOfLines(...)
            local lines = {}
            for _, message in ipairs({ ... }) do
                lines[#lines + 1] = { message = message }
            end
            return Reader.measures({ { lines = lines } })
        end

        it("reads the abort count from the pre-#165 phases line", function()
            local m = measuresOfLines(
                "  phases: P0 merge=0(free=0) P2 pivot=4(abort=0) P4 pack=2",
                "  phases: P0 merge=0(free=0) P2 pivot=1(abort=8) P4 pack=0")
            assert.equals(2, m.phaseLines)
            assert.equals(1, m.phaseZeroAbort)
        end)

        it("reads it from the post-#165 line, where a stranded count follows", function()
            local m = measuresOfLines(
                "  phases: P0 merge=0(free=0) P2 pivot=4(abort=0,stranded=0) P4 pack=2",
                "  phases: P0 merge=0(free=0) P2 pivot=1(abort=1,stranded=8) P4 pack=0")
            assert.equals(2, m.phaseLines)
            assert.equals(1, m.phaseZeroAbort,
                "one of these two aborted nothing, whichever form it is written in")
        end)

        -- #178 puts two terms inside the plan line's input bracket. The
        -- reader takes three things off that line and none of them is a
        -- field parse, so this is a check that the three survive rather
        -- than a new capability. The frozen fixture above carries the
        -- pre-#178 form and keeps carrying it.
        it("reads a plan line that carries the bank skip terms", function()
            local m = measuresOfLines(
                "Sort plan: 4.2ms, 0 ops, 0 deficits, 0 unplaced "
                .. "(input: 603 slots / 7 tabs, locked=2) unviewable:none "
                .. "[T1:59 T2:98(locked=2)]",
                "Sort plan: 4.2ms, 0 ops, 0 deficits, 10 unplaced "
                .. "(input: 603 slots / 7 tabs, locked=0) unviewable:none "
                .. "[T1:59 T2:98]")
            assert.equals(2, m.planLines)
            assert.equals(1, m.planZeroUnplaced,
                "the zero-unplaced probe reads the term after unplaced")
            assert.equals(2, m.distinctPlans,
                "a locked count is part of what makes two plans distinct")
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

        it("names what the cursor probe answered for each run", function()
            -- #171 made this line the tripwire for the whole sort: a capture
            -- where GetCursorInfo has gone quiet looks exactly like a bank
            -- full of failed lifts until the record says which it was.
            local text = skeletonOf()
            assert.is_truthy(text:find("| Probe |", 1, true), text)
            assert.is_truthy(text:find("GetCursorInfo [item:14]", 1, true))
        end)

        it("says so when a run finished with its guard disabled", function()
            local text = skeletonOf()
            assert.is_truthy(text:find("guard off", 1, true),
                "a run that finished unguarded must not read as an ordinary one")
        end)

        it("renders a run that emitted no probe line at all", function()
            -- Run 2 aborted without one, and session 1 predates the probe
            -- entirely. Neither may break the skeleton.
            local text = skeletonOf()
            assert.is_truthy(text:find("Run 2", 1, true))

            local db = Reader.load(FIXTURE)
            local rows = Reader.list(db)
            local old = Reader.skeleton(rows[1], Reader.runs(db, 1))
            assert.is_string(old)
            assert.is_truthy(old:find("No executed run in this session", 1, true))
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
