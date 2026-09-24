------------------------------------------------------------------------
-- savedvariables_spec.lua — what actually reaches the SavedVariables file.
--
-- docs/DATA-MODEL.md section 2 rests on one AceDB behaviour: a value equal to
-- its default is stripped before the file is written, so absence from the file
-- means "never diverged from the default" rather than "missing". That single
-- fact explains the five declared-and-absent keys, decides what #71 does about
-- eventCounts, and is why raising the schemaVersion default would strand guilds
-- past migrations 9 to 11 (#76).
--
-- None of it was executable before #77: spec/mock_ace.lua modelled a login
-- (copyDefaults) and never a logout (removeDefaults), so every claim in that
-- section rested on reading library source.
--
-- The whole point is that this file asserts the DOCUMENT. When a key is added
-- to or removed from the defaults block in src/Core.lua, the counts below move
-- and section 2 has to move with them.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local Vendor = require("spec.vendor_helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

-- A REAL AceDB, to pin the mock port against. Six of these shims are globals
-- AceDB reads once at load to build its profile keys, which this addon never
-- uses: it keys by guild under `global`. CreateFrame is the seventh, because
-- AceDB owns one frame solely to catch PLAYER_LOGOUT and mock_wow frames have
-- no RegisterEvent. Same rule as wire_helpers and strmatch: a global a
-- vendored library needs at load and production never reads is shimmed for
-- the load and restored, rather than becoming a permanent entry in mock_wow,
-- which exists to describe the client the addon actually talks to.
local RealAceDB = Vendor.loadVendored(
    { "LibStub.lua", "AceDB-3.0.lua" },
    "AceDB-3.0",
    {
        GetRealmName = function() return "TestRealm" end,
        UnitName = function() return "Tester" end,
        UnitClass = function() return "Warrior", "WARRIOR" end,
        UnitRace = function() return "Human", "Human" end,
        UnitFactionGroup = function() return "Alliance" end,
        GetLocale = function() return "enUS" end,
        GetCurrentRegion = function() return 1 end,
        GetCurrentRegionName = function() return "US" end,
        CreateFrame = function()
            return {
                RegisterEvent = function() end,
                UnregisterEvent = function() end,
                SetScript = function() end,
            }
        end,
    }
)

-- Sorted, so a failure prints a readable diff rather than a pairs-order jumble.
-- A non-string key renders bracketed, because this codebase treats the
-- number-versus-string distinction as load-bearing (a synced layout arrives
-- string-keyed and src/Restock.lua number-coerces it back), and a plain
-- tostring would let a case pass under either shape.
local function sortedKeys(t)
    local keys = {}
    if type(t) == "table" then
        for k in pairs(t) do
            keys[#keys + 1] = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        end
    end
    table.sort(keys)
    return keys
end

-- Every key declared under guilds["*"] in src/Core.lua. Seventeen.
local DECLARED = {
    "accessControl", "altLinks", "bankLayout", "knownPeers", "moneyTransactions",
    "playerRealms", "playerStats", "restock", "schemaVersion", "seenTxHashes",
    "snapshots", "sortAccess", "stockAlerts", "stockReserves", "syncState",
    "teams", "transactions",
}
table.sort(DECLARED)  -- compared against sortedKeys, so the order is the mechanism

-- Section 2's "declared but absent, and why that is normal" table. Five.
-- dailySummaries and weeklySummaries left this list when #62 removed the tiered
-- storage module along with their declarations.
local ABSENT_WHEN_UNTOUCHED = {
    "altLinks", "restock", "snapshots", "stockAlerts", "teams",
}

-- The twelve declared keys section 2 lists as reaching disk. The thirteenth,
-- eventCounts, is undeclared and has its own describe below.
local SURVIVES_WHEN_DIVERGED = {
    { key = "accessControl", diverge = function(g) g.accessControl.configuredAt = 500 end },
    { key = "bankLayout", diverge = function(g) g.bankLayout.version = 2 end },
    { key = "knownPeers", diverge = function(g) g.knownPeers["Bob-Realm"] = { txCount = 1 } end },
    { key = "moneyTransactions", diverge = function(g) g.moneyTransactions[1] = { id = "m:0" } end },
    { key = "playerRealms", diverge = function(g) g.playerRealms["Bob"] = "Realm" end },
    { key = "playerStats", diverge = function(g) g.playerStats["Bob-Realm"].totalDepositCount = 3 end },
    { key = "schemaVersion", diverge = function(g) g.schemaVersion = 11 end },
    { key = "seenTxHashes", diverge = function(g) g.seenTxHashes["h:0"] = 1700000000 end },
    { key = "sortAccess", diverge = function(g) g.sortAccess.updatedAt = 500 end },
    { key = "stockReserves", diverge = function(g) g.stockReserves[12345] = 20 end },
    { key = "syncState", diverge = function(g) g.syncState.lastSyncTimestamp = 500 end },
    { key = "transactions", diverge = function(g) g.transactions[1] = { id = "t:0" } end },
}

describe("SavedVariables", function()
    local GBL, db

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "TestGuild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        db = MockAce.dbInstance
    end)

    -- The guild table as it exists in the file after a logout, read with rawget
    -- throughout: indexing would go through a wildcard metatable and could
    -- recreate the very key under test.
    local function diskGuild(name)
        local guilds = rawget(db.global, "guilds")
        if not guilds then return nil end
        return rawget(guilds, name or "TestGuild")
    end

    ---------------------------------------------------------------------------
    -- The defaults block itself
    ---------------------------------------------------------------------------

    describe("the declared shape", function()
        it("declares exactly the seventeen keys section 2 accounts for", function()
            local guild = db.global.guilds["TestGuild"]
            assert.same(DECLARED, sortedKeys(guild))
        end)

        it("accounts for every declared key as either absent or surviving", function()
            -- 5 + 12 = 17. This is the arithmetic section 2 turns on, and it is
            -- what catches a key added to the defaults block and to neither list.
            local accounted = {}
            for _, k in ipairs(ABSENT_WHEN_UNTOUCHED) do accounted[#accounted + 1] = k end
            for _, entry in ipairs(SURVIVES_WHEN_DIVERGED) do accounted[#accounted + 1] = entry.key end
            table.sort(accounted)
            assert.same(DECLARED, accounted)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Stripping
    ---------------------------------------------------------------------------

    describe("the logout strip", function()
        it("leaves nothing behind for a guild that was only ever read", function()
            local _ = db.global.guilds["TestGuild"]
            db:_simulateLogout()
            assert.is_nil(diskGuild())
        end)

        it("keeps a guild that diverged in one key, and only that key", function()
            db.global.guilds["TestGuild"].schemaVersion = 11
            db:_simulateLogout()

            local guild = diskGuild()
            assert.is_not_nil(guild)
            assert.same({ "schemaVersion" }, sortedKeys(guild))
            assert.equals(11, guild.schemaVersion)
        end)

        it("strips the five keys section 2 records as declared and absent", function()
            -- Touched only by being read, which is what a real client does on
            -- every login, so this is the ordinary case rather than a corner.
            local guild = db.global.guilds["TestGuild"]
            for _, key in ipairs(ABSENT_WHEN_UNTOUCHED) do
                local _ = guild[key]
            end
            guild.schemaVersion = 11  -- so the guild itself survives
            db:_simulateLogout()

            for _, key in ipairs(ABSENT_WHEN_UNTOUCHED) do
                assert.is_nil(rawget(diskGuild(), key), key .. " should not reach disk")
            end
        end)

        for _, entry in ipairs(SURVIVES_WHEN_DIVERGED) do
            it("keeps " .. entry.key .. " once it has diverged", function()
                entry.diverge(db.global.guilds["TestGuild"])
                db:_simulateLogout()

                local guild = diskGuild()
                assert.is_not_nil(guild, "the guild itself was stripped")
                assert.is_not_nil(rawget(guild, entry.key), entry.key .. " should reach disk")
            end)
        end
    end)

    ---------------------------------------------------------------------------
    -- Collapse, which is the part that reads like data loss and is not
    ---------------------------------------------------------------------------

    describe("empty-table collapse", function()
        it("collapses restock bottom up, subtables first", function()
            -- restock = { items = {}, budget = 0, pending = {} }. Reading any of
            -- it must leave nothing, or the key stops meaning "never used".
            local guild = db.global.guilds["TestGuild"]
            local _ = guild.restock.items
            local _ = guild.restock.pending
            assert.equals(0, guild.restock.budget)
            guild.schemaVersion = 11

            db:_simulateLogout()
            assert.is_nil(rawget(diskGuild(), "restock"))
        end)

        it("strips a player who only ever held defaults", function()
            -- Every playerStats field defaults to zero or an empty table, so a
            -- player with no activity leaves no trace. That looks like data
            -- loss and is not: UpdatePlayerStats vivifies the entry again on
            -- next use.
            local guild = db.global.guilds["TestGuild"]
            local _ = guild.playerStats["Ghost-Realm"]
            guild.playerStats["Alice-Realm"].totalDepositCount = 2

            db:_simulateLogout()

            local stats = rawget(diskGuild(), "playerStats")
            assert.same({ "Alice-Realm" }, sortedKeys(stats))
        end)

        it("keeps only the diverged field of a player who has one", function()
            db.global.guilds["TestGuild"].playerStats["Alice-Realm"].totalDepositCount = 2
            db:_simulateLogout()

            local alice = rawget(diskGuild(), "playerStats")["Alice-Realm"]
            assert.same({ "totalDepositCount" }, sortedKeys(alice))
        end)
    end)

    ---------------------------------------------------------------------------
    -- eventCounts: the reverse case, and the one #71 changes
    ---------------------------------------------------------------------------

    describe("eventCounts", function()
        it("survives the strip even when empty, because it is undeclared", function()
            -- An undeclared key is never subject to default stripping, so it is
            -- written out verbatim. Declaring it (#71) changes exactly this, and
            -- this assertion is what will have to be rewritten when it does.
            local guild = db.global.guilds["TestGuild"]
            guild.eventCounts = {}
            guild.schemaVersion = 11

            db:_simulateLogout()
            assert.is_not_nil(rawget(diskGuild(), "eventCounts"))
        end)

        it("is not in the declared set", function()
            assert.is_nil(rawget(db.global.guilds["TestGuild"], "eventCounts"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- The schemaVersion tripwire (#76) made executable
    ---------------------------------------------------------------------------

    describe("schemaVersion", function()
        it("is stripped at the default and reads the default again after a login", function()
            -- This is why the default IS the stored version of every guild
            -- sitting at it, and why raising it would strand those guilds past
            -- migrations 9 to 11 rather than migrating them.
            local guild = db.global.guilds["TestGuild"]
            assert.equals(8, guild.schemaVersion)
            guild.transactions[1] = { id = "t:0" }  -- so the guild survives

            db:_simulateLogout()
            assert.is_nil(rawget(diskGuild(), "schemaVersion"))

            db:_simulateLogin()
            assert.equals(8, db.global.guilds["TestGuild"].schemaVersion)
        end)

        it("survives once a migration has moved it past the default", function()
            db.global.guilds["TestGuild"].schemaVersion = 11
            db:_simulateLogout()
            assert.equals(11, rawget(diskGuild(), "schemaVersion"))

            db:_simulateLogin()
            assert.equals(11, db.global.guilds["TestGuild"].schemaVersion)
        end)
    end)

    ---------------------------------------------------------------------------
    -- The metatable clear, which is load-bearing for these specs and not only
    -- for the library
    ---------------------------------------------------------------------------

    describe("the metatable clear", function()
        it("does not recreate a guild when the stripped file is read back", function()
            -- removeDefaults opens with setmetatable(db, nil) precisely so the
            -- walk cannot create subtables through the wildcard it is stripping.
            -- Without it, reading the on-disk image is enough to repopulate it,
            -- and every absence assertion above passes for the wrong reason.
            db.global.guilds["TestGuild"].schemaVersion = 11
            db:_simulateLogout()

            local _ = rawget(db.global, "guilds")["SomeoneElse"]
            assert.same({ "TestGuild" }, sortedKeys(rawget(db.global, "guilds")))
        end)

        it("does not recreate a player when the stripped file is read back", function()
            db.global.guilds["TestGuild"].playerStats["Alice-Realm"].totalDepositCount = 2
            db:_simulateLogout()

            local stats = rawget(diskGuild(), "playerStats")
            local _ = stats["Nobody-Realm"]
            assert.same({ "Alice-Realm" }, sortedKeys(stats))
        end)
    end)

    ---------------------------------------------------------------------------
    -- The read path, against the library it stands in for
    ---------------------------------------------------------------------------

    describe("wildcard vivification", function()
        it("creates a table with no literal wildcard key in it", function()
            -- The mock built a vivified table by deep-copying the template,
            -- which copies the literal "*" key along with everything else.
            -- copyDefaults starts from an empty table, so a real client's
            -- playerStats is empty here and the suite's held one phantom
            -- player. Seven production sites walk this table with pairs, four
            -- of them inside migrations, and two resolve every name they find
            -- and write it back (src/Core.lua:761 in MigrateSchemaV2ToV3, and
            -- :1704 in RepairPlayerNames, which is not a migration). So one
            -- migration was storing a resolved player no client can have.
            local stats = db.global.guilds["TestGuild"].playerStats
            assert.same({}, sortedKeys(stats))
            assert.is_nil(rawget(stats, "*"))
        end)

        it("re-applies the template to a guild already in the file", function()
            -- copyDefaults has a second loop for tables already present in
            -- the SavedVariables, which the mock never had, so it modelled a
            -- fresh install and never an upgrade. Every migration spec in the
            -- suite runs against the shape this produces.
            db.global.guilds["TestGuild"].schemaVersion = 11
            db:_simulateLogout()
            db:_simulateLogin()

            local guild = db.global.guilds["TestGuild"]
            assert.same(DECLARED, sortedKeys(guild))
            assert.equals(11, guild.schemaVersion)
            assert.is_table(guild.transactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Branches this addon's defaults cannot reach, ported anyway
    --
    -- GBL declares two "*" table wildcards and no "**", no scalar wildcard and
    -- nothing that passes a blocker. Those branches are transcribed from the
    -- library all the same, because porting only the reachable half is how the
    -- mock came to model a login and never a logout. Synthetic defaults here,
    -- so a future defaults block that does reach them finds them working.
    ---------------------------------------------------------------------------

    describe("wildcard forms GBL does not use", function()
        -- Build the same synthetic defaults on BOTH implementations.
        --
        -- The first cut of these cases resolved `_G.LibStub("AceDB-3.0")`,
        -- which at test time is the mock, so they asserted the port against
        -- hand-written expectations. That is the self-agreement this file
        -- exists to reject, and it landed on exactly the branches the
        -- production differential below cannot reach, since GBL declares no
        -- "**", no scalar wildcard and passes no blocker. Found by the code
        -- review of this PR.
        --
        -- createAceDB claims MockAce.dbInstance unconditionally, which the
        -- repo CLAUDE.md names as breaking the single-instance assumption, so
        -- the slot is put back.
        local function bothSynthetic(defaults)
            local savedInstance = MockAce.dbInstance
            local mine = _G.LibStub("AceDB-3.0"):New("SyntheticDB", defaults)
            MockAce.dbInstance = savedInstance

            local sv = {}
            local theirs = RealAceDB:New(sv, defaults)
            return mine, theirs, sv
        end

        -- Run a script on both, strip both, hand back the two on-disk images.
        local function stripBoth(defaults, script)
            local mine, theirs, sv = bothSynthetic(defaults)
            script(mine.global)
            script(theirs.global)
            mine:_simulateLogout()
            theirs:RegisterDefaults(nil)
            return mine.global, sv.global
        end

        it("serves a scalar wildcard without storing it", function()
            local mine, theirs = bothSynthetic({ global = { limits = { ["*"] = 7 } } })
            assert.equals(7, mine.global.limits.anything)
            assert.same({}, sortedKeys(mine.global.limits))
            assert.equals(theirs.global.limits.anything, mine.global.limits.anything)
            assert.same(sortedKeys(theirs.global.limits), sortedKeys(mine.global.limits))
        end)

        it("answers a nil key with nil rather than vivifying", function()
            local mine, theirs = bothSynthetic({
                global = { bags = { ["*"] = { size = 0 } } },
            })
            assert.is_nil(mine.global.bags[nil])
            assert.is_nil(theirs.global.bags[nil])
        end)

        it("answers a nil key with nil for a scalar wildcard too", function()
            -- The table wildcard and the scalar wildcard each have their own
            -- nil guard in the library, and only the first had a case here.
            local mine, theirs = bothSynthetic({ global = { limits = { ["*"] = 7 } } })
            assert.is_nil(mine.global.limits[nil])
            assert.is_nil(theirs.global.limits[nil])
        end)

        it("merges a ** template into every named sibling", function()
            local mine, theirs = bothSynthetic({
                global = {
                    tabs = {
                        ["**"] = { shared = true },
                        named = { own = 1 },
                    },
                },
            })
            assert.is_true(mine.global.tabs.named.shared)
            assert.equals(1, mine.global.tabs.named.own)
            assert.equals(theirs.global.tabs.named.shared, mine.global.tabs.named.shared)
            assert.equals(theirs.global.tabs.named.own, mine.global.tabs.named.own)
        end)

        it("strips a scalar wildcard value that never diverged", function()
            local mine, theirs = stripBoth(
                { global = { limits = { ["*"] = 7 } } },
                function(g)
                    g.limits.a = 7   -- equals the wildcard default
                    g.limits.b = 9   -- does not
                end
            )
            assert.same({ "b" }, sortedKeys(rawget(mine, "limits")))
            assert.same(theirs, mine)
        end)

        it("strips ** content from a named key that has no say in it", function()
            local mine, theirs = stripBoth(
                {
                    global = {
                        tabs = {
                            ["**"] = { shared = true },
                            named = { own = 1 },
                        },
                    },
                },
                function(g)
                    local _ = g.tabs.named.shared
                    g.tabs.named.extra = 2
                end
            )
            local named = rawget(rawget(mine, "tabs"), "named")
            assert.is_nil(rawget(named, "shared"))
            assert.equals(2, named.extra)
            assert.same(theirs, mine)
        end)

        it("blocks the ** strip for a key the named table declares itself", function()
            -- The blocker exists for exactly one arrangement, and a fixture
            -- without it cannot see the argument at all: the value has to
            -- EQUAL the ** default, so the ** pass wants to strip it, and
            -- DIFFER from the named key own default, so the later named pass
            -- leaves it alone. With `named = { own = 1 }` and a ** template of
            -- `{ shared = true }` no key is in both, blocker[k] is nil every
            -- time, and dropping the whole term changes nothing.
            local mine, theirs = stripBoth(
                {
                    global = {
                        tabs = {
                            ["**"] = { shared = true },
                            named = { shared = false, own = 1 },
                        },
                    },
                },
                function(g)
                    assert.is_false(g.tabs.named.shared)
                    g.tabs.named.shared = true
                end
            )
            -- Checked in steps: without the blocker the ** pass strips shared,
            -- the named pass then strips own, and the empty table collapses, so
            -- a single chained read would raise instead of reporting.
            local tabs = rawget(mine, "tabs")
            assert.is_not_nil(tabs, "tabs collapsed")
            local named = rawget(tabs, "named")
            assert.is_not_nil(named, "named collapsed: the ** strip was not blocked")
            assert.is_true(rawget(named, "shared"))
            assert.same(theirs, mine)
        end)

        it("blocks the ** strip inside a nested wildcard template", function()
            -- removeDefaults carries the blocker term TWICE, once in the
            -- scalar compare and once in the table branch, and the case above
            -- only reaches the first. The second needs a ** template that
            -- itself declares a wildcard, so the recursion enters the table
            -- branch with a blocker in hand. Same observability rule: the
            -- value equals the wildcard default and differs from the named
            -- key own default, so only the blocker decides.
            local mine, theirs = stripBoth(
                {
                    global = {
                        tabs = {
                            ["**"] = { ["*"] = { n = 0 } },
                            named = { special = { n = 7 } },
                        },
                    },
                },
                function(g)
                    assert.equals(7, g.tabs.named.special.n)
                    g.tabs.named.special.n = 0
                end
            )
            local tabs = rawget(mine, "tabs")
            assert.is_not_nil(tabs, "tabs collapsed")
            local named = rawget(tabs, "named")
            assert.is_not_nil(named, "named collapsed")
            local special = rawget(named, "special")
            assert.is_not_nil(special, "special collapsed: the nested ** strip was not blocked")
            assert.equals(0, rawget(special, "n"))
            assert.same(theirs, mine)
        end)
    end)

    ---------------------------------------------------------------------------
    -- The profile section
    ---------------------------------------------------------------------------

    describe("the profile half", function()
        -- Asserted against the port alone, and this says so rather than
        -- implying the differential covers it. A real AceDB keeps the profile
        -- at `sv.profiles[<profile key>]` and this mock has no profile system
        -- at all, so the two have no comparable shape. `_simulateLogout` and
        -- `_simulateLogin` both walk `defaults.profile`, which is where `ui`,
        -- `scanning`, `sync`, `sort` and `restock` live, so it needed saying.
        it("strips a profile value that never diverged", function()
            db.profile.ui.scale = 2.0
            db:_simulateLogout()

            local ui = rawget(db.profile, "ui")
            assert.is_not_nil(ui, "the whole ui table collapsed")
            assert.equals(2.0, rawget(ui, "scale"))
            assert.is_nil(rawget(ui, "width"), "an untouched profile default reached disk")
        end)

        it("puts profile defaults back at the next login", function()
            db.profile.ui.scale = 2.0
            db:_simulateLogout()
            db:_simulateLogin()

            assert.equals(2.0, db.profile.ui.scale)
            assert.equals(1000, db.profile.ui.width)
        end)
    end)

    ---------------------------------------------------------------------------
    -- The differential: this mock against the library it stands in for
    --
    -- Everything above asserts section 2 against the port in spec/mock_ace.lua.
    -- A port can only ever agree with itself, and what section 2 is accused of
    -- is resting on a reading of AceDB rather than on anything executable, so
    -- a port trusted on its own reproduces that defect one level down. These
    -- cases hand the SAME defaults table to a real AceDB and compare the file
    -- each one leaves behind.
    --
    -- RegisterDefaults(nil) is the public seam onto removeDefaults: copyDefaults
    -- and removeDefaults are both file-locals and cannot be called directly.
    --
    -- What it cannot see: luassert compares tables with metatables ignored, so
    -- a mock that left a live wildcard metatable on a stripped table would
    -- agree here. That is what the dedicated "metatable clear" describe above
    -- is for, and why this is not a diff of the whole function.
    ---------------------------------------------------------------------------

    describe("against a real AceDB", function()
        -- Both sides are built the same way, from the addon own defaults table
        -- read off the mock instance. An earlier cut compared the instance that
        -- OnInitialize had already driven against a freshly built real one,
        -- which balances only while OnInitialize writes nothing under global:
        -- one migration run at init, or RecordOwnCharacter firing earlier, and
        -- all eight cases red while the port is correct. Found by the code
        -- review of this PR.
        local function bothImages(script)
            local defaults = db._defaults

            local savedInstance = MockAce.dbInstance
            local mine = _G.LibStub("AceDB-3.0"):New("GuildBankLedgerDB", defaults)
            MockAce.dbInstance = savedInstance

            script(mine.global.guilds["TestGuild"])
            mine:_simulateLogout()

            local sv = {}
            local theirs = RealAceDB:New(sv, defaults)
            script(theirs.global.guilds["TestGuild"])
            theirs:RegisterDefaults(nil)

            return mine.global, sv.global
        end

        it("agrees on a guild that was only ever read", function()
            local mine, theirs = bothImages(function() end)
            assert.same(theirs, mine)
        end)

        it("agrees on a guild that diverged in one scalar", function()
            local mine, theirs = bothImages(function(g) g.schemaVersion = 11 end)
            assert.same(theirs, mine)
        end)

        it("agrees on a player with one diverged field", function()
            local mine, theirs = bothImages(function(g)
                g.playerStats["Alice-Realm"].totalDepositCount = 2
            end)
            assert.same(theirs, mine)
        end)

        it("agrees on a player who only ever held defaults", function()
            local mine, theirs = bothImages(function(g)
                local _ = g.playerStats["Ghost-Realm"]
                g.schemaVersion = 11
            end)
            assert.same(theirs, mine)
        end)

        it("agrees on the five declared-and-absent keys after a read", function()
            local mine, theirs = bothImages(function(g)
                for _, key in ipairs(ABSENT_WHEN_UNTOUCHED) do
                    local _ = g[key]
                end
                g.schemaVersion = 11
            end)
            assert.same(theirs, mine)
        end)

        it("agrees when every declared key has diverged at once", function()
            local mine, theirs = bothImages(function(g)
                for _, entry in ipairs(SURVIVES_WHEN_DIVERGED) do
                    entry.diverge(g)
                end
            end)
            assert.same(theirs, mine)
        end)

        it("agrees that an undeclared key survives the strip", function()
            local mine, theirs = bothImages(function(g)
                g.eventCounts = {}
                g.schemaVersion = 11
            end)
            assert.same(theirs, mine)
        end)

        it("agrees on what a fresh vivification contains", function()
            local savedInstance = MockAce.dbInstance
            local mine = _G.LibStub("AceDB-3.0"):New("GuildBankLedgerDB", db._defaults)
            MockAce.dbInstance = savedInstance

            local sv = {}
            local theirs = RealAceDB:New(sv, db._defaults)

            assert.same(
                sortedKeys(theirs.global.guilds["TestGuild"]),
                sortedKeys(mine.global.guilds["TestGuild"])
            )
            assert.same(
                sortedKeys(theirs.global.guilds["TestGuild"].playerStats),
                sortedKeys(mine.global.guilds["TestGuild"].playerStats)
            )
        end)
    end)
end)
