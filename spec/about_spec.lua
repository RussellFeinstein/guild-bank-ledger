------------------------------------------------------------------------
-- about_spec.lua — Tests for UI/AboutView.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce

describe("AboutView", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        _G.MockWoW_guildName = "Test Guild"
        GBL:OnEnable()
    end)

    describe("BuildAboutTab", function()
        it("creates widgets without error", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            assert.has_no.errors(function()
                GBL:BuildAboutTab(container)
            end)
        end)

        it("adds children to the container", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            -- Container should have at least a ScrollFrame child
            assert.is_true(#container._children > 0)
        end)

        it("creates a ScrollFrame as the first child", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            local scroll = container._children[1]
            assert.equals("ScrollFrame", scroll._type)
        end)

        it("includes version in the header", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            local scroll = container._children[1]
            -- First child of scroll is the header label
            local header = scroll._children[1]
            assert.equals("Label", header._type)
            assert.is_truthy(header._text:find("GuildBankLedger"))
        end)

        it("includes the Ko-fi URL in an EditBox", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            local scroll = container._children[1]
            local foundKofi = false
            for _, child in ipairs(scroll._children) do
                if child._type == "EditBox" and child._text:find("ko%-fi%.com/RexxyBear") then
                    foundKofi = true
                    break
                end
            end
            assert.is_true(foundKofi, "Expected a Ko-fi EditBox")
        end)

        it("includes the CurseForge URL in an EditBox", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            local scroll = container._children[1]
            local foundCurse = false
            for _, child in ipairs(scroll._children) do
                if child._type == "EditBox" and child._text:find("curseforge%.com") then
                    foundCurse = true
                    break
                end
            end
            assert.is_true(foundCurse, "Expected a CurseForge EditBox")
        end)

        it("includes author credit", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildAboutTab(container)
            local scroll = container._children[1]
            local foundAuthor = false
            for _, child in ipairs(scroll._children) do
                if child._type == "Label" and child._text:find("RexxyBear") then
                    foundAuthor = true
                    break
                end
            end
            assert.is_true(foundAuthor, "Expected author label mentioning RexxyBear")
        end)
    end)
end)
