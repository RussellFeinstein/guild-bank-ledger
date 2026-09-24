------------------------------------------------------------------------
-- schema_version_spec.lua - the schemaVersion ladder (#76)
--
-- schemaVersion defaults to 8 (src/Core.lua:124) while migrations run to 11,
-- and that is correct rather than stale. AceDB strips a value equal to its
-- default before the SavedVariables file is written, so the default IS the
-- stored version of every guild sitting at it: raise it and every one of
-- those guilds becomes 11 without having run migrations 9 to 11, and nothing
-- comes back for them.
--
-- The default and that round trip were already pinned before this file existed:
-- spec/savedvariables_spec.lua asserts them against a real AceDB, and that
-- landed in PR #261 under #77 rather than here. Raising the default to 11 reds
-- that file and leaves this one green, which is the right split. What this file
-- pins is the other half of the property: nothing advances the version except
-- the migration that earned it.
--
-- The version is written by the ladder's ten rungs, plus exactly two writes
-- that are not rungs. One of those two sits INSIDE a rung (rung 5 drops the
-- version before calling rung 4's function again) and the other is outside
-- MigrateAllGuilds entirely, so "outside the ladder" is the wrong axis: what
-- they have in common is that neither advances the progression.
--
--   The ladder. MigrateAllGuilds (src/Core.lua:1607) makes twelve calls per
--   guild and ten of them bump one rung: RepairCorruptedPlayerRealms runs
--   first and writes no version, and MigrateSortAccessShape sits between
--   rungs 8 and 9 and writes none either. Every gate below 9 is the loose
--   `>= N` form and the 9 to 10 and 10 to 11 gates are strict (`~= 9` at
--   :1422, `~= 10` at :1530), because MigrateNormalizePeerNames
--   short-circuits on cold realm APIs and leaves the guild at 8; a loose gate
--   there would let 10 or 11 be reached from 8 and strand the 8 to 9 work for
--   good. So what protects the low half of the ladder is the CALL ORDER and
--   what protects the top is those two gates, and `assert.same(LADDER, ...)`
--   below is the assertion that covers both: it is what reds when either
--   strict gate is loosened to `>=`, and it is the only thing in this file
--   that catches a rung being dropped.
--
--   The two writes that are not rungs. MigrateCrossSlotDedup, which IS rung 5,
--   drops the version to 4 on entry (:1081) so its own pass 1 re-runs the
--   same-slot dedup, whose gate is `>= 5`; that write is deliberate and
--   load-bearing, and it is why the recorder below counts only top-level
--   calls. And GBL:DeduplicateRecords sets it to 5 to force that same pass
--   (:2854) and cannot put it back, which is a defect filed as #263. Its two
--   cases here are characterization and say so in their names.
--
-- One gate is not the shape the rest are: MigrateOccurrenceScheme (:287)
-- reads `guildData.schemaVersion >= 2` with no `or 0`, where the other seven
-- loose gates read `(guildData.schemaVersion or 0) >= N`. A nil version
-- therefore raises inside MigrateAllGuilds, which is not pcall-protected, so
-- it aborts the ladder for that guild and every guild after it in the pairs
-- walk. Recorded on #263 beside the DeduplicateRecords raise, since the two
-- are the same shape and the same decision.
--
-- What spec/core_spec.lua already covers, so that it is not added again here:
-- each strict migration "refuses to bump from schema 8", MigrateRecoverPeerRealms
-- also "refuses to bump from schema 9" (:1344), and MigrateNormalizeStoredRealms
-- "skips already-migrated guilds (schemaVersion >= 10)" (:710). Those are the
-- cases that kill a gate loosened so it RUNS BELOW its rung. The two cases in
-- "the strict gates" here kill the opposite family, a gate inverted so it runs
-- ABOVE its rung (`< 10` in place of `~= 10`), which nothing else reaches.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- The call order in MigrateAllGuilds for the calls that carry a version, with
-- the version each must be entered at and the version it must leave.
-- MigrateSortAccessShape is in the list deliberately: it is called between
-- rungs 8 and 9 and writes no version, so a future edit giving it one shows up
-- here as a changed ladder rather than as nothing. RepairCorruptedPlayerRealms
-- is the twelfth call and is pinned by its own case below rather than here,
-- because it runs ahead of rung 1 and is conditional on playerRealms.
local LADDER = {
    { name = "MigrateOccurrenceScheme",      before = 1,  after = 2 },
    { name = "MigrateSchemaV2ToV3",          before = 2,  after = 3 },
    { name = "MigrateOccurrenceToPerSlot",   before = 3,  after = 4 },
    { name = "MigrateDeduplicateRecords",    before = 4,  after = 5 },
    { name = "MigrateCrossSlotDedup",        before = 5,  after = 6 },
    { name = "MigrateAccessControl",         before = 6,  after = 7 },
    { name = "MigrateRepairEpochTimestamps", before = 7,  after = 8 },
    { name = "MigrateSortAccessShape",       before = 8,  after = 8 },
    { name = "MigrateNormalizePeerNames",    before = 8,  after = 9 },
    { name = "MigrateNormalizeStoredRealms", before = 9,  after = 10 },
    { name = "MigrateRecoverPeerRealms",     before = 10, after = 11 },
}

-- The one call in LADDER that must NOT move the version.
local NON_BUMPING = { MigrateSortAccessShape = true }

describe("schemaVersion", function()
    local GBL, guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        guildData = GBL:GetGuildData()

        -- MigrateRecoverPeerRealms refuses a cold roster (GetNumGuildMembers
        -- is 0) and returns without bumping, so a ladder run against the
        -- default empty roster stops at 10 and would pin the short-circuit
        -- instead of the walk.
        MockWoW.guildRoster = {
            { name = "Katorriwl-Stormrage", isOnline = true },
        }
        -- Named as a precondition rather than left implicit: if the mock field
        -- is ever renamed, the ladder cases would otherwise fail as
        -- "expected 11, was 10" and read as a regression in the 10 to 11 gate.
        assert.is_true(GetNumGuildMembers() > 0)
    end)

    -- Wraps every migration MigrateAllGuilds calls that carries a version,
    -- records the version each saw on the way in and left on the way out, and
    -- hands back the sequence. Recording the sequence is the whole point: the
    -- endpoint alone cannot tell a walk from a jump.
    --
    -- Only top-level calls are recorded. MigrateCrossSlotDedup calls
    -- MigrateDeduplicateRecords from inside itself, and that nested call is a
    -- fact about that one migration rather than a rung of the ladder, so it is
    -- pinned in its own describe below instead of being folded in here.
    local function walk()
        local seen, originals, depth = {}, {}, 0
        for _, rung in ipairs(LADDER) do
            originals[rung.name] = GBL[rung.name]
        end
        for _, rung in ipairs(LADDER) do
            local name = rung.name
            GBL[name] = function(self, gd)
                local entry
                if gd == guildData and depth == 0 then
                    entry = { name = name, before = gd.schemaVersion }
                    seen[#seen + 1] = entry
                end
                depth = depth + 1
                -- Collected rather than assigned so the wrapper stays
                -- arity-faithful: a migration that later returns a second
                -- value must reach production and these cases the same way.
                local results = { originals[name](self, gd) }
                depth = depth - 1
                if entry then entry.after = gd.schemaVersion end
                return unpack(results)
            end
        end

        GBL:MigrateAllGuilds()

        -- Restored by walking LADDER, not pairs(originals): a renamed or
        -- misspelled LADDER entry never enters that table, so pairs would skip
        -- it and leave a wrapper installed whose body indexes nil.
        for _, rung in ipairs(LADDER) do GBL[rung.name] = originals[rung.name] end
        return seen
    end

    ---------------------------------------------------------------------------
    -- 1. The ladder
    ---------------------------------------------------------------------------

    describe("the migration ladder", function()
        it("walks a guild at 1 to 11 one rung at a time, in order", function()
            guildData.schemaVersion = 1

            assert.same(LADDER, walk())
            assert.equals(11, guildData.schemaVersion)
        end)

        it("bumps each rung by exactly one, and moves nothing on the shape step", function()
            -- Not implied by the assert.same above, and it is the reason that
            -- one has to compare the whole table rather than walk it: a chain
            -- can read continuous while a rung is missing. Deleting a rung and
            -- editing its LADDER row to match leaves every `before` equal to
            -- the previous `after` and the endpoint still 11.
            guildData.schemaVersion = 1

            local seen = walk()
            assert.equals(#LADDER, #seen)
            local version = 1
            for i, entry in ipairs(seen) do
                local rung = LADDER[i]
                assert.equals(rung.name, entry.name,
                    string.format("call %d was %s, expected %s", i, entry.name, rung.name))
                assert.equals(version, entry.before,
                    string.format("rung %d (%s) was entered at %s, expected %s",
                        i, entry.name, tostring(entry.before), tostring(version)))
                local expected = NON_BUMPING[entry.name] and version or version + 1
                assert.equals(expected, entry.after,
                    string.format("rung %d (%s) left the version at %s, expected %s",
                        i, entry.name, tostring(entry.after), tostring(expected)))
                version = entry.after
            end
            assert.equals(11, version)
            -- Read off the guild rather than off the last recorded entry, or an
            -- unlisted rung appended after MigrateRecoverPeerRealms is invisible.
            assert.equals(version, guildData.schemaVersion)
        end)

        it("moves no version for a guild already at 11", function()
            -- "No version", not "no work": MigrateSortAccessShape has no
            -- schemaVersion gate at all (src/Core.lua:2203) and rebuilds
            -- guildData.sortAccess on every run at any version. This case is
            -- about the version field only.
            guildData.schemaVersion = 11

            local seen = walk()
            assert.equals(#LADDER, #seen)
            for _, entry in ipairs(seen) do
                assert.equals(11, entry.before, entry.name .. " saw a version below 11")
                assert.equals(11, entry.after, entry.name .. " moved a guild already at 11")
            end
            assert.equals(11, guildData.schemaVersion)
        end)

        it("calls RepairCorruptedPlayerRealms once per guild, ahead of rung 1", function()
            -- The twelfth call in the per-guild loop (src/Core.lua:1615-1617).
            -- It writes no version, so the LADDER table cannot see it, and the
            -- comment on that call says it has to run before any migration that
            -- consults the roster cache. Nothing else in the suite pins either.
            guildData.schemaVersion = 1
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }

            local calls, firstRungSeen = 0, false
            local repair = GBL.RepairCorruptedPlayerRealms
            local rung1 = GBL.MigrateOccurrenceScheme
            GBL.RepairCorruptedPlayerRealms = function(self, t)
                calls = calls + 1
                assert.is_false(firstRungSeen, "repair ran after the first rung")
                return repair(self, t)
            end
            GBL.MigrateOccurrenceScheme = function(self, gd)
                firstRungSeen = true
                return rung1(self, gd)
            end

            GBL:MigrateAllGuilds()

            GBL.RepairCorruptedPlayerRealms = repair
            GBL.MigrateOccurrenceScheme = rung1
            assert.equals(1, calls)
        end)
    end)

    ---------------------------------------------------------------------------
    -- 2. The strict gates, inverted rather than loosened
    ---------------------------------------------------------------------------

    describe("the strict gates", function()
        -- Both cases sit ABOVE the gate, which is the one side a gate loosened
        -- to `>=` also refuses, so neither of these catches that loosening;
        -- the ladder's assert.same does. What they catch is the other
        -- direction, a gate inverted to run above its own rung (`< 10` for
        -- `~= 10`), which would re-run a realm canonicalization over a guild
        -- that has already had it. spec/core_spec.lua holds the below-the-rung
        -- side for both migrations.

        it("MigrateNormalizeStoredRealms does not re-run a guild at 11", function()
            guildData.schemaVersion = 11
            guildData.playerRealms = { ["Alice"] = "Aerie Peak" }

            local rewrites = GBL:MigrateNormalizeStoredRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(11, guildData.schemaVersion)
            assert.equals("Aerie Peak", guildData.playerRealms["Alice"])
        end)

        it("MigrateRecoverPeerRealms does not re-run a guild at 11", function()
            guildData.schemaVersion = 11
            guildData.knownPeers = { ["Katorriwl"] = { lastSeen = 1000 } }

            local rewrites = GBL:MigrateRecoverPeerRealms(guildData)

            assert.equals(0, rewrites)
            assert.equals(11, guildData.schemaVersion)
            assert.is_not_nil(guildData.knownPeers["Katorriwl"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- 3. Migration 9's gate is the loose form, and the call order is the
    --    reason that is safe
    ---------------------------------------------------------------------------

    describe("MigrateNormalizePeerNames", function()
        it("advances a guild at 3 straight to 9 when called on its own (characterization)", function()
            -- Its gate is `>= 9` (src/Core.lua:1360) rather than the strict form
            -- its two successors carry one rung up each (`~= 9` at :1422 and
            -- `~= 10` at :1530); the strict form here would be `~= 8`. So on its
            -- own it will advance any guild below 9 and the 4 to 8 work is
            -- skipped. Nothing in production calls it
            -- that way: MigrateAllGuilds reaches it only at 8, which the ladder
            -- cases above assert. Recorded rather than blessed, so that if the
            -- gate is ever tightened this case is the one that has to change.
            --
            -- Tightening it IS a safe improvement, and measured: changing :1360
            -- to `~= 8` reds exactly this case in the whole 2551-case suite and
            -- nothing else, because the ladder only ever reaches the migration
            -- at 8. It is not done in this PR because src/Core.lua is packaged,
            -- so the one-line change turns a test-only PR into a version stamp
            -- across six artifacts plus a tag, pushed to every auto-updating
            -- install, to harden a path nothing in production can reach. Worth
            -- doing as part of the next release that touches this file.
            guildData.schemaVersion = 3

            GBL:MigrateNormalizePeerNames(guildData)

            assert.equals(9, guildData.schemaVersion)
        end)
    end)

    ---------------------------------------------------------------------------
    -- 4. MigrateCrossSlotDedup's own write, which is deliberate
    ---------------------------------------------------------------------------

    describe("MigrateCrossSlotDedup", function()
        it("drops the version to 4 so its pass 1 re-runs the same-slot dedup", function()
            -- src/Core.lua:1081 sets the version to 4 before calling
            -- MigrateDeduplicateRecords, whose gate is `>= 5`. Without that
            -- write the nested call is entered at 5, returns 0 and pass 1
            -- silently does nothing, which is the whole reason this migration
            -- exists (it re-runs the same-slot pass over duplicates created
            -- after v0.14.2 ran it once). Asserted through the version the
            -- nested call is entered at, since a no-op pass leaves no other
            -- trace on an empty fixture.
            guildData.schemaVersion = 5

            local entered
            local original = GBL.MigrateDeduplicateRecords
            GBL.MigrateDeduplicateRecords = function(self, gd)
                entered = gd.schemaVersion
                return original(self, gd)
            end
            GBL:MigrateCrossSlotDedup(guildData)
            GBL.MigrateDeduplicateRecords = original

            assert.equals(4, entered)
            assert.equals(6, guildData.schemaVersion)
        end)
    end)

    ---------------------------------------------------------------------------
    -- 5. DeduplicateRecords, the write outside the ladder (#263)
    ---------------------------------------------------------------------------

    describe("DeduplicateRecords writes the version outside the ladder", function()
        it("skips a rung a guild below 4 still owed, for good (characterization)", function()
            -- src/Core.lua:2851-2857 forces the version to 5 to open
            -- MigrateCrossSlotDedup's gate, then restores it only
            -- `if savedSchema > 6`. The branch is entered only below 6, so the
            -- restore cannot fire on any path into it and the guild is left at
            -- 6 wherever it started.
            --
            -- The fixture is 3 and not 5 on purpose. At 4 and 5 the forced
            -- write loses nothing (the nested 4 to 5 pass runs, and 6 is where
            -- the ladder would have left the guild anyway), so a case starting
            -- there asserts the CORRECT outcome and cannot see the defect. The
            -- harm window is 1 to 3: from 3, MigrateOccurrenceToPerSlot's
            -- `>= 4` gate is satisfied by the forced 5 before it ever runs, and
            -- no later pass revisits it.
            guildData.schemaVersion = 3

            -- Entry versions rather than a call count: MigrateAllGuilds calls
            -- every migration unconditionally and the gate decides, so being
            -- called says nothing. This one does its work only when entered
            -- below 4.
            local enteredAt = {}
            local original = GBL.MigrateOccurrenceToPerSlot
            GBL.MigrateOccurrenceToPerSlot = function(self, gd)
                enteredAt[#enteredAt + 1] = gd.schemaVersion
                return original(self, gd)
            end

            GBL:DeduplicateRecords(guildData)
            assert.equals(6, guildData.schemaVersion)
            assert.same({}, enteredAt, "the 3 to 4 migration was reached after all")

            -- And it is permanent: the ladder will not come back for it. It is
            -- called once more, at 6, where its own gate turns it away.
            GBL:MigrateAllGuilds()
            GBL.MigrateOccurrenceToPerSlot = original

            assert.equals(11, guildData.schemaVersion)
            assert.same({ 6 }, enteredAt,
                "the ladder reached the skipped rung at a version below 4")
        end)

        it("raises on a guild whose schemaVersion is nil, after the legacy pass has run (characterization)", function()
            -- The gate reads `(guildData.schemaVersion or 0)` and the restore
            -- compares the raw value, so a nil passes the gate and reaches a
            -- numeric compare. The operands are matched rather than just the
            -- word "compare": every other raise on this path would be a
            -- different pair, and the assertion has to be able to tell a fix to
            -- this line from a fix somewhere else.
            --
            -- Nilling the field on a guild from GetGuildData is enough because
            -- AceDB copies scalar defaults INTO each guild table rather than
            -- serving them through __index (the wildcard metatable is on
            -- `guilds`), so the value only comes back across a logout and login.
            guildData.schemaVersion = nil

            local cleanups = 0
            local original = GBL.CleanupWithEventCounts
            GBL.CleanupWithEventCounts = function(self, gd)
                cleanups = cleanups + 1
                return original(self, gd)
            end

            local ok, err = pcall(function() return GBL:DeduplicateRecords(guildData) end)

            GBL.CleanupWithEventCounts = original
            assert.is_false(ok)
            assert.is_truthy(tostring(err):match("attempt to compare number with nil"))
            -- The end state, so a fix cannot move the raise and still pass: the
            -- legacy pass has already completed and left 6, and the count-based
            -- cleanup below it never ran at all.
            assert.equals(6, guildData.schemaVersion)
            assert.equals(0, cleanups)
        end)
    end)

    -----------------------------------------------------------------------
    -- 6. One guild's bad data must not strand the rest of the walk (#263)
    -----------------------------------------------------------------------

    describe("MigrateAllGuilds survives a guild that raises", function()
        -- Two guilds. The second is materialised through AceDB's `guilds["*"]`
        -- template by indexing it, the idiom spec/core_spec.lua:525 uses, so it
        -- arrives fully defaulted rather than as a partial literal.
        local BOOM = "migration exploded on purpose"

        -- `pairs` order over the guild table is not controllable, so a case
        -- written as "guild A raises, guild B still finishes" passes on unfixed
        -- code whenever the walk happens to reach B first. These stub the rung to
        -- raise on its FIRST call whatever guild that is, record which guild that
        -- was, and assert about the other one.
        local function raiseOnFirstGuild(rung)
            local victim
            local original = GBL[rung]
            GBL[rung] = function(self, gd)
                if not victim then
                    victim = gd
                    error(BOOM, 0)
                end
                return original(self, gd)
            end
            return function() return victim, original end
        end

        local function twoGuilds()
            local other = GBL.db.global.guilds["Early Guild"]
            guildData.schemaVersion = 1
            other.schemaVersion = 1
            return other
        end

        it("continues to the next guild when one guild's migration raises", function()
            local other = twoGuilds()
            -- Rung 3, so the guild it hits is left below 6 and in the window
            -- where DeduplicateRecords used to skip a rung for good.
            local read = raiseOnFirstGuild("MigrateOccurrenceToPerSlot")

            GBL:MigrateAllGuilds()

            local victim, original = read()
            GBL.MigrateOccurrenceToPerSlot = original
            assert.is_not_nil(victim, "the stub never fired")
            local survivor = (victim == guildData) and other or guildData
            assert.equals(11, survivor.schemaVersion,
                "the guild after the failing one did not finish its ladder")
            assert.equals(3, victim.schemaVersion,
                "the failing guild should be left where the raise happened")
        end)

        it("logs one system ERROR naming the guild and both versions, and prints once", function()
            twoGuilds()
            local read = raiseOnFirstGuild("MigrateOccurrenceToPerSlot")
            Helpers.clearPrints()

            GBL:MigrateAllGuilds()

            local victim, original = read()
            GBL.MigrateOccurrenceToPerSlot = original
            local errors = {}
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.level == "ERROR" then errors[#errors + 1] = e.message end
            end
            assert.equals(1, #errors)
            -- The guild by name, where it is LEFT (3, which is what the next
            -- session resumes from), where this attempt STARTED (1), and the
            -- error itself. Both versions, because they differ and a reader
            -- wants each: one says how far it got, the other says where it is.
            local name = (victim == guildData) and "TestGuild" or "Early Guild"
            assert.is_truthy(errors[1]:find(name, 1, true), errors[1])
            assert.is_truthy(errors[1]:find("schema 3", 1, true), errors[1])
            assert.is_truthy(errors[1]:find("entered at 1", 1, true), errors[1])
            assert.is_truthy(errors[1]:find(BOOM, 1, true), errors[1])
            assert.is_true(Helpers.printContains(BOOM))
        end)

        it("names a guild that keeps failing only once per session", function()
            twoGuilds()
            local original = GBL.MigrateOccurrenceToPerSlot
            GBL.MigrateOccurrenceToPerSlot = function() error(BOOM, 0) end

            local firstFailures = GBL:MigrateAllGuilds()
            local secondFailures = GBL:MigrateAllGuilds()

            GBL.MigrateOccurrenceToPerSlot = original
            local n = 0
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.level == "ERROR" then n = n + 1 end
            end
            -- Both guilds fail, so two lines on the first walk and none on the
            -- second: the 500-entry system buffer is what a capture reader has.
            assert.equals(2, n)
            assert.equals(2, firstFailures)
            assert.equals(2, secondFailures)
        end)

        it("resets the hash cache when a migration raises", function()
            -- Counted relative to the moment of the raise rather than absolutely:
            -- how many rungs reset the cache on the way in depends on the fixture
            -- (MigrateOccurrenceScheme returns early on a guild with no records,
            -- before its own reset), and that is not what this case is about. What
            -- it asserts is that the failure branch resets exactly once, whatever
            -- ran before it.
            guildData.schemaVersion = 1
            local resets, atRaise = 0, nil
            local originalReset = GBL.ResetHashCache
            GBL.ResetHashCache = function(self) resets = resets + 1 end
            local originalRung = GBL.MigrateOccurrenceToPerSlot
            GBL.MigrateOccurrenceToPerSlot = function()
                atRaise = resets
                error(BOOM, 0)
            end

            GBL:MigrateAllGuilds()

            GBL.MigrateOccurrenceToPerSlot = originalRung
            GBL.ResetHashCache = originalReset
            assert.is_not_nil(atRaise, "the stub never fired")
            -- A raise leaves ids rewritten by the rungs that did run against a
            -- cache keyed on the old ones, so the branch must clear it.
            assert.equals(atRaise + 1, resets)
        end)
    end)
end)
