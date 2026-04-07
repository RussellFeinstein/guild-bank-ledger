------------------------------------------------------------------------
-- GuildBankLedger — Core.lua
-- AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local VERSION = "0.2.3"

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
            scale = 1.0, width = 800, height = 600,
            font = "Fonts\\FRIZQT__.TTF", fontSize = 12,
            colorblindMode = false, highContrast = false, lockFrame = false,
        },
        scanning = { autoScan = true, scanDelay = 0.5, notifyOnScan = true },
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
end

function GBL:OnEnable()
    -- Bank open/close detection (10.0.2+)
    if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker then
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    end

    self:RegisterEvent("GUILD_ROSTER_UPDATE")
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
    if not self:GetGuildName() then
        return
    end

    self.bankOpen = true
    self:SendMessage("GBL_BANK_OPENED")

    if self.db.profile.scanning.autoScan then
        self:StartFullScan()
    end

    -- M2: Scan transaction logs and compact old data
    self:ScanTransactions()
    local guildData = self:GetGuildData()
    if guildData then
        self:RunCompaction(guildData)
    end
end

function GBL:OnBankClosed()
    local wasScanning = self.scanInProgress
    self.bankOpen = false
    self.scanInProgress = false
    self:SendMessage("GBL_BANK_CLOSED")

    if wasScanning then
        self:CancelPendingScan()
    end
end

function GBL:IsBankOpen()
    return self.bankOpen
end

------------------------------------------------------------------------
-- Guild info
------------------------------------------------------------------------

function GBL:GetGuildName()
    local guildName = GetGuildInfo("player")
    return guildName
end

function GBL:GetGuildData()
    local guildName = self:GetGuildName()
    if not guildName then return nil end
    return self.db.global.guilds[guildName]
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

function GBL:HandleSlashCommand(input)
    input = input and strtrim(input) or ""
    local command = input:lower()

    if command == "status" then
        self:PrintStatus()
    elseif command == "scan" then
        self:ManualScan()
    elseif command == "help" or command == "" then
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
