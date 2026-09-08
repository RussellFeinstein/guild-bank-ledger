------------------------------------------------------------------------
-- GuildBankLedger — UI/Accessibility.lua
-- Colorblind-safe palettes, font scaling, triple encoding utilities.
-- Pure logic module — no AceGUI or frame creation dependency.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- Minimum / maximum font size (pt) for user scaling
local FONT_SIZE_MIN = 8
local FONT_SIZE_MAX = 24

-- Palette keys returned by GetColorblindMode()
local CB_NORMAL      = "normal"
local CB_PROTANOPIA  = "protanopia"
local CB_DEUTERANOPIA = "deuteranopia"
local CB_TRITANOPIA  = "tritanopia"

-- Map WoW CVar colorblindMode values (0-3) to palette keys
local CB_MODE_MAP = {
    [0] = CB_NORMAL,
    [1] = CB_PROTANOPIA,
    [2] = CB_DEUTERANOPIA,
    [3] = CB_TRITANOPIA,
}

------------------------------------------------------------------------
-- Color palettes — 4.5:1 contrast against dark backgrounds (~#1a1a1a)
-- Each mode adjusts hues to remain distinguishable under that deficiency.
------------------------------------------------------------------------

GBL.A11Y = {}

GBL.A11Y.PALETTES = {
    [CB_NORMAL] = {
        WITHDRAW = { r = 0.90, g = 0.30, b = 0.30 },  -- #E64D4D
        DEPOSIT  = { r = 0.30, g = 0.80, b = 0.40 },  -- #4DCC66
        MOVE     = { r = 0.30, g = 0.50, b = 0.90 },  -- #4D80E6
        ALERT    = { r = 1.00, g = 0.70, b = 0.00 },  -- #FFB300
        NEUTRAL  = { r = 0.80, g = 0.80, b = 0.80 },  -- #CCCCCC
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_PROTANOPIA] = {
        WITHDRAW = { r = 0.90, g = 0.60, b = 0.30 },  -- #E6994D  orange replaces red
        DEPOSIT  = { r = 0.30, g = 0.60, b = 0.90 },  -- #4D99E6  blue replaces green
        MOVE     = { r = 0.30, g = 0.50, b = 0.90 },  -- #4D80E6
        ALERT    = { r = 1.00, g = 0.70, b = 0.00 },  -- #FFB300
        NEUTRAL  = { r = 0.80, g = 0.80, b = 0.80 },  -- #CCCCCC
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_DEUTERANOPIA] = {
        WITHDRAW = { r = 0.90, g = 0.60, b = 0.30 },  -- #E6994D  orange replaces red
        DEPOSIT  = { r = 0.30, g = 0.60, b = 0.90 },  -- #4D99E6  blue replaces green
        MOVE     = { r = 0.60, g = 0.40, b = 0.80 },  -- #9966CC  purple replaces blue
        ALERT    = { r = 1.00, g = 0.70, b = 0.00 },  -- #FFB300
        NEUTRAL  = { r = 0.80, g = 0.80, b = 0.80 },  -- #CCCCCC
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_TRITANOPIA] = {
        WITHDRAW = { r = 0.90, g = 0.30, b = 0.30 },  -- #E64D4D  red stays
        DEPOSIT  = { r = 0.30, g = 0.80, b = 0.40 },  -- #4DCC66  green stays
        MOVE     = { r = 0.90, g = 0.60, b = 0.30 },  -- #E6994D  orange replaces blue
        ALERT    = { r = 1.00, g = 0.70, b = 0.00 },  -- #FFB300
        NEUTRAL  = { r = 0.80, g = 0.80, b = 0.80 },  -- #CCCCCC
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
}

-- High-contrast palettes — 7:1+ contrast (WCAG AAA)
GBL.A11Y.PALETTES_HC = {
    [CB_NORMAL] = {
        WITHDRAW = { r = 1.00, g = 0.20, b = 0.20 },  -- #FF3333
        DEPOSIT  = { r = 0.20, g = 1.00, b = 0.40 },  -- #33FF66
        MOVE     = { r = 0.40, g = 0.60, b = 1.00 },  -- #6699FF
        ALERT    = { r = 1.00, g = 0.85, b = 0.00 },  -- #FFD900
        NEUTRAL  = { r = 1.00, g = 1.00, b = 1.00 },  -- #FFFFFF
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_PROTANOPIA] = {
        WITHDRAW = { r = 1.00, g = 0.65, b = 0.20 },  -- #FFA633
        DEPOSIT  = { r = 0.20, g = 0.60, b = 1.00 },  -- #3399FF
        MOVE     = { r = 0.40, g = 0.60, b = 1.00 },  -- #6699FF
        ALERT    = { r = 1.00, g = 0.85, b = 0.00 },  -- #FFD900
        NEUTRAL  = { r = 1.00, g = 1.00, b = 1.00 },  -- #FFFFFF
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_DEUTERANOPIA] = {
        WITHDRAW = { r = 1.00, g = 0.65, b = 0.20 },  -- #FFA633
        DEPOSIT  = { r = 0.20, g = 0.60, b = 1.00 },  -- #3399FF
        MOVE     = { r = 0.70, g = 0.40, b = 1.00 },  -- #B366FF
        ALERT    = { r = 1.00, g = 0.85, b = 0.00 },  -- #FFD900
        NEUTRAL  = { r = 1.00, g = 1.00, b = 1.00 },  -- #FFFFFF
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
    [CB_TRITANOPIA] = {
        WITHDRAW = { r = 1.00, g = 0.20, b = 0.20 },  -- #FF3333
        DEPOSIT  = { r = 0.20, g = 1.00, b = 0.40 },  -- #33FF66
        MOVE     = { r = 1.00, g = 0.65, b = 0.20 },  -- #FFA633
        ALERT    = { r = 1.00, g = 0.85, b = 0.00 },  -- #FFD900
        NEUTRAL  = { r = 1.00, g = 1.00, b = 1.00 },  -- #FFFFFF
        FOCUS    = { r = 1.00, g = 1.00, b = 0.00 },  -- #FFFF00
    },
}

-- Shape icons for transaction types (never rely on color alone — WCAG 1.4.1)
GBL.A11Y.ICONS = {
    withdraw = "Interface\\BUTTONS\\UI-GroupLoot-Pass-Up",     -- down arrow
    deposit  = "Interface\\BUTTONS\\UI-GroupLoot-Coin-Up",     -- up arrow
    move     = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up",   -- horizontal
}

-- Text labels for transaction types (third encoding channel)
GBL.A11Y.TX_LABELS = {
    withdraw       = "Withdraw",
    deposit        = "Deposit",
    move           = "Move",
    repair         = "Repair",
    buyTab         = "Tab Purchase",
    depositSummary = "Deposit Summary",
}

------------------------------------------------------------------------
-- Colorblind mode detection
------------------------------------------------------------------------

--- Detect WoW's active colorblind mode from the CVar.
-- @return string palette key: "normal", "protanopia", "deuteranopia", or "tritanopia"
function GBL:GetColorblindMode()
    local cvar = GetCVar and GetCVar("colorblindMode")
    local mode = tonumber(cvar) or 0
    return CB_MODE_MAP[mode] or CB_NORMAL
end

------------------------------------------------------------------------
-- Color access
------------------------------------------------------------------------

--- Get the appropriate color for a given key, respecting colorblind mode
-- and high-contrast setting.
-- @param colorKey string one of: "WITHDRAW", "DEPOSIT", "MOVE", "ALERT", "NEUTRAL", "FOCUS"
-- @return table {r, g, b} color values (0-1)
function GBL:GetAccessibleColor(colorKey)
    local mode = self:GetColorblindMode()
    local useHC = self.db and self.db.profile and self.db.profile.ui
        and self.db.profile.ui.highContrast
    local palettes = useHC and self.A11Y.PALETTES_HC or self.A11Y.PALETTES
    local palette = palettes[mode] or palettes[CB_NORMAL]
    return palette[colorKey] or palette.NEUTRAL
end

------------------------------------------------------------------------
-- Font scaling
------------------------------------------------------------------------

--- Apply user font scale factor and clamp to allowed range.
-- @param baseSize number the base font size in points (default: profile fontSize)
-- @return number clamped scaled font size
function GBL:GetScaledFontSize(baseSize)
    if not baseSize then
        baseSize = (self.db and self.db.profile and self.db.profile.ui
            and self.db.profile.ui.fontSize) or 12
    end
    if baseSize < FONT_SIZE_MIN then
        return FONT_SIZE_MIN
    elseif baseSize > FONT_SIZE_MAX then
        return FONT_SIZE_MAX
    end
    return baseSize
end

--- Get the font path and scaled size from profile settings.
-- @return string fontPath, number fontSize
function GBL:GetScaledFont()
    local fontPath = (self.db and self.db.profile and self.db.profile.ui
        and self.db.profile.ui.font) or "Fonts\\FRIZQT__.TTF"
    local fontSize = self:GetScaledFontSize()
    return fontPath, fontSize
end

------------------------------------------------------------------------
-- Timestamp formatting
------------------------------------------------------------------------

--- Format a Unix timestamp for display using the profile's date format.
-- @param timestamp number Unix timestamp (from GetServerTime)
-- @return string formatted date/time string
function GBL:FormatTimestamp(timestamp)
    if not timestamp or timestamp == 0 then
        return "Unknown"
    end
    local fmt = (self.db and self.db.profile and self.db.profile.export
        and self.db.profile.export.dateFormat) or "%Y-%m-%d %H:%M"
    return date(fmt, timestamp)
end

------------------------------------------------------------------------
-- Transaction type display (triple encoding)
------------------------------------------------------------------------

--- Get the full display representation for a transaction type.
-- Returns color, icon path, and text label for triple encoding.
-- @param txType string one of "withdraw", "deposit", "move", "repair", "buyTab", "depositSummary"
-- @return table { color={r,g,b}, icon=string|nil, label=string }
function GBL:GetTxTypeDisplay(txType)
    if not txType then
        return {
            color = self:GetAccessibleColor("NEUTRAL"),
            icon = nil,
            label = "Unknown",
        }
    end

    -- Map tx type to color key
    local colorKey = "NEUTRAL"
    if txType == "withdraw" then
        colorKey = "WITHDRAW"
    elseif txType == "deposit" or txType == "depositSummary" then
        colorKey = "DEPOSIT"
    elseif txType == "move" then
        colorKey = "MOVE"
    elseif txType == "repair" or txType == "buyTab" then
        colorKey = "ALERT"
    end

    return {
        color = self:GetAccessibleColor(colorKey),
        icon = self.A11Y.ICONS[txType],
        label = self.A11Y.TX_LABELS[txType] or txType,
    }
end

------------------------------------------------------------------------
-- Keyboard navigation
------------------------------------------------------------------------

-- Focus state
GBL.A11Y.focusOrder = {}    -- ordered list of focusable widgets
GBL.A11Y.focusIndex = 0     -- 0 = no focus

--- Register a widget as focusable at a given position in tab order.
-- @param widget table AceGUI widget
-- @param order number position in focus order (1-based)
function GBL:RegisterFocusable(widget, order)
    self.A11Y.focusOrder[order] = widget
end

--- Clear the focus order (call when switching tabs).
--- Hides any drawn ring first. AceGUI pools and reuses widget frames, so a
--- ring left showing on a released widget reappears on whatever recycles
--- that frame, which reads as a focus indicator on an unrelated control.
function GBL:ClearFocusOrder()
    for _, widget in pairs(self.A11Y.focusOrder) do
        if widget and widget._focusRing then
            self:SetFocusIndicator(widget, false)
        end
    end
    self.A11Y.focusOrder = {}
    self.A11Y.focusIndex = 0
end

--- Advance focus by delta (+1 for Tab, -1 for Shift+Tab).
-- Wraps at boundaries (focus trap).
-- @param delta number +1 or -1
function GBL:AdvanceFocus(delta)
    local order = self.A11Y.focusOrder
    local count = #order
    if count == 0 then return end

    -- Remove indicator from old widget
    if self.A11Y.focusIndex > 0 and order[self.A11Y.focusIndex] then
        self:SetFocusIndicator(order[self.A11Y.focusIndex], false)
    end

    -- Advance with wrap
    local newIndex = self.A11Y.focusIndex + delta
    if newIndex < 1 then
        newIndex = count
    elseif newIndex > count then
        newIndex = 1
    end

    self.A11Y.focusIndex = newIndex

    -- Apply indicator to new widget
    if order[newIndex] then
        self:SetFocusIndicator(order[newIndex], true)
    end
end

--- Thickness of the focus ring, in pixels, per WCAG 2.4.7 focus-visible.
local FOCUS_RING_THICKNESS = 2

--- Build (once) the four edge textures that make up a widget's focus ring.
--- Returns nil for anything without a real frame: ChangelogView and several
--- specs register plain tables as focusables, and those must keep working.
local function ensureFocusRing(widget)
    if widget._focusRing then return widget._focusRing end
    local frame = widget.frame
    if not frame or not frame.CreateTexture then return nil end

    local t = FOCUS_RING_THICKNESS
    local ring = {}
    for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
        local tex = frame:CreateTexture(nil, "OVERLAY")
        if tex.SetDrawLayer then tex:SetDrawLayer("OVERLAY", 7) end
        if edge == "top" then
            tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
            tex:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
            tex:SetHeight(t)
        elseif edge == "bottom" then
            tex:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            tex:SetHeight(t)
        elseif edge == "left" then
            tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
            tex:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
            tex:SetWidth(t)
        else
            tex:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            tex:SetWidth(t)
        end
        tex:Hide()
        ring[edge] = tex
    end
    widget._focusRing = ring
    return ring
end

--- Show or hide the focus indicator on a widget.
--- Draws a 2px ring in the palette's FOCUS colour, which is what makes a
--- keyboard focus walk visible. Before this drew anything, SetFocusIndicator
--- only set widget._focused, so Tab advanced focus with nothing on screen.
--- The flag is still set: it is the state other code and the specs read.
-- @param widget table AceGUI widget
-- @param active boolean true to show, false to hide
function GBL:SetFocusIndicator(widget, active)
    if not widget then return end
    widget._focused = active

    local ring = ensureFocusRing(widget)
    if not ring then return end

    if active then
        local c = self:GetAccessibleColor("FOCUS")
        for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
            local tex = ring[edge]
            if tex.SetColorTexture then
                tex:SetColorTexture(c.r or 1, c.g or 1, c.b or 0, 1)
            end
            tex:Show()
        end
    else
        for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
            ring[edge]:Hide()
        end
    end
end

--- Restore focus to the last focused element (on frame reopen).
function GBL:RestoreFocus()
    local order = self.A11Y.focusOrder
    local idx = self.A11Y.focusIndex
    if idx > 0 and order[idx] then
        self:SetFocusIndicator(order[idx], true)
    end
end

------------------------------------------------------------------------
-- Frame position clamping
------------------------------------------------------------------------

--- Clamp a frame's position to screen bounds.
-- @param frame table WoW frame (or AceGUI frame.frame)
function GBL:ClampFrameToScreen(frame)
    if frame and frame.SetClampedToScreen then
        frame:SetClampedToScreen(true)
    end
end
