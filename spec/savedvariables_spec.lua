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
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

-- Sorted, so a failure prints a readable diff rather than a pairs-order jumble.
local function sortedKeys(t)
    local keys = {}
    if type(t) == "table" then
        for k in pairs(t) do keys[#keys + 1] = tostring(k) end
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
end)
