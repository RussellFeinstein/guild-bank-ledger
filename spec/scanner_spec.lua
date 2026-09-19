------------------------------------------------------------------------
-- scanner_spec.lua — Tests for Scanner.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

describe("Scanner", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()

        -- Open the bank
        MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
            Enum.PlayerInteractionType.GuildBanker)
    end)

    describe("full scan", function()
        it("reads all slots from all viewable tabs", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, true)

            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask of Power", count = 5 },
                [3] = { itemID = 101, name = "Potion of Speed", count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 200, name = "Iron Ore", count = 20 },
            })

            -- Reset scan state from auto-scan (bank open triggers it)
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()
            -- Fire timers to chain through tabs
            MockWoW.fireTimers()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results)
            assert.is_not_nil(results[1])
            assert.is_not_nil(results[2])
            assert.equals(2, results[1].itemCount)
            assert.equals(1, results[2].itemCount)
        end)

        it("skips empty slots", function()
            MockWoW.addTab("Tab 1", nil, true)

            -- Only slot 5 has an item (slots 1-4 are nil/empty)
            Helpers.populateTab(1, {
                [5] = { itemID = 100, name = "Flask of Power", count = 1 },
            })

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results[1])
            assert.equals(1, results[1].itemCount)
            assert.is_not_nil(results[1].slots[5])
            assert.is_nil(results[1].slots[1])
        end)

        it("skips non-viewable tabs", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, false)  -- not viewable
            MockWoW.addTab("Tab 3", nil, true)

            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Item A", count = 1 },
            })
            Helpers.populateTab(3, {
                [1] = { itemID = 300, name = "Item C", count = 1 },
            })

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()
            MockWoW.fireTimers()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results[1])
            assert.is_nil(results[2])  -- tab 2 was skipped
            assert.is_not_nil(results[3])
        end)

        it("reports correct item counts per tab", function()
            MockWoW.addTab("Tab 1", nil, true)

            local items = {}
            for i = 1, 10 do
                items[i] = { itemID = 100 + i, name = "Item " .. i, count = i }
            end
            Helpers.populateTab(1, items)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.equals(10, results[1].itemCount)
        end)

        it("cancels gracefully when bank closes mid-scan", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, true)

            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Item", count = 1 },
            })

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            -- Close bank before timers fire (mid-scan)
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)

            assert.is_false(GBL:IsBankOpen())
            assert.is_false(GBL.scanInProgress)

            -- Timers should not continue scanning
            MockWoW.fireTimers()
            -- No crash, scan was cancelled
        end)

        it("calls QueryGuildBankTab for each viewable tab", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, true)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()
            MockWoW.fireTimers()

            assert.is_true(MockWoW.guildBank.queriedTabs[1] or false)
            assert.is_true(MockWoW.guildBank.queriedTabs[2] or false)
        end)

        it("returns results with correct structure per slot", function()
            MockWoW.addTab("Tab 1", nil, true)
            Helpers.populateTab(1, {
                [7] = { itemID = 999, name = "Epic Sword", count = 1, quality = 4 },
            })

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            local slot = results[1].slots[7]
            assert.is_not_nil(slot)
            assert.is_not_nil(slot.itemLink)
            assert.equals(1, slot.count)
            assert.equals(7, slot.slotIndex)
            assert.equals(1, slot.tabIndex)
            assert.is_string(slot.texture)
        end)

        it("handles single tab scan", function()
            MockWoW.addTab("Only Tab", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 50, name = "Gem", count = 3 },
            })

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results)
            assert.is_not_nil(results[1])
            assert.equals(1, results[1].itemCount)
        end)

        it("returns empty results when zero viewable tabs", function()
            -- No tabs added, or all tabs non-viewable
            MockWoW.addTab("Hidden", nil, false)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results)
            -- No tab data
            local count = 0
            for _ in pairs(results) do count = count + 1 end
            assert.equals(0, count)
        end)

        it("skips locked items", function()
            MockWoW.addTab("Tab 1", nil, true)
            -- Manually set up a locked item
            local tab = MockWoW.guildBank.tabs[1]
            tab.slots = {
                [1] = {
                    itemLink = Helpers.makeItemLink(100, "Normal Item"),
                    texture = "icon", count = 1, quality = 1, locked = false,
                },
                [2] = {
                    itemLink = Helpers.makeItemLink(101, "Locked Item"),
                    texture = "icon", count = 1, quality = 1, locked = true,
                },
            }

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.equals(1, results[1].itemCount)
            assert.is_not_nil(results[1].slots[1])
            assert.is_nil(results[1].slots[2])
            -- The locked slot is skipped from the snapshot but counted, so a
            -- sort planned against this scan can be diagnosed.
            assert.equals(1, results[1].lockedSkips)
        end)

        it("waits for GUILDBANKBAGSLOTS_CHANGED before scanning (first-open safety)", function()
            -- Regression for the v0.29.9 report: on first bank open after
            -- login, the client has no slot data yet. The OLD scanner called
            -- TryScanCurrentTab immediately after QueryGuildBankTab, which
            -- read 98 nil slots, unregistered the event, and moved on — so
            -- when the server's response actually arrived, the scanner was
            -- no longer listening. Everything showed as "missing."
            --
            -- This test simulates the sequence: scan starts with NO data;
            -- data+event arrive later; scanner must have captured it.
            MockWoW.addTab("Tab 1", nil, true)
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            -- Override QueryGuildBankTab to suppress the mock's synchronous
            -- event firing so we can control when the "server response" happens.
            local mockQuery = _G.QueryGuildBankTab
            _G.QueryGuildBankTab = function(tabIndex)
                MockWoW.guildBank.queriedTabs[tabIndex] = true
                -- No event fired here — simulates data-not-yet-arrived.
            end

            GBL:StartFullScan()

            -- Scan should still be waiting (no data, no event yet).
            assert.is_true(GBL.scanInProgress,
                "scan should still be in progress before data arrives")

            -- Now populate data and fire the server-response event.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 101, name = "Potion", count = 5 },
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")

            -- Any chained tab-advance timers.
            MockWoW.fireTimers()

            local results = GBL:GetLastScanResults()
            assert.is_not_nil(results)
            assert.is_not_nil(results[1])
            assert.equals(2, results[1].itemCount,
                "scan should have captured the delayed data, not the empty pre-data state")

            _G.QueryGuildBankTab = mockQuery
        end)
    end)

    describe("scan diagnostics (v0.32.8)", function()
        -- completedVia distinguishes a warm scan (driven by the server's
        -- GUILDBANKBAGSLOTS_CHANGED) from one that fell back to the query
        -- timeout (server data may never have arrived — the cold-cache
        -- fingerprint behind phantom sort plans).
        it("records completedVia 'event' when a tab scans from the slots-changed event", function()
            MockWoW.addTab("Tab 1", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
            })
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            -- Default mock fires GUILDBANKBAGSLOTS_CHANGED synchronously on
            -- QueryGuildBankTab, so the tab scans via the event path.
            GBL:StartFullScan()

            local results = GBL:GetLastScanResults()
            assert.equals("event", results[1].completedVia)
        end)

        it("records completedVia 'timeout' when the event never fires", function()
            MockWoW.addTab("Tab 1", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
            })
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            -- Suppress the synchronous event so the query-timeout fallback
            -- drives the scan instead (the cold-cache code path).
            local mockQuery = _G.QueryGuildBankTab
            _G.QueryGuildBankTab = function(tabIndex)
                MockWoW.guildBank.queriedTabs[tabIndex] = true
            end

            GBL:StartFullScan()
            -- Fire the SCAN_TIMEOUT fallback timer.
            MockWoW.fireTimers()

            local results = GBL:GetLastScanResults()
            assert.equals("timeout", results[1].completedVia)

            _G.QueryGuildBankTab = mockQuery
        end)
    end)

    describe("scan coverage (#137)", function()
        -- The scan skips tabs the player's rank cannot view, so a hidden
        -- tab's absence from the results reads exactly like a tab that was
        -- scanned and found empty. Recording which tabs the scan actually
        -- covered is what lets the sort planner tell those apart (#137).
        -- It cannot ride on the results table itself: every reader there
        -- assumes each value is a tab result, and the Layout editor's
        -- Capture treats a present entry as "scanned, capture it".
        it("records the viewable tabs the scan covered", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, false)  -- not viewable
            MockWoW.addTab("Tab 3", nil, true)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()
            MockWoW.fireTimers()

            local coverage = GBL:GetLastScanCoverage()
            assert.is_not_nil(coverage)
            assert.same({ 1, 3 }, coverage.viewableTabs)
        end)

        -- Recording is not a display concern. notifyOnScan governs one
        -- chat line, and a user who turned that off must still get a
        -- filtered plan, or the sort plans into hidden tabs for them
        -- alone. Every other spec here runs with the setting on, so
        -- nothing else in the suite can catch that.
        it("records coverage with scan notifications turned off", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, false)
            GBL.db.profile.scanning.notifyOnScan = false

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()
            MockWoW.fireTimers()

            local coverage = GBL:GetLastScanCoverage()
            assert.is_not_nil(coverage)
            assert.same({ 1 }, coverage.viewableTabs,
                "coverage must not depend on a chat-output setting")
        end)

        -- Distinct from nil on purpose, and the distinction is the whole
        -- point of the record: a scan that ran and saw no tab means every
        -- declared tab is hidden, which the planner must act on. nil means
        -- no scan yet, which it must not act on.
        it("records an empty list when no tab is viewable", function()
            MockWoW.addTab("Hidden", nil, false)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true

            GBL:StartFullScan()

            local coverage = GBL:GetLastScanCoverage()
            assert.is_not_nil(coverage)
            assert.same({}, coverage.viewableTabs)
        end)

        it("replaces the coverage on the next scan", function()
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.addTab("Tab 2", nil, false)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true
            GBL:StartFullScan()
            MockWoW.fireTimers()
            assert.same({ 1 }, GBL:GetLastScanCoverage().viewableTabs)

            -- The rank gained the tab, or the guild bought it.
            MockWoW.guildBank.tabs[2].isViewable = true
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true
            GBL:StartFullScan()
            MockWoW.fireTimers()

            assert.same({ 1, 2 }, GBL:GetLastScanCoverage().viewableTabs)
        end)

        -- Cancelling clears the in-flight scan state, not the last
        -- completed scan's record, which is how lastScanResults already
        -- behaves. A preview taken after a cancelled rescan reads both,
        -- so the two must survive together or the planner pairs a
        -- snapshot with no coverage and silently stops filtering.
        it("survives a cancelled scan", function()
            MockWoW.addTab("Tab 1", nil, true)

            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true
            GBL:StartFullScan()
            MockWoW.fireTimers()

            GBL:CancelPendingScan()

            local coverage = GBL:GetLastScanCoverage()
            assert.is_not_nil(coverage,
                "a cancelled scan erased the last completed scan's coverage")
            assert.same({ 1 }, coverage.viewableTabs)
        end)
    end)

    -- The link-less probe (#178). A bank slot with no item link falls out of
    -- the snapshot as if it were empty, and the scan has never been able to
    -- tell those two apart: ScanTab gates on GetGuildBankItemLink and never
    -- reaches GetGuildBankItemInfo when the link is nil. This measures
    -- whether the info call reports anything for such a slot, so the bank
    -- nolink counter #178 wants can be built on an observed predicate rather
    -- than on a guess. See the v0.39.5 cursor outage for the cost of the
    -- other order.
    --
    -- These tests prove the tally arithmetic and NOTHING about the API. The
    -- mock returns whatever the slot table holds, so all four arms pass here
    -- whatever a real client does. The in-game capture is the evidence, and
    -- it has to be taken on a cold item cache to mean anything.
    describe("link-less slot probe (#178)", function()
        -- The shared before_each fires PLAYER_INTERACTION_MANAGER_FRAME_SHOW,
        -- autoScan defaults on, and with no tab added that scan short-circuits
        -- straight into FinalizeScan. So a probe line already exists before
        -- the first line of any test here runs. Clearing inside the helper is
        -- what makes probeLine() read this scan's line rather than that one.
        local function scanTabWith(slots)
            MockWoW.addTab("Tab 1", nil, true)
            MockWoW.guildBank.tabs[1].slots = slots
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true
            GBL:ClearLog("system")
            GBL:StartFullScan()
            MockWoW.fireTimers()
        end

        local function probeLine()
            local entries = GBL:GetLog("system") or {}
            for i = #entries, 1, -1 do
                local m = entries[i].message or ""
                if m:find("^Scan linkless:") then return m end
            end
            return nil
        end

        it("counts a link-less slot that reports only a texture", function()
            scanTabWith({ [1] = { texture = "icon" } })

            local m = probeLine()
            assert.is_not_nil(m, "no probe line in the system log")
            assert.is_truthy(m:find("texture-only=1", 1, true), m)
            assert.is_truthy(m:find("count-only=0", 1, true), m)
            assert.is_truthy(m:find("both=0", 1, true), m)
        end)

        it("counts a link-less slot that reports only a count", function()
            scanTabWith({ [1] = { count = 4 } })

            local m = probeLine()
            assert.is_not_nil(m, "no probe line in the system log")
            assert.is_truthy(m:find("texture-only=0", 1, true), m)
            assert.is_truthy(m:find("count-only=1", 1, true), m)
            assert.is_truthy(m:find("both=0", 1, true), m)
        end)

        it("counts a link-less slot that reports both", function()
            scanTabWith({ [1] = { texture = "icon", count = 4 } })

            local m = probeLine()
            assert.is_not_nil(m, "no probe line in the system log")
            assert.is_truthy(m:find("texture-only=0", 1, true), m)
            assert.is_truthy(m:find("count-only=0", 1, true), m)
            assert.is_truthy(m:find("both=1", 1, true), m)
        end)

        -- A count of zero is an empty slot, not an occupancy signal. Without
        -- this the arm reads every empty slot on the tab as data.
        it("reads a zero count as no data rather than as a count signal", function()
            scanTabWith({ [1] = { count = 0 } })

            local m = probeLine()
            assert.is_not_nil(m, "no probe line in the system log")
            assert.is_truthy(m:find("0 with data", 1, true), m)
            assert.is_truthy(m:find("neither=98", 1, true), m)
        end)

        -- The whole format, pinned once. Every other test here names one arm,
        -- so a swapped pair of labels would read as correct to all of them.
        it("renders both totals and all four arms, and they reconcile", function()
            scanTabWith({
                [1] = {
                    itemLink = Helpers.makeItemLink(100, "Real Item"),
                    texture = "icon", count = 2,
                },
                [2] = { texture = "icon" },
                [3] = { count = 4 },
                [4] = { texture = "icon", count = 4 },
            })

            -- 98 slots, one of them linked, so 97 have no link. Three of those
            -- reported something; the other 94 are ordinary empty slots, which
            -- is why the denominator is never the interesting number.
            assert.equals(
                "Scan linkless: 97 no-link slot(s), 3 with data "
                .. "[texture-only=1 count-only=1 both=1 neither=94]",
                probeLine())
        end)

        it("does not carry one scan's tally into the next", function()
            scanTabWith({ [1] = { texture = "icon" } })
            assert.is_truthy(probeLine():find("texture-only=1", 1, true))

            MockWoW.guildBank.tabs[1].slots = {}
            GBL:CancelPendingScan()
            GBL.scanInProgress = false
            GBL.bankOpen = true
            GBL:ClearLog("system")
            GBL:StartFullScan()
            MockWoW.fireTimers()

            local m = probeLine()
            assert.is_not_nil(m, "no probe line in the system log")
            assert.is_truthy(m:find("texture-only=0", 1, true), m)
            assert.is_truthy(m:find("0 with data", 1, true), m)
        end)

        -- The probe observes and changes nothing. A link-less slot stays out
        -- of the snapshot, and it must not reach lockedSkips either: that
        -- counter means "holds an item we could identify and could not read",
        -- and widening it would silently change what the new plan-line term
        -- reports.
        it("admits nothing and leaves lockedSkips alone", function()
            scanTabWith({
                [1] = { texture = "icon", count = 4 },
                [2] = { texture = "icon", count = 4, locked = true },
            })

            local results = GBL:GetLastScanResults()
            assert.equals(0, results[1].itemCount)
            assert.is_nil(results[1].slots[1])
            assert.equals(0, results[1].lockedSkips,
                "a link-less slot was counted as a locked skip")
            assert.is_truthy(probeLine():find("both=2", 1, true))
        end)

        -- Found by the mutation pass: adding noteLinkless to the locked
        -- branch survived the whole suite. A slot that HAS a link is not the
        -- case this measures, whatever else is true of it, and counting one
        -- would inflate the denominator with slots the nolink term will never
        -- describe. The existing "skips locked items" test covers the locked
        -- counter and says nothing about the probe, so nothing tied the two
        -- together until now.
        it("counts no-link slots only, not a linked slot that is locked", function()
            scanTabWith({
                [1] = {
                    itemLink = Helpers.makeItemLink(100, "Locked Item"),
                    texture = "icon", count = 3, locked = true,
                },
            })

            assert.equals(1, GBL:GetLastScanResults()[1].lockedSkips)
            local m = probeLine()
            assert.is_truthy(
                m:find("Scan linkless: 97 no-link slot(s), 0 with data", 1, true), m)
        end)
    end)
end)

------------------------------------------------------------------------
-- Scan coverage before the first scan (#137)
--
-- Its own describe because the Scanner block above opens the bank in
-- before_each, and autoScan runs a scan on bank open. That scan finishes
-- having seen no tab, which is a real state and a different one: the
-- planner filters on an empty coverage list and must not filter on nil.
-- Reaching the nil means never opening the bank, which is a fresh login.
------------------------------------------------------------------------

describe("Scanner coverage before any scan", function()
    it("is nil until a scan finishes", function()
        Helpers.setupMocks()
        local GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
        MockWoW.addTab("Tab 1", nil, true)

        assert.is_nil(GBL:GetLastScanCoverage())
    end)
end)

------------------------------------------------------------------------
-- Bag scanning (#139: include bags in sort)
--
-- ScanBags is the synchronous bag-side sibling of the tab scan: it reads
-- C_Container state directly (no query round-trip, no events) and emits a
-- bank-shaped snapshot keyed by NEGATIVE pseudo-tab indices so the sort
-- planner can consume it without learning a second slot vocabulary.
------------------------------------------------------------------------

describe("Scanner bag scanning", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    describe("pseudo-tab helpers", function()
        it("encodes bagIDs 0..5 to tabs -1..-6", function()
            assert.equals(-1, GBL:TabFromBagID(0))
            assert.equals(-3, GBL:TabFromBagID(2))
            assert.equals(-6, GBL:TabFromBagID(5))
        end)

        it("decodes negative tabs back to bagIDs", function()
            assert.equals(0, GBL:BagIDFromTab(-1))
            assert.equals(2, GBL:BagIDFromTab(-3))
            assert.equals(5, GBL:BagIDFromTab(-6))
        end)

        it("returns nil for tabs that are not bag pseudo-tabs", function()
            assert.is_nil(GBL:BagIDFromTab(4))
            assert.is_nil(GBL:BagIDFromTab(0))
            assert.is_nil(GBL:BagIDFromTab(-7))
        end)

        -- -1.5 decodes to bagID 0.5, which is inside the range check and
        -- comes back out as a fractional bagID. Nothing produces one today,
        -- but the decoder is the boundary that keeps a bad tab from reaching
        -- C_Container as a bag index, so it rejects rather than rounds.
        it("returns nil for a negative tab that is not an integer", function()
            assert.is_nil(GBL:BagIDFromTab(-1.5))
            assert.is_nil(GBL:BagIDFromTab(-5.001))
        end)

        it("formats bag and bank slot references", function()
            assert.equals("Bag0/5", GBL:FormatSlotRef(-1, 5))
            assert.equals("Bag5/1", GBL:FormatSlotRef(-6, 1))
            assert.equals("T3/12", GBL:FormatSlotRef(3, 12))
        end)
    end)

    describe("ScanBags", function()
        it("returns an empty table when no bags exist", function()
            assert.same({}, GBL:ScanBags())
        end)

        it("emits an entry with zero items for a present but empty bag", function()
            Helpers.populateBag(0, {})
            local result = GBL:ScanBags()
            assert.is_not_nil(result[-1])
            assert.equals(0, result[-1].itemCount)
            assert.same({}, result[-1].slots)
        end)

        it("emits a bank-shaped entry keyed by pseudo-tab", function()
            Helpers.populateBag(0, {
                [3] = { itemID = 100, name = "Iron Ore", count = 20 },
            })
            local result = GBL:ScanBags()
            assert.is_not_nil(result[-1])
            local slot = result[-1].slots[3]
            assert.is_not_nil(slot)
            assert.equals(20, slot.count)
            assert.equals(3, slot.slotIndex)
            assert.equals(-1, slot.tabIndex)
            assert.equals(100, slot.itemID)
            assert.is_truthy(slot.itemLink:find("Hitem:100", 1, true))
            assert.equals(1, result[-1].itemCount)
        end)

        it("scans the reagent bag as pseudo-tab -6", function()
            Helpers.populateBag(5, {
                [1] = { itemID = 200, name = "Chromatic Dust", count = 40 },
            })
            local result = GBL:ScanBags()
            assert.is_not_nil(result[-6])
            assert.equals(200, result[-6].slots[1].itemID)
        end)

        it("omits bags that do not exist", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Iron Ore", count = 1 },
            })
            local result = GBL:ScanBags()
            assert.is_not_nil(result[-1])
            for tab in pairs(result) do
                assert.equals(-1, tab)
            end
        end)

        it("skips bound items and counts them", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Warbound Ore", count = 5, isBound = true },
                [2] = { itemID = 101, name = "Iron Ore", count = 5 },
            })
            local result = GBL:ScanBags()
            assert.is_nil(result[-1].slots[1])
            assert.is_not_nil(result[-1].slots[2])
            assert.equals(1, result[-1].itemCount)
            assert.equals(1, result[-1].boundSkips)
        end)

        it("skips locked slots and counts them", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Iron Ore", count = 5, locked = true },
            })
            local result = GBL:ScanBags()
            assert.is_nil(result[-1].slots[1])
            assert.equals(0, result[-1].itemCount)
            assert.equals(1, result[-1].lockedSkips)
        end)

        -- A bound item sitting in a transiently locked slot hits both skip
        -- branches. It must count as bound: locked is a retry-and-it-clears
        -- state, bound is permanent, so reporting the transient reason tells
        -- the user to retry a deposit the server will refuse every time.
        it("counts a slot that is both bound and locked as bound", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Warbound Ore", count = 5,
                        isBound = true, locked = true },
            })
            local result = GBL:ScanBags()
            assert.is_nil(result[-1].slots[1])
            assert.equals(1, result[-1].boundSkips)
            assert.equals(0, result[-1].lockedSkips)
        end)

        it("skips bag 5 when Enum.BagIndex is absent", function()
            Helpers.populateBag(5, {
                [1] = { itemID = 200, name = "Chromatic Dust", count = 1 },
            })
            local stash = _G.Enum.BagIndex
            _G.Enum.BagIndex = nil
            local result = GBL:ScanBags()
            _G.Enum.BagIndex = stash
            assert.is_nil(result[-6])
        end)

        it("skips slots with no usable item link", function()
            Helpers.populateBag(0, {
                -- Item data not yet streamed: itemID known, hyperlink nil.
                [1] = { itemID = 100, name = "Iron Ore", count = 1, noHyperlink = true },
                -- Caged battle pet: hyperlink present but not an item: link.
                [2] = { itemID = 82800, name = "Feline Familiar", count = 1,
                        link = "|cff0070dd|Hbattlepet:1234:1:3:158:10:12:0|h[Feline Familiar]|h|r" },
                [3] = { itemID = 101, name = "Copper Ore", count = 2 },
            })
            local result = GBL:ScanBags()
            assert.is_nil(result[-1].slots[1])
            assert.is_nil(result[-1].slots[2])
            assert.is_not_nil(result[-1].slots[3])
            assert.equals(1, result[-1].itemCount)
            assert.equals(2, result[-1].noLink)
        end)

        it("warms the item cache once per distinct scanned item", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Iron Ore", count = 20 },
                [2] = { itemID = 100, name = "Iron Ore", count = 5 },
                [3] = { itemID = 101, name = "Copper Ore", count = 3 },
            })
            local seen = {}
            local orig = GBL.GetMaxStack
            GBL.GetMaxStack = function(self, id)
                seen[id] = (seen[id] or 0) + 1
                return orig(self, id)
            end
            GBL:ScanBags()
            GBL.GetMaxStack = orig
            assert.equals(1, seen[100])
            assert.equals(1, seen[101])
        end)

        -- Scanner sits above BankLayout in the .toc, so ExtractItemID is
        -- resolved at call time and can legitimately be missing. SortPlanner
        -- and Restock both carry the same inline fallback; without it every
        -- bag slot silently counts as noLink and the sort sees empty bags.
        it("parses item links itself when BankLayout.ExtractItemID is absent", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Iron Ore", count = 20 },
            })
            local stash = GBL.BankLayout
            GBL.BankLayout = nil
            local result = GBL:ScanBags()
            GBL.BankLayout = stash

            assert.is_not_nil(result[-1].slots[1])
            assert.equals(100, result[-1].slots[1].itemID)
            assert.equals(1, result[-1].itemCount)
            assert.equals(0, result[-1].noLink)
        end)

        -- Same load-order reasoning as ExtractItemID above: the cache warm is
        -- an optimisation, so a missing GetMaxStack must not take the scan
        -- down with it.
        it("still scans when GetMaxStack is unavailable", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Iron Ore", count = 20 },
            })
            local stash = GBL.GetMaxStack
            GBL.GetMaxStack = nil
            local ok, result = pcall(function() return GBL:ScanBags() end)
            GBL.GetMaxStack = stash

            assert.is_true(ok)
            assert.equals(1, result[-1].itemCount)
        end)

        -- The reagent bag index comes from the client, and the pseudo-tab
        -- range is 0..5. A value outside it would encode to a tab that
        -- BagIDFromTab cannot decode, so the executor could never turn the
        -- op back into a bag. Derive the scan list from what decodes.
        it("ignores a reagent bag index outside the encodable range", function()
            Helpers.populateBag(9, {
                [1] = { itemID = 100, name = "Iron Ore", count = 20 },
            })
            local stash = _G.Enum.BagIndex.ReagentBag
            _G.Enum.BagIndex.ReagentBag = 9
            local result = GBL:ScanBags()
            _G.Enum.BagIndex.ReagentBag = stash

            assert.is_nil(result[-10])
            for tabIndex in pairs(result) do
                assert.is_not_nil(GBL:BagIDFromTab(tabIndex))
            end
        end)
    end)
end)
