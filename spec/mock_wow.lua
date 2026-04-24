--- mock_wow.lua — WoW API mock environment for busted tests
-- Sets up global WoW API functions and tables that addon code expects.

local MockWoW = {}

-- Captured print output for assertions
MockWoW.prints = {}

-- Mock guild bank state
MockWoW.guildBank = {
    tabs = {},       -- array of { name, icon, isViewable, numSlots, slots = {} }
    numTabs = 0,
    queriedTabs = {},  -- tabIndex -> true after QueryGuildBankTab
    transactionLogs = {},  -- tabIndex -> array of {type, name, itemLink, count, tab1, tab2, year, month, day, hour}
    moneyTransactions = {},  -- array of {type, name, amount, year, month, day, hour}
    queriedLogs = {},  -- tabIndex -> true after QueryGuildBankLog
}

-- Mock guild state
MockWoW.guild = {
    name = nil,      -- nil = not in guild
    rankName = "Officer",
    rankIndex = 1,
    faction = nil,
    realm = nil,
    ranks = {},      -- array of rank names, 1-indexed (1 = GM, 2 = next rank, etc.)
}

-- Mock player state
MockWoW.player = { name = "TestOfficer", realm = "TestRealm" }

-- Mock group state
MockWoW.inRaid = false

-- Mock combat state
MockWoW.inCombat = false

-- Mock item info (itemID -> {classID, subclassID})
MockWoW.itemInfo = {}

-- Mock server time
MockWoW.serverTime = 1711700000

-- Mock framerate (for FPS-adaptive throttling)
MockWoW.framerate = 60

-- Pending timers (for C_Timer.After)
MockWoW.pendingTimers = {}

-- Frame event handlers
MockWoW.frames = {}

---------------------------------------------------------------------------
-- Setup / teardown
---------------------------------------------------------------------------

function MockWoW.reset()
    MockWoW.prints = {}
    MockWoW.guildBank = {
        tabs = {},
        numTabs = 0,
        queriedTabs = {},
        transactionLogs = {},
        moneyTransactions = {},
        queriedLogs = {},
    }
    MockWoW.guild = {
        name = nil,
        rankName = "Officer",
        rankIndex = 1,
        faction = nil,
        realm = nil,
        ranks = {},  -- array of rank names, 1-indexed (1 = GM, 2 = next rank, etc.)
    }
    MockWoW.player = { name = "TestOfficer", realm = "TestRealm" }
    MockWoW.inRaid = false
    MockWoW.itemInfo = {}
    MockWoW.itemNames = {}
    MockWoW.itemInfoRequested = {}
    MockWoW.guildRoster = {}
    MockWoW.serverTime = 1711700000
    MockWoW.pendingTimers = {}
    MockWoW.frames = {}
    MockWoW.cvars = {}
    MockWoW.framerate = 60
    MockWoW.chatMessageFilters = {}
    MockWoW.cursor = nil
end

---------------------------------------------------------------------------
-- Guild bank tab/slot helpers
---------------------------------------------------------------------------

--- Add a tab to the mock guild bank.
-- @param name string Tab name
-- @param icon string Icon path
-- @param isViewable boolean Whether the player can view this tab
-- @param slots table Array of { itemLink, texture, count, quality, locked, itemID } or nil for empty
function MockWoW.addTab(name, icon, isViewable, slots)
    local tab = {
        name = name or "Tab",
        icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
        isViewable = isViewable ~= false,  -- default true
        slots = slots or {},
    }
    table.insert(MockWoW.guildBank.tabs, tab)
    MockWoW.guildBank.numTabs = #MockWoW.guildBank.tabs
    return #MockWoW.guildBank.tabs
end

---------------------------------------------------------------------------
-- Install globals
---------------------------------------------------------------------------

function MockWoW.install()
    -- Enum
    _G.Enum = _G.Enum or {}
    _G.Enum.PlayerInteractionType = _G.Enum.PlayerInteractionType or {}
    _G.Enum.PlayerInteractionType.GuildBanker = 10

    -- Constants
    _G.MAX_GUILDBANK_SLOTS_PER_TAB = 98
    _G.MAX_GUILDBANK_TABS = 8
    _G.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."

    -- Chat frame message filter mock
    _G.ChatFrame_AddMessageEventFilter = function(event, func)
        MockWoW.chatMessageFilters[event] = MockWoW.chatMessageFilters[event] or {}
        table.insert(MockWoW.chatMessageFilters[event], func)
    end

    -- Print capture
    _G.print = function(...)
        local args = {}
        for i = 1, select("#", ...) do
            args[i] = tostring(select(i, ...))
        end
        table.insert(MockWoW.prints, table.concat(args, " "))
    end

    -- String utilities (WoW built-ins)
    _G.format = string.format

    _G.strsplit = function(delimiter, str, pieces)
        local results = {}
        local pattern = "([^" .. delimiter .. "]*)" .. delimiter .. "?"
        local count = 0
        for match in str:gmatch(pattern) do
            count = count + 1
            if pieces and count >= pieces then
                -- Last piece gets the rest
                local pos = 0
                for _ = 1, count - 1 do
                    pos = str:find(delimiter, pos + 1, true)
                end
                results[count] = str:sub(pos + 1)
                break
            end
            results[count] = match
        end
        return unpack(results)
    end

    _G.strtrim = function(str)
        return str:match("^%s*(.-)%s*$")
    end

    _G.tinsert = table.insert
    _G.tremove = table.remove
    _G.date = os.date

    _G.wipe = function(t)
        for k in pairs(t) do
            t[k] = nil
        end
        return t
    end

    -- Server time
    _G.GetServerTime = function()
        return MockWoW.serverTime
    end

    -- Guild info
    _G.GetGuildInfo = function(_unit)
        if MockWoW.guild.name then
            return MockWoW.guild.name, MockWoW.guild.rankName, MockWoW.guild.rankIndex, MockWoW.guild.realm
        end
        return nil
    end

    _G.IsInGuild = function()
        return MockWoW.guild.name ~= nil
    end

    _G.GuildControlGetNumRanks = function()
        return #MockWoW.guild.ranks
    end

    _G.GuildControlGetRankName = function(index)
        return MockWoW.guild.ranks[index] or ("Rank " .. index)
    end

    _G.IsInRaid = function()
        return MockWoW.inRaid
    end

    -- Guild bank tabs
    _G.GetNumGuildBankTabs = function()
        return MockWoW.guildBank.numTabs
    end

    _G.GetGuildBankTabInfo = function(tabIndex)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then
            return nil, nil, false
        end
        return tab.name, tab.icon, tab.isViewable
    end

    -- Query (marks tab as ready) — simulates the server responding by firing
    -- GUILDBANKBAGSLOTS_CHANGED synchronously. Real WoW fires this event a
    -- short time after QueryGuildBankTab; for tests we fire immediately so
    -- scanner flows don't need explicit event firing.
    _G.QueryGuildBankTab = function(tabIndex)
        MockWoW.guildBank.queriedTabs[tabIndex] = true
        if _G.__MockAce_fireEvent then
            _G.__MockAce_fireEvent("GUILDBANKBAGSLOTS_CHANGED")
        end
    end

    -- Query transaction log (marks tab log as ready)
    _G.QueryGuildBankLog = function(tab)
        MockWoW.guildBank.queriedLogs[tab] = true
    end

    -- Transaction log access
    _G.GetNumGuildBankTransactions = function(tab)
        local log = MockWoW.guildBank.transactionLogs[tab]
        return log and #log or 0
    end

    _G.GetGuildBankTransaction = function(tab, index)
        local log = MockWoW.guildBank.transactionLogs[tab]
        if not log or not log[index] then return nil end
        local tx = log[index]
        return tx.type, tx.name, tx.itemLink, tx.count,
               tx.tab1, tx.tab2, tx.year, tx.month, tx.day, tx.hour
    end

    -- Money transaction log access
    _G.GetNumGuildBankMoneyTransactions = function()
        return #MockWoW.guildBank.moneyTransactions
    end

    _G.GetGuildBankMoneyTransaction = function(index)
        local tx = MockWoW.guildBank.moneyTransactions[index]
        if not tx then return nil end
        return tx.type, tx.name, tx.amount, tx.year, tx.month, tx.day, tx.hour
    end

    -- Guild bank item access
    _G.GetGuildBankItemLink = function(tabIndex, slotIndex)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then return nil end
        local slot = tab.slots[slotIndex]
        if not slot then return nil end
        return slot.itemLink
    end

    _G.GetGuildBankItemInfo = function(tabIndex, slotIndex)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then return nil end
        local slot = tab.slots[slotIndex]
        if not slot then return nil end
        return slot.texture, slot.count, slot.locked, slot.isFiltered, slot.quality
    end

    ---------------------------------------------------------------------
    -- Cursor + guild bank movement (M-sort-2).
    --
    -- Simplified model:
    --   * MockWoW.cursor holds { itemLink, itemID, count, src = {tabIndex, slotIndex} } or nil.
    --   * PickupGuildBankItem / SplitGuildBankItem pick items up into cursor.
    --   * PickupGuildBankItem with a filled cursor drops the cursor onto the slot.
    --   * If the dest is empty → place. If dest has the same item → merge (capped for realism).
    --   * If dest has a different item → swap: cursor gets dest's old contents, src gets nothing.
    --   * ClearCursor discards cursor contents (does NOT return them to src).
    --   * Every completed mutation fires GUILDBANKBAGSLOTS_CHANGED (unless suppressed).
    ---------------------------------------------------------------------

    MockWoW.cursor = nil

    local function fireBankEvent()
        local handlers = MockWoW.frames  -- not used here
        handlers = nil
        -- Mock addon events go through MockAce; we call through to any
        -- registered AceEvent handler via the global MockAce fireEvent shim.
        if _G.__MockAce_fireEvent then
            _G.__MockAce_fireEvent("GUILDBANKBAGSLOTS_CHANGED")
        end
    end
    MockWoW.fireGuildBankBagslotsChanged = fireBankEvent

    _G.ClearCursor = function()
        MockWoW.cursor = nil
    end

    _G.CursorHasItem = function()
        return MockWoW.cursor ~= nil
    end

    local function extractItemID(itemLink)
        if not itemLink then return nil end
        local id = itemLink:match("Hitem:(%d+)")
        return id and tonumber(id) or nil
    end

    --- Pick up the full stack in (tabIndex, slotIndex) or drop cursor onto it.
    _G.PickupGuildBankItem = function(tabIndex, slotIndex)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then return end
        local slot = tab.slots[slotIndex]
        if MockWoW.cursor == nil then
            -- Pickup: grab whole slot.
            if not slot then return end
            MockWoW.cursor = {
                itemLink = slot.itemLink,
                itemID = extractItemID(slot.itemLink),
                count = slot.count,
                src = { tabIndex = tabIndex, slotIndex = slotIndex },
                texture = slot.texture,
                quality = slot.quality,
            }
            tab.slots[slotIndex] = nil
            fireBankEvent()
        else
            -- Drop: place cursor onto the slot.
            local cur = MockWoW.cursor
            if not slot then
                -- Empty destination: place.
                tab.slots[slotIndex] = {
                    itemLink = cur.itemLink,
                    texture = cur.texture,
                    count = cur.count,
                    quality = cur.quality,
                    locked = false,
                    isFiltered = false,
                    itemID = cur.itemID,
                }
                MockWoW.cursor = nil
                fireBankEvent()
            elseif extractItemID(slot.itemLink) == cur.itemID then
                -- Same item: merge. No stack cap enforced in mock — fine for planner's purposes.
                slot.count = slot.count + cur.count
                MockWoW.cursor = nil
                fireBankEvent()
            else
                -- Different item: swap. Cursor gets dest's contents; dest gets cursor's.
                local prev = slot
                tab.slots[slotIndex] = {
                    itemLink = cur.itemLink,
                    texture = cur.texture,
                    count = cur.count,
                    quality = cur.quality,
                    locked = false,
                    isFiltered = false,
                    itemID = cur.itemID,
                }
                MockWoW.cursor = {
                    itemLink = prev.itemLink,
                    itemID = extractItemID(prev.itemLink),
                    count = prev.count,
                    src = { tabIndex = tabIndex, slotIndex = slotIndex },
                    texture = prev.texture,
                    quality = prev.quality,
                }
                fireBankEvent()
            end
        end
    end

    --- Pick up a partial stack from (tabIndex, slotIndex).
    _G.SplitGuildBankItem = function(tabIndex, slotIndex, amount)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then return end
        local slot = tab.slots[slotIndex]
        if not slot or MockWoW.cursor ~= nil then return end
        amount = math.min(amount or slot.count, slot.count)
        if amount <= 0 then return end
        MockWoW.cursor = {
            itemLink = slot.itemLink,
            itemID = extractItemID(slot.itemLink),
            count = amount,
            src = { tabIndex = tabIndex, slotIndex = slotIndex },
            texture = slot.texture,
            quality = slot.quality,
        }
        slot.count = slot.count - amount
        if slot.count == 0 then
            tab.slots[slotIndex] = nil
        end
        fireBankEvent()
    end

    --- Test utility: simulate a foreign player deleting an item from a slot
    --- (e.g. another guild member withdrawing while we're sorting). Fires
    --- GUILDBANKBAGSLOTS_CHANGED as the real server would.
    function MockWoW.foreignRemoveSlot(tabIndex, slotIndex)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if tab and tab.slots[slotIndex] then
            tab.slots[slotIndex] = nil
            fireBankEvent()
        end
    end

    --- Test utility: simulate a foreign player placing an item into a slot.
    function MockWoW.foreignPlaceSlot(tabIndex, slotIndex, itemID, name, count)
        local tab = MockWoW.guildBank.tabs[tabIndex]
        if not tab then return end
        local link = "|cffffffff|Hitem:" .. itemID .. "::::::::70:::::|h[" .. (name or "Test") .. "]|h|r"
        tab.slots[slotIndex] = {
            itemLink = link, texture = "", count = count or 1,
            locked = false, isFiltered = false, itemID = itemID, quality = 1,
        }
        fireBankEvent()
    end

    -- C_Timer
    _G.C_Timer = {
        After = function(delay, callback)
            local timer = { delay = delay, callback = callback, cancelled = false }
            timer.Cancel = function(self) self.cancelled = true end
            table.insert(MockWoW.pendingTimers, timer)
            return timer
        end,
        NewTicker = function(delay, callback, iterations)
            local timer = { delay = delay, callback = callback, cancelled = false, iterations = iterations or -1 }
            timer.Cancel = function(self) self.cancelled = true end
            table.insert(MockWoW.pendingTimers, timer)
            return timer
        end,
    }

    -- Name disambiguation (retail: sender includes realm suffix)
    _G.Ambiguate = function(name, context)
        if context == "none" then
            return name:match("^([^%-]+)") or name
        end
        return name
    end

    -- Combat state
    MockWoW.inCombat = false
    _G.InCombatLockdown = function() return MockWoW.inCombat end
    _G.UnitAffectingCombat = function() return MockWoW.inCombat end

    -- Bank close (hookable)
    _G.C_PlayerInteractionManager = {
        ClearInteraction = function() end,
    }
    _G.CloseGuildBankFrame = function() end

    -- Player info
    _G.UnitName = function(unit)
        if unit == "player" then
            return MockWoW.player.name, MockWoW.player.realm
        end
        return nil
    end

    -- Realm info
    _G.GetNormalizedRealmName = function()
        return MockWoW.player.realm
    end

    _G.GetRealmName = function()
        return MockWoW.player.realm
    end

    -- Guild roster
    _G.GetNumGuildMembers = function()
        return #MockWoW.guildRoster
    end

    _G.GetGuildRosterInfo = function(index)
        local m = MockWoW.guildRoster[index]
        if not m then return nil end
        return m.name, m.rank or "Member", m.rankIndex or 1,
               m.level or 70, m.classDisplayName or "Warrior",
               m.zone or "", m.publicNote or "", m.officerNote or "",
               m.isOnline ~= false, m.status or 0, m.classFileName or "WARRIOR",
               m.achievementPoints or 0, m.achievementRank or 0
    end

    -- Item info (name/link lookup for ItemCache)
    _G.GetItemInfo = function(itemID)
        local info = MockWoW.itemNames[itemID]
        if info then
            return info.name, info.link
        end
        return nil
    end

    -- C_Item (configurable per itemID via MockWoW.itemInfo)
    _G.C_Item = {
        GetItemInfoInstant = function(itemID)
            -- Returns: itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID
            local info = MockWoW.itemInfo[itemID]
            local classID = info and info.classID or 0
            local subclassID = info and info.subclassID or 0
            return itemID, "", "", "", "", classID, subclassID
        end,
        RequestLoadItemDataByID = function(itemID)
            MockWoW.itemInfoRequested[itemID] = true
        end,
    }

    -- CreateFrame stub
    _G.CreateFrame = function(frameType, name, parent, template)
        local frame = {
            _type = frameType,
            _name = name,
            _scripts = {},
            _shown = false,
            Show = function(self) self._shown = true end,
            Hide = function(self) self._shown = false end,
            IsShown = function(self) return self._shown end,
            SetScript = function(self, event, handler)
                self._scripts[event] = handler
            end,
            GetScript = function(self, event)
                return self._scripts[event]
            end,
            SetSize = function() end,
            SetPoint = function() end,
            SetMovable = function() end,
            EnableMouse = function() end,
            RegisterForDrag = function() end,
            SetClampedToScreen = function() end,
            CreateFontString = function()
                local fs = { _text = "" }
                fs.SetFont = function() end
                fs.SetPoint = function() end
                fs.SetText = function(_, t) fs._text = t end
                fs.GetText = function() return fs._text end
                return fs
            end,
        }
        table.insert(MockWoW.frames, frame)
        return frame
    end

    -- GetAddOnMetadata
    _G.GetAddOnMetadata = function(addon, field)
        if addon == "GuildBankLedger" and field == "Version" then
            return "0.9.5"
        end
        return nil
    end

    -- GetTime (game time in seconds, fractional)
    _G.GetTime = function()
        return MockWoW.serverTime + 0.0
    end

    -- GetFramerate (for FPS-adaptive throttling)
    _G.GetFramerate = function()
        return MockWoW.framerate
    end

    -- CVars (for colorblind mode detection etc.)
    MockWoW.cvars = MockWoW.cvars or {}
    _G.GetCVar = function(name)
        return MockWoW.cvars[name]
    end
    _G.SetCVar = function(name, value)
        MockWoW.cvars[name] = value
    end

    -- UIParent stub
    _G.UIParent = _G.UIParent or {
        GetEffectiveScale = function() return 1.0 end,
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }

    -- UISpecialFrames (ESC-to-close registration)
    _G.UISpecialFrames = _G.UISpecialFrames or {}

    -- GameTooltip stub
    _G.GameTooltip = _G.GameTooltip or {
        _lines = {},
        SetOwner = function() end,
        ClearLines = function(self) self._lines = {} end,
        AddLine = function(self, text) table.insert(self._lines, text) end,
        Show = function() end,
        Hide = function() end,
        SetHyperlink = function() end,
    }

    -- Font object stubs
    local fontStub = {
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end,
        SetFont = function() end,
    }
    _G.GameFontNormal = _G.GameFontNormal or fontStub
    _G.GameFontNormalLarge = _G.GameFontNormalLarge or fontStub
    _G.GameFontHighlight = _G.GameFontHighlight or fontStub
    _G.ChatFontNormal = _G.ChatFontNormal or fontStub

    -- Color constants
    _G.NORMAL_FONT_COLOR = _G.NORMAL_FONT_COLOR or { r = 1.0, g = 0.82, b = 0.0 }
    _G.HIGHLIGHT_FONT_COLOR = _G.HIGHLIGHT_FONT_COLOR or { r = 1.0, g = 1.0, b = 1.0 }

    -- Sound stubs
    _G.PlaySound = function() end
    _G.SOUNDKIT = _G.SOUNDKIT or { IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851 }

    -- Slash command registration support
    _G.SlashCmdList = _G.SlashCmdList or {}
    _G.SLASH_GBL1 = nil
    _G.SLASH_GBL2 = nil
    _G.hash_SlashCmdList = {}
end

--- Fire all pending C_Timer.After callbacks (immediate execution for tests).
function MockWoW.fireTimers()
    local timers = MockWoW.pendingTimers
    MockWoW.pendingTimers = {}
    for _, timer in ipairs(timers) do
        if not timer.cancelled then
            timer.callback()
        end
    end
end

--- Cancel all pending timers.
function MockWoW.cancelTimers()
    for _, timer in ipairs(MockWoW.pendingTimers) do
        timer.cancelled = true
    end
    MockWoW.pendingTimers = {}
end

--- Get captured print output.
function MockWoW.getPrints()
    return MockWoW.prints
end

--- Clear captured prints.
function MockWoW.clearPrints()
    MockWoW.prints = {}
end

return MockWoW
