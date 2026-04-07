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
