------------------------------------------------------------------------
-- access_control_row_spec.lua - the Sync tab's Access Control row (#222)
--
-- The GetAccessLevel half of the Member decision is pinned in
-- spec/access_control_spec.lua; this is the half a GM actually reads. The
-- dropdown's labels are display text over unchanged wire values, and its
-- default has to agree with what the level computation does with a
-- threshold and no mode, or the GM is shown one thing and the guild gets
-- another.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Access Control row", function()
    local GBL

    local function findWidget(node, wtype, label)
        for _, c in ipairs(node._children or {}) do
            if c._type == wtype and (label == nil or c._label == label) then return c end
            local nested = findWidget(c, wtype, label)
            if nested then return nested end
        end
        return nil
    end

    local function build()
        local AceGUI = LibStub("AceGUI-3.0")
        local container = AceGUI:Create("SimpleGroup")
        GBL:BuildAccessControlRow(container)
        return container
    end

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        MockWoW.guild.ranks = { "Guild Master", "Officer", "Raider", "Member" }
        GBL:OnEnable()
    end)

    it("offers Member and Sync only over the stored values", function()
        local mode = findWidget(build(), "Dropdown", "Restricted mode")

        assert.is_not_nil(mode)
        assert.equals("Member", mode._list.own_transactions)
        assert.equals("Sync only", mode._list.sync_only)
    end)

    it("defaults to Member when a threshold is set and no mode is stored", function()
        local gd = GBL:GetGuildData()
        gd.accessControl = { rankThreshold = 3 }

        local mode = findWidget(build(), "Dropdown", "Restricted mode")

        assert.equals("own_transactions", mode._value)
    end)

    it("shows the stored mode when there is one", function()
        local gd = GBL:GetGuildData()
        gd.accessControl = { rankThreshold = 3, restrictedMode = "sync_only" }

        local mode = findWidget(build(), "Dropdown", "Restricted mode")

        assert.equals("sync_only", mode._value)
    end)

    it("tells the GM what they picked in the words they picked it by", function()
        local container = build()
        local rank = findWidget(container, "Dropdown", "Full access up to rank")
        local mode = findWidget(container, "Dropdown", "Restricted mode")
        local apply = findWidget(container, "Button")
        rank:SetValue(4)
        mode:SetValue("own_transactions")
        MockWoW.clearPrints()

        apply:Fire("OnClick")

        local said = table.concat(MockWoW.prints, " | ")
        assert.is_truthy(said:find("Member", 1, true),
            "the confirmation should name the mode the way the dropdown does: " .. said)
        assert.is_nil(said:find("own_transactions", 1, true))
        -- The wire value is what gets stored, whatever the line says.
        assert.equals("own_transactions", GBL:GetGuildData().accessControl.restrictedMode)
    end)
end)
