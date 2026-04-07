------------------------------------------------------------------------
-- accessibility_spec.lua — Tests for UI/Accessibility.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local GBL

describe("Accessibility", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("GetColorblindMode", function()
        it("returns 'normal' when CVar is 0", function()
            MockWoW.cvars["colorblindMode"] = "0"
            assert.equals("normal", GBL:GetColorblindMode())
        end)

        it("returns 'protanopia' when CVar is 1", function()
            MockWoW.cvars["colorblindMode"] = "1"
            assert.equals("protanopia", GBL:GetColorblindMode())
        end)

        it("returns 'deuteranopia' when CVar is 2", function()
            MockWoW.cvars["colorblindMode"] = "2"
            assert.equals("deuteranopia", GBL:GetColorblindMode())
        end)

        it("returns 'tritanopia' when CVar is 3", function()
            MockWoW.cvars["colorblindMode"] = "3"
            assert.equals("tritanopia", GBL:GetColorblindMode())
        end)

        it("defaults to 'normal' when CVar is nil", function()
            MockWoW.cvars["colorblindMode"] = nil
            assert.equals("normal", GBL:GetColorblindMode())
        end)
    end)

    describe("GetAccessibleColor", function()
        it("returns normal palette colors by default", function()
            MockWoW.cvars["colorblindMode"] = "0"
            local color = GBL:GetAccessibleColor("WITHDRAW")
            assert.equals(0.90, color.r)
            assert.equals(0.30, color.g)
            assert.equals(0.30, color.b)
        end)

        it("returns protanopia palette when mode is 1", function()
            MockWoW.cvars["colorblindMode"] = "1"
            local color = GBL:GetAccessibleColor("WITHDRAW")
            -- Protanopia shifts red to orange
            assert.equals(0.90, color.r)
            assert.equals(0.60, color.g)
            assert.equals(0.30, color.b)
        end)

        it("returns high-contrast palette when highContrast is true", function()
            MockWoW.cvars["colorblindMode"] = "0"
            GBL.db.profile.ui.highContrast = true
            local color = GBL:GetAccessibleColor("WITHDRAW")
            assert.equals(1.00, color.r)
            assert.equals(0.20, color.g)
            assert.equals(0.20, color.b)
        end)

        it("returns NEUTRAL for unknown color key", function()
            MockWoW.cvars["colorblindMode"] = "0"
            local color = GBL:GetAccessibleColor("NONEXISTENT")
            local neutral = GBL.A11Y.PALETTES.normal.NEUTRAL
            assert.equals(neutral.r, color.r)
            assert.equals(neutral.g, color.g)
            assert.equals(neutral.b, color.b)
        end)
    end)

    describe("GetScaledFontSize", function()
        it("clamps below minimum (8pt)", function()
            assert.equals(8, GBL:GetScaledFontSize(4))
        end)

        it("clamps above maximum (24pt)", function()
            assert.equals(24, GBL:GetScaledFontSize(30))
        end)

        it("returns the input when within range", function()
            assert.equals(14, GBL:GetScaledFontSize(14))
        end)

        it("uses profile fontSize when no argument given", function()
            GBL.db.profile.ui.fontSize = 16
            assert.equals(16, GBL:GetScaledFontSize())
        end)

        it("clamps profile fontSize when out of range", function()
            GBL.db.profile.ui.fontSize = 50
            assert.equals(24, GBL:GetScaledFontSize())
        end)
    end)

    describe("GetScaledFont", function()
        it("returns font path and scaled size from profile", function()
            GBL.db.profile.ui.font = "Fonts\\ARIALN.TTF"
            GBL.db.profile.ui.fontSize = 14
            local path, size = GBL:GetScaledFont()
            assert.equals("Fonts\\ARIALN.TTF", path)
            assert.equals(14, size)
        end)
    end)

    describe("FormatTimestamp", function()
        it("formats a valid timestamp", function()
            local result = GBL:FormatTimestamp(1711700000)
            assert.is_string(result)
            assert.is_not.equals("Unknown", result)
        end)

        it("returns 'Unknown' for zero timestamp", function()
            assert.equals("Unknown", GBL:FormatTimestamp(0))
        end)

        it("returns 'Unknown' for nil timestamp", function()
            assert.equals("Unknown", GBL:FormatTimestamp(nil))
        end)
    end)

    describe("GetTxTypeDisplay", function()
        it("returns triple (color, icon, label) for withdraw", function()
            MockWoW.cvars["colorblindMode"] = "0"
            local display = GBL:GetTxTypeDisplay("withdraw")
            assert.is_table(display.color)
            assert.is_truthy(display.color.r)
            assert.equals("Interface\\BUTTONS\\UI-GroupLoot-Pass-Up", display.icon)
            assert.equals("Withdraw", display.label)
        end)

        it("returns triple for deposit", function()
            local display = GBL:GetTxTypeDisplay("deposit")
            assert.equals("Deposit", display.label)
            assert.is_truthy(display.icon)
        end)

        it("returns triple for move", function()
            local display = GBL:GetTxTypeDisplay("move")
            assert.equals("Move", display.label)
            assert.is_truthy(display.icon)
        end)

        it("returns ALERT color for repair type", function()
            MockWoW.cvars["colorblindMode"] = "0"
            local display = GBL:GetTxTypeDisplay("repair")
            local alert = GBL.A11Y.PALETTES.normal.ALERT
            assert.equals(alert.r, display.color.r)
            assert.equals("Repair", display.label)
            assert.is_nil(display.icon)  -- no shape icon for repair
        end)

        it("returns NEUTRAL and 'Unknown' for nil type", function()
            local display = GBL:GetTxTypeDisplay(nil)
            assert.equals("Unknown", display.label)
            assert.is_nil(display.icon)
        end)

        it("returns the raw type string as label for unrecognized types", function()
            local display = GBL:GetTxTypeDisplay("customType")
            assert.equals("customType", display.label)
        end)
    end)

    describe("A11Y constants", function()
        it("has icons for withdraw, deposit, and move", function()
            assert.is_string(GBL.A11Y.ICONS.withdraw)
            assert.is_string(GBL.A11Y.ICONS.deposit)
            assert.is_string(GBL.A11Y.ICONS.move)
        end)

        it("has text labels for all standard tx types", function()
            local expected = { "withdraw", "deposit", "move", "repair", "buyTab", "depositSummary" }
            for _, txType in ipairs(expected) do
                assert.is_string(GBL.A11Y.TX_LABELS[txType],
                    "Missing TX_LABEL for type: " .. txType)
            end
        end)

        it("has 4 palette variants", function()
            assert.is_table(GBL.A11Y.PALETTES.normal)
            assert.is_table(GBL.A11Y.PALETTES.protanopia)
            assert.is_table(GBL.A11Y.PALETTES.deuteranopia)
            assert.is_table(GBL.A11Y.PALETTES.tritanopia)
        end)

        it("has 4 high-contrast palette variants", function()
            assert.is_table(GBL.A11Y.PALETTES_HC.normal)
            assert.is_table(GBL.A11Y.PALETTES_HC.protanopia)
            assert.is_table(GBL.A11Y.PALETTES_HC.deuteranopia)
            assert.is_table(GBL.A11Y.PALETTES_HC.tritanopia)
        end)
    end)

    describe("Keyboard navigation", function()
        local w1, w2, w3

        before_each(function()
            GBL:ClearFocusOrder()
            w1 = { _focused = false }
            w2 = { _focused = false }
            w3 = { _focused = false }
            GBL:RegisterFocusable(w1, 1)
            GBL:RegisterFocusable(w2, 2)
            GBL:RegisterFocusable(w3, 3)
        end)

        it("advances focus forward with Tab", function()
            GBL:AdvanceFocus(1)
            assert.is_true(w1._focused)
            assert.is_false(w2._focused)
        end)

        it("advances through multiple elements", function()
            GBL:AdvanceFocus(1)  -- focus w1
            GBL:AdvanceFocus(1)  -- focus w2
            assert.is_false(w1._focused)
            assert.is_true(w2._focused)
        end)

        it("wraps forward from last to first", function()
            GBL.A11Y.focusIndex = 3
            GBL:AdvanceFocus(1)
            assert.equals(1, GBL.A11Y.focusIndex)
            assert.is_true(w1._focused)
        end)

        it("wraps backward from first to last", function()
            GBL.A11Y.focusIndex = 1
            GBL:AdvanceFocus(-1)
            assert.equals(3, GBL.A11Y.focusIndex)
            assert.is_true(w3._focused)
        end)

        it("clears focus order", function()
            GBL:AdvanceFocus(1)
            GBL:ClearFocusOrder()
            assert.equals(0, GBL.A11Y.focusIndex)
            assert.equals(0, #GBL.A11Y.focusOrder)
        end)

        it("sets focus indicator on widget", function()
            GBL:SetFocusIndicator(w1, true)
            assert.is_true(w1._focused)
            GBL:SetFocusIndicator(w1, false)
            assert.is_false(w1._focused)
        end)

        it("restores focus to last focused element", function()
            GBL:AdvanceFocus(1)
            GBL:AdvanceFocus(1)
            -- w2 is focused
            GBL:SetFocusIndicator(w2, false)  -- simulate close
            GBL:RestoreFocus()
            assert.is_true(w2._focused)
        end)
    end)

    describe("ClampFrameToScreen", function()
        it("calls SetClampedToScreen when available", function()
            local clamped = false
            local frame = {
                SetClampedToScreen = function(_, val) clamped = val end,
            }
            GBL:ClampFrameToScreen(frame)
            assert.is_true(clamped)
        end)

        it("does not error on nil frame", function()
            assert.has_no.errors(function()
                GBL:ClampFrameToScreen(nil)
            end)
        end)
    end)
end)
