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
    "GetGuildRosterInfo",
    "GetNumGuildMembers",
    "IsInGuild",
    "IsInRaid",
    "UnitAffectingCombat",
    "Ambiguate",
    "GetFramerate",
    "GuildControlGetNumRanks",
    "GuildControlGetRankName",
    "UnitName",
    "GetNormalizedRealmName",
    "PickupGuildBankItem",
    "SplitGuildBankItem",
    "ClearCursor",
    "CursorHasItem",

    -- WoW constants and tables
    "Enum",
    "ERR_CHAT_PLAYER_NOT_FOUND_S",
    "MAX_GUILDBANK_SLOTS_PER_TAB",
    "MAX_GUILDBANK_TABS",
    "NORMAL_FONT_COLOR",
    "HIGHLIGHT_FONT_COLOR",
    "SOUNDKIT",

    -- WoW UI
    "ChatFrame_AddMessageEventFilter",
    "GameTooltip",
    "UIParent",
    "UISpecialFrames",
    "GameFontNormal",
    "GameFontNormalSmall",
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

    -- Lua extensions (WoW LuaJIT)
    "bit",

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
