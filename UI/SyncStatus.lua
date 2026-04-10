------------------------------------------------------------------------
-- GuildBankLedger — UI/SyncStatus.lua
-- Sync tab: enable toggle, peer list, status, audit trail
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the Sync tab inside a container.
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildSyncTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Controls row
    local controlRow = AceGUI:Create("SimpleGroup")
    controlRow:SetFullWidth(true)
    controlRow:SetLayout("Flow")
    container:AddChild(controlRow)

    -- Scrollable content area (declared early so closure captures it)
    local syncContent = AceGUI:Create("ScrollFrame")
    syncContent:SetFullWidth(true)
    syncContent:SetFullHeight(true)
    syncContent:SetLayout("Flow")

    -- Enable sync checkbox
    local enableCB = AceGUI:Create("CheckBox")
    enableCB:SetLabel("Enable Sync")
    enableCB:SetWidth(150)
    enableCB:SetValue(self:IsSyncEnabled())
    enableCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        if value then
            self:EnableSync()
        else
            self:DisableSync()
        end
        self:RenderSyncContent(syncContent)
    end)
    controlRow:AddChild(enableCB)

    -- Auto-sync checkbox
    local autoCB = AceGUI:Create("CheckBox")
    autoCB:SetLabel("Auto-sync")
    autoCB:SetWidth(150)
    autoCB:SetValue(self.db.profile.sync.autoSync)
    autoCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.sync.autoSync = value
    end)
    controlRow:AddChild(autoCB)

    -- Broadcast Hello button
    local helloBtn = AceGUI:Create("Button")
    helloBtn:SetText("Broadcast Hello")
    helloBtn:SetWidth(140)
    helloBtn:SetCallback("OnClick", function()
        self:BroadcastHello(true)
        self:RenderSyncContent(syncContent)
    end)
    controlRow:AddChild(helloBtn)

    container:AddChild(syncContent)

    self._syncContent = syncContent
    self:RenderSyncContent(syncContent)
end

------------------------------------------------------------------------
-- Content renderer
------------------------------------------------------------------------

--- Render the sync tab's scrollable content: status, peers, audit trail.
-- @param container AceGUI ScrollFrame
function GBL:RenderSyncContent(container)
    container:ReleaseChildren()

    local AceGUI = LibStub("AceGUI-3.0")

    if not self:IsSyncEnabled() then
        local disabledLabel = AceGUI:Create("Label")
        disabledLabel:SetFullWidth(true)
        disabledLabel:SetText(
            "Sync is disabled. Enable it above to share transaction data"
            .. " with other guild members running this addon.")
        container:AddChild(disabledLabel)
        return
    end

    -- Current status
    local status = self:GetSyncStatus()
    local statusText = "Idle"
    if status.sending then
        statusText = "Sending to " .. (status.sendTarget or "?")
            .. " (" .. status.sendProgress .. ")"
    elseif status.receiving then
        statusText = "Receiving from " .. (status.receiveSource or "?")
            .. " (" .. status.receiveProgress .. ")"
    end

    local statusLabel = AceGUI:Create("Label")
    statusLabel:SetFullWidth(true)
    statusLabel:SetText("|cffffcc00Status:|r " .. statusText)
    container:AddChild(statusLabel)

    -- Local transaction count
    local countLabel = AceGUI:Create("Label")
    countLabel:SetFullWidth(true)
    countLabel:SetText("|cffffcc00Local transactions:|r " .. self:GetTxCount())
    container:AddChild(countLabel)

    -- Peer list
    self:RenderPeerList(container)

    -- Audit trail
    self:RenderAuditTrail(container)
end

------------------------------------------------------------------------
-- Peer list
------------------------------------------------------------------------

--- Render the online peers section.
-- @param container AceGUI container
function GBL:RenderPeerList(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    header:SetText("|cffffcc00Online peers:|r")
    container:AddChild(header)

    local peers = self:GetSyncPeers()
    local hasPeers = false

    for name, info in pairs(peers) do
        hasPeers = true
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)

        local ago = GetServerTime() - (info.lastSeen or 0)
        local agoStr
        if ago < 60 then
            agoStr = ago .. "s ago"
        elseif ago < 3600 then
            agoStr = math.floor(ago / 60) .. "m ago"
        else
            agoStr = math.floor(ago / 3600) .. "h ago"
        end

        -- Version status indicator
        local peerVersion = info.version or "?"
        local versionTag = ""
        if peerVersion ~= self.version then
            versionTag = " |cffff6600(outdated)|r"
        end

        lbl:SetText("  " .. name
            .. " — v" .. peerVersion .. versionTag
            .. ", " .. (info.txCount or 0) .. " tx"
            .. ", seen " .. agoStr)
        container:AddChild(lbl)
    end

    if not hasPeers then
        local none = AceGUI:Create("Label")
        none:SetFullWidth(true)
        none:SetText("  No peers detected yet."
            .. " Other guild members with the addon will appear here.")
        container:AddChild(none)
    end
end

------------------------------------------------------------------------
-- Audit trail
------------------------------------------------------------------------

--- Render the recent sync log entries.
-- @param container AceGUI container
function GBL:RenderAuditTrail(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    header:SetText("|cffffcc00Sync log:|r")
    container:AddChild(header)

    local trail = self:GetAuditTrail()

    if #trail == 0 then
        local none = AceGUI:Create("Label")
        none:SetFullWidth(true)
        none:SetText("  No sync events yet.")
        container:AddChild(none)
        return
    end

    local maxDisplay = 20
    for i = 1, math.min(#trail, maxDisplay) do
        local entry = trail[i]
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        local ts = date("%H:%M:%S", entry.timestamp)
        lbl:SetText("  [" .. ts .. "] " .. entry.message)
        container:AddChild(lbl)
    end
end
