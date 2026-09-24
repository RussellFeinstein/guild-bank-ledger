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
-- The default and that round trip are pinned in spec/savedvariables_spec.lua
-- against a real AceDB (#77). What this file pins is the other half of the
-- same property: nothing advances the version except the migration that
-- earned it.
--
-- Three places write schemaVersion.
--
--   1. The ladder. MigrateAllGuilds (src/Core.lua:1607) calls eleven
--      migrations in order, ten of which bump by one rung. Every gate below 9
--      is the loose `>= N` form, so what keeps a guild from skipping rungs is
--      the CALL ORDER, not the gates; the tests here assert that order
--      directly rather than the endpoint, because a guild that jumped
--      straight to 11 also arrives at 11.
--
--   2. The two strict gates. MigrateNormalizeStoredRealms is `~= 9`
--      (src/Core.lua:1422) and MigrateRecoverPeerRealms is `~= 10` (:1530),
--      because MigrateNormalizePeerNames short-circuits on cold realm APIs
--      and leaves the guild at 8; a loose gate there would let 10 or 11 be
--      reached from 8 and strand the 8 -> 9 work for good. spec/core_spec.lua
--      already pins the low side: each carries a "refuses to bump from schema
--      8", and MigrateRecoverPeerRealms also carries a "refuses to bump from
--      schema 9" (:1344). What nothing covered is the side ABOVE the gate, a
--      guild already at 11, which is what this file adds.
--
--   3. DeduplicateRecords (src/Core.lua:2846), which writes the version
--      outside the ladder to force the legacy cross-slot pass. It had no
--      coverage of that write at all before this file: every case in
--      spec/data_integrity_spec.lua's DeduplicateRecords describe sets a
--      version at or above 6, which is the branch that does not run. The
--      cases here are characterization and say so in their names, because
--      what they record is a defect (the restore line cannot fire, and it
--      raises on a nil), filed as #263 rather than fixed here.
--
-- MigrateCrossSlotDedup writes the version a fourth time, inside itself, and
-- that one is deliberate: see its describe below.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- The call order in MigrateAllGuilds, with the version each migration must be
-- entered at and the version it must leave. MigrateSortAccessShape is in the
-- list deliberately: it is called between rungs 8 and 9 and writes no version
-- at all, so a future edit giving it one shows up here as a changed ladder
-- rather than as nothing.
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
    end)

    -- Wraps every migration MigrateAllGuilds calls, records the version each
    -- saw on the way in and left on the way out, and hands back the sequence.
    -- Recording the sequence is the whole point: the endpoint alone cannot
    -- tell a walk from a jump.
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
                -- No pcall around this: depth is local to one walk() call and
                -- a migration that throws fails the test outright, so there is
                -- nothing to keep balanced and a pcall would only flatten the
                -- callee's return values.
                depth = depth + 1
                local result = originals[name](self, gd)
                depth = depth - 1
                if entry then entry.after = gd.schemaVersion end
                return result
            end
        end

        GBL:MigrateAllGuilds()

        for name, fn in pairs(originals) do GBL[name] = fn end
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

        it("enters every migration at the version its predecessor left", function()
            -- Stated separately from the sequence compare above because this is
            -- the property the loose `>= N` gates rely on and do not enforce:
            -- each one is only safe because nothing calls it before the one
            -- below it has run.
            guildData.schemaVersion = 1

            local seen = walk()
            assert.equals(#LADDER, #seen)
            local version = 1
            for i, entry in ipairs(seen) do
                assert.equals(version, entry.before,
                    string.format("rung %d (%s) was entered at %s, expected %d",
                        i, entry.name, tostring(entry.before), version))
                version = entry.after
            end
            assert.equals(11, version)
        end)

        it("is a no-op for a guild already at 11", function()
            guildData.schemaVersion = 11

            local seen = walk()
            assert.equals(#LADDER, #seen)
            for _, entry in ipairs(seen) do
                assert.equals(11, entry.before, entry.name .. " saw a version below 11")
                assert.equals(11, entry.after, entry.name .. " moved a guild already at 11")
            end
            assert.equals(11, guildData.schemaVersion)
        end)
    end)

    ---------------------------------------------------------------------------
    -- 2. The strict gates, from above. The low side is already covered in
    --    spec/core_spec.lua, which is why neither of these sets 8 or 9.
    ---------------------------------------------------------------------------

    describe("the strict gates", function()
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
            -- Its gate is `>= 9` (src/Core.lua:1360), not the `~= 8` its two
            -- successors use, so on its own it will advance any guild below 9
            -- and the 4 to 8 work is skipped. Nothing in production calls it
            -- that way: MigrateAllGuilds reaches it only at 8, which the ladder
            -- tests above assert. Recorded rather than blessed, so that if the
            -- gate is ever tightened this case is the one that has to change.
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
    -- 5. DeduplicateRecords, the write outside the ladder
    ---------------------------------------------------------------------------

    describe("DeduplicateRecords writes the version outside the ladder", function()
        it("leaves a guild below 6 at 6 rather than restoring it (characterization)", function()
            -- src/Core.lua:2851-2857 sets the version to 5 to force the legacy
            -- cross-slot pass, then restores it only `if savedSchema > 6`. The
            -- branch is entered only when the version is below 6, so the
            -- restore cannot fire on any path into it, and MigrateCrossSlotDedup
            -- leaves the guild at 6 on its way out. A guild at 5 is therefore
            -- advanced past migrations for the same reason this whole file
            -- exists. Unreachable in production, because OnInitialize runs
            -- MigrateAllGuilds (:197) before it loops DeduplicateRecords
            -- (:204); recorded here so a fix or a deletion is visible in a
            -- diff. Filed as #263.
            guildData.schemaVersion = 5

            GBL:DeduplicateRecords(guildData)

            assert.equals(6, guildData.schemaVersion)
        end)

        it("raises on a guild whose schemaVersion is nil (characterization)", function()
            -- The gate reads `(guildData.schemaVersion or 0)` and the restore
            -- compares the raw value, so a nil gets into the branch and then
            -- into a numeric compare. AceDB puts the default back for any guild
            -- whose key was stripped, so this needs a guild table that never
            -- came from GetGuildData. Filed as #263 with the case above.
            guildData.schemaVersion = nil

            local ok, err = pcall(function() return GBL:DeduplicateRecords(guildData) end)

            assert.is_false(ok)
            assert.is_truthy(tostring(err):match("attempt to compare"))
        end)
    end)
end)
