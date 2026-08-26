------------------------------------------------------------------------
-- mock_container_spec.lua — Contract tests for the C_Container mock
--
-- The bag half of the sort pipeline (#139) moves items with C_Container
-- calls against the same MockWoW.cursor the guild bank mock uses. These
-- specs pin that shared-cursor contract before any executor spec depends
-- on it, in particular the max-stack bounce restoring into the BAG when
-- the cursor was picked up from one (the pre-existing bounce path
-- assumed a bank source and would silently lose a bag-sourced item).
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("C_Container mock", function()
    before_each(function()
        Helpers.setupMocks()
    end)

    it("GetContainerNumSlots reports the configured bag size", function()
        Helpers.populateBag(0, {}, 16)
        assert.equals(16, C_Container.GetContainerNumSlots(0))
        assert.equals(0, C_Container.GetContainerNumSlots(3))
    end)

    it("GetContainerItemInfo returns the retail table form", function()
        Helpers.populateBag(0, {
            [2] = { itemID = 100, name = "Iron Ore", count = 7,
                    locked = true, isBound = true },
        })
        local info = C_Container.GetContainerItemInfo(0, 2)
        assert.is_table(info)
        assert.equals(7, info.stackCount)
        assert.equals(100, info.itemID)
        assert.is_true(info.isLocked)
        assert.is_true(info.isBound)
        assert.equals("string", type(info.hyperlink))
    end)

    it("GetContainerItemInfo returns nil for empty slots and absent bags", function()
        Helpers.populateBag(0, {})
        assert.is_nil(C_Container.GetContainerItemInfo(0, 1))
        assert.is_nil(C_Container.GetContainerItemInfo(4, 1))
    end)

    it("PickupContainerItem lifts the whole stack onto the shared cursor", function()
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        C_Container.PickupContainerItem(0, 1)
        assert.is_true(CursorHasItem())
        assert.equals(20, MockWoW.cursor.count)
        assert.equals(100, MockWoW.cursor.itemID)
        assert.equals(0, MockWoW.cursor.src.bagID)
        assert.equals(1, MockWoW.cursor.src.slotIndex)
        assert.is_nil(MockWoW.bags[0].slots[1])
    end)

    it("a bag pickup drops into a guild bank slot", function()
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        C_Container.PickupContainerItem(0, 1)
        PickupGuildBankItem(1, 4)
        assert.is_false(CursorHasItem())
        local slot = MockWoW.guildBank.tabs[1].slots[4]
        assert.is_not_nil(slot)
        assert.equals(20, slot.count)
        assert.equals(100, slot.itemID)
        assert.is_nil(MockWoW.bags[0].slots[1])
    end)

    it("SplitContainerItem lifts a partial stack", function()
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        C_Container.SplitContainerItem(0, 1, 5)
        assert.equals(5, MockWoW.cursor.count)
        assert.equals(15, MockWoW.bags[0].slots[1].stackCount)
        PickupGuildBankItem(1, 1)
        assert.equals(5, MockWoW.guildBank.tabs[1].slots[1].count)
    end)

    it("a merge that would exceed maxStack bounces back to the bag slot", function()
        MockWoW.itemNames[100] = { stackCount = 20 }
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 5 },
        })
        C_Container.PickupContainerItem(0, 1)
        PickupGuildBankItem(1, 1)
        assert.is_false(CursorHasItem())
        -- Bank stack untouched, bag stack restored: nothing lost.
        assert.equals(20, MockWoW.guildBank.tabs[1].slots[1].count)
        local bagSlot = MockWoW.bags[0].slots[1]
        assert.is_not_nil(bagSlot)
        assert.equals(5, bagSlot.stackCount)
    end)

    it("PickupContainerItem on a locked slot leaves the cursor empty", function()
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 5, locked = true },
        })
        C_Container.PickupContainerItem(0, 1)
        assert.is_false(CursorHasItem())
        assert.is_not_nil(MockWoW.bags[0].slots[1])
    end)

    it("GetContainerItemInfo returns a copy, not the live slot table", function()
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 7 },
        })
        -- Retail builds a fresh table per call. A caller must not be able
        -- to write through into the bag, and a captured table must keep
        -- reading what the slot held at call time.
        local info = C_Container.GetContainerItemInfo(0, 1)
        info.stackCount = 999
        assert.equals(7, MockWoW.bags[0].slots[1].stackCount)
        assert.equals(7, C_Container.GetContainerItemInfo(0, 1).stackCount)

        local before = C_Container.GetContainerItemInfo(0, 1)
        C_Container.SplitContainerItem(0, 1, 3)
        assert.equals(7, before.stackCount)
        assert.equals(4, MockWoW.bags[0].slots[1].stackCount)
    end)

    it("a bag-sourced bounce fires no bank event", function()
        -- The drop was refused, so no guild bank slot changed. Firing
        -- GUILDBANKBAGSLOTS_CHANGED here would claim one did.
        MockWoW.itemNames[100] = { stackCount = 20 }
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 5 },
        })
        C_Container.PickupContainerItem(0, 1)
        MockWoW.deferredBankEvents = true
        MockWoW.queuedBankEvents = {}
        PickupGuildBankItem(1, 1)
        assert.equals(0, #MockWoW.queuedBankEvents)
        -- The bounce still completed: cursor empty, bag stack restored.
        assert.is_false(CursorHasItem())
        assert.equals(5, MockWoW.bags[0].slots[1].stackCount)
    end)

    it("a later generic fire is not gated by the skipped bounce event", function()
        -- fireBankEvent consumes _lastMutatedTab. Skipping the fire on a
        -- bag bounce has to clear it too, or the next mutation inherits a
        -- stale tab and gets gated away under viewGatedReads.
        MockWoW.itemNames[100] = { stackCount = 20 }
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 5 },
        })
        C_Container.PickupContainerItem(0, 1)
        PickupGuildBankItem(1, 1)
        assert.is_nil(MockWoW.guildBank._lastMutatedTab)
    end)

    it("dropping the cursor into a bag raises", function()
        -- Bags are a sort SOURCE only: findPivot walks the blocked tab
        -- plus overflow tabs, Phase 3 sweeps display tabs, Phase 4 packs
        -- overflow tabs. The planner side is pinned by applyPlan's
        -- dstTab >= 1 assertion, but executor specs never route through
        -- applyPlan, so the mock is the only thing standing between an
        -- executor regression and a silently accepted bag destination.
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 5 },
        })
        C_Container.PickupContainerItem(0, 1)
        assert.is_true(CursorHasItem())
        assert.has_error(function()
            C_Container.PickupContainerItem(0, 2)
        end)
    end)

    it("a bounce into a source holding a different item raises", function()
        -- Unreachable through the pipeline: a full pickup nils the source
        -- so the restore branch runs, and a split leaves the same item
        -- behind. Constructed by hand here so the blind merge cannot come
        -- back as silent count inflation.
        MockWoW.itemNames[100] = { stackCount = 20 }
        MockWoW.addTab("Tab 1", nil, true)
        Helpers.populateTab(1, {
            [1] = { itemID = 100, name = "Iron Ore", count = 20 },
        })
        Helpers.populateBag(0, {
            [1] = { itemID = 100, name = "Iron Ore", count = 10 },
        })
        C_Container.SplitContainerItem(0, 1, 5)
        -- Something else claims the source slot while the cursor is up.
        MockWoW.bags[0].slots[1] = {
            hyperlink = Helpers.makeItemLink(101, "Copper Ore", 1),
            iconFileID = 134400, stackCount = 5, quality = 1,
            isLocked = false, isBound = false, itemID = 101,
        }
        assert.has_error(function()
            PickupGuildBankItem(1, 1)
        end)
    end)
end)
