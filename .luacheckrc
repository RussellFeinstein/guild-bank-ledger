std = "lua51"

-- WoW global environment
read_globals = {
    -- WoW API
    "CreateFrame",
    "GetGuildBankItemInfo",
    "GetGuildBankItemLink",
    "GetGuildBankTabInfo",
    "GetGuildInfo",
    "GetNumGuildBankTabs",
    "GetServerTime",
    "QueryGuildBankLog",
    "QueryGuildBankTab",
    "GetGuildBankTransaction",
    "GetNumGuildBankTransactions",
    "GetGuildBankMoneyTransaction",
    "GetNumGuildBankMoneyTransactions",
    "InCombatLockdown",
    "IsInGuild",
    "UnitAffectingCombat",
    "UnitName",

    -- WoW constants and tables
    "Enum",
    "MAX_GUILDBANK_SLOTS_PER_TAB",
    "MAX_GUILDBANK_TABS",
    "NORMAL_FONT_COLOR",
    "HIGHLIGHT_FONT_COLOR",
    "SOUNDKIT",

    -- WoW UI
    "GameTooltip",
    "UIParent",
    "UISpecialFrames",
    "GameFontNormal",
    "GameFontHighlight",
    "ChatFontNormal",
    "PlaySound",
    "GetCVar",
    "SetCVar",

    -- WoW utilities
    "C_Item",
    "C_Timer",
    "GetAddOnMetadata",
    "GetTime",
    "format",
    "strsplit",
    "strtrim",
    "tinsert",
    "tremove",
    "wipe",
    "date",
    "print",

    -- Ace3 / LibStub
    "LibStub",
}

-- Addon global + hookable WoW APIs
globals = {
    "GuildBankLedger",
    "GuildBankLedgerDB",
    "C_PlayerInteractionManager",
    "CloseGuildBankFrame",
}

exclude_files = {
    "Libs/**",
    "spec/**",
}

-- Ignore unused self in Ace callback methods and underscore-prefixed vars
ignore = {
    "212/self",   -- unused argument 'self' (Ace method callbacks)
    "211/_.*",    -- unused local variables prefixed with underscore
    "212/_.*",    -- unused arguments prefixed with underscore
}

max_line_length = 120
