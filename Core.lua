------------------------------------------------------------------------
-- GuildBankLedger — Core.lua
-- AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local VERSION = "0.4.0"

local GBL = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0"
)

-- AceDB defaults
local defaults = {
    global = {
        guilds = {
            ["*"] = {
                transactions = {},
                moneyTransactions = {},
                dailySummaries = {},
                weeklySummaries = {},
                snapshots = {},
                playerStats = {
                    ["*"] = {
                        withdrawals = {},
                        deposits = {},
                        totalWithdrawCount = 0,
                        totalDepositCount = 0,
                        moneyWithdrawn = 0,
                        moneyDeposited = 0,
                        firstSeen = 0,
                        lastSeen = 0,
                    },
                },
                teams = {},
                altLinks = {},
                stockAlerts = {},
                seenTxHashes = {},
                syncState = { lastSyncTimestamp = 0, syncVersion = 0, peers = {} },
                schemaVersion = 1,
            },
        },
    },
    profile = {
        minimap = { hide = false },
        ui = {
            scale = 1.0, width = 900, height = 600,
            font = "Fonts\\FRIZQT__.TTF", fontSize = 12,
            colorblindMode = false, highContrast = false, lockFrame = false,
            openOnBankOpen = true,
            autoOpenMaxRank = 2,
        },
        scanning = {
            autoScan = true, scanDelay = 0.5, notifyOnScan = true,
            thankYouMessage = "Thanks for helping run the guild!",
            lockBankWhileScanning = false,
        },
        alerts = { enabled = true, chatNotify = true, soundNotify = true },
        export = { delimiter = ",", includeHeaders = true, dateFormat = "%Y-%m-%d %H:%M" },
        sync = { enabled = false, autoSync = true },
        filters = { defaultDays = 7, defaultCategory = "ALL" },
    },
}

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function GBL:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildBankLedgerDB", defaults, true)
    self.bankOpen = false
    self.scanInProgress = false
    self.lastScanTime = 0
    self.version = VERSION

    self:RegisterChatCommand("gbl", "HandleSlashCommand")
    self:RegisterChatCommand("guildbankledger", "HandleSlashCommand")

    -- Minimap button (M3)
    self:SetupMinimapButton()
end

function GBL:OnEnable()
    -- Bank open/close detection (10.0.2+)
    if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker then
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    end

    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:InstallBankCloseHook()
end

function GBL:OnDisable()
    self:UnregisterAllEvents()
    if self.bankOpen then
        self:OnBankClosed()
    end
end

------------------------------------------------------------------------
-- Event handlers
------------------------------------------------------------------------

function GBL:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_event, interactionType)
    if interactionType ~= Enum.PlayerInteractionType.GuildBanker then
        return
    end
    self:OnBankOpened()
end

function GBL:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(_event, interactionType)
    if interactionType ~= Enum.PlayerInteractionType.GuildBanker then
        return
    end
    self:OnBankClosed()
end

function GBL:GUILD_ROSTER_UPDATE()
    -- Placeholder for future roster-change handling
end

------------------------------------------------------------------------
-- Bank open/close
------------------------------------------------------------------------

function GBL:OnBankOpened()
    self.bankOpen = true

    -- GetGuildInfo("player") can return nil if the roster hasn't loaded yet.
    -- Retry a few times before giving up.
    self:WaitForGuildName(function()
        if not self.bankOpen then return end
        self:SendMessage("GBL_BANK_OPENED")

        if self.db.profile.ui.openOnBankOpen and self:IsOfficerRank() then
            self:CreateMainFrame()
            local shown = self.mainFrame.frame and self.mainFrame.frame:IsShown()
            if not shown then
                self.mainFrame:Show()
                self:RefreshUI()
                self._autoOpenedFrame = true
            end
        end

        if self.db.profile.scanning.autoScan then
            self:StartFullScan()
        end

        -- Backfill tab names on old records while bank is open
        self:BackfillTabNames()

        -- Defer transaction scan and compaction so the bank frame renders first
        C_Timer.After(0, function()
            if not self.bankOpen then return end
            local newCount = self:ScanTransactions()
            self:PrintScanResult(newCount)
            C_Timer.After(0, function()
                if not self.bankOpen then return end
                local guildData = self:GetGuildData()
                if guildData then
                    self:RunCompaction(guildData)
                end
            end)
        end)
    end)
end

--- Wait for GetGuildInfo to return a guild name, then call the callback.
-- Retries up to 10 times at 0.5s intervals. Bails if bank is closed.
-- @param callback function Called once guild name is available
function GBL:WaitForGuildName(callback)
    local maxRetries = 10
    local retryDelay = 0.5

    local function tryResolve(attempt)
        if not self.bankOpen then return end
        if self:GetGuildName() then
            callback()
            return
        end
        if attempt >= maxRetries then
            self:Print("Could not determine guild name. Try reopening the bank.")
            return
        end
        C_Timer.After(retryDelay, function()
            tryResolve(attempt + 1)
        end)
    end

    tryResolve(1)
end

function GBL:OnBankClosed()
    local wasScanning = self.scanInProgress
    self.bankOpen = false
    self.scanInProgress = false
    self:SendMessage("GBL_BANK_CLOSED")

    if wasScanning then
        self:CancelPendingScan()
    end

    -- Close the ledger window if it was auto-opened with the bank
    if self._autoOpenedFrame and self.mainFrame then
        self.mainFrame:Hide()
        self._autoOpenedFrame = nil
    end
end

function GBL:IsBankOpen()
    return self.bankOpen
end

------------------------------------------------------------------------
-- Bank close lock (prevent manual close during scan)
------------------------------------------------------------------------

--- Check whether a manual bank close should be blocked.
-- Returns true only if: lock is on, scan is running, and NOT in combat.
-- @return boolean true if the close should be blocked
function GBL:ShouldBlockBankClose()
    if not self.db.profile.scanning.lockBankWhileScanning then
        return false
    end
    if not self.scanInProgress then
        return false
    end
    -- Never block if combat or other forced close
    if InCombatLockdown and InCombatLockdown() then
        return false
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return false
    end
    return true
end

--- Install a pre-hook on the guild bank close function.
-- Blocks manual close while scanning if the lock setting is enabled.
function GBL:InstallBankCloseHook()
    if self._bankCloseHooked then return end
    self._bankCloseHooked = true

    -- Hook C_PlayerInteractionManager.ClearInteraction (10.0.2+)
    if C_PlayerInteractionManager and C_PlayerInteractionManager.ClearInteraction then
        local originalClear = C_PlayerInteractionManager.ClearInteraction
        C_PlayerInteractionManager.ClearInteraction = function(interactionType, ...)
            if interactionType == Enum.PlayerInteractionType.GuildBanker
                and GBL:ShouldBlockBankClose() then
                GBL:Print("Scan in progress — bank close blocked. Uncheck 'Lock while scanning' to disable.")
                return
            end
            return originalClear(interactionType, ...)
        end
    end

    -- Also hook CloseGuildBankFrame if it exists (older API / addons that call it)
    if CloseGuildBankFrame then
        local originalClose = CloseGuildBankFrame
        _G.CloseGuildBankFrame = function(...)
            if GBL:ShouldBlockBankClose() then
                GBL:Print("Scan in progress — bank close blocked.")
                return
            end
            return originalClose(...)
        end
    end
end

------------------------------------------------------------------------
-- Guild info
------------------------------------------------------------------------

function GBL:GetGuildName()
    local guildName = GetGuildInfo("player")
    if guildName then
        self._cachedGuildName = guildName
    end
    return self._cachedGuildName
end

--- Check if the player's guild rank is at or above the officer threshold.
-- GetGuildInfo returns rankIndex (0 = GM, 1 = next rank, etc).
-- Lower index = higher rank.
-- @return boolean true if player rank <= autoOpenMaxRank
function GBL:IsOfficerRank()
    local _, _, rankIndex = GetGuildInfo("player")
    if not rankIndex then return false end
    local threshold = self.db.profile.ui.autoOpenMaxRank or 2
    return rankIndex <= threshold
end

function GBL:GetGuildData()
    local guildName = self:GetGuildName()
    if not guildName then return nil end
    return self.db.global.guilds[guildName]
end

------------------------------------------------------------------------
-- Tab name backfill
------------------------------------------------------------------------

--- Fill in tabName on old transaction records that only have tab numbers.
-- Only works while the bank is open (GetGuildBankTabInfo available).
function GBL:BackfillTabNames()
    local guildData = self:GetGuildData()
    if not guildData then return end

    for _, tx in ipairs(guildData.transactions) do
        if tx.tab and not tx.tabName then
            tx.tabName = self:GetTabName(tx.tab)
        end
        if tx.destTab and not tx.destTabName then
            tx.destTabName = self:GetTabName(tx.destTab)
        end
    end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

function GBL:HandleSlashCommand(input)
    input = input and strtrim(input) or ""
    local command = input:lower()

    if command == "" or command == "show" then
        self:ToggleMainFrame()
    elseif command == "status" then
        self:PrintStatus()
    elseif command == "scan" then
        self:ManualScan()
    elseif command == "help" then
        self:PrintHelp()
    else
        self:Print("Unknown command: " .. command .. ". Type /gbl help for usage.")
    end
end

function GBL:PrintStatus()
    local guildName = self:GetGuildName() or "Not in a guild"
    local txCount = 0
    local moneyCount = 0
    local guildData = self:GetGuildData()
    if guildData then
        txCount = #guildData.transactions
        moneyCount = #guildData.moneyTransactions
    end

    local lastScan = "Never"
    if self.lastScanTime > 0 then
        lastScan = date("%Y-%m-%d %H:%M:%S", self.lastScanTime)
    end

    self:Print("|cffffcc00GuildBankLedger v" .. self.version .. "|r")
    self:Print("Guild: " .. guildName)
    self:Print("Transactions: " .. txCount)
    self:Print("Money transactions: " .. moneyCount)
    self:Print("Last scan: " .. lastScan)
    self:Print("Bank open: " .. (self.bankOpen and "Yes" or "No"))
end

function GBL:PrintHelp()
    self:Print("|cffffcc00GuildBankLedger v" .. self.version .. " — Commands:|r")
    self:Print("  /gbl         — Toggle the ledger window")
    self:Print("  /gbl show    — Toggle the ledger window")
    self:Print("  /gbl status  — Show addon status")
    self:Print("  /gbl scan    — Manually scan the guild bank")
    self:Print("  /gbl help    — Show this help message")
end

function GBL:ManualScan()
    if not self:IsBankOpen() then
        self:Print("Guild bank is not open.")
        return
    end
    if self.scanInProgress then
        self:Print("Scan already in progress.")
        return
    end
    self:StartFullScan()
end

------------------------------------------------------------------------
-- Scan result message
------------------------------------------------------------------------

--- Print the transaction scan result with optional thank-you message.
-- Only prints when new transactions were found.
-- @param newCount number Count of newly recorded transactions
function GBL:PrintScanResult(newCount)
    if not newCount or newCount == 0 then return end

    local guildData = self:GetGuildData()
    local total = 0
    if guildData then
        total = #guildData.transactions + #guildData.moneyTransactions
    end

    local result = format("Recorded %d new transaction%s.",
        newCount, newCount == 1 and "" or "s")

    -- Append thank-you message if configured
    local thankYou = self.db.profile.scanning.thankYouMessage
    if thankYou and thankYou ~= "" then
        local player = UnitName("player") or "you"
        thankYou = thankYou:gsub("{count}", tostring(newCount))
        thankYou = thankYou:gsub("{total}", tostring(total))
        thankYou = thankYou:gsub("{player}", player)
        self:Print(result .. " " .. thankYou)
    else
        self:Print(result)
    end
end
