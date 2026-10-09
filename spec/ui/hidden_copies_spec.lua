------------------------------------------------------------------------
-- hidden_copies_spec.lua - the history tabs leave out the proven copies (#346)
--
-- GBL:MoneyScanCopies names the money records sync carried back to the
-- scan of this account's that minted them (spec/money_scan_copies_spec.lua).
-- RecordsForView, the one place a tab's rows are decided, leaves them out,
-- so the Gold log and the Consumption tab count each such transaction once
-- under every filter. The records stay stored. The Gold log's count line
-- says how many it left out under the filters in force, so a missing row
-- is never silent.
--
-- At full access RecordsForView used to hand the renderer the live money
-- table; with a copy to leave out it hands a fresh array per render. That
-- is the switch that left eight filter callbacks rendering from a stale
-- capture on #222 (lessons, 2026-09-22), so the cases that drive a filter
-- and a sort header after a refresh run here at full access as well.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local HOUR = 3600
local ME = "TestOfficer-TestRealm"
local DEPOSITOR = "Katorri-TestRealm"
local FOREIGN = "Fluphie-TestRealm"

describe("History tabs leave out the proven money copies (#346)", function()
    local GBL, gd, S, T

    local function money(opts)
        local rec = {
            type = opts.type or "deposit",
            player = opts.player or DEPOSITOR,
            amount = opts.amount or 50000,
            timestamp = opts.timestamp or T,
            scanTime = opts.scanTime,
            scannedBy = opts.scannedBy,
        }
        rec._occurrence = opts.occ or 0
        rec.id = GBL:ComputeTxHash(rec) .. ":" .. rec._occurrence
        return rec
    end

    -- This account's scan of a transaction, two hours after it.
    local function mine(opts)
        opts = opts or {}
        opts.scannedBy = opts.scannedBy or ME
        opts.scanTime = opts.scanTime or (opts.timestamp or T) + 2 * HOUR
        return money(opts)
    end

    -- The same record carried back by a peer four hours later, numbered :1.
    local function echo(opts)
        opts = opts or {}
        opts.scannedBy = opts.scannedBy or "sync:Flameus-TestRealm"
        opts.scanTime = opts.scanTime or (opts.timestamp or T) + 6 * HOUR
        opts.occ = opts.occ or 1
        return money(opts)
    end

    local function item(player, offsetHours)
        local rec = {
            type = "deposit", player = player, itemID = 111, itemLink = "[Test Item]",
            count = 1, tab = 1, timestamp = S - offsetHours * HOUR,
            scanTime = S, scannedBy = ME,
        }
        rec._occurrence = 0
        rec.id = GBL:ComputeTxHash(rec) .. ":0"
        return rec
    end

    local function store(list, ...)
        for _, rec in ipairs({ ... }) do
            table.insert(gd[list], rec)
            gd.seenTxHashes[rec.id] = rec.timestamp
        end
    end

    local function holds(records, rec)
        for _, r in ipairs(records or {}) do
            if r == rec then return true end
        end
        return false
    end

    -- Every label text rendered under a node, at any depth.
    local function renderedLabels(node, seen)
        seen = seen or {}
        for _, c in ipairs(node._children or {}) do
            if c._type == "Label" and c._text then seen[c._text] = true end
            renderedLabels(c, seen)
        end
        return seen
    end

    local function anyLabelContains(text)
        for label in pairs(renderedLabels(GBL.tabGroup)) do
            if label:find(text, 1, true) then return true end
        end
        return false
    end

    local function findWidget(node, wtype, label)
        for _, c in ipairs(node._children or {}) do
            if c._type == wtype and (label == nil or c._label == label) then return c end
            local nested = findWidget(c, wtype, label)
            if nested then return nested end
        end
        return nil
    end

    -- Capture the array a render is handed while `drive` runs.
    local function handedTo(method, drive)
        local handed
        local orig = GBL[method]
        GBL[method] = function(self, c, records, filters)
            handed = records
            return orig(self, c, records, filters)
        end
        drive()
        GBL[method] = orig
        return handed
    end

    local own, copy, other

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.player.name = "TestOfficer"
        MockWoW.player.realm = "TestRealm"
        GBL:OnEnable()
        S = MockWoW.serverTime
        T = S - 10 * HOUR - 17

        gd = GBL:GetGuildData()
        gd.playerRealms = { TestOfficer = "TestRealm" }
        gd.eventCounts = {}
        gd.transactions = {}
        gd.moneyTransactions = {}
        GBL.db.global.characters = { [ME] = S }

        own, copy = mine(), echo()
        other = money({
            player = FOREIGN, amount = 70000, timestamp = S - 1800,
            scanTime = S, scannedBy = ME,
        })
        store("moneyTransactions", own, copy, other)
        store("transactions", item(ME, 3))
    end)

    ---------------------------------------------------------------------------
    -- RecordsForView
    ---------------------------------------------------------------------------

    describe("RecordsForView", function()
        it("leaves the copy out of the money rows at full access, and the store holds it", function()
            local tx, rows = GBL:RecordsForView(gd)

            assert.equals(2, #rows)
            assert.is_true(holds(rows, own))
            assert.is_true(holds(rows, other))
            assert.is_false(holds(rows, copy))
            assert.equals(gd.transactions, tx)
            assert.equals(3, #gd.moneyTransactions)
            assert.equals(copy, gd.moneyTransactions[2])
            assert.is_not_nil(gd.seenTxHashes[copy.id])
        end)

        it("keeps the records it left out for the Gold log", function()
            GBL:RecordsForView(gd)

            local hidden = GBL._hiddenMoneyCopies
            assert.equals(1, #hidden)
            assert.equals(copy, hidden[1])
        end)

        it("leaves the copies out of a member's own rows, and keeps only the member's", function()
            MockWoW.guild.rankIndex = 5
            gd.accessControl = { rankThreshold = 3, restrictedMode = "own_transactions" }
            local T3 = S - 20 * HOUR - 41
            local mineToo = mine({ player = ME, timestamp = T3 })
            local copyToo = echo({ player = ME, timestamp = T3 })
            store("moneyTransactions", mineToo, copyToo)

            local _, rows = GBL:RecordsForView(gd)

            assert.equals(1, #rows)
            assert.equals(mineToo, rows[1])
            local hidden = GBL._hiddenMoneyCopies
            assert.equals(1, #hidden)
            assert.equals(copyToo, hidden[1])
        end)

        it("hands a sync_only client nothing, and nothing hidden", function()
            MockWoW.guild.rankIndex = 5
            gd.accessControl = { rankThreshold = 3, restrictedMode = "sync_only" }
            GBL._hiddenMoneyCopies = { copy }

            local tx, rows = GBL:RecordsForView(gd)

            assert.equals(0, #tx)
            assert.equals(0, #rows)
            assert.equals(0, #GBL._hiddenMoneyCopies)
        end)

        it("hands the live money table through when nothing is a copy", function()
            gd.moneyTransactions = { own, other }

            local _, rows = GBL:RecordsForView(gd)

            assert.equals(gd.moneyTransactions, rows)
            assert.equals(0, #GBL._hiddenMoneyCopies)
        end)
    end)

    ---------------------------------------------------------------------------
    -- The Gold log
    ---------------------------------------------------------------------------

    describe("the Gold log", function()
        local function openGoldLog(dateRange)
            GBL:CreateMainFrame()
            GBL:SelectTab("goldlog")
            GBL:RefreshUI()
            if dateRange then
                findWidget(GBL.tabGroup, "Dropdown", "Date Range"):Fire("OnValueChanged", dateRange)
            end
        end

        it("says on its count line how many duplicates it left out", function()
            openGoldLog()

            assert.is_true(renderedLabels(GBL.tabGroup)["2 gold transactions (1 duplicate hidden)"])
            assert.is_false(holds(GBL._goldLogTransactions, copy))
        end)

        it("counts in the plural", function()
            local T2 = S - 5 * HOUR - 29
            store("moneyTransactions", mine({ timestamp = T2 }), echo({ timestamp = T2 }))

            openGoldLog()

            assert.is_true(renderedLabels(GBL.tabGroup)["3 gold transactions (2 duplicates hidden)"])
        end)

        it("says nothing when nothing is left out", function()
            gd.moneyTransactions = { own, other }

            openGoldLog()

            assert.is_true(renderedLabels(GBL.tabGroup)["2 gold transactions"])
            assert.is_false(anyLabelContains("hidden"))
        end)

        it("counts only what the filters in force would show", function()
            -- The last hour holds the other member's deposit and not the copy.
            openGoldLog("1h")

            assert.is_true(renderedLabels(GBL.tabGroup)["1 gold transactions"])
            assert.is_false(anyLabelContains("hidden"))
        end)

        it("says it on the paged count line too", function()
            GBL.GOLD_LOG_PAGE_SIZE = 1

            openGoldLog()

            assert.is_true(renderedLabels(GBL.tabGroup)["Showing 1-1 of 2 gold transactions (1 duplicate hidden)"])
        end)

        it("counts a member's own copies only", function()
            MockWoW.guild.rankIndex = 5
            gd.accessControl = { rankThreshold = 3, restrictedMode = "own_transactions" }
            local T3 = S - 20 * HOUR - 41
            store("moneyTransactions", mine({ player = ME, timestamp = T3 }),
                echo({ player = ME, timestamp = T3 }))

            openGoldLog("all")

            assert.is_true(renderedLabels(GBL.tabGroup)["1 gold transactions (1 duplicate hidden)"])
        end)

        it("leaves the store as it was", function()
            local before = { gd.moneyTransactions[1], gd.moneyTransactions[2], gd.moneyTransactions[3] }

            openGoldLog("all")
            GBL:RefreshUI()

            assert.equals(3, #gd.moneyTransactions)
            for i, rec in ipairs(before) do assert.equals(rec, gd.moneyTransactions[i]) end
            assert.equals(copy.timestamp, gd.seenTxHashes[copy.id])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Controls after a refresh, at full access (lessons, 2026-09-22)
    ---------------------------------------------------------------------------

    describe("controls after a refresh", function()
        it("re-render the Gold log from the rows that arrived since the build, still without the copies", function()
            GBL:CreateMainFrame()
            GBL:SelectTab("goldlog")
            GBL:RefreshUI()

            local T2 = S - 20 * HOUR - 29
            local own2, copy2 = mine({ timestamp = T2 }), echo({ timestamp = T2 })
            local fresh = money({
                player = FOREIGN, amount = 90000, timestamp = S - 2 * HOUR,
                scanTime = S, scannedBy = ME,
            })
            store("moneyTransactions", own2, copy2, fresh)
            GBL:RefreshUI()

            local byDate = handedTo("RenderGoldLog", function()
                findWidget(GBL.tabGroup, "Dropdown", "Date Range"):Fire("OnValueChanged", "all")
            end)
            assert.is_true(holds(byDate, fresh))
            assert.is_true(holds(byDate, own2))
            assert.is_false(holds(byDate, copy2))
            assert.is_false(holds(byDate, copy))

            local bySort = handedTo("RenderGoldLog", function()
                findWidget(GBL.tabGroup, "InteractiveLabel"):Fire("OnClick")
            end)
            assert.is_true(holds(bySort, fresh))
            assert.is_false(holds(bySort, copy2))
            assert.is_true(renderedLabels(GBL.tabGroup)["4 gold transactions (2 duplicates hidden)"])
        end)

        it("re-render consumption from the rows that arrived since the build, still without the copies", function()
            GBL:CreateMainFrame()
            GBL:SelectTab("consumption")
            GBL:RefreshUI()

            local T2 = S - 20 * HOUR - 29
            local own2, copy2 = mine({ timestamp = T2 }), echo({ timestamp = T2 })
            local newItem = item(FOREIGN, 4)
            store("moneyTransactions", own2, copy2)
            store("transactions", newItem)
            GBL:RefreshUI()

            local handed = handedTo("RenderConsumptionDashboard", function()
                findWidget(GBL.tabGroup, "Dropdown", "Category"):Fire("OnValueChanged", "ALL")
            end)
            assert.is_true(holds(handed, newItem))
            assert.is_true(holds(handed, own2))
            assert.is_false(holds(handed, copy2))
            assert.is_false(holds(handed, copy))
        end)
    end)

    ---------------------------------------------------------------------------
    -- The Consumption tab
    ---------------------------------------------------------------------------

    describe("the Consumption tab", function()
        it("says how many duplicates it left out of its gold totals", function()
            GBL:CreateMainFrame()
            GBL:SelectTab("consumption")
            GBL:RefreshUI()

            assert.is_true(anyLabelContains("(1 duplicate hidden)"))
        end)

        it("says nothing when nothing is left out", function()
            gd.moneyTransactions = { own, other }

            GBL:CreateMainFrame()
            GBL:SelectTab("consumption")
            GBL:RefreshUI()

            assert.is_false(anyLabelContains("hidden"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- What the check costs, and a check that fails
    ---------------------------------------------------------------------------

    describe("the check", function()
        it("is not run for a tab that shows no gold rows", function()
            local calls = 0
            local orig = GBL.MoneyScanCopies
            GBL.MoneyScanCopies = function(self, g)
                calls = calls + 1
                return orig(self, g)
            end
            GBL:CreateMainFrame()
            calls = 0

            GBL:SelectTab("transactions")
            GBL:RefreshUI()
            GBL:SelectTab("sync")
            GBL:RefreshUI()
            local idle = calls
            GBL:SelectTab("goldlog")
            GBL.MoneyScanCopies = orig

            assert.equals(0, idle)
            assert.is_true(calls > 0)
        end)

        it("shows every gold record when it raises, and says so once a session", function()
            GBL.MoneyScanCopies = function() error("a record the check cannot read") end

            local _, rows = GBL:RecordsForView(gd)
            GBL:RecordsForView(gd)

            assert.equals(3, #rows)
            assert.is_true(holds(rows, copy))
            assert.equals(0, #GBL._hiddenMoneyCopies)
            local lines = 0
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Duplicate check failed", 1, true) then lines = lines + 1 end
            end
            assert.equals(1, lines)
        end)

        it("says so once for each guild whose check raises", function()
            -- A player can change guild without logging out (#287).
            GBL.MoneyScanCopies = function() error("a record the check cannot read") end
            local other = GBL.db.global.guilds["OtherGuild"]

            GBL:RecordsForView(gd)
            GBL:RecordsForView(other)
            GBL:RecordsForView(gd)

            local lines = 0
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Duplicate check failed", 1, true) then lines = lines + 1 end
            end
            assert.equals(2, lines)
        end)

        it("leaves the hidden list alone for a caller that wants the item rows only", function()
            GBL:RecordsForView(gd)
            GBL:RecordsForView(gd, true)

            assert.equals(1, #GBL._hiddenMoneyCopies)
            assert.equals(copy, GBL._hiddenMoneyCopies[1])
        end)
    end)

    ---------------------------------------------------------------------------
    -- /gbl cleanup
    ---------------------------------------------------------------------------

    describe("/gbl cleanup", function()
        -- A pair of one transaction with a count of 1: the cleanup removes the
        -- later-scanned one.
        local function trimmablePair()
            local first = money({
                player = FOREIGN, amount = 1234, timestamp = S - 3 * HOUR - 5,
                scanTime = S - 2 * HOUR, scannedBy = ME,
            })
            local second = money({
                player = FOREIGN, amount = 1234, timestamp = S - 3 * HOUR + 55,
                scanTime = S - HOUR, scannedBy = "sync:Aeglos-TestRealm", occ = 1,
            })
            store("moneyTransactions", first, second)
            gd.eventCounts[GBL:BuildTxPrefix(first) .. math.floor(first.timestamp / HOUR)] =
                { count = 1, asOf = 1 }
            return first, second
        end

        local function counting(method)
            local n = { calls = 0 }
            local orig = GBL[method]
            GBL[method] = function(...)
                n.calls = n.calls + 1
                return orig(...)
            end
            return n
        end

        it("refreshes the window, so a record it removed leaves the Gold log", function()
            -- The copy keeps the Gold log on a fresh array, which only a
            -- refresh replaces.
            local _, second = trimmablePair()
            GBL:ToggleMainFrame()
            GBL:SelectTab("goldlog")
            assert.is_true(holds(GBL._goldLogTransactions, second))

            GBL:RunCleanup()

            assert.is_false(holds(gd.moneyTransactions, second))
            assert.is_false(holds(GBL._goldLogTransactions, second))
            assert.is_false(holds(GBL._goldLogTransactions, copy))
        end)

        it("rebuilds no tab that holds no history rows", function()
            -- A refresh of Restock, Sort or Layout is a full rebuild, which
            -- drops the focus the confirm-at-price pause set and any text not
            -- yet committed in a Layout field.
            local _, second = trimmablePair()
            GBL:ToggleMainFrame()
            GBL:SelectTab("sync")
            local selects = counting("SelectTab")

            GBL:RunCleanup()

            assert.is_false(holds(gd.moneyTransactions, second))
            assert.equals(0, selects.calls)
        end)

        it("refreshes nothing when it removed nothing", function()
            GBL:ToggleMainFrame()
            GBL:SelectTab("goldlog")
            local refreshes = counting("RefreshUI")

            GBL:RunCleanup()

            assert.equals(0, refreshes.calls)
        end)

        it("refreshes nothing while the window is closed", function()
            trimmablePair()
            GBL:CreateMainFrame()
            GBL:SelectTab("goldlog")
            local refreshes = counting("RefreshUI")

            GBL:RunCleanup()

            assert.equals(0, refreshes.calls)
        end)
    end)

    ---------------------------------------------------------------------------
    -- After a sync receive
    ---------------------------------------------------------------------------

    describe("after a sync receive", function()
        local Sync = require("spec.sync_helpers")
        local own3

        -- The record as the guildmate holds it: this account's scan, which
        -- that store numbered :1.
        local function wireCopy()
            local rec = echo({ scannedBy = ME, scanTime = T + 2 * HOUR })
            return {
                type = rec.type, player = rec.player, amount = rec.amount,
                timestamp = rec.timestamp, scanTime = rec.scanTime,
                scannedBy = rec.scannedBy, id = rec.id,
            }
        end

        local function receive()
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = {}, moneyTransactions = { wireCopy() },
            })
        end

        local function synced()
            local found = {}
            for _, r in ipairs(gd.moneyTransactions) do
                if type(r.scannedBy) == "string" and r.scannedBy:find("^sync:") then
                    found[#found + 1] = r
                end
            end
            return found
        end

        before_each(function()
            GBL, gd = Sync.setup()
            -- The sync setup logs in as OfficerA; the scans here are an alt's.
            GBL.db.global.characters = { [ME] = 1 }
            gd.playerRealms = { TestOfficer = "TestRealm" }
            -- A count far from every record here, so the cleanup after the
            -- receive runs and reaches none of them.
            gd.eventCounts = { ["deposit|Elsewhere-TestRealm|1|475000"] = { count = 1, asOf = 1 } }
            GBL:ToggleMainFrame()
            GBL:SelectTab("goldlog")
            own3 = mine()
            store("moneyTransactions", own3)
        end)

        it("leaves out the copy the receive stored, and the store keeps it", function()
            receive()

            local got = synced()
            assert.equals(1, #got, "the receive stored the copy")
            assert.equals(2, #gd.moneyTransactions)
            assert.is_true(holds(GBL._goldLogTransactions, own3))
            assert.is_false(holds(GBL._goldLogTransactions, got[1]))
        end)

        it("matches the same copy sent again by its id, and stores nothing", function()
            receive()
            receive()

            assert.equals(2, #gd.moneyTransactions)
            assert.equals(1, #synced())
        end)
    end)
end)
