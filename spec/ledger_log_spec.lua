------------------------------------------------------------------------
-- ledger_log_spec.lua: what each guild bank log read writes to the
-- ledger log channel (#85)
--
-- Every read writes at most one summary line, "Bank log read:", with
-- on=open or on=rescan, the timer that ran it (via=event or via=timeout),
-- the new and read counts, and a per-tab new/read breakdown. The open
-- read is INFO on every bank visit. A rescan is INFO when it stored
-- something or its per-tab counts moved since the previous read, and
-- DEBUG otherwise, because a quiet rescan runs every 3s at the bank.
-- WARN lines name entries the read could not record, and an ERROR names
-- a rescan read that raised.
--
-- Needles are single terms (`on=open`, `T1=2/2`) matched as plain text,
-- never two fields joined, so a reordered line still reads correctly.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("Ledger log lines (#85)", function()
    local GBL
    local MockWoW
    local MockAce
    local link

    before_each(function()
        Helpers.setupMocks()
        MockWoW = Helpers.MockWoW
        MockAce = Helpers.MockAce
        MockWoW.guild.name = "Test Guild"
        MockWoW.guildBank.numTabs = 2
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL.bankOpen = true
        GBL:ClearLog(nil)
        link = Helpers.makeItemLink(12345, "Flask", 1)
    end)

    --- Ledger lines at one level (nil for every level), oldest first.
    local function lines(level)
        local out = {}
        local log = GBL:GetLog("ledger")
        for i = #log, 1, -1 do
            if level == nil or log[i].level == level then
                out[#out + 1] = log[i].message
            end
        end
        return out
    end

    local function has(s, needle)
        return s ~= nil and s:find(needle, 1, true) ~= nil
    end

    --- The bank-open read, run by the debounce after one log event.
    local function openRead()
        local result
        GBL:ScanTransactions(function(n) result = n end)
        MockAce.fireEvent("GUILDBANKLOG_UPDATE")
        Helpers.fireTimersAt(GBL.LEDGER_SCAN_DEBOUNCE)
        return result
    end

    --- A periodic rescan, run by its debounce after one log event.
    local function rescan()
        local result
        GBL:RescanTransactionLogs(function(n) result = n end)
        MockAce.fireEvent("GUILDBANKLOG_UPDATE")
        Helpers.fireTimersAt(GBL.LEDGER_RESCAN_DEBOUNCE)
        return result
    end

    describe("the bank-open read", function()
        it("writes one INFO line even when nothing is new", function()
            openRead()
            local info = lines("INFO")
            assert.equals(1, #info)
            assert.is_true(has(info[1], "Bank log read:"), info[1])
            assert.is_true(has(info[1], "on=open"), info[1])
            assert.is_true(has(info[1], "new=0"), info[1])
            assert.is_true(has(info[1], "T1=0/0"), info[1])
            assert.is_true(has(info[1], "T2=0/0"), info[1])
            assert.is_true(has(info[1], "M=0/0"), info[1])
        end)

        it("counts what it stored, by tab and in total", function()
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Raider1", link, 5, 1, nil, 0),
                Helpers.makeTransaction("withdraw", "Raider2", link, 3, 1, nil, 1),
            })
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            assert.equals(3, openRead())
            local line = lines("INFO")[1]
            assert.is_true(has(line, "new=3"), line)
            assert.is_true(has(line, "items=2"), line)
            assert.is_true(has(line, "money=1"), line)
            assert.is_true(has(line, "read=3"), line)
            assert.is_true(has(line, "T1=2/2"), line)
            assert.is_true(has(line, "T2=0/0"), line)
            assert.is_true(has(line, "M=1/1"), line)
        end)

        it("counts entries it already held as read and not new", function()
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Raider1", link, 5, 1, nil, 0),
            })
            GBL:ReadAllTransactions(GBL:GetGuildData())

            assert.equals(0, openRead())
            local line = lines("INFO")[1]
            assert.is_true(has(line, "new=0"), line)
            assert.is_true(has(line, "T1=0/1"), line)
        end)

        it("says via=event when the debounce runs the read", function()
            openRead()
            assert.is_true(has(lines("INFO")[1], "via=event"))
        end)

        it("says via=timeout when the fallback runs the read", function()
            GBL:ScanTransactions(function() end)
            Helpers.fireTimersAt(GBL.LEDGER_SCAN_FALLBACK)
            local line = lines("INFO")[1]
            assert.is_true(has(line, "on=open"), line)
            assert.is_true(has(line, "via=timeout"), line)
        end)

        it("says so when the guild bank window closed before the read", function()
            local result
            GBL:ScanTransactions(function(n) result = n end)
            GBL.bankOpen = false
            Helpers.fireTimersAt(GBL.LEDGER_SCAN_FALLBACK)

            assert.equals(0, result)
            local line = lines("INFO")[1]
            assert.is_true(has(line, "on=open"), line)
            assert.is_true(has(line, "abandoned"), line)
        end)
    end)

    describe("a periodic rescan", function()
        before_each(function()
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Raider1", link, 5, 1, nil, 0),
                Helpers.makeTransaction("withdraw", "Raider2", link, 3, 1, nil, 1),
            })
            openRead()
            GBL:ClearLog("ledger")
        end)

        it("writes nothing when nothing moved and debug is off", function()
            assert.equals(0, rescan())
            assert.equals(0, #GBL:GetLog("ledger"))
        end)

        it("writes DEBUG when nothing moved and debug is on", function()
            GBL.db.profile.ledger.debugChat = true
            rescan()
            local debug = lines("DEBUG")
            assert.equals(1, #debug)
            assert.is_true(has(debug[1], "on=rescan"), debug[1])
            assert.equals(0, #lines("INFO"))
        end)

        it("writes INFO when it stored something", function()
            table.insert(MockWoW.guildBank.transactionLogs[1],
                Helpers.makeTransaction("deposit", "Raider3", link, 7, 1, nil, 0))

            assert.equals(1, rescan())
            local info = lines("INFO")
            assert.equals(1, #info)
            assert.is_true(has(info[1], "on=rescan"), info[1])
            assert.is_true(has(info[1], "new=1"), info[1])
            assert.is_true(has(info[1], "T1=1/3"), info[1])
        end)

        it("writes INFO when a tab's read count moved with nothing new", function()
            -- A tab answering empty where it answered two entries a moment
            -- ago is the read most worth seeing (#336).
            MockWoW.guildBank.transactionLogs[1] = {}

            assert.equals(0, rescan())
            local info = lines("INFO")
            assert.equals(1, #info)
            assert.is_true(has(info[1], "new=0"), info[1])
            assert.is_true(has(info[1], "T1=0/0"), info[1])
        end)

        it("says via=timeout when the fallback runs the read", function()
            GBL.db.profile.ledger.debugChat = true
            GBL:RescanTransactionLogs(function() end)
            Helpers.fireTimersAt(GBL.LEDGER_RESCAN_FALLBACK)
            assert.is_true(has(lines("DEBUG")[1], "via=timeout"))
        end)

        it("writes ERROR when its read raises, and still answers 0", function()
            GBL.ReadAllTransactions = function() error("test explosion") end

            assert.equals(0, rescan())
            local errors = lines("ERROR")
            assert.equals(1, #errors)
            assert.is_true(has(errors[1], "on=rescan"), errors[1])
            assert.is_true(has(errors[1], "test explosion"), errors[1])
        end)
    end)

    describe("entries the read could not record", function()
        it("counts an entry with no name and warns once", function()
            -- The client returns these: Blizzard's own UI shows them as
            -- "Unknown" (#335). The read loop drops them.
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Raider1", link, 5, 1, nil, 0),
                Helpers.makeTransaction("deposit", nil, link, 2, 1, nil, 0),
            })

            openRead()
            local info = lines("INFO")[1]
            assert.is_true(has(info, "skipped=1"), info)
            assert.is_true(has(info, "T1=1/2"), info)
            local warns = lines("WARN")
            assert.equals(1, #warns)
            assert.is_true(has(warns[1], "no type or name"), warns[1])
            assert.is_true(has(warns[1], "T1=1"), warns[1])

            -- The same entry read again every 3s is not a new warning.
            rescan()
            assert.equals(1, #lines("WARN"))
        end)

        it("warns again when a second nameless entry appears", function()
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", nil, link, 2, 1, nil, 0),
            })
            openRead()
            table.insert(MockWoW.guildBank.transactionLogs[1],
                Helpers.makeTransaction("withdraw", nil, link, 4, 1, nil, 0))

            rescan()
            local warns = lines("WARN")
            assert.equals(2, #warns)
            assert.is_true(has(warns[2], "T1=2"), warns[2])
        end)

        it("compares a guild's read only with that guild's previous one", function()
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", nil, link, 2, 1, nil, 0),
            })
            openRead()
            assert.equals(1, #lines("WARN"))

            MockWoW.guild.name = "Other Guild"
            openRead()
            assert.equals(2, #lines("WARN"))
        end)

        it("counts a record refused at store and warns", function()
            -- An empty name passes the read loop and fails the store's
            -- player check.
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "", link, 2, 1, nil, 0),
            })

            assert.equals(0, openRead())
            local info = lines("INFO")[1]
            assert.is_true(has(info, "refused=1"), info)
            local warns = lines("WARN")
            assert.equals(1, #warns)
            assert.is_true(has(warns[1], "refused"), warns[1])
            assert.is_true(has(warns[1], "T1=1"), warns[1])
        end)
    end)

    describe("StoreBatchRecords", function()
        it("returns the refused count as a third value", function()
            local guildData = GBL:GetGuildData()
            local good = GBL:CreateTxRecord("deposit", "Raider1", link, 5, 1, nil, 0, 0, 0, 0)
            local bad = GBL:CreateTxRecord("deposit", "", link, 2, 1, nil, 0, 0, 0, 0)

            local stored, _, refused = GBL:StoreBatchRecords({ good, bad }, guildData, "transactions", nil)
            assert.equals(1, stored)
            assert.equals(1, refused)
        end)
    end)
end)
