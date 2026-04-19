------------------------------------------------------------------------
-- GuildBankLedger — UI/SyncStatus.lua
-- Sync tab: enable toggle, peer list, status, audit trail
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Format sync status text from a status snapshot.
-- @param status table From GetSyncStatus()
-- @return string Human-readable status text
function GBL:FormatSyncStatusText(status)
    local parts = {}
    if status.sending then
        table.insert(parts, "Sending to " .. (status.sendTarget or "?")
            .. " (" .. status.sendProgress .. ")")
    end
    if status.receiving then
        local progress = status.receiveProgress
        if progress == "0/0" then progress = "waiting..." end
        table.insert(parts, "Receiving from " .. (status.receiveSource or "?")
            .. " (" .. progress .. ")")
    end
    if status.combatPaused then
        table.insert(parts, "Paused (combat)")
    end
    return (#parts > 0) and table.concat(parts, " | ") or "Idle"
end

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

    -- Chat log checkbox
    local chatCB = AceGUI:Create("CheckBox")
    chatCB:SetLabel("Chat Log")
    chatCB:SetWidth(120)
    chatCB:SetValue(self.db.profile.sync.chatLog)
    chatCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.sync.chatLog = value
    end)
    controlRow:AddChild(chatCB)

    -- Broadcast Hello button
    local helloBtn = AceGUI:Create("Button")
    helloBtn:SetText("Broadcast Hello")
    helloBtn:SetWidth(140)
    helloBtn:SetCallback("OnClick", function()
        self:BroadcastHello(true)
        self:RenderSyncContent(syncContent)
    end)
    controlRow:AddChild(helloBtn)

    -- Open Sync Log button
    local logBtn = AceGUI:Create("Button")
    logBtn:SetText("Open Sync Log")
    logBtn:SetWidth(140)
    logBtn:SetCallback("OnClick", function()
        self:ShowSyncLog()
    end)
    controlRow:AddChild(logBtn)

    -- GM-only access control section
    if self:IsGuildMaster() then
        self:BuildAccessControlRow(container)
    end

    container:AddChild(syncContent)

    self._syncContent = syncContent
    self:RenderSyncContent(syncContent)
end

------------------------------------------------------------------------
-- Access control (GM only)
------------------------------------------------------------------------

--- Build the GM-only access control configuration row.
-- @param container AceGUI container
function GBL:BuildAccessControlRow(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local row = AceGUI:Create("SimpleGroup")
    row:SetFullWidth(true)
    row:SetLayout("Flow")
    container:AddChild(row)

    -- Section label
    local label = AceGUI:Create("Label")
    label:SetWidth(120)
    label:SetText("|cffffcc00Access Control|r")
    row:AddChild(label)

    -- Build rank name list for the dropdown
    local rankList = { [0] = "Unrestricted" }
    local rankOrder = { 0 }
    local numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
    for i = 1, numRanks do
        local rankName = GuildControlGetRankName and GuildControlGetRankName(i) or ("Rank " .. i)
        -- Dropdown value = rank index (1-based from API, but GetGuildInfo uses 0-based)
        -- GuildControlGetRankName(1) = GM, GuildControlGetRankName(2) = next rank, etc.
        -- GetGuildInfo rankIndex: 0 = GM, 1 = next rank, etc.
        -- So GuildControlGetRankName(i) corresponds to rankIndex (i - 1)
        local rankIndex = i - 1
        rankList[i] = rankName .. " (rank " .. rankIndex .. ")"
        rankOrder[#rankOrder + 1] = i
    end

    -- Current access control settings
    local guildData = self:GetGuildData()
    local ac = guildData and guildData.accessControl or {}
    local currentThreshold = ac.rankThreshold
    -- Map nil threshold to dropdown value 0 ("Unrestricted")
    -- Map numeric threshold to dropdown value (threshold + 1) to align with GuildControlGetRankName index
    local currentDropdownValue = currentThreshold and (currentThreshold + 1) or 0

    -- Rank threshold dropdown
    local rankDropdown = AceGUI:Create("Dropdown")
    rankDropdown:SetLabel("Full access up to rank")
    rankDropdown:SetWidth(200)
    rankDropdown:SetList(rankList, rankOrder)
    rankDropdown:SetValue(currentDropdownValue)
    row:AddChild(rankDropdown)

    -- Restricted mode dropdown
    local modeList = {
        sync_only = "Sync Only",
        own_transactions = "Own Transactions Only",
    }
    local modeOrder = { "sync_only", "own_transactions" }
    local modeDropdown = AceGUI:Create("Dropdown")
    modeDropdown:SetLabel("Restricted mode")
    modeDropdown:SetWidth(190)
    modeDropdown:SetList(modeList, modeOrder)
    modeDropdown:SetValue(ac.restrictedMode or "sync_only")
    modeDropdown:SetDisabled(currentThreshold == nil)
    row:AddChild(modeDropdown)

    -- Enable/disable mode dropdown when threshold changes
    rankDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        modeDropdown:SetDisabled(value == 0)
    end)

    -- Apply button
    local applyBtn = AceGUI:Create("Button")
    applyBtn:SetText("Apply")
    applyBtn:SetWidth(80)
    applyBtn:SetCallback("OnClick", function()
        if not guildData then return end

        local rankVal = rankDropdown:GetValue()
        local threshold = (rankVal == 0) and nil or (rankVal - 1)
        local mode = modeDropdown:GetValue()

        local playerName = self:ResolvePlayerName(UnitName("player") or "Unknown")
        guildData.accessControl = {
            rankThreshold = threshold,
            restrictedMode = threshold and mode or nil,
            configuredBy = playerName,
            configuredAt = GetServerTime(),
        }

        self:Print("Access control updated: "
            .. (threshold and ("rank " .. threshold .. ", " .. mode) or "unrestricted"))
        self:BroadcastHello(true)
        self:SendMessage("GBL_ACCESS_CONTROL_CHANGED")
    end)
    row:AddChild(applyBtn)
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
    local statusText = self:FormatSyncStatusText(status)

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

        -- Version status indicator (directional: who needs to update?)
        local peerVersion = info.version or "?"
        local versionTag = ""
        if info.outdated then
            if info.versionRelation == "local_behind" then
                versionTag = " |cff44aaff(newer — update available)|r"
            else
                versionTag = " |cffff4400(outdated — no sync)|r"
            end
        elseif peerVersion ~= self.version then
            local cmp = self:CompareSemver(self.version, peerVersion)
            if cmp < 0 then
                versionTag = " |cff44aaff(newer — update available)|r"
            else
                versionTag = " |cffff6600(outdated)|r"
            end
        end

        local seenStr = info.rosterOnly
            and "|cffa0a0a0online (no HELLO)|r"
            or ("seen " .. agoStr)

        lbl:SetText("  " .. name
            .. " — v" .. peerVersion .. versionTag
            .. ", " .. (info.txCount or 0) .. " tx"
            .. ", " .. seenStr)
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
