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
    end)
end)
