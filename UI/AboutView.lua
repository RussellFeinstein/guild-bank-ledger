------------------------------------------------------------------------
-- GuildBankLedger — UI/AboutView.lua
-- About tab: addon info, donation links, credits.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the About tab inside a container.
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildAboutTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("List")
    container:AddChild(scroll)
    scroll.frame:SetPoint("BOTTOMRIGHT", container.content, "BOTTOMRIGHT", 0, 0)

    -- Header
    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    header:SetFontObject(GameFontNormalLarge)
    header:SetText("|cffffcc00GuildBankLedger|r  |cff999999v" .. (self.version or "?") .. "|r")
    scroll:AddChild(header)

    -- Author
    local author = AceGUI:Create("Label")
    author:SetFullWidth(true)
    local fontPath, fontSize = self:GetScaledFont()
    author:SetFont(fontPath, fontSize)
    author:SetText("by |cff69ccf0RexxyBear|r")
    scroll:AddChild(author)

    -- Spacer
    local spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    scroll:AddChild(spacer)

    -- Description
    local desc = AceGUI:Create("Label")
    desc:SetFullWidth(true)
    desc:SetFont(fontPath, fontSize)
    desc:SetText("Persistent guild bank transaction logging for World of Warcraft. " ..
        "Captures every transaction before WoW's 25-entry-per-tab log rolls over.")
    scroll:AddChild(desc)

    -- Spacer
    spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    scroll:AddChild(spacer)

    -- Support section
    local supportHeader = AceGUI:Create("Label")
    supportHeader:SetFullWidth(true)
    supportHeader:SetFontObject(GameFontNormalLarge)
    supportHeader:SetText("|cffffcc00Support|r")
    scroll:AddChild(supportHeader)

    local supportDesc = AceGUI:Create("Label")
    supportDesc:SetFullWidth(true)
    supportDesc:SetFont(fontPath, fontSize)
    supportDesc:SetText("If you find this addon useful, consider buying me a coffee:")
    scroll:AddChild(supportDesc)

    -- Ko-fi URL (copyable EditBox)
    local kofiBox = AceGUI:Create("EditBox")
    kofiBox:SetFullWidth(true)
    kofiBox:SetLabel("Ko-fi — select and Ctrl+C to copy")
    kofiBox:SetText("https://ko-fi.com/RexxyBear")
    kofiBox:DisableButton(true)
    kofiBox:SetCallback("OnEnterPressed", function(widget)
        widget:SetText("https://ko-fi.com/RexxyBear")
        widget:ClearFocus()
    end)
    scroll:AddChild(kofiBox)

    -- Spacer
    spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    scroll:AddChild(spacer)

    -- CurseForge URL (copyable EditBox)
    local curseBox = AceGUI:Create("EditBox")
    curseBox:SetFullWidth(true)
    curseBox:SetLabel("CurseForge — select and Ctrl+C to copy")
    curseBox:SetText("https://www.curseforge.com/wow/addons/guild-bank-ledger")
    curseBox:DisableButton(true)
    curseBox:SetCallback("OnEnterPressed", function(widget)
        widget:SetText("https://www.curseforge.com/wow/addons/guild-bank-ledger")
        widget:ClearFocus()
    end)
    scroll:AddChild(curseBox)

    -- Spacer
    spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    scroll:AddChild(spacer)

    -- Credits section
    local creditsHeader = AceGUI:Create("Label")
    creditsHeader:SetFullWidth(true)
    creditsHeader:SetFontObject(GameFontNormalLarge)
    creditsHeader:SetText("|cffffcc00Credits|r")
    scroll:AddChild(creditsHeader)

    local libs = AceGUI:Create("Label")
    libs:SetFullWidth(true)
    libs:SetFont(fontPath, fontSize)
    libs:SetText("Libraries: Ace3, LibDeflate, LibDBIcon, LibDataBroker")
    scroll:AddChild(libs)

    local license = AceGUI:Create("Label")
    license:SetFullWidth(true)
    license:SetFont(fontPath, fontSize)
    license:SetText("License: MIT")
    scroll:AddChild(license)
end
