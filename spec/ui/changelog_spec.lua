------------------------------------------------------------------------
-- changelog_spec.lua — Tests for UI/ChangelogView.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

local GBL

--- Find the first child of a given type in a container.
local function findChild(container, widgetType)
    for _, child in ipairs(container._children) do
        if child._type == widgetType then
            return child
        end
    end
end

describe("ChangelogView", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL._changelogCurrentPage = nil -- reset pagination state
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

            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
        end)

        it("creates individual label widgets per line", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            -- Use a small dataset (single page) to avoid pagination nav bar
            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = {
                {"1.0.0", "2026-01-01", { Added = {"Feature A"} }},
                {"0.9.0", "2025-12-01", { Fixed = {"Bug B"} }},
            }

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            -- More children than entries (one per line, not one per entry)
            assert.is_true(#scroll._children > #GBL.CHANGELOG_DATA)
            for _, child in ipairs(scroll._children) do
                assert.equals("Label", child._type)
            end

            GBL.CHANGELOG_DATA = original
        end)

        it("first label contains the newest version", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            -- First child is navGroup (when paginated), version header follows
            local labelIdx = scroll._children[1]._type == "SimpleGroup" and 2 or 1
            local firstLabel = scroll._children[labelIdx]
            local newest = GBL.CHANGELOG_DATA[1][1]
            assert.truthy(firstLabel._text:find(newest, 1, true))
        end)

        it("section content is visible in child labels", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            -- Use a minimal dataset to test
            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = {
                {"1.0.0", "2026-01-01", {
                    Added = {"Visible feature"},
                    Fixed = {"Visible fix"},
                }},
            }

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            local texts = {}
            for _, child in ipairs(scroll._children) do
                texts[#texts + 1] = child._text
            end
            local combined = table.concat(texts, "\n")
            assert.truthy(combined:find("Added:"))
            assert.truthy(combined:find("Fixed:"))
            assert.truthy(combined:find("Visible feature"))
            assert.truthy(combined:find("Visible fix"))

            GBL.CHANGELOG_DATA = original
        end)

        it("works with empty CHANGELOG_DATA", function()
            GBL.CHANGELOG_DATA = {}
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            assert.equals(0, #scroll._children)
        end)
    end)

    ----------------------------------------------------------------
    -- Pagination
    ----------------------------------------------------------------

    describe("Pagination", function()
        local function makeEntries(n)
            local data = {}
            for i = 1, n do
                data[i] = {
                    string.format("0.%d.0", n - i + 1),
                    "2026-01-01",
                    { Added = {"Entry " .. i} },
                }
            end
            return data
        end

        it("hides nav bar when data fits one page", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(5)

            GBL:BuildChangelogTab(container)

            -- Only child should be the ScrollFrame (no nav bar)
            assert.equals(1, #container._children)
            assert.equals("ScrollFrame", container._children[1]._type)

            GBL.CHANGELOG_DATA = original
        end)

        it("shows nav bar when data exceeds one page", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL:BuildChangelogTab(container)

            -- Only child is ScrollFrame (nav is inside scroll)
            assert.equals(1, #container._children)
            assert.equals("ScrollFrame", container._children[1]._type)
            -- First child of scroll is the nav group
            local scroll = container._children[1]
            assert.equals("SimpleGroup", scroll._children[1]._type)

            GBL.CHANGELOG_DATA = original
        end)

        it("defaults to page 1", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL:BuildChangelogTab(container)

            assert.equals(1, GBL._changelogCurrentPage)

            -- First child is navGroup, second is first entry's version header
            local scroll = findChild(container, "ScrollFrame")
            local firstLabel = scroll._children[2]  -- skip navGroup
            assert.truthy(firstLabel._text:find("0.15.0", 1, true))

            GBL.CHANGELOG_DATA = original
        end)

        it("Next button advances to page 2", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL:BuildChangelogTab(container)

            -- Fire the Next button's OnClick (navGroup is first child of scroll)
            local scroll = findChild(container, "ScrollFrame")
            local navGroup = scroll._children[1]
            local nextBtn = navGroup._children[3] -- prev, label, next
            nextBtn:Fire("OnClick")

            assert.equals(2, GBL._changelogCurrentPage)

            -- Scroll should now show entries from page 2 (entries 11-15)
            scroll = findChild(container, "ScrollFrame")
            local navGroup2 = scroll._children[1]  -- nav is still first
            local firstLabel = scroll._children[2]  -- first entry after nav
            assert.truthy(firstLabel._text:find("0.5.0", 1, true))

            GBL.CHANGELOG_DATA = original
        end)

        it("Prev button disabled on page 1", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            local navGroup = scroll._children[1]
            local prevBtn = navGroup._children[1]
            assert.is_true(prevBtn._disabled)
            assert.truthy(prevBtn._text:find("- Previous -"))

            GBL.CHANGELOG_DATA = original
        end)

        it("Next button disabled on last page", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL._changelogCurrentPage = 2
            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            local navGroup = scroll._children[1]
            local nextBtn = navGroup._children[3]
            assert.is_true(nextBtn._disabled)
            assert.truthy(nextBtn._text:find("- Next -"))

            GBL.CHANGELOG_DATA = original
        end)

        it("page label shows correct page count", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(25)

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            local navGroup = scroll._children[1]
            local pageLabel = navGroup._children[2]
            assert.truthy(pageLabel._text:find("Page 1 of 3"))

            GBL.CHANGELOG_DATA = original
        end)

        it("clamps page to valid range", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            -- Set page beyond range
            GBL._changelogCurrentPage = 99
            GBL:BuildChangelogTab(container)
            assert.equals(2, GBL._changelogCurrentPage)

            -- Set page below range
            container:ReleaseChildren()
            GBL._changelogCurrentPage = -5
            GBL:BuildChangelogTab(container)
            assert.equals(1, GBL._changelogCurrentPage)

            GBL.CHANGELOG_DATA = original
        end)

        it("renders only entries for the current page", function()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")

            local original = GBL.CHANGELOG_DATA
            GBL.CHANGELOG_DATA = makeEntries(15)

            GBL:BuildChangelogTab(container)

            local scroll = findChild(container, "ScrollFrame")
            local texts = {}
            for _, child in ipairs(scroll._children) do
                texts[#texts + 1] = child._text
            end
            local combined = table.concat(texts, "\n")

            -- Page 1 should have entries 1-10 (versions 0.15.0 down to 0.6.0)
            assert.truthy(combined:find("0.15.0", 1, true))
            assert.truthy(combined:find("0.6.0", 1, true))
            -- Should NOT have page 2 entries
            assert.falsy(combined:find("0.5.0", 1, true))

            GBL.CHANGELOG_DATA = original
        end)
    end)
end)
