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
    "GetMoney",
    "QueryGuildBankLog",
    "QueryGuildBankTab",
    "GetGuildBankTransaction",
    "GetNumGuildBankTransactions",
    "GetGuildBankMoneyTransaction",
    "GetNumGuildBankMoneyTransactions",
    "InCombatLockdown",
    "IsInInstance",
    "GetGuildRosterInfo",
    "GetNumGuildMembers",
    "IsInGuild",
    "IsInRaid",
    "IsShiftKeyDown",
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
    "GameFontNormalLarge",
    "GameFontHighlight",
    "ChatFontNormal",
    "PlaySound",
    "GetCVar",
    "SetCVar",

    -- WoW utilities
    "C_AuctionHouse",
    "C_ChatBubbles",
    "C_Item",
    "C_Timer",
    "Item",
    "GetAddOnMetadata",
    "GetItemInfo",
    "GetRealmName",
    "GetTime",
    "debugprofilestop",
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

    -- Optional dependencies (OptionalDeps in the .toc; nil when the addon is absent)
    "Auctionator",
    "AuctionatorShoppingFrame",

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
    ".luarocks/**",  -- CI installs busted / luacheck here; not our code
    ".github/**",
}

-- Ignore unused self in Ace callback methods and underscore-prefixed vars
ignore = {
    "212/self",   -- unused argument 'self' (Ace method callbacks)
    "211/_.*",    -- unused local variables prefixed with underscore
    "212/_.*",    -- unused arguments prefixed with underscore
    "213/_.*",    -- unused loop variables prefixed with underscore
    "542",        -- empty if branch (intentional pattern for early-out comments)
}

max_line_length = 120

-- CHANGELOG_DATA holds user-facing strings on one line per entry. Length
-- enforcement on those lines would force awkward concatenations that don't
-- improve readability, so we skip the limit for this file.
files["UI/ChangelogView.lua"] = {
    max_line_length = false,
}
