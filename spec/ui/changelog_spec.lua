------------------------------------------------------------------------
-- changelog_spec.lua — Tests for UI/ChangelogView.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

local GBL

describe("ChangelogView", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    ----------------------------------------------------------------
    -- Data integrity
    ----------------------------------------------------------------

    describe("CHANGELOG_DATA", function()
        it("is a non-empty table", function()
            assert.is_table(GBL.CHANGELOG_DATA)
            assert.is_true(#GBL.CHANGELOG_DATA > 0)
        end)

        it("first entry version matches addon version", function()
            local first = GBL.CHANGELOG_DATA[1]
            assert.equals(GBL.version, first[1])
        end)

        it("every entry has version, date, and sections", function()
            for i, entry in ipairs(GBL.CHANGELOG_DATA) do
                assert.is_string(entry[1], "entry " .. i .. " missing version")
                assert.is_string(entry[2], "entry " .. i .. " missing date")
                assert.is_table(entry[3], "entry " .. i .. " missing sections")
            end
        end)

        it("dates match YYYY-MM-DD format", function()
            for i, entry in ipairs(GBL.CHANGELOG_DATA) do
                assert.truthy(
                    entry[2]:match("^%d%d%d%d%-%d%d%-%d%d$"),
                    "entry " .. i .. " date '" .. entry[2] .. "' not YYYY-MM-DD"
                )
            end
        end)

        it("section types are valid", function()
            local valid = {
                Added = true, Changed = true, Fixed = true,
                Removed = true, Deprecated = true, Security = true,
            }
            for i, entry in ipairs(GBL.CHANGELOG_DATA) do
                for sType, entries in pairs(entry[3]) do
                    assert.is_true(valid[sType],
                        "entry " .. i .. " has invalid section type: " .. tostring(sType))
                    assert.is_table(entries)
                    assert.is_true(#entries > 0,
                        "entry " .. i .. " section " .. sType .. " is empty")
                end
            end
        end)

        it("milestone field is a string when present", function()
            for i, entry in ipairs(GBL.CHANGELOG_DATA) do
                if entry[4] ~= nil then
                    assert.is_string(entry[4],
                        "entry " .. i .. " milestone is not a string")
                end
            end
        end)
    end)

    ----------------------------------------------------------------
    -- FormatChangelogEntry
    ----------------------------------------------------------------

    describe("FormatChangelogEntry", function()
        it("includes version and date", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Test feature"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("v1%.0%.0"))
            assert.truthy(result:find("2026%-01%-01"))
        end)

        it("includes section type name", function()
            local entry = {"1.0.0", "2026-01-01", {
                Fixed = {"A bug fix"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("Fixed:"))
        end)

        it("includes entry text", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"My new feature"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("My new feature"))
        end)

        it("includes milestone when present", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Feature"},
            }, "Milestone M1: Test"}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("Milestone M1: Test"))
        end)

        it("omits milestone line when absent", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Feature"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.falsy(result:find("Milestone"))
        end)

        it("handles multiple sections", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"New thing"},
                Fixed = {"Old bug"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("Added:"))
            assert.truthy(result:find("Fixed:"))
            assert.truthy(result:find("New thing"))
            assert.truthy(result:find("Old bug"))
        end)

        it("handles multiple entries per section", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Feature A", "Feature B", "Feature C"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("Feature A"))
            assert.truthy(result:find("Feature B"))
            assert.truthy(result:find("Feature C"))
        end)

        it("contains newlines between lines", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Feature"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            assert.truthy(result:find("\n"))
        end)

        it("contains WoW color codes", function()
            local entry = {"1.0.0", "2026-01-01", {
                Added = {"Feature"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            -- Gold version header
            assert.truthy(result:find("|cffffcc00"))
            -- Green for Added
            assert.truthy(result:find("|cff55ff55"))
        end)

        it("renders sections in standard order", function()
            local entry = {"1.0.0", "2026-01-01", {
                Removed = {"Old thing"},
                Added = {"New thing"},
                Fixed = {"Bug"},
                Changed = {"Behavior"},
            }}
            local result = GBL:FormatChangelogEntry(entry)
            local posAdded = result:find("Added:")
            local posChanged = result:find("Changed:")
            local posFixed = result:find("Fixed:")
            local posRemoved = result:find("Removed:")
            assert.is_true(posAdded < posChanged)
            assert.is_true(posChanged < posFixed)
            assert.is_true(posFixed < posRemoved)
        end)
    end)

    ----------------------------------------------------------------
    -- BuildChangelogTab
    ----------------------------------------------------------------

    describe("BuildChangelogTab", function()
        it("creates a ScrollFrame child", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            assert.is_true(#container._children > 0)
            local scroll = container._children[1]
            assert.equals("ScrollFrame", scroll._type)
        end)

        it("creates one label per changelog entry", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            local scroll = container._children[1]
            assert.equals(#GBL.CHANGELOG_DATA, #scroll._children)
            for _, child in ipairs(scroll._children) do
                assert.equals("Label", child._type)
            end
        end)

        it("first label contains the newest version", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            local scroll = container._children[1]
            local firstLabel = scroll._children[1]
            local newest = GBL.CHANGELOG_DATA[1][1]
            assert.truthy(firstLabel._text:find(newest, 1, true))
        end)

        it("works with empty CHANGELOG_DATA", function()
            GBL.CHANGELOG_DATA = {}
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            local scroll = container._children[1]
            assert.equals(0, #scroll._children)
        end)
    end)
end)
